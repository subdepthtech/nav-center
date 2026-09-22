import Foundation
import Darwin

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

        try assertNoSymlinkSegments(applications, root: repoRoot, label: "applications root")
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

    public struct Identity: Equatable {
        public let device: dev_t
        public let inode: ino_t
    }

    public static func identity(_ url: URL) throws -> Identity {
        var value = stat()
        guard lstat(url.path, &value) == 0, (value.st_mode & S_IFMT) != S_IFLNK else {
            throw NavCenterError.invalidPath("Path is missing or linked: \(url.lastPathComponent)")
        }
        return Identity(device: value.st_dev, inode: value.st_ino)
    }

    public static func assertNoSymlinkSegments(_ url: URL, root: URL, label: String) throws {
        let root = URL(fileURLWithPath: lexicalPath(root), isDirectory: true)
        guard isInside(url, parent: root) else {
            throw NavCenterError.invalidPath("\(label) must stay inside its configured root.")
        }
        var current = root
        let relative = lexicalPath(url).dropFirst(root.path.count).split(separator: "/")
        for segment in [String?](arrayLiteral: nil) + relative.map({ Optional(String($0)) }) {
            if let segment { current.appendPathComponent(segment) }
            var value = stat()
            if lstat(current.path, &value) == 0 {
                guard (value.st_mode & S_IFMT) != S_IFLNK else {
                    throw NavCenterError.invalidPath("\(label) must not contain a symbolic link: \(current.lastPathComponent)")
                }
            } else if errno != ENOENT {
                throw fileError("Inspect \(label)")
            }
        }
    }

    public static func assertWritablePath(_ url: URL, inside root: URL, label: String) throws {
        try withParent(url, inside: root, createParents: true, label: label) { parent, name in
            try assertWritableLeaf(parent, name: name, label: label)
        }
    }

    public static func assertExistingRegularFile(_ url: URL, inside root: URL, label: String) throws {
        try withParent(url, inside: root, createParents: false, label: label) { parent, name in
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw fileError("Open \(label)") }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                throw NavCenterError.invalidPath("\(label) must be a regular file.")
            }
        }
    }

    public static func createDirectory(_ url: URL, inside root: URL, label: String) throws {
        guard isInside(url, parent: root) else { throw NavCenterError.invalidPath("\(label) is outside its configured root.") }
        try assertNoSymlinkSegments(root, root: root, label: "workspace root")
        if !FileManager.default.fileExists(atPath: root.path) {
            // Only the configured root's parent can contain macOS system aliases (/tmp, /var).
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try withParent(url.appendingPathComponent(".directory-check"), inside: root, createParents: true, label: label) { _, _ in }
    }

    public static func readData(_ url: URL, inside root: URL, label: String, maxBytes: Int = 32 * 1024 * 1024) throws -> Data {
        try withParent(url, inside: root, createParents: false, label: label) { parent, name in
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw fileError("Read \(label)") }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maxBytes else {
                throw NavCenterError.invalidPath("\(label) must be a regular file no larger than \(maxBytes) bytes.")
            }
            var result = Data()
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count == 0 { break }
                if count < 0 { if errno == EINTR { continue }; throw fileError("Read \(label)") }
                guard result.count + count <= maxBytes else { throw NavCenterError.invalidPath("\(label) exceeds the size limit.") }
                result.append(contentsOf: bytes.prefix(count))
            }
            return result
        }
    }

    public static func readUTF8(_ url: URL, inside root: URL, label: String, maxBytes: Int) throws -> String {
        let data = try readData(url, inside: root, label: label, maxBytes: maxBytes)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NavCenterError.invalidPath("\(label) is not valid UTF-8.")
        }
        return text
    }

    public static func atomicWrite(_ data: Data, to url: URL, inside root: URL, label: String) throws {
        let rootIdentity = try identity(root)
        try withParent(url, inside: root, createParents: true, label: label) { parent, name in
            try assertWritableLeaf(parent, name: name, label: label)
            let temporary = ".nav-center-\(UUID().uuidString)"
            let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw fileError("Stage \(label)") }
            defer { close(fd); _ = unlinkat(parent, temporary, 0) }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 { if errno == EINTR { continue }; throw fileError("Write \(label)") }
                    offset += count
                }
            }
            guard fsync(fd) == 0 else { throw fileError("Flush \(label)") }
            try assertBoundDirectory(parent, path: url.deletingLastPathComponent(), root: root, rootIdentity: rootIdentity)
            try assertWritableLeaf(parent, name: name, label: label)
            guard renameat(parent, temporary, parent, name) == 0 else { throw fileError("Commit \(label)") }
            _ = fsync(parent)
        }
    }

    public static func removeFile(_ url: URL, inside root: URL, label: String) throws {
        try withParent(url, inside: root, createParents: false, label: label) { parent, name in
            try assertWritableLeaf(parent, name: name, label: label)
            try assertBoundDirectory(parent, path: url.deletingLastPathComponent(), root: root, rootIdentity: try identity(root))
            guard unlinkat(parent, name, 0) == 0 else { throw fileError("Remove \(label)") }
            _ = fsync(parent)
        }
    }

    public static func moveItem(_ source: URL, to target: URL, inside root: URL, label: String) throws {
        try withParent(source, inside: root, createParents: false, label: label) { from, sourceName in
            try withParent(target, inside: root, createParents: true, label: label) { to, targetName in
                var info = stat()
                guard fstatat(from, sourceName, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      (info.st_mode & S_IFMT) == S_IFDIR || ((info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1) else {
                    throw NavCenterError.invalidPath("\(label) source must be an unlinked regular file or directory.")
                }
                guard fstatat(to, targetName, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
                    throw NavCenterError.invalidPath("\(label) destination already exists.")
                }
                let rootIdentity = try identity(root)
                try assertBoundDirectory(from, path: source.deletingLastPathComponent(), root: root, rootIdentity: rootIdentity)
                try assertBoundDirectory(to, path: target.deletingLastPathComponent(), root: root, rootIdentity: rootIdentity)
                guard renameatx_np(from, sourceName, to, targetName, UInt32(RENAME_EXCL)) == 0 else { throw fileError("Move \(label)") }
                _ = fsync(from); _ = fsync(to)
            }
        }
    }

    private static func assertWritableLeaf(_ parent: Int32, name: String, label: String) throws {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
                throw NavCenterError.invalidPath("\(label) must be an unlinked regular file.")
            }
        } else if errno != ENOENT { throw fileError("Inspect \(label)") }
    }

    private static func withParent<T>(_ url: URL, inside root: URL, createParents: Bool, label: String, _ work: (Int32, String) throws -> T) throws -> T {
        let root = URL(fileURLWithPath: lexicalPath(root), isDirectory: true)
        let target = URL(fileURLWithPath: lexicalPath(url))
        guard target != root, isInside(target, parent: root) else { throw NavCenterError.invalidPath("\(label) must stay inside its configured root.") }
        try assertNoSymlinkSegments(target, root: root, label: label)
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw fileError("Open configured root") }
        defer { close(rootFD) }
        let originalRoot = try descriptorIdentity(rootFD)
        var fd = dup(rootFD)
        guard fd >= 0 else { throw fileError("Open \(label) parent") }
        defer { close(fd) }
        let components = target.path.dropFirst(root.path.count).split(separator: "/").map(String.init)
        var walked = root
        for part in components.dropLast() {
            try assertBoundDirectory(fd, path: walked, root: root, rootIdentity: originalRoot)
            if createParents, mkdirat(fd, part, 0o700) != 0, errno != EEXIST { throw fileError("Create \(label) parent") }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw fileError("Open \(label) parent") }
            close(fd); fd = next
            walked.appendPathComponent(part)
        }
        try assertBoundDirectory(fd, path: walked, root: root, rootIdentity: originalRoot)
        return try work(fd, components.last!)
    }

    private static func descriptorIdentity(_ fd: Int32) throws -> Identity {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw fileError("Inspect open directory") }
        return Identity(device: value.st_dev, inode: value.st_ino)
    }

    // Re-open from the configured name rather than trusting a descriptor whose directory
    // may have been moved elsewhere. O_NOFOLLOW applies at every owned component.
    private static func assertBoundDirectory(_ expected: Int32, path: URL, root: URL, rootIdentity: Identity) throws {
        let rootPath = lexicalPath(root)
        let pathString = lexicalPath(path)
        guard isInside(path, parent: root) else { throw NavCenterError.invalidPath("Directory left its configured root.") }
        var current = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw fileError("Reopen configured root") }
        defer { close(current) }
        guard try descriptorIdentity(current) == rootIdentity else { throw NavCenterError.invalidPath("Configured root changed during access.") }
        for part in pathString.dropFirst(rootPath.count).split(separator: "/") {
            let next = openat(current, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw fileError("Reopen owned directory") }
            close(current); current = next
        }
        guard try descriptorIdentity(current) == descriptorIdentity(expected) else {
            throw NavCenterError.invalidPath("Destination directory changed during access; operation stopped.")
        }
    }

    // Foundation may collapse /private/tmp only for existing URLs. Use lexical
    // normalization for both existing and future paths so containment is stable.
    // The two macOS system aliases are above the user-owned workspace boundary.
    private static func lexicalPath(_ url: URL) -> String {
        var components: [Substring] = []
        for part in url.path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(part)
        }
        if components.count >= 2, components[0] == "private", ["tmp", "var"].contains(String(components[1])) {
            components.removeFirst()
        }
        return "/" + components.joined(separator: "/")
    }

    private static func fileError(_ operation: String) -> NavCenterError {
        .invalidPath("\(operation) failed: \(String(cString: strerror(errno)))")
    }

    public static func realpath(_ url: URL, label: String) throws -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NavCenterError.notFound("\(label) not found: \(url.path)")
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    public static func isInside(_ child: URL, parent: URL) -> Bool {
        let childPath = lexicalPath(child)
        let parentPath = lexicalPath(parent)
        return !childPath.contains("\0") && !parentPath.contains("\0") && (childPath == parentPath || childPath.hasPrefix(parentPath == "/" ? "/" : parentPath + "/"))
    }

    public static func repoRelativePath(root: URL, url: URL) -> String {
        let rootPath = lexicalPath(root)
        let path = lexicalPath(url)
        if path == rootPath {
            return "."
        }
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return path
    }
}
