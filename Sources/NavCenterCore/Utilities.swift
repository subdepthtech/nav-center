import Foundation

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
        guard markdown.hasPrefix("---\n"),
              let endRange = markdown.range(of: "\n---", range: markdown.index(markdown.startIndex, offsetBy: 4)..<markdown.endIndex) else {
            return FrontmatterDocument(metadata: [:], body: markdown)
        }

        let frontmatter = markdown[markdown.index(markdown.startIndex, offsetBy: 4)..<endRange.lowerBound]
        let bodyStart = markdown.index(endRange.lowerBound, offsetBy: 4)
        var metadata: [String: String] = [:]
        for line in frontmatter.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            metadata[key] = stripYAMLScalar(raw)
        }
        return FrontmatterDocument(metadata: metadata, body: String(markdown[bodyStart...]).trimmingCharacters(in: .newlines))
    }

    public static func yamlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func stripYAMLScalar(_ value: String) -> String {
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            let inner = value.dropFirst().dropLast()
            return inner
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

public enum TextUtil {
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
    public static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil, environment: [String: String] = [:]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable.hasPrefix("/") ? URL(fileURLWithPath: executable) : URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = executable.hasPrefix("/") ? arguments : [executable] + arguments
        process.currentDirectoryURL = cwd
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
