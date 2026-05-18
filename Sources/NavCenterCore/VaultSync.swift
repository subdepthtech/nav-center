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
        let packageURL = URL(fileURLWithPath: applicationPath, relativeTo: repoRoot).standardizedFileURL
        let resolved = try PathSafety.resolvePackage(root: repoRoot, packageName: packageURL.lastPathComponent)
        let vaultValues = try vaultRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if vaultValues.isSymbolicLink == true || vaultValues.isDirectory != true {
            throw NavCenterError.invalidPath("Vault project root must be a real directory: \(vaultRoot.path)")
        }
        _ = try PathSafety.realpath(vaultRoot, label: "Vault project root")
        let target = vaultRoot.appendingPathComponent("applications/\(resolved.packageName)", isDirectory: true)
        var count = 0

        count += try copyIfPresent(resolved.packageURL.appendingPathComponent("posting.md"), to: target.appendingPathComponent("posting.md"), sourceRoot: resolved.packageURL)
        count += try copyIfPresent(resolved.packageURL.appendingPathComponent("ats-report.json"), to: target.appendingPathComponent("ats-report.json"), sourceRoot: resolved.packageURL)
        for fileName in try FileManager.default.contentsOfDirectory(atPath: resolved.packageURL.path) {
            let source = resolved.packageURL.appendingPathComponent(fileName)
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if fileName != "posting.md", fileName.hasSuffix(".md"), values.isRegularFile == true, values.isSymbolicLink != true {
                count += try copyIfPresent(source, to: target.appendingPathComponent(fileName), sourceRoot: resolved.packageURL)
            }
        }
        count += try copyIfPresent(resolved.packageURL.appendingPathComponent("artifacts", isDirectory: true), to: target.appendingPathComponent("artifacts", isDirectory: true), sourceRoot: resolved.packageURL)

        if count == 0 {
            throw NavCenterError.notFound("No package files found to sync in: \(PathSafety.repoRelativePath(root: repoRoot, url: resolved.packageURL))")
        }
        return VaultSyncResult(applicationName: resolved.packageName, targetURL: target, copiedCount: count)
    }

    private func copyIfPresent(_ source: URL, to target: URL, sourceRoot: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: source.path) else { return 0 }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true { throw NavCenterError.invalidPath("Package source must not be a symlink: \(source.path)") }
        if values.isDirectory == true {
            var count = 0
            for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                count += try copyIfPresent(child, to: target.appendingPathComponent(child.lastPathComponent), sourceRoot: sourceRoot)
            }
            return count
        }
        guard values.isRegularFile == true else { return 0 }
        try PathSafety.assertWritablePath(target, inside: vaultRoot, label: "Vault sync target")
        try FileManager.default.copyItemReplacing(source, to: target)
        return 1
    }
}

extension FileManager {
    func copyItemReplacing(_ source: URL, to target: URL) throws {
        try createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileExists(atPath: target.path) {
            try removeItem(at: target)
        }
        try copyItem(at: source, to: target)
    }
}
