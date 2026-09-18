import Foundation
import NavCenterCore
import Darwin

struct CodexPackageEditBroker {
    let packageURL: URL
    let stagingURL: URL

    private let workspaceRoot: URL
    private let workspaceIdentity: NavCenterCore.PathSafety.Identity
    private let applicationsIdentity: NavCenterCore.PathSafety.Identity
    private let baseline: [String: Data]
    private let packageIdentity: FileIdentity
    private let stagingIdentity: FileIdentity

    init(
        packageURL: URL,
        workspaceRoot: URL? = nil,
        stagingParent: URL = FileManager.default.temporaryDirectory
    ) throws {
        let workspace = workspaceRoot ?? packageURL.deletingLastPathComponent().deletingLastPathComponent()
        let resolved = try NavCenterCore.PathSafety.resolvePackage(root: workspace, packageName: packageURL.lastPathComponent)
        guard resolved.packageURL.standardizedFileURL == packageURL.standardizedFileURL else {
            throw CodexPackageEditBrokerError.invalidChange("Package does not belong to the approved workspace.")
        }
        self.workspaceRoot = workspace
        self.workspaceIdentity = try NavCenterCore.PathSafety.identity(workspace)
        self.applicationsIdentity = try NavCenterCore.PathSafety.identity(workspace.appendingPathComponent("applications"))
        let canonicalPackage = try NavCenterCore.PathSafety.realpath(resolved.packageURL, label: "application package")
        let originalFiles = try Self.snapshotAllowedFiles(in: canonicalPackage)
        let originalPackageIdentity = try Self.fileIdentity(of: canonicalPackage)
        let stagingCandidate = stagingParent.appendingPathComponent("nav-center-codex-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: stagingCandidate,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let canonicalStaging = try NavCenterCore.PathSafety.realpath(stagingCandidate, label: "Codex edit staging directory")
            let originalStagingIdentity = try Self.fileIdentity(of: canonicalStaging)
            for (name, data) in originalFiles {
                try data.write(to: canonicalStaging.appendingPathComponent(name), options: .atomic)
            }
            self.packageURL = canonicalPackage
            self.stagingURL = canonicalStaging
            self.baseline = originalFiles
            self.packageIdentity = originalPackageIdentity
            self.stagingIdentity = originalStagingIdentity
        } catch {
            try? FileManager.default.removeItem(at: stagingCandidate)
            throw error
        }
    }

    func cleanup() throws {
        guard FileManager.default.fileExists(atPath: stagingURL.path) else { return }
        try NavCenterCore.PathSafety.assertNoSymlinkSegments(stagingURL, root: stagingURL, label: "Codex staging")
        guard try Self.fileIdentity(of: stagingURL) == stagingIdentity else {
            throw CodexPackageEditBrokerError.invalidChange("Staging directory changed; replacement content was preserved.")
        }
        try FileManager.default.removeItem(at: stagingURL)
    }

    func applyValidatedChanges(beforeCommit: (() throws -> Void)? = nil) throws -> [String] {
        try assertRootIdentitiesUnchanged()
        let staged = try Self.snapshotStagingDirectory(stagingURL)
        try assertPackageMatches(baseline)

        let changedNames = Set(baseline.keys).union(staged.keys).filter { baseline[$0] != staged[$0] }.sorted()
        try changedNames.forEach { name in
            let target = packageURL.appendingPathComponent(name)
            try NavCenterCore.PathSafety.assertNoSymlinkSegments(target, root: packageURL, label: "Codex package edit")
            if FileManager.default.fileExists(atPath: target.path) {
                try NavCenterCore.PathSafety.assertExistingRegularFile(target, inside: packageURL, label: "Codex package edit")
            }
        }

        try beforeCommit?()
        var expectedPackage = baseline
        var appliedNames: [String] = []
        do {
            for name in changedNames {
                try assertPackageMatches(expectedPackage)
                let target = packageURL.appendingPathComponent(name)
                if let data = staged[name] {
                    try NavCenterCore.PathSafety.atomicWrite(data, to: target, inside: workspaceRoot, label: "Codex package edit")
                    expectedPackage[name] = data
                } else {
                    try NavCenterCore.PathSafety.removeFile(target, inside: workspaceRoot, label: "Codex package edit")
                    expectedPackage.removeValue(forKey: name)
                }
                appliedNames.append(name)
            }
            try assertPackageMatches(expectedPackage)
        } catch {
            do {
                try restoreBaseline(for: appliedNames, expectedCurrent: expectedPackage)
            } catch let rollbackError {
                throw CodexPackageEditBrokerError.invalidChange(
                    "Applying staged Codex edits failed and rollback also failed: \(error.localizedDescription); \(rollbackError.localizedDescription)"
                )
            }
            throw error
        }
        return changedNames
    }

