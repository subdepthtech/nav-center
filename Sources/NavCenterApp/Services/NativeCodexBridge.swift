import Foundation
import Darwin
import CoreFoundation
import NavCenterCore

final class NativeCodexBridge {
    private static let bridgesLock = NSLock()
    private static var bridges: [String: NativeCodexBridge] = [:]

    static func shared(repoRoot: URL) -> NativeCodexBridge {
        bridgesLock.lock()
        defer { bridgesLock.unlock() }
        let key = repoRoot.standardizedFileURL.path
        if let bridge = bridges[key] {
            return bridge
        }
        let bridge = NativeCodexBridge(repoRoot: repoRoot)
        bridges[key] = bridge
        return bridge
    }

    private let repoRoot: URL
    private let injectedCommand: String?
    private let probeConfiguration: ToolProbeConfiguration?
    private let args = ["app-server", "--listen", "stdio://"]
    private let sessionLock = NSRecursiveLock()
    private let writeLock = NSLock()
    private let lock = NSLock()
    private var process: CodexOwnedProcess?
    private var stdoutBuffer = Data()
    private var startingThreadID: String?
    private var cancellationRequested = false
    private let turnTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let shutdownGrace: TimeInterval
    private var stderrTail = ""
    private var nextID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var activeTurns: [String: ActiveTurn] = [:]
    private var queuedTurnNotifications: [String: [(method: String, params: [String: Any])]] = [:]
    private var queuedApprovalRequests: [String: [(id: CodexRequestID, params: [String: Any])]] = [:]
    private var activatingTurns = Set<String>()
    private var initialized: [String: Any] = [:]

    init(repoRoot: URL, command: String? = nil, probeConfiguration: ToolProbeConfiguration? = nil, turnTimeout: TimeInterval = 600, requestTimeout: TimeInterval = 15, shutdownGrace: TimeInterval = 1) {
        self.repoRoot = repoRoot
        self.injectedCommand = command
        self.probeConfiguration = probeConfiguration
        self.turnTimeout = turnTimeout
        self.requestTimeout = requestTimeout
        self.shutdownGrace = shutdownGrace
    }

    func cancelCurrentTurn() {
        lock.lock()
        cancellationRequested = true
        lock.unlock()
    }

    func shutdown() {
        cancelCurrentTurn()
        stopServer()
    }


    func status() throws -> CodexStatusResponse {
        try withSessionLock {
            try statusUnlocked()
        }
    }

    private func statusUnlocked() throws -> CodexStatusResponse {
        try start()
        let account = try request("account/read", params: ["refreshToken": false])
        lock.lock(); let initialized = self.initialized; lock.unlock()
        return CodexStatusResponse(
            ok: true,
            userAgent: Self.string(initialized["userAgent"]),
            codexHome: Self.string(initialized["codexHome"]),
            account: Self.codexAccount(account["account"]),
            requiresOpenaiAuth: Self.bool(account["requiresOpenaiAuth"]),
            authMethod: Self.codexAccount(account["account"])?.type,
            localOnly: true
        )
    }

    func loginStart(type: String) throws -> CodexLoginStartResponse {
        try withSessionLock {
            try start()
            let result = try request("account/login/start", params: ["type": type])
            return CodexLoginStartResponse(
                type: Self.string(result["type"]),
                loginId: Self.string(result["loginId"]).nonEmpty,
                authUrl: Self.string(result["authUrl"]).nonEmpty,
                verificationUrl: Self.string(result["verificationUrl"]).nonEmpty,
                userCode: Self.string(result["userCode"]).nonEmpty
            )
        }
    }

    func runPackageChat(_ payload: CodexChatRequest) throws -> CodexChatResponse {
        try withSessionLock {
            try runPackageChatUnlocked(payload)
        }
    }

