import Foundation

public struct WorkspaceInitializationResult: Codable, Equatable {
    public let workspaceRoot: URL
    public let createdDirectories: [String]
    public let masterResumeCreated: Bool
}

public final class WorkspaceManager {
    public static let environmentKey = "NAV_CENTER_WORKSPACE_ROOT"
    public static let requiredDirectories = [
        "applications",
        "master-resumes",
        "tracking",
        "imports/originals",
        "imports/markdown",
        "backups",
        "logs",
        "feedback",
        "templates"
    ]

    public let workspaceRoot: URL
    private let fileManager: FileManager

    public init(workspaceRoot: URL, fileManager: FileManager = .default) {
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.fileManager = fileManager
    }

    public static func defaultWorkspaceRoot(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Nav Center", isDirectory: true)
            .appendingPathComponent("Workspace", isDirectory: true)
            .standardizedFileURL
    }

    public static func resolveWorkspaceRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) -> URL {
        if let override = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        _ = currentDirectory
        return defaultWorkspaceRoot(homeDirectory: homeDirectory)
    }

    @discardableResult
    public func initialize() throws -> WorkspaceInitializationResult {
        try initialize(includeTrackingDirectory: true)
    }

    /// Prepares the workspace surfaces needed for package browsing without
    /// opening or creating the optional tracker directory. An existing tracker
    /// path is still checked for symbolic links before package data is loaded.
    @discardableResult
    public func initializeForPackageBrowsing() throws -> WorkspaceInitializationResult {
        try initialize(includeTrackingDirectory: false)
    }

    private func initialize(includeTrackingDirectory: Bool) throws -> WorkspaceInitializationResult {
        try PathSafety.createDirectory(workspaceRoot, inside: workspaceRoot, label: "workspace root")

        var created: [String] = []
        for relativePath in Self.requiredDirectories where includeTrackingDirectory || relativePath != "tracking" {
            let url = workspaceRoot.appendingPathComponent(relativePath, isDirectory: true)
            let existed = fileManager.fileExists(atPath: url.path)
            try PathSafety.createDirectory(url, inside: workspaceRoot, label: relativePath)
            if !existed { created.append(relativePath) }
        }
        if !includeTrackingDirectory {
            let tracking = workspaceRoot.appendingPathComponent("tracking", isDirectory: true)
            try PathSafety.assertNoSymlinkSegments(tracking, root: workspaceRoot, label: "tracking directory")
        }

        let masterResumeURL = workspaceRoot.appendingPathComponent("master-resumes/master_primary.yaml")
        let masterResumeCreated: Bool
        if fileManager.fileExists(atPath: masterResumeURL.path) {
            try PathSafety.assertExistingRegularFile(masterResumeURL, inside: workspaceRoot, label: "master resume")
            masterResumeCreated = false
        } else {
            try PathSafety.atomicWrite(Data(seedMasterResume.utf8), to: masterResumeURL, inside: workspaceRoot, label: "master resume")
            masterResumeCreated = true
        }

        for name in ["resume.css", "cover-letter.css"] {
            let url = workspaceRoot.appendingPathComponent("templates/" + name)
            if !fileManager.fileExists(atPath: url.path) {
                let css = "@page { size: Letter; margin: 0.65in; } body { font-family: Helvetica, Arial, sans-serif; font-size: 10.5pt; line-height: 1.35; color: #111; } h1 { font-size: 20pt; } h2 { font-size: 13pt; } a { color: inherit; }"
                try PathSafety.atomicWrite(Data(css.utf8), to: url, inside: workspaceRoot, label: "document template")
            } else { try PathSafety.assertExistingRegularFile(url, inside: workspaceRoot, label: "document template") }
        }

        return WorkspaceInitializationResult(
            workspaceRoot: workspaceRoot,
            createdDirectories: created,
            masterResumeCreated: masterResumeCreated
        )
    }

    private var seedMasterResume: String {
        """
        profile:
          name: Example Candidate
          headline: ""
          location: ""
          links: []
        summary: []
        experience: []
        education: []
        certifications: []
        skills: []
        source_notes:
          - "Created by Nav Center onboarding. Replace sample values after reviewing imported documents."
        """
    }
}