    static func approvalPathsAreAllowed(_ paths: [String], inside stagingURL: URL) -> Bool {
        guard let canonicalRoot = try? NavCenterCore.PathSafety.realpath(stagingURL, label: "Codex edit staging directory"),
              canonicalRoot == stagingURL.standardizedFileURL else {
            return false
        }
        return !paths.isEmpty && paths.allSatisfy { approvalTarget(for: $0, inside: canonicalRoot) != nil }
    }

    static func isAllowedFileName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\") else { return false }
        return name == "posting.md"
            || name == "interview-prep.md"
            || name == "interview-transcript.md"
            || name == "interview-review-prompt.md"
            || name == "interview-review.md"
            || NavCenterCore.isPackageNoteMarkdown(name)
            || name.range(of: #"^Resume_[^/]+\.md$"#, options: .regularExpression) != nil
            || name.range(of: #"^CoverLetter_[^/]+\.md$"#, options: .regularExpression) != nil
    }

    private static func approvalTarget(for rawPath: String, inside stagingURL: URL) -> URL? {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.contains("\0") else { return nil }
        let rawComponents = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !rawComponents.contains(where: { $0 == "." || $0 == ".." }) else { return nil }

        let candidate = normalized.hasPrefix("/")
            ? URL(fileURLWithPath: normalized)
            : stagingURL.appendingPathComponent(normalized)
        let target = candidate.standardizedFileURL
        let root = stagingURL.standardizedFileURL
        guard NavCenterCore.PathSafety.isInside(target, parent: root) else { return nil }

        let relative = NavCenterCore.PathSafety.repoRelativePath(root: root, url: target)
        guard isAllowedFileName(relative) else { return nil }
        do {
            try NavCenterCore.PathSafety.assertNoSymlinkSegments(target, root: root, label: "Codex staged edit")
            if FileManager.default.fileExists(atPath: target.path) {
                try NavCenterCore.PathSafety.assertExistingRegularFile(target, inside: root, label: "Codex staged edit")
                try assertSingleLink(target, label: "Codex staged edit")
            }
            return target
        } catch {
            return nil
        }
    }

    private static func snapshotAllowedFiles(in packageURL: URL) throws -> [String: Data] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: packageURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        var snapshot: [String: Data] = [:]
        for entry in entries where isAllowedFileName(entry.lastPathComponent) {
            try NavCenterCore.PathSafety.assertExistingRegularFile(entry, inside: packageURL, label: "Codex package source")
            try assertSingleLink(entry, label: "Codex package source")
            snapshot[entry.lastPathComponent] = try NavCenterCore.PathSafety.readData(entry, inside: packageURL, label: "Codex source", maxBytes: 4 * 1024 * 1024)
        }
        return snapshot
    }

