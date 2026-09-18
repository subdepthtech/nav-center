import Foundation

public struct VaultSyncResult: Equatable {
    public let applicationName: String
    public let targetURL: URL
    public let copiedCount: Int
}

public final class VaultSync {
    private let repoRoot: URL
    private let vaultRoot: URL

    public init(repoRoot: URL, vaultRoot: URL) {
        self.repoRoot = repoRoot
        self.vaultRoot = vaultRoot
    }

    public func sync(applicationPath: String) throws -> VaultSyncResult {
        let packageURL = (applicationPath.hasPrefix("/") ? URL(fileURLWithPath: applicationPath) : repoRoot.appendingPathComponent(applicationPath)).standardizedFileURL
        let resolved = try PathSafety.resolvePackage(root: repoRoot, packageName: packageURL.lastPathComponent)
        guard PathSafety.repoRelativePath(root: repoRoot, url: packageURL) == "applications/" + resolved.packageName else {
            throw NavCenterError.invalidPath("Expected applications/<application> inside the configured workspace.")
        }
        let vaultValues = try vaultRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if vaultValues.isSymbolicLink == true || vaultValues.isDirectory != true {
            throw NavCenterError.invalidPath("Vault project root must be a real directory: \(vaultRoot.path)")
        }
        _ = try PathSafety.realpath(vaultRoot, label: "Vault project root")
        let target = vaultRoot.appendingPathComponent("applications/\(resolved.packageName)", isDirectory: true)
        var prepared: [(URL, Data)] = []
        var bytes = 0

        try prepareIfPresent(resolved.packageURL.appendingPathComponent("posting.md"), to: target.appendingPathComponent("posting.md"), prepared: &prepared, bytes: &bytes)
        try prepareIfPresent(resolved.packageURL.appendingPathComponent("ats-report.json"), to: target.appendingPathComponent("ats-report.json"), prepared: &prepared, bytes: &bytes)
        for fileName in try FileManager.default.contentsOfDirectory(atPath: resolved.packageURL.path) {
            let source = resolved.packageURL.appendingPathComponent(fileName)
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if fileName != "posting.md", fileName.hasSuffix(".md"), values.isRegularFile == true, values.isSymbolicLink != true {
                try prepareIfPresent(source, to: target.appendingPathComponent(fileName), prepared: &prepared, bytes: &bytes)
            }
        }
        try prepareIfPresent(resolved.packageURL.appendingPathComponent("artifacts", isDirectory: true), to: target.appendingPathComponent("artifacts", isDirectory: true), prepared: &prepared, bytes: &bytes)

        if prepared.isEmpty {
            throw NavCenterError.notFound("No package files found to sync in: \(PathSafety.repoRelativePath(root: repoRoot, url: resolved.packageURL))")
        }
        try CoreFileSetCommit.apply(prepared, inside: vaultRoot)
        return VaultSyncResult(applicationName: resolved.packageName, targetURL: target, copiedCount: prepared.count)
    }

    private func prepareIfPresent(_ source: URL, to target: URL, prepared: inout [(URL, Data)], bytes: inout Int) throws {
        guard SQLiteSupport.exists(source) else { return }
        try PathSafety.assertNoSymlinkSegments(source, root: repoRoot, label: "Vault sync source")
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isDirectory == true {
            for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                try prepareIfPresent(child, to: target.appendingPathComponent(child.lastPathComponent), prepared: &prepared, bytes: &bytes)
            }
            return
        }
        guard values.isRegularFile == true else { throw NavCenterError.invalidPath("Vault sync source must be a regular file.") }
        let data = try PathSafety.readData(source, inside: repoRoot, label: "Vault sync source", maxBytes: 128 * 1024 * 1024 - bytes)
        bytes += data.count
        prepared.append((target, data))
    }
}
