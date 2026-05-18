import Foundation

public enum NavCenterError: Error, LocalizedError, Equatable {
    case invalidPath(String)
    case notFound(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let message), .notFound(let message), .commandFailed(let message):
            return message
        }
    }
}

public struct ResolvedPackage: Equatable {
    public let packageName: String
    public let packageURL: URL
}

public enum PathSafety {
    public static func applicationsRoot(repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent("applications", isDirectory: true)
    }

    public static func resolvePackage(root repoRoot: URL, packageName: String) throws -> ResolvedPackage {
        let safeName = try normalizePackageName(packageName)
        let applications = applicationsRoot(repoRoot: repoRoot)
        let packageURL = applications.appendingPathComponent(safeName, isDirectory: true)

        let realApplications = try realpath(applications, label: "applications root")
        let realPackage = try realpath(packageURL, label: "application package")
        guard isInside(realPackage, parent: realApplications) else {
            throw NavCenterError.invalidPath("Application package must stay inside applications root: \(safeName)")
        }
        try assertNoSymlinkSegments(packageURL, root: applications, label: "application package")

        return ResolvedPackage(packageName: safeName, packageURL: packageURL)
    }

    public static func normalizePackageName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty
            || trimmed == "."
            || trimmed == ".."
            || trimmed.contains("/")
            || trimmed.contains("\\")
            || trimmed.contains("\0") {
            throw NavCenterError.invalidPath("Package name is not allowed: \(value)")
        }
        return trimmed
    }

    public static func assertNoSymlinkSegments(_ url: URL, root: URL, label: String) throws {
        let rootPath = root.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            throw NavCenterError.invalidPath("\(label) must stay inside \(root.path): \(url.path)")
        }

        var current = root.standardizedFileURL
        let relative = targetPath.dropFirst(rootPath.count).split(separator: "/").map(String.init)
        for segment in relative {
            current.appendPathComponent(segment)
            if FileManager.default.fileExists(atPath: current.path) {
                let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    throw NavCenterError.invalidPath("\(label) must not contain a symlink: \(current.path)")
                }
            }
        }
    }

    public static func assertWritablePath(_ url: URL, inside root: URL, label: String) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try assertNoSymlinkSegments(parent, root: root, label: "\(label) parent")
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw NavCenterError.invalidPath("\(label) must not be a symlink: \(url.path)")
            }
        }
        let realRoot = try realpath(root, label: "\(label) root")
        let realParent = try realpath(parent, label: "\(label) parent")
        guard isInside(realParent, parent: realRoot) else {
            throw NavCenterError.invalidPath("\(label) must stay inside \(root.path): \(url.path)")
        }
    }

    public static func assertExistingRegularFile(_ url: URL, inside root: URL, label: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NavCenterError.notFound("\(label) not found: \(url.path)")
        }
        try assertNoSymlinkSegments(url, root: root, label: label)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true || values.isRegularFile != true {
            throw NavCenterError.invalidPath("\(label) must be a regular file inside \(root.path): \(url.path)")
        }
        let realRoot = try realpath(root, label: "\(label) root")
        let realFile = try realpath(url, label: label)
        guard isInside(realFile, parent: realRoot) else {
            throw NavCenterError.invalidPath("\(label) must stay inside \(root.path): \(url.path)")
        }
    }

    public static func realpath(_ url: URL, label: String) throws -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NavCenterError.notFound("\(label) not found: \(url.path)")
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    public static func isInside(_ child: URL, parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    public static func repoRelativePath(root: URL, url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == rootPath {
            return "."
        }
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return path
    }
}
