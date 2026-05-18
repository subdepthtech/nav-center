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
        "feedback"
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
        try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try PathSafety.assertNoSymlinkSegments(workspaceRoot, root: workspaceRoot, label: "workspace root")

        var created: [String] = []
        for relativePath in Self.requiredDirectories {
            let url = workspaceRoot.appendingPathComponent(relativePath, isDirectory: true)
            let existed = fileManager.fileExists(atPath: url.path)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            try PathSafety.assertNoSymlinkSegments(url, root: workspaceRoot, label: relativePath)
            if !existed { created.append(relativePath) }
        }

        let masterResumeURL = workspaceRoot.appendingPathComponent("master-resumes/master_primary.yaml")
        let masterResumeCreated: Bool
        if fileManager.fileExists(atPath: masterResumeURL.path) {
            masterResumeCreated = false
        } else {
            try seedMasterResume.write(to: masterResumeURL, atomically: true, encoding: .utf8)
            masterResumeCreated = true
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