    private static func snapshotStagingDirectory(_ stagingURL: URL) throws -> [String: Data] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: stagingURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        var snapshot: [String: Data] = [:]
        for entry in entries {
            let name = entry.lastPathComponent
            guard isAllowedFileName(name) else {
                throw CodexPackageEditBrokerError.invalidChange(
                    "Codex created a disallowed staged target: \(name)"
                )
            }
            try NavCenterCore.PathSafety.assertExistingRegularFile(entry, inside: stagingURL, label: "Codex staged edit")
            try assertSingleLink(entry, label: "Codex staged edit")
            snapshot[name] = try NavCenterCore.PathSafety.readData(entry, inside: stagingURL, label: "Codex staged content", maxBytes: 4 * 1024 * 1024)
        }
        return snapshot
    }

    private func assertRootIdentitiesUnchanged() throws {
        _ = try NavCenterCore.PathSafety.resolvePackage(root: workspaceRoot, packageName: packageURL.lastPathComponent)
        guard try NavCenterCore.PathSafety.identity(workspaceRoot) == workspaceIdentity,
              try NavCenterCore.PathSafety.identity(workspaceRoot.appendingPathComponent("applications")) == applicationsIdentity else {
            throw CodexPackageEditBrokerError.invalidChange("Approved workspace identity changed while Codex was working.")
        }
        let currentPackage = try NavCenterCore.PathSafety.realpath(packageURL, label: "application package")
        let currentStaging = try NavCenterCore.PathSafety.realpath(stagingURL, label: "Codex edit staging directory")
        guard currentPackage == packageURL,
              currentStaging == stagingURL,
              try Self.fileIdentity(of: currentPackage) == packageIdentity,
              try Self.fileIdentity(of: currentStaging) == stagingIdentity else {
            throw CodexPackageEditBrokerError.invalidChange(
                "Package or staging directory identity changed while Codex was working; no staged edits were applied."
            )
        }
    }

    private func assertPackageMatches(_ expected: [String: Data]) throws {
        try assertRootIdentitiesUnchanged()
        let current = try Self.snapshotAllowedFiles(in: packageURL)
        guard current == expected else {
            throw CodexPackageEditBrokerError.invalidChange(
                "Package Markdown changed while Codex was working; no further staged edits were applied."
            )
        }
    }

    private func restoreBaseline(
        for changedNames: [String],
        expectedCurrent: [String: Data]
    ) throws {
        try assertRootIdentitiesUnchanged()
        let current = try Self.snapshotAllowedFiles(in: packageURL)
        guard changedNames.allSatisfy({ current[$0] == expectedCurrent[$0] }) else {
            throw CodexPackageEditBrokerError.invalidChange(
                "Package Markdown changed during rollback; newer content was not overwritten."
            )
        }
        for name in changedNames {
            let target = packageURL.appendingPathComponent(name)
            if let data = baseline[name] {
                if FileManager.default.fileExists(atPath: target.path) {
                    try NavCenterCore.PathSafety.assertExistingRegularFile(target, inside: packageURL, label: "Codex edit rollback")
                }
                try NavCenterCore.PathSafety.atomicWrite(data, to: target, inside: workspaceRoot, label: "Codex package edit")
            } else if FileManager.default.fileExists(atPath: target.path) {
                try NavCenterCore.PathSafety.assertExistingRegularFile(target, inside: packageURL, label: "Codex edit rollback")
                try NavCenterCore.PathSafety.removeFile(target, inside: workspaceRoot, label: "Codex package edit")
            }
        }
    }

    private static func fileIdentity(of url: URL) throws -> FileIdentity {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw CodexPackageEditBrokerError.invalidChange(
                "Could not inspect filesystem identity for \(url.path)."
            )
        }
        return FileIdentity(
            device: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(truncatingIfNeeded: metadata.st_ino)
        )
    }

    private static func assertSingleLink(_ url: URL, label: String) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_nlink == 1 else {
            throw CodexPackageEditBrokerError.invalidChange(
                "\(label) must not be a hard link: \(url.path)"
            )
        }
    }
}

private struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
}

private enum CodexPackageEditBrokerError: Error, LocalizedError {
    case invalidChange(String)

    var errorDescription: String? {
        switch self {
        case .invalidChange(let message):
            return message
        }
    }
}
