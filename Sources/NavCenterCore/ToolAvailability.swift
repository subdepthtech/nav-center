import Darwin
import Foundation

public enum ExternalTool: String, Codable, CaseIterable, Equatable, Sendable {
    case atsim
    case exportTool = "export-tool"
    case pandoc
    case pdftotext
    case chrome
    case ruby
    case codex

    public var displayName: String {
        switch self {
        case .atsim: return "atsim"
        case .exportTool: return "Export tool"
        case .pandoc: return "Pandoc"
        case .pdftotext: return "pdftotext"
        case .chrome: return "Google Chrome"
        case .ruby: return "Ruby"
        case .codex: return "Codex CLI"
        }
    }

    public var environmentVariable: String? {
        switch self {
        case .atsim: return "NAV_CENTER_ATSIM_BIN"
        case .exportTool: return "NAV_CENTER_EXPORT_BIN"
        case .pandoc: return "PANDOC_BIN"
        case .pdftotext: return "PDFTOTEXT_BIN"
        case .chrome: return "CHROME_BIN"
        case .ruby: return nil
        case .codex: return "DASHBOARD_CODEX_BIN"
        }
    }

    public var defaultCommand: String? {
        switch self {
        case .atsim: return "atsim"
        case .exportTool: return nil
        case .pandoc: return "pandoc"
        case .pdftotext: return "pdftotext"
        case .chrome: return "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        case .ruby: return "ruby"
        case .codex: return "codex"
        }
    }

    public var purpose: String {
        switch self {
        case .atsim: return "Confirmed ATS scan"
        case .exportTool: return "Optional replacement for the built-in resume export"
        case .pandoc: return "Document export (Markdown to HTML and DOCX)"
        case .pdftotext: return "Document export (PDF text extraction)"
        case .chrome: return "Document export (PDF rendering)"
        case .ruby: return "Master resume YAML validation"
        case .codex: return "Codex panel"
        }
    }

    public var installHint: String {
        switch self {
        case .atsim:
            return "install atsim into an isolated Python environment and expose its launcher on PATH"
        case .exportTool:
            return "leave NAV_CENTER_EXPORT_BIN unset to use the built-in exporter"
        case .pandoc:
            return "brew install pandoc"
        case .pdftotext:
            return "brew install poppler"
        case .chrome:
            return "install Google Chrome in /Applications"
        case .ruby:
            return "use the Ruby included with macOS at /usr/bin/ruby"
        case .codex:
            return "install the Codex CLI and sign in once from a terminal"
        }
    }
}

public enum ToolState: String, Codable, Sendable {
    case found
    case missing
    case overrideInvalid = "override-invalid"
    case builtIn = "built-in"
}

public enum ToolSource: String, Codable, Sendable {
    case environment
    case path
    case fallback
    case defaultPath = "default-path"
}

public struct ToolStatus: Codable, Equatable, Identifiable, Sendable {
    public var id: String { tool.rawValue }
    public let tool: ExternalTool
    public let state: ToolState
    public let resolvedPath: String?
    public let source: ToolSource?
    public let environmentVariable: String?
    public let installHint: String
    public let summary: String

    public init(
        tool: ExternalTool,
        state: ToolState,
        resolvedPath: String?,
        source: ToolSource?,
        environmentVariable: String?,
        installHint: String,
        summary: String
    ) {
        self.tool = tool
        self.state = state
        self.resolvedPath = resolvedPath
        self.source = source
        self.environmentVariable = environmentVariable
        self.installHint = installHint
        self.summary = summary
    }
}

public struct ToolAvailabilityReport: Codable, Equatable, Sendable {
    public let tools: [ToolStatus]

    public static let empty = ToolAvailabilityReport(tools: [])

    public init(tools: [ToolStatus]) {
        self.tools = tools
    }

    public var missing: [ToolStatus] {
        tools.filter { $0.state == .missing || $0.state == .overrideInvalid }
    }

    public func redacted(homeDirectory: URL) -> ToolAvailabilityReport {
        ToolAvailabilityReport(tools: tools.map { status in
            ToolStatus(
                tool: status.tool,
                state: status.state,
                resolvedPath: status.resolvedPath.map { PathRedactor.redact($0, homeDirectory: homeDirectory) },
                source: status.source,
                environmentVariable: status.environmentVariable,
                installHint: status.installHint,
                summary: PathRedactor.redact(status.summary, homeDirectory: homeDirectory)
            )
        })
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        tools = try container.decode([ToolStatus].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(tools)
    }
}

public struct ToolProbeConfiguration: Sendable {
    public let environment: [String: String]
    public let homeDirectory: URL
    public let fallbackDirectories: [String]
    public let isExecutableRegularFile: @Sendable (String) -> Bool

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fallbackDirectories: [String]? = nil,
        isExecutableRegularFile: (@Sendable (String) -> Bool)? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.fallbackDirectories = fallbackDirectories ?? ToolProbe.fallbackDirectories(homeDirectory: homeDirectory)
        self.isExecutableRegularFile = isExecutableRegularFile ?? ToolProbe.defaultIsExecutableRegularFile
    }
}

public enum ToolProbe {
    /// Shown after `navcenterctl doctor`'s tool table. Kept here so the fallback
    /// directory list has a single source under Sources/.
    public static let finderPathNotice = "Finder-launched apps do not see your shell PATH. Tools in /opt/homebrew/bin, /usr/local/bin, or ~/.local/bin are found automatically; otherwise set the variable with `launchctl setenv NAME /absolute/path` before opening Nav Center."

