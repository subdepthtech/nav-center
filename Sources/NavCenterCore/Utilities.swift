import Foundation
import Darwin

public enum FileKind: String, Codable, Equatable {
    case posting
    case resumeSource = "resume-source"
    case coverLetterSource = "cover-letter-source"
    case interviewPrep = "interview-prep"
    case atsArtifact = "ats-artifact"
    case artifact
    case packageFile = "package-file"
}

public struct FrontmatterDocument: Equatable {
    public let metadata: [String: String]
    public let body: String
}

public enum Markdown {
    public static func parseFrontmatter(_ markdown: String) -> FrontmatterDocument {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.indices.dropFirst().first(where: { lines[$0] == "---" }) else {
            return FrontmatterDocument(metadata: [:], body: markdown)
        }
        var metadata: [String: String] = [:]
        for line in lines[1..<end] {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            metadata[key] = stripYAMLScalar(raw)
        }
        return FrontmatterDocument(metadata: metadata, body: lines.dropFirst(end + 1).joined(separator: "\n").trimmingCharacters(in: .newlines))
    }

    public static func yamlString(_ value: String) -> String {
        // JSON strings are valid YAML double-quoted scalars with unambiguous escapes.
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func stripYAMLScalar(_ value: String) -> String {
        if value.hasPrefix("\""), let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) {
            return decoded
        }
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

}

public enum TextUtil {
    public static func calendarDay(_ value: String) -> Date? {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    public static func slugify(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        return String(scalars)
            .replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    public static func splitSignals(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: CharacterSet.newlines)
            .flatMap { $0.components(separatedBy: ". ") }
            .map {
                $0.replacingOccurrences(of: #"^#+\s*|^[-*]\s*|\*\*?|\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { $0.count >= 24 }
            .filter { !$0.lowercased().hasPrefix("source url:") && !$0.lowercased().hasPrefix("source file:") }
    }

    public static func unique(_ lines: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in lines {
            let key = line.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(line)
            if result.count >= limit { break }
        }
        return result
    }
}

public struct ProcessResult: Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum ProcessRunner {
    // Preserve the four-argument callable used by package-action hooks.
    public static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil, environment: [String: String] = [:]) throws -> ProcessResult {
        try run(executable, arguments, cwd: cwd, environment: environment, timeout: 120)
    }

    public static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil,
                           environment: [String: String] = [:], timeout: TimeInterval,
                           maximumOutputBytes: Int = 32 * 1024 * 1024,
                           isCancelled: () -> Bool = { false }) throws -> ProcessResult {
        guard timeout > 0, maximumOutputBytes > 0 else { throw NavCenterError.commandFailed("Invalid process limits.") }
        let program = executable.hasPrefix("/") ? executable : "/usr/bin/env"
        let argv = [program] + (executable.hasPrefix("/") ? arguments : [executable] + arguments)
        let env = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        guard (argv + env.map { "\($0.key)=\($0.value)" }).allSatisfy({ !$0.contains("\0") }) else {
            throw NavCenterError.commandFailed("Process arguments must not contain NUL.")
        }
        var outputPipe: [Int32] = [0, 0]
        var errorPipe: [Int32] = [0, 0]
        guard pipe(&outputPipe) == 0 else { throw spawnError() }
        guard pipe(&errorPipe) == 0 else { close(outputPipe[0]); close(outputPipe[1]); throw spawnError() }
        var descriptors = outputPipe + errorPipe
        defer { descriptors.filter { $0 >= 0 }.forEach { close($0) } }
        for fd in descriptors { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        if let cwd {
            guard posix_spawn_file_actions_addchdir_np(&actions, cwd.path) == 0 else { throw spawnError() }
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let cArguments = argv.map { strdup($0) } + [nil]
        let cEnvironment = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cArguments.compactMap { $0 }.forEach { free($0) }; cEnvironment.compactMap { $0 }.forEach { free($0) } }
        var child: pid_t = 0
        let spawnResult = cArguments.withUnsafeBufferPointer { args in
            cEnvironment.withUnsafeBufferPointer { environment in
                posix_spawn(&child, program, &actions, &attributes, args.baseAddress!, environment.baseAddress!)
            }
        }
        guard spawnResult == 0 else { throw NavCenterError.commandFailed("Could not launch \(URL(fileURLWithPath: executable).lastPathComponent): \(String(cString: strerror(spawnResult)))") }
        close(outputPipe[1]); descriptors[1] = -1
        close(errorPipe[1]); descriptors[3] = -1
        for fd in [outputPipe[0], errorPipe[0]] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var output = Data(), errors = Data()
        var status: Int32 = 0
        var reaped = false
        let deadline = Date().addingTimeInterval(timeout)
        var failure: String?
        defer {
            if !reaped {
                kill(-child, SIGKILL)
                while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            }
        }
        var eof = [false, false]
        while !reaped || !eof.allSatisfy({ $0 }) {
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            for (index, fd) in [outputPipe[0], errorPipe[0]].enumerated() where !eof[index] {
                while true {
                    let count = Darwin.read(fd, &bytes, bytes.count)
                    if count == 0 { eof[index] = true; break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        if errno != EAGAIN { failure = "Could not read process output." }
                        break
                    }
                    if output.count + errors.count + count > maximumOutputBytes { failure = "Process output exceeded its limit."; break }
                    if index == 0 { output.append(contentsOf: bytes.prefix(count)) }
                    else { errors.append(contentsOf: bytes.prefix(count)) }
                }
            }
            if !reaped {
                let result = waitpid(child, &status, WNOHANG)
                if result == child { reaped = true }
                else if result < 0 && errno != EINTR { failure = "Could not collect process status." }
            }
            if isCancelled() { failure = "Process cancelled." }
            if Date() >= deadline { failure = "Process timed out." }
            if let failure {
                // The child starts in its own process group; never signal unrelated applications.
                kill(-child, SIGTERM)
                Thread.sleep(forTimeInterval: 0.05)
                kill(-child, SIGKILL)
                if !reaped { while waitpid(child, &status, 0) < 0 && errno == EINTR {}; reaped = true }
                throw NavCenterError.commandFailed(failure)
            }
            if !reaped || !eof.allSatisfy({ $0 }) { Thread.sleep(forTimeInterval: 0.01) }
        }
        let exitStatus: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return ProcessResult(status: exitStatus, stdout: String(decoding: output, as: UTF8.self), stderr: String(decoding: errors, as: UTF8.self))
    }

    private static func spawnError() -> NavCenterError {
        .commandFailed("Could not prepare process: \(String(cString: strerror(errno)))")
    }
}