    private func runPackageChatUnlocked(_ payload: CodexChatRequest) throws -> CodexChatResponse {
        lock.lock(); cancellationRequested = false; lock.unlock()
        try start()
        let packageName = try PathSafetyBridge.normalizePackageName(payload.packageName)
        let resolved = try NavCenterCore.PathSafety.resolvePackage(root: repoRoot, packageName: packageName)
        try NavCenterCore.PathSafety.assertExistingRegularFile(resolved.packageURL.appendingPathComponent("posting.md"), inside: resolved.packageURL, label: "posting.md")
        let editBroker = payload.allowEdits ? try CodexPackageEditBroker(packageURL: resolved.packageURL, workspaceRoot: repoRoot) : nil
        return try withEditBrokerCleanup(editBroker) {
            let workingDirectory = editBroker?.stagingURL ?? repoRoot
            let message = payload.message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                throw DashboardAPIError.serverUnavailable("Codex chat requires a message.")
            }
            if payload.allowEdits && !payload.confirmed {
                throw DashboardAPIError.serverUnavailable("Codex markdown edits require explicit confirmation.")
            }
            let account = try statusUnlocked()
            guard account.account != nil else {
                throw DashboardAPIError.serverUnavailable("Codex app-server is not signed in. Start sign-in before chatting.")
            }

            let threadID: String
            if let previous = payload.threadId, !previous.isEmpty {
                let resumed = try request("thread/resume", params: ["threadId": previous, "cwd": workingDirectory.path])
                guard Self.string((resumed["thread"] as? [String: Any])?["id"]) == previous else {
                    throw DashboardAPIError.serverUnavailable("Codex could not resume the selected conversation.")
                }
                threadID = previous
            } else { threadID = try createThread(cwd: workingDirectory) }
            let prompt = Self.buildPrompt(
                packageName: packageName,
                message: message,
                allowEdits: payload.allowEdits,
                repoRoot: repoRoot,
                workingDirectory: workingDirectory
            )
            let sandboxPolicy: [String: Any] = payload.allowEdits
                ? Self.workspaceWriteSandboxPolicy(editRoot: workingDirectory)
                : ["type": "readOnly", "networkAccess": false]
            lock.lock(); startingThreadID = threadID; lock.unlock()
            defer { lock.lock(); startingThreadID = nil; lock.unlock() }
            let turn = try request("turn/start", params: [
                "threadId": threadID,
                "input": [["type": "text", "text": prompt, "text_elements": []]],
                "cwd": workingDirectory.path,
                "approvalPolicy": "on-request",
                "approvalsReviewer": "user",
                "sandboxPolicy": sandboxPolicy
            ])
            let turnInfo = turn["turn"] as? [String: Any] ?? [:]
            let turnID = Self.string(turnInfo["id"])
            guard !turnID.isEmpty else {
                throw DashboardAPIError.serverUnavailable("Codex app-server did not return a turn id.")
            }
            lock.lock()
            activeTurns[turnID] = ActiveTurn(
                threadID: threadID,
                allowEdits: payload.allowEdits,
                editRoot: editBroker?.stagingURL
            )
            activatingTurns.insert(turnID)
            lock.unlock()
            activateTurn(turnID)
            defer {
                lock.lock()
                activeTurns.removeValue(forKey: turnID)
                activatingTurns.remove(turnID)
                queuedTurnNotifications.removeValue(forKey: turnID)
                queuedApprovalRequests.removeValue(forKey: turnID)
                lock.unlock()
            }

            let completed = try waitForTurn(turnID, timeout: turnTimeout)
            // No server or child may retain write authority over staging while it
            // is validated, copied back, or removed, even after a reported completion.
            if editBroker != nil || completed.status != "completed" { stopServer() }
            if completed.status == "completed", let editBroker {
                _ = try editBroker.applyValidatedChanges()
            }
            let text = completed.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return CodexChatResponse(
                ok: completed.status == "completed",
                threadId: threadID,
                turnId: turnID,
                status: completed.status,
                message: text,
                diff: completed.diff,
                account: account.account
            )
        }
    }

    private func withEditBrokerCleanup<T>(
        _ editBroker: CodexPackageEditBroker?,
        operation: () throws -> T
    ) throws -> T {
        do {
            let value = try operation()
            try editBroker?.cleanup()
            return value
        } catch let operationError {
            stopServer()
            do {
                try editBroker?.cleanup()
            } catch let cleanupError {
                throw DashboardAPIError.serverUnavailable(
                    "Codex request failed and staging cleanup also failed: \(operationError.localizedDescription); \(cleanupError.localizedDescription)"
                )
            }
            throw operationError
        }
    }

    private func createThread(cwd: URL) throws -> String {
        let result = try request("thread/start", params: ["cwd": cwd.path])
        let thread = result["thread"] as? [String: Any] ?? [:]
        let id = Self.string(thread["id"])
        if id.isEmpty {
            throw DashboardAPIError.serverUnavailable("Codex app-server did not return a thread id.")
        }
        return id
    }

    private func start() throws {
        lock.lock(); let running = process?.isRunning == true; lock.unlock()
        if running { return }
        resetTerminatedProcess()
        let launch = try codexLaunch()
        lock.lock()
        stdoutBuffer.removeAll(); stderrTail = ""; initialized = [:]
        queuedTurnNotifications.removeAll(); queuedApprovalRequests.removeAll(); activatingTurns.removeAll()
        lock.unlock()
        let process = CodexOwnedProcess()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.currentDirectoryURL = repoRoot
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            guard let process else { return }
            self?.handleStdout(Data(handle.availableData), from: process)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let text = String(data: handle.availableData, encoding: .utf8) ?? ""
            guard let self, let process else { return }
            self.lock.lock()
            if self.process === process { self.stderrTail = String((self.stderrTail + text).suffix(4_000)) }
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] process in
            self?.handleProcessTermination(process)
        }
        lock.lock(); self.process = process; lock.unlock()
        do {
            try process.run()
            let initialized = try request("initialize", params: [
                "clientInfo": ["name": "nav-center", "title": "Nav Center", "version": FeedbackDiagnostics.buildVersion]
            ])
            lock.lock(); self.initialized = initialized; lock.unlock()
            try writeJSON(["method": "initialized", "params": [:]])
        } catch {
            stopServer()
            throw DashboardAPIError.serverUnavailable("Codex could not complete startup. Check the Codex installation and supported app-server version. \(error.localizedDescription)")
        }
    }

    private func request(_ method: String, params: [String: Any], timeout: TimeInterval? = nil) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout ?? requestTimeout)
        let id = nextRequestID()
        let pending = PendingRequest()
        lock.lock()
        self.pending[id] = pending
        lock.unlock()
        do {
            try writeJSON(["id": id, "method": method, "params": params], deadline: deadline)
        } catch {
            lock.lock()
            self.pending.removeValue(forKey: id)
            lock.unlock()
            throw error
        }
        var received = false
        while Date() < deadline {
            if pending.semaphore.wait(timeout: .now() + min(0.02, max(0, deadline.timeIntervalSinceNow))) == .success { received = true; break }
            lock.lock(); let cancelled = cancellationRequested; lock.unlock()
            if cancelled && method != "turn/interrupt" { break }
        }
        guard received else {
            lock.lock()
            self.pending.removeValue(forKey: id)
            let stderr = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            lock.unlock()
            let detail = stderr.isEmpty ? "" : " Last stderr: \(stderr)"
            throw DashboardAPIError.serverUnavailable("Codex app-server request timed out: \(method).\(detail)")
        }
        if let error = pending.error {
            throw DashboardAPIError.serverUnavailable(error)
        }
        return pending.result ?? [:]
    }

    private func waitForTurn(_ turnID: String, timeout: TimeInterval) throws -> ActiveTurn {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock()
            let turn = activeTurns[turnID]
            let cancelled = cancellationRequested
            lock.unlock()
            if cancelled || Date() >= deadline {
                if let turn {
                    _ = try? request("turn/interrupt", params: ["threadId": turn.threadID, "turnId": turnID], timeout: shutdownGrace)
                }
                // Terminate this owned transport after interruption so it cannot retain a stale turn.
                // Staging is disposed by the outer scope only after this bounded stop finishes.
                stopServer()
                throw DashboardAPIError.serverUnavailable(cancelled ? "Codex turn cancelled." : "Codex turn timed out.")
            }
            if let turn, turn.completed { return turn }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func stopServer() {
        lock.lock(); let owned = process; lock.unlock()
        guard let owned else {
            lock.lock(); cancellationRequested = false; lock.unlock()
            return
        }
        if owned.isRunning {
            owned.terminate()
            let deadline = Date().addingTimeInterval(shutdownGrace)
            while owned.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if owned.isRunning { owned.forceKill() }
            owned.waitUntilExit()
        }
        (owned.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (owned.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        try? (owned.standardInput as? Pipe)?.fileHandleForWriting.close()
        if process === owned { process = nil; initialized = [:] }
        cancellationRequested = false
        lock.unlock()
    }

    private func handleStdout(_ data: Data, from source: CodexOwnedProcess) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard process === source else { lock.unlock(); return }
        stdoutBuffer.append(data)
        var frames: [Data] = []
        while let newline = stdoutBuffer.firstIndex(of: 10) {
            frames.append(Data(stdoutBuffer[..<newline]))
            stdoutBuffer.removeSubrange(...newline)
        }
        let oversized = stdoutBuffer.count > 4 * 1024 * 1024 || frames.contains { $0.count > 4 * 1024 * 1024 }
        lock.unlock()
        if oversized { protocolFailure("Codex JSONL frame exceeds the size limit."); return }
        for frame in frames where !frame.isEmpty {
            guard let line = String(data: frame, encoding: .utf8) else { protocolFailure("Codex sent invalid UTF-8."); return }
            handleLine(line)
        }
    }

    private func protocolFailure(_ reason: String) {
        lock.lock()
        let requests = Array(pending.values); pending.removeAll()
        for id in activeTurns.keys {
            activeTurns[id]?.status = "failed"; activeTurns[id]?.message = reason; activeTurns[id]?.completed = true
        }
        let owned = process
        lock.unlock()
        for request in requests { request.error = reason; request.semaphore.signal() }
        if owned?.isRunning == true { owned?.terminate() }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            protocolFailure("Codex sent malformed JSONL.")
            return
        }
        if let requestID = CodexRequestID(object["id"]), case .integer(let id) = requestID, object["method"] == nil {
            lock.lock()
            let pending = pending.removeValue(forKey: id)
            lock.unlock()
            if let error = object["error"] as? [String: Any] {
                pending?.error = Self.string(error["message"])
            } else {
                pending?.result = object["result"] as? [String: Any] ?? [:]
            }
            pending?.semaphore.signal()
            return
        }
        if let id = CodexRequestID(object["id"]) {
            switch Self.string(object["method"]) {
            case "item/fileChange/requestApproval":
                let params = object["params"] as? [String: Any] ?? [:]
                let turnID = Self.string(params["turnId"])
                lock.lock()
                let shouldQueue = Self.shouldQueueApproval(
                    turnID: turnID,
                    hasActiveTurn: activeTurns[turnID] != nil,
                    isActivating: activatingTurns.contains(turnID)
                ) && (Self.string(params["threadId"]) == startingThreadID || activeTurns[turnID] != nil) && queuedApprovalRequests.values.reduce(0, { $0 + $1.count }) < 128
                if shouldQueue {
                    queuedApprovalRequests[turnID, default: []].append((id: id, params: params))
                }
                lock.unlock()
                if !shouldQueue {
                    handleApprovalRequest(id: id, params: params)
                }
                return
            case "item/commandExecution/requestApproval":
                try? writeJSON(["id": id.jsonValue, "result": ["decision": "decline"]])
                return
            case "item/permissions/requestApproval":
                try? writeJSON([
                    "id": id.jsonValue,
                    "result": [
                        "permissions": [:],
                        "scope": "turn",
                        "strictAutoReview": true
                    ]
                ])
                return
            default:
                break
            }
        }
        if object["id"] != nil && CodexRequestID(object["id"]) == nil { protocolFailure("Codex sent an unsupported request ID."); return }
        handleNotification(method: Self.string(object["method"]), params: object["params"] as? [String: Any] ?? [:])
    }

    private func handleNotification(method: String, params: [String: Any]) {
        let turnInfo = params["turn"] as? [String: Any] ?? [:]
        let turnID = Self.string(params["turnId"]).nonEmpty ?? Self.string(turnInfo["id"])
        guard !turnID.isEmpty else { return }
        lock.lock()
        if activeTurns[turnID] == nil || activatingTurns.contains(turnID) {
            if Self.string(params["threadId"]) == startingThreadID,
               queuedTurnNotifications.values.reduce(0, { $0 + $1.count }) < 1024 {
                queuedTurnNotifications[turnID, default: []].append((method: method, params: params))
            }
            lock.unlock()
            return
        }
        applyNotificationLocked(method: method, params: params, turnID: turnID)
        lock.unlock()
    }

    private func activateTurn(_ turnID: String) {
        while true {
            lock.lock()
            let notifications = queuedTurnNotifications.removeValue(forKey: turnID) ?? []
            let approvals = queuedApprovalRequests.removeValue(forKey: turnID) ?? []
            for notification in notifications {
                applyNotificationLocked(
                    method: notification.method,
                    params: notification.params,
                    turnID: turnID
                )
            }
            if notifications.isEmpty && approvals.isEmpty {
                activatingTurns.remove(turnID)
                lock.unlock()
                return
            }
            lock.unlock()
            for approval in approvals {
                handleApprovalRequest(id: approval.id, params: approval.params)
            }
        }
    }

    private func applyNotificationLocked(method: String, params: [String: Any], turnID: String) {
        let turnInfo = params["turn"] as? [String: Any] ?? [:]
        var turn = activeTurns[turnID]
        guard turn?.completed == false, Self.string(params["threadId"]) == turn?.threadID else { return }
        switch method {
        case "item/agentMessage/delta":
            let delta = Self.string(params["delta"])
            if (turn?.message.utf8.count ?? 0) + delta.utf8.count > 4 * 1024 * 1024 {
                turn?.status = "failed"; turn?.message = "Codex response exceeds the size limit."; turn?.completed = true
            } else { turn?.message += delta }
        case "item/started", "item/completed":
            guard Self.string(params["threadId"]) == turn?.threadID else { break }
            if let update = Self.fileChangeUpdate(method: method, params: params) {
                turn?.patches[update.itemID] = update.paths
                turn?.diff = update.diff
            }
        case "item/fileChange/patchUpdated":
            guard Self.string(params["threadId"]) == turn?.threadID else { break }
            if let update = Self.fileChangeUpdate(method: method, params: params) {
                turn?.patches[update.itemID] = update.paths
                turn?.diff = update.diff
            }
        case "turn/completed":
            let info = turnInfo
            turn?.status = Self.string(info["status"]).isEmpty ? "completed" : Self.string(info["status"])
            turn?.completed = true
            if let items = info["items"] as? [[String: Any]], items.contains(where: { Self.string($0["type"]) == "agentMessage" }) {
                turn?.message = items.compactMap { item in
                    Self.string(item["type"]) == "agentMessage" ? Self.string(item["text"]) : nil
                }.joined(separator: "\n\n")
            }
        default:
            break
        }
        if let turn {
            activeTurns[turnID] = turn
        }
    }

    private func handleApprovalRequest(id: CodexRequestID, params: [String: Any]) {
        let turnID = Self.string(params["turnId"])
        let itemID = Self.string(params["itemId"])
        lock.lock()
        let turn = activeTurns[turnID]
        let paths = turn?.patches[itemID]
        lock.unlock()
        let allowed = Self.shouldApproveFileChange(
            params: params,
            expectedThreadID: turn?.threadID,
            allowEdits: turn?.allowEdits == true && turn?.completed == false,
            editRoot: turn?.editRoot,
            paths: paths
        )
        try? writeJSON(["id": id.jsonValue, "result": ["decision": allowed ? "accept" : "decline"]])
    }

    static func shouldApproveFileChange(
        params: [String: Any],
        expectedThreadID: String?,
        allowEdits: Bool,
        editRoot: URL?,
        paths: [String]?
    ) -> Bool {
        let threadID = string(params["threadId"])
        let turnID = string(params["turnId"])
        let itemID = string(params["itemId"])
        guard allowEdits,
              !threadID.isEmpty,
              !turnID.isEmpty,
              !itemID.isEmpty,
              threadID == expectedThreadID,
              string(params["grantRoot"]).isEmpty,
              let editRoot,
              let paths else {
            return false
        }
        return CodexPackageEditBroker.approvalPathsAreAllowed(paths, inside: editRoot)
    }

    static func shouldQueueApproval(
        turnID: String,
        hasActiveTurn: Bool,
        isActivating: Bool
    ) -> Bool {
        !turnID.isEmpty && (!hasActiveTurn || isActivating)
    }

    static func fileChangeUpdate(method: String, params: [String: Any]) -> CodexFileChangeUpdate? {
        let item: [String: Any]
        switch method {
        case "item/started", "item/completed":
            item = params["item"] as? [String: Any] ?? [:]
            guard string(item["type"]) == "fileChange" else { return nil }
        case "item/fileChange/patchUpdated":
            item = params
        default:
            return nil
        }
        let itemID = string(item["id"]).nonEmpty ?? string(item["itemId"])
        guard !itemID.isEmpty, let changes = item["changes"] as? [[String: Any]] else { return nil }
        return CodexFileChangeUpdate(
            itemID: itemID,
            paths: changes.map { string($0["path"]) },
            diff: changes.map { string($0["diff"]) }.joined(separator: "\n")
        )
    }

    private func writeJSON(_ object: [String: Any], deadline: Date? = nil) throws {
        let deadline = deadline ?? Date().addingTimeInterval(requestTimeout)
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 4 * 1024 * 1024 else { throw DashboardAPIError.serverUnavailable("Codex request exceeds the size limit.") }
        data.append(10)
        while !writeLock.try() {
            guard Date() < deadline else { throw DashboardAPIError.serverUnavailable("Codex pipe write timed out.") }
            Thread.sleep(forTimeInterval: 0.005)
        }
        defer { writeLock.unlock() }
        lock.lock()
        let owned = process
        let fd = (owned?.standardInput as? Pipe).map { dup($0.fileHandleForWriting.fileDescriptor) } ?? -1
        lock.unlock()
        guard let owned, owned.isRunning, fd >= 0 else {
            if fd >= 0 { close(fd) }
            throw DashboardAPIError.serverUnavailable("Codex app-server is not running.")
        }
        defer { close(fd) }
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else {
            throw DashboardAPIError.serverUnavailable("Could not configure the Codex transport.")
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                lock.lock(); let cancelled = cancellationRequested; let current = process === owned; lock.unlock()
                guard current, owned.isRunning else { throw DashboardAPIError.serverUnavailable("Codex app-server exited during a write.") }
                guard !cancelled || Self.string(object["method"]) == "turn/interrupt" else { throw DashboardAPIError.serverUnavailable("Codex turn cancelled.") }
                guard Date() < deadline else { throw DashboardAPIError.serverUnavailable("Codex pipe write timed out.") }
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { Thread.sleep(forTimeInterval: 0.005); continue }
                throw DashboardAPIError.serverUnavailable("Codex app-server pipe closed during a write.")
            }
        }
    }

    private func nextRequestID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    private func appendStderr(_ text: String) {
        lock.lock()
        stderrTail = String((stderrTail + text).suffix(4_000))
        lock.unlock()
    }

    private func withSessionLock<T>(_ work: () throws -> T) throws -> T {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return try work()
    }

    private func resetTerminatedProcess() {
        lock.lock(); defer { lock.unlock() }
        guard let process, !process.isRunning else { return }
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardInput as? Pipe)?.fileHandleForWriting.closeFile()
        self.process = nil
    }

    private func handleProcessTermination(_ terminatedProcess: CodexOwnedProcess) {
        lock.lock()
        guard process === terminatedProcess else { lock.unlock(); return }
        process = nil
        let pendingRequests = Array(pending.values)
        pending.removeAll()
        let stderr = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = stderr.isEmpty
            ? "Codex app-server exited before completing the request."
            : "Codex app-server exited before completing the request. Last stderr: \(stderr)"
        let turnIDs = Array(activeTurns.keys)
        for turnID in turnIDs {
            guard activeTurns[turnID]?.completed == false else { continue }
            activeTurns[turnID]?.status = "failed"
            activeTurns[turnID]?.message = message
            activeTurns[turnID]?.completed = true
        }
        lock.unlock()

        for request in pendingRequests {
            request.error = message
            request.semaphore.signal()
        }
    }

    private static func buildPrompt(
        packageName: String,
        message: String,
        allowEdits: Bool,
        repoRoot: URL,
        workingDirectory: URL
    ) -> String {
        let editBoundary = allowEdits
            ? [
                "The user explicitly enabled package markdown edits for this turn.",
                "The working directory is an isolated staging directory for applications/\(packageName): \(workingDirectory.path)",
                "Allowed write targets are only root-level posting.md, interview-prep.md, interview-transcript.md, interview-review-prompt.md, interview-review.md, Resume_*.md, CoverLetter_*.md, and package-note Markdown such as keyterms-study-guide.md.",
                "Do not create subdirectories, symlinks, or non-Markdown files in the staging directory.",
                "Other repository content is read-only. Resolve repository-relative read paths from \(repoRoot.path).",
                "Do not edit generated artifacts, tracker files, vault mirrors, docs, config, scripts, or git history."
            ].joined(separator: "\n")
            : "This is a read-only turn. Review, search, and suggest, but do not edit files."
        return [
            "You are Codex running inside the native Nav Center through codex app-server.",
            "Work only in the configured Nav Center workspace. Keep everything local-first.",
            "Do not submit applications, send outreach, scrape, upload private files, change auth, commit, push, or update vault docs.",
            "Current package: applications/\(packageName)",
            editBoundary,
            "",
            "User request:",
            message
        ].joined(separator: "\n")
    }

    static func workspaceWriteSandboxPolicy(editRoot: URL) -> [String: Any] {
        [
            "type": "workspaceWrite",
            "writableRoots": [editRoot.path],
            "networkAccess": false,
            "excludeTmpdirEnvVar": true,
            "excludeSlashTmp": true
        ]
    }

    static func resolveCodexCommand(configuration: ToolProbeConfiguration = .init()) throws -> String {
        let resolved = ToolProbe.resolve(.codex, configuration: configuration)
        guard resolved.state == .found, let path = resolved.resolvedPath, path.hasPrefix("/") else {
            throw DashboardAPIError.serverUnavailable(ToolProbe.missingToolMessage(resolved, action: "Codex"))
        }
        return path
    }

    /// Probe resolution runs on every start unless a test injected `command`.
    /// The environment launcher below is only that injected non-absolute seam.
    private func codexLaunch() throws -> (executableURL: URL, arguments: [String]) {
        if let injectedCommand {
            if injectedCommand.hasPrefix("/") {
                return (URL(fileURLWithPath: injectedCommand), args)
            }
            return (URL(fileURLWithPath: "/usr/bin/env"), [injectedCommand] + args)
        }
        let path = try Self.resolveCodexCommand(configuration: probeConfiguration ?? ToolProbeConfiguration())
        return (URL(fileURLWithPath: path), args)
    }

    private static func codexAccount(_ value: Any?) -> CodexAccount? {
        guard let object = value as? [String: Any] else { return nil }
        return CodexAccount(
            type: string(object["type"]),
            email: string(object["email"]).nonEmpty,
            planType: string(object["planType"]).nonEmpty
        )
    }

    private static func string(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        return String(describing: value)
    }

    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        return string(value).lowercased() == "true"
    }
}

