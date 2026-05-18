import Foundation
import NavCenterCore

final class NativeCodexBridge {
    private static var bridges: [String: NativeCodexBridge] = [:]

    static func shared(repoRoot: URL) -> NativeCodexBridge {
        let key = repoRoot.standardizedFileURL.path
        if let bridge = bridges[key] {
            return bridge
        }
        let bridge = NativeCodexBridge(repoRoot: repoRoot)
        bridges[key] = bridge
        return bridge
    }

    private let repoRoot: URL
    private let command: String
    private let args = ["app-server", "--listen", "stdio://"]
    private let sessionLock = NSRecursiveLock()
    private let writeLock = NSLock()
    private let lock = NSLock()
    private var process: Process?
    private var stdoutBuffer = ""
    private var stderrTail = ""
    private var nextID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var activeTurns: [String: ActiveTurn] = [:]
    private var queuedTurnNotifications: [String: [(method: String, params: [String: Any])]] = [:]
    private var initialized: [String: Any] = [:]

    private init(repoRoot: URL) {
        self.repoRoot = repoRoot
        self.command = Self.resolveCodexCommand()
    }

    func status() throws -> CodexStatusResponse {
        try withSessionLock {
            try statusUnlocked()
        }
    }

    private func statusUnlocked() throws -> CodexStatusResponse {
        try start()
        let account = try request("account/read", params: ["refreshToken": false])
        let auth = try request("getAuthStatus", params: ["includeToken": false, "refreshToken": false])
        return CodexStatusResponse(
            ok: true,
            userAgent: Self.string(initialized["userAgent"]),
            codexHome: Self.string(initialized["codexHome"]),
            account: Self.codexAccount(account["account"]),
            requiresOpenaiAuth: Self.bool(account["requiresOpenaiAuth"]),
            authMethod: Self.string(auth["authMethod"]).nonEmpty,
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
        try start()
        let packageName = try PathSafetyBridge.normalizePackageName(payload.packageName)
        let resolved = try NavCenterCore.PathSafety.resolvePackage(root: repoRoot, packageName: packageName)
        try NavCenterCore.PathSafety.assertExistingRegularFile(resolved.packageURL.appendingPathComponent("posting.md"), inside: resolved.packageURL, label: "posting.md")
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

        let threadID = payload.threadId?.isEmpty == false ? payload.threadId! : try createThread()
        let prompt = Self.buildPrompt(packageName: packageName, message: message, allowEdits: payload.allowEdits)
        let turn = try request("turn/start", params: [
            "threadId": threadID,
            "input": [["type": "text", "text": prompt, "text_elements": []]],
            "cwd": repoRoot.path,
            "approvalPolicy": "on-request",
            "approvalsReviewer": "user",
            "sandboxPolicy": payload.allowEdits
                ? [
                    "type": "workspaceWrite",
                    "writableRoots": [repoRoot.path],
                    "networkAccess": false,
                    "excludeTmpdirEnvVar": false,
                    "excludeSlashTmp": false
                ]
                : ["type": "readOnly", "networkAccess": false]
        ])
        let turnInfo = turn["turn"] as? [String: Any] ?? [:]
        let turnID = Self.string(turnInfo["id"])
        guard !turnID.isEmpty else {
            throw DashboardAPIError.serverUnavailable("Codex app-server did not return a turn id.")
        }
        lock.lock()
        activeTurns[turnID] = ActiveTurn(packageName: packageName, allowEdits: payload.allowEdits)
        let queuedNotifications = queuedTurnNotifications.removeValue(forKey: turnID) ?? []
        lock.unlock()
        for notification in queuedNotifications {
            handleNotification(method: notification.method, params: notification.params)
        }

        let completed = try waitForTurn(turnID, timeout: 10 * 60)
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

    private func createThread() throws -> String {
        let result = try request("thread/start", params: ["cwd": repoRoot.path])
        let thread = result["thread"] as? [String: Any] ?? [:]
        let id = Self.string(thread["id"])
        if id.isEmpty {
            throw DashboardAPIError.serverUnavailable("Codex app-server did not return a thread id.")
        }
        return id
    }

    private func start() throws {
        if process?.isRunning == true {
            return
        }
        resetTerminatedProcess()
        let process = Process()
        if command.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
        }
        process.currentDirectoryURL = repoRoot
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.handleStdout(Data(handle.availableData))
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(data: handle.availableData, encoding: .utf8) ?? ""
            self?.appendStderr(text)
        }
        process.terminationHandler = { [weak self] process in
            self?.handleProcessTermination(process)
        }
        try process.run()
        self.process = process
        initialized = try request("initialize", params: [
            "clientInfo": ["name": "nav-center", "title": "Nav Center", "version": "0.1.0"]
        ])
    }