    public static func fallbackDirectories(homeDirectory: URL) -> [String] {
        var home = homeDirectory.standardizedFileURL.path
        if home.count > 1, home.hasSuffix("/") { home.removeLast() }
        return ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin"]
    }

    public static func resolve(_ tool: ExternalTool, configuration: ToolProbeConfiguration) -> ToolStatus {
        let override = overrideValue(tool, environment: configuration.environment)
        if tool == .exportTool, override == nil {
            return status(tool, state: .builtIn, resolvedPath: nil, source: nil, summary: "built-in")
        }
        if let override, override.contains("/") {
            let variable = tool.environmentVariable ?? "override"
            if !override.hasPrefix("/") {
                return status(tool, state: .overrideInvalid, resolvedPath: override, source: nil, summary: "\(variable) must be an absolute path")
            }
            if configuration.isExecutableRegularFile(override) {
                return status(tool, state: .found, resolvedPath: override, source: .environment, summary: foundSummary(override, .environment))
            }
            return status(tool, state: .overrideInvalid, resolvedPath: override, source: nil, summary: "\(variable) is not an executable file")
        }

        guard let command = override ?? tool.defaultCommand else {
            return status(tool, state: .missing, resolvedPath: nil, source: nil, summary: "missing")
        }
        if command.hasPrefix("/") {
            if configuration.isExecutableRegularFile(command) {
                return status(tool, state: .found, resolvedPath: command, source: .defaultPath, summary: foundSummary(command, .defaultPath))
            }
            return status(tool, state: .missing, resolvedPath: nil, source: nil, summary: "missing")
        }

        for directory in pathDirectories(configuration.environment["PATH"] ?? "") where directory.hasPrefix("/") {
            let candidate = joined(directory, command)
            guard candidate.hasPrefix("/") else { continue }
            if configuration.isExecutableRegularFile(candidate) {
                return status(tool, state: .found, resolvedPath: candidate, source: .path, summary: foundSummary(candidate, .path))
            }
        }
        for directory in configuration.fallbackDirectories where directory.hasPrefix("/") {
            let candidate = joined(directory, command)
            guard candidate.hasPrefix("/") else { continue }
            if configuration.isExecutableRegularFile(candidate) {
                return status(tool, state: .found, resolvedPath: candidate, source: .fallback, summary: foundSummary(candidate, .fallback))
            }
        }
        return status(tool, state: .missing, resolvedPath: nil, source: nil, summary: "missing")
    }

    public static func report(configuration: ToolProbeConfiguration = .init()) -> ToolAvailabilityReport {
        ToolAvailabilityReport(tools: ExternalTool.allCases.map { resolve($0, configuration: configuration) })
    }

    public static func executablePath(for tool: ExternalTool, configuration: ToolProbeConfiguration) -> String? {
        let resolved = resolve(tool, configuration: configuration)
        guard resolved.state == .found else { return nil }
        return resolved.resolvedPath
    }

    public static func missingToolMessage(_ status: ToolStatus, action: String) -> String {
        let name = status.tool.displayName
        switch status.state {
        case .overrideInvalid:
            let variable = status.environmentVariable ?? status.tool.environmentVariable ?? "the override"
            return "\(action) needs \(name), but \(variable) does not point to an executable file. Fix or unset \(variable)."
        case .missing:
            if let variable = status.environmentVariable ?? status.tool.environmentVariable {
                return "\(action) needs \(name), which was not found on PATH or in /opt/homebrew/bin, /usr/local/bin, or ~/.local/bin. Set \(variable) to its absolute path, or \(status.installHint) and reopen Nav Center."
            }
            return "\(action) needs \(name), which was not found on PATH. Reinstall Xcode Command Line Tools or \(status.installHint)."
        case .found, .builtIn:
            return status.summary
        }
    }

    // stat + X_OK: FileManager.isExecutableFile treats directories as executable.
    static let defaultIsExecutableRegularFile: @Sendable (String) -> Bool = { path in
        guard !path.isEmpty else { return false }
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    private static func overrideValue(_ tool: ExternalTool, environment: [String: String]) -> String? {
        guard let name = tool.environmentVariable, let value = environment[name], !value.isEmpty else { return nil }
        return value
    }

    private static func pathDirectories(_ path: String) -> [String] {
        path.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
    }

    private static func joined(_ directory: String, _ command: String) -> String {
        if directory == "/" { return "/" + command }
        return directory.hasSuffix("/") ? directory + command : directory + "/" + command
    }

    private static func foundSummary(_ path: String, _ source: ToolSource) -> String {
        let origin: String
        switch source {
        case .environment: origin = "environment override"
        case .path: origin = "PATH"
        case .fallback: origin = "fallback directory"
        case .defaultPath: origin = "default path"
        }
        return "found at \(path) (\(origin))"
    }

    private static func status(
        _ tool: ExternalTool,
        state: ToolState,
        resolvedPath: String?,
        source: ToolSource?,
        summary: String
    ) -> ToolStatus {
        ToolStatus(
            tool: tool,
            state: state,
            resolvedPath: resolvedPath,
            source: source,
            environmentVariable: tool.environmentVariable,
            installHint: tool.installHint,
            summary: summary
        )
    }
}