private enum CodexRequestID {
    case integer(Int)
    case string(String)
    init?(_ value: Any?) {
        if let text = value as? String { self = .string(text); return }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              let integer = Int(number.stringValue) else { return nil }
        self = .integer(integer)
    }
    var jsonValue: Any {
        switch self { case .integer(let value): return value; case .string(let value): return value }
    }
}

private final class PendingRequest {
    let semaphore = DispatchSemaphore(value: 0)
    var result: [String: Any]?
    var error: String?
}

private struct ActiveTurn {
    var threadID: String
    var allowEdits: Bool
    var editRoot: URL?
    var message = ""
    var diff = ""
    var status = "inProgress"
    var completed = false
    var patches: [String: [String]] = [:]
}

struct CodexFileChangeUpdate: Equatable {
    var itemID: String
    var paths: [String]
    var diff: String
}

private enum PathSafetyBridge {
    static func normalizePackageName(_ value: String) throws -> String {
        try NavCenterCore.PathSafety.normalizePackageName(value)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

// Foundation.Process cannot atomically put a child in an owned process group.
// This transport uses spawn attributes so forced shutdown also stops descendants.
private final class CodexOwnedProcess: @unchecked Sendable {
    var executableURL: URL?
    var arguments: [String] = []
    var currentDirectoryURL: URL?
    var standardInput: Any?
    var standardOutput: Any?
    var standardError: Any?
    var terminationHandler: ((CodexOwnedProcess) -> Void)?
    private let stateLock = NSLock()
    private let completion = DispatchGroup()
    private var exitSource: DispatchSourceProcess?
    private var canSignal = false
    private var running = false
    private var pid: pid_t = 0
    var isRunning: Bool { stateLock.lock(); defer { stateLock.unlock() }; return running }
    var processIdentifier: pid_t { stateLock.lock(); defer { stateLock.unlock() }; return pid }

    func run() throws {
        guard let executableURL, let input = standardInput as? Pipe,
              let output = standardOutput as? Pipe, let errors = standardError as? Pipe else {
            throw DashboardAPIError.serverUnavailable("Codex transport is incomplete.")
        }
        let argv = [executableURL.path] + arguments
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        guard (argv + environment).allSatisfy({ !$0.contains("\0") }) else { throw DashboardAPIError.serverUnavailable("Invalid Codex launch arguments.") }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func check(_ result: Int32) throws {
            guard result == 0 else { throw DashboardAPIError.serverUnavailable("Codex transport setup failed: \(String(cString: strerror(result)))") }
        }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        let descriptors = [input.fileHandleForReading.fileDescriptor, input.fileHandleForWriting.fileDescriptor,
                           output.fileHandleForReading.fileDescriptor, output.fileHandleForWriting.fileDescriptor,
                           errors.fileHandleForReading.fileDescriptor, errors.fileHandleForWriting.fileDescriptor]
        try check(posix_spawn_file_actions_adddup2(&actions, descriptors[0], STDIN_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, descriptors[3], STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, descriptors[5], STDERR_FILENO))
        for fd in descriptors where fd > STDERR_FILENO { try check(posix_spawn_file_actions_addclose(&actions, fd)) }
        if let currentDirectoryURL { try check(posix_spawn_file_actions_addchdir_np(&actions, currentDirectoryURL.path)) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        let cArguments = argv.map { strdup($0) } + [nil]
        let cEnvironment = environment.map { strdup($0) } + [nil]
        defer { cArguments.compactMap { $0 }.forEach { free($0) }; cEnvironment.compactMap { $0 }.forEach { free($0) } }
        var child: pid_t = 0
        try check(cArguments.withUnsafeBufferPointer { args in
            cEnvironment.withUnsafeBufferPointer { env in
                posix_spawn(&child, executableURL.path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        })
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        stateLock.lock(); pid = child; running = true; canSignal = true; stateLock.unlock()
        let ownedPID = child
        completion.enter()
        let source = DispatchSource.makeProcessSource(identifier: ownedPID, eventMask: .exit, queue: .global(qos: .utility))
        exitSource = source
        source.setEventHandler { [self] in collectExit(ownedPID) }
        source.resume()
    }

    private func collectExit(_ ownedPID: pid_t) {
        stateLock.lock()
        guard running else { stateLock.unlock(); return }
        var info = siginfo_t()
        let observed = waitid(P_PID, id_t(ownedPID), &info, WEXITED | WNOHANG | WNOWAIT)
        if (observed == 0 && info.si_pid == 0) || (observed < 0 && errno == EINTR) {
            stateLock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.01) { [self] in collectExit(ownedPID) }
            return
        }
        // The unreaped leader reserves the PGID. Hold the same lock used by public signals
        // through descendant cleanup, ownership closure and the nonblocking reap.
        if observed == 0 && info.si_pid == ownedPID && canSignal { kill(-ownedPID, SIGKILL) }
        canSignal = false
        var status: Int32 = 0
        let collected = waitpid(ownedPID, &status, WNOHANG)
        if collected == 0 || (collected < 0 && errno == EINTR) {
            stateLock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.01) { [self] in collectExit(ownedPID) }
            return
        }
        running = false
        exitSource?.cancel()
        exitSource = nil
        stateLock.unlock()
        defer { completion.leave() }
        terminationHandler?(self)
    }

    func terminate() {
        stateLock.lock(); defer { stateLock.unlock() }
        if canSignal { kill(-pid, SIGTERM) }
    }

    func forceKill() {
        stateLock.lock(); defer { stateLock.unlock() }
        if canSignal { kill(-pid, SIGKILL) }
    }

    func waitUntilExit() { completion.wait() }
}