    private func request(_ method: String, params: [String: Any], timeout: TimeInterval = 15) throws -> [String: Any] {
        let id = nextRequestID()
        let pending = PendingRequest()
        lock.lock()
        self.pending[id] = pending
        lock.unlock()
        do {
            try writeJSON(["id": id, "method": method, "params": params])
        } catch {
            lock.lock()
            self.pending.removeValue(forKey: id)
            lock.unlock()
            throw error
        }
        guard pending.semaphore.wait(timeout: .now() + timeout) == .success else {
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
        while Date() < deadline {
            lock.lock()
            let turn = activeTurns[turnID]
            lock.unlock()
            if let turn, turn.completed {
                return turn
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw DashboardAPIError.serverUnavailable("Codex turn timed out.")
    }

    private func handleStdout(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        stdoutBuffer += text
        let lines = stdoutBuffer.split(separator: "\n", omittingEmptySubsequences: false)
        stdoutBuffer = lines.last.map(String.init) ?? ""
        let complete = lines.dropLast().map(String.init)
        lock.unlock()
        for line in complete where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let id = object["id"] as? Int, object["method"] == nil {
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
        if let id = object["id"] as? Int, Self.string(object["method"]) == "item/fileChange/requestApproval" {
            handleApprovalRequest(id: id, params: object["params"] as? [String: Any] ?? [:])
            return
        }
        handleNotification(method: Self.string(object["method"]), params: object["params"] as? [String: Any] ?? [:])
    }

    private func handleNotification(method: String, params: [String: Any]) {
        let turnInfo = params["turn"] as? [String: Any] ?? [:]
        let turnID = Self.string(params["turnId"]).nonEmpty ?? Self.string(turnInfo["id"])
        guard !turnID.isEmpty else { return }
        lock.lock()
        var turn = activeTurns[turnID]
        if turn == nil {
            queuedTurnNotifications[turnID, default: []].append((method: method, params: params))
            lock.unlock()
            return
        }
        switch method {
        case "item/agentMessage/delta":
            turn?.message += Self.string(params["delta"])
        case "item/fileChange/patchUpdated":
            let itemID = Self.string(params["itemId"])
            let changes = (params["changes"] as? [[String: Any]] ?? []).map { Self.string($0["path"]) }
            if !itemID.isEmpty {
                turn?.patches[itemID] = changes
            }
            turn?.diff = Self.string(params["diff"])
        case "turn/completed":
            let info = turnInfo
            turn?.status = Self.string(info["status"]).isEmpty ? "completed" : Self.string(info["status"])
            turn?.completed = true
            if turn?.message.isEmpty == true {
                let items = info["items"] as? [[String: Any]] ?? []
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
        lock.unlock()
    }

    private func handleApprovalRequest(id: Int, params: [String: Any]) {
        let turnID = Self.string(params["turnId"])
        let itemID = Self.string(params["itemId"])
        lock.lock()
        let turn = activeTurns[turnID]
        let paths = turn?.patches[itemID] ?? []
        lock.unlock()
        let allowed = turn?.allowEdits == true && paths.allSatisfy { path in
            Self.isPackageMarkdownEditAllowed(packageName: turn?.packageName ?? "", path: path)
        }
        try? writeJSON(["id": id, "result": ["decision": allowed ? "approve" : "decline"]])
    }

    private func writeJSON(_ object: [String: Any]) throws {
        guard let stdin = process?.standardInput as? Pipe else {
            throw DashboardAPIError.serverUnavailable("Codex app-server is not running.")
        }
        guard process?.isRunning == true else {
            throw DashboardAPIError.serverUnavailable("Codex app-server exited. Start a new chat turn after refreshing status.")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try stdin.fileHandleForWriting.write(contentsOf: data)
            try stdin.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
        } catch {
            throw DashboardAPIError.serverUnavailable("Codex app-server pipe write failed: \(error.localizedDescription)")
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
        guard let process, !process.isRunning else { return }
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardInput as? Pipe)?.fileHandleForWriting.closeFile()
        self.process = nil
    }

    private func handleProcessTermination(_ terminatedProcess: Process) {
        lock.lock()
        if process === terminatedProcess {
            process = nil
        }
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

    private static func buildPrompt(packageName: String, message: String, allowEdits: Bool) -> String {
        let editBoundary = allowEdits
            ? [
                "The user explicitly enabled package markdown edits for this turn.",
                "Allowed write targets are only applications/\(packageName)/posting.md, applications/\(packageName)/interview-prep.md, applications/\(packageName)/interview-transcript.md, applications/\(packageName)/interview-review-prompt.md, applications/\(packageName)/interview-review.md, Resume_*.md, CoverLetter_*.md, and root package note markdown such as keyterms-study-guide.md in that same package.",
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

    private static func isPackageMarkdownEditAllowed(packageName: String, path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let prefix = "applications/\(packageName)/"
        guard normalized.hasPrefix(prefix) else { return false }
        let relative = String(normalized.dropFirst(prefix.count))
        guard !relative.contains("/") else { return false }
        return relative == "posting.md"
            || relative == "interview-prep.md"
            || relative == "interview-transcript.md"
            || relative == "interview-review-prompt.md"
            || relative == "interview-review.md"
            || NavCenterCore.isPackageNoteMarkdown(relative)
            || relative.range(of: #"^Resume_[^/]+\.md$"#, options: .regularExpression) != nil
            || relative.range(of: #"^CoverLetter_[^/]+\.md$"#, options: .regularExpression) != nil
    }

    private static func resolveCodexCommand() -> String {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["DASHBOARD_CODEX_BIN"], !explicit.isEmpty {
            return explicit
        }
        for dir in (env["PATH"] ?? "").split(separator: ":").map(String.init) {
            let candidate = "\(dir)/codex"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        for candidate in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(NSHomeDirectory())/.local/bin/codex"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "codex"
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

private final class PendingRequest {
    let semaphore = DispatchSemaphore(value: 0)
    var result: [String: Any]?
    var error: String?
}

private struct ActiveTurn {
    var packageName: String
    var allowEdits: Bool
    var message = ""
    var diff = ""
    var status = "inProgress"
    var completed = false
    var patches: [String: [String]] = [:]
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
