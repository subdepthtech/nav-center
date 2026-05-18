import Foundation

enum DashboardAPIError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    case httpStatus(Int, String)
    case missingPackageName
    case repoMismatch(expected: String, actual: String)
    case serverUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let message), .serverUnavailable(let message):
            return message
        case .httpStatus(let status, let message):
            return "Dashboard API returned HTTP \(status): \(message)"
        case .missingPackageName:
            return "This application does not have an application package."
        case .repoMismatch(let expected, let actual):
            return "Dashboard server is for \(actual), but this app is running from \(expected)."
        }
    }
}

struct DashboardHealth: Codable {
    var ok: Bool
    var service: String
    var localOnly: Bool
    var features: DashboardFeatures? = nil
    var generatedAt: String
    var repoRoot: String
    var tracker: TrackerSource
    var packages: PackageSource
}

struct DashboardFeatures: Codable {
    var codexAppServer: Bool?
}

struct DashboardSummary: Codable {
    var generatedAt: String
    var localOnly: Bool
    var totals: DashboardTotals
    var statusCounts: [String: Int]
    var upcomingActions: [ApplicationSummary]
    var recentApplications: [ApplicationSummary]
    var packageHealth: PackageHealthSummary
    var sources: DashboardSources
}

struct DashboardTotals: Codable {
    var applications: Int
    var trackerRows: Int
    var packageOnly: Int
    var packages: Int
    var artifacts: Int
    var nextActionsDue: Int
    var pursueNow: Int
    var generated: Int
    var submitted: Int
    var interviews: Int
}

struct PackageHealthSummary: Codable {
    var withPosting: Int
    var withResumeSource: Int
    var withInterviewPrep: Int
    var withArtifacts: Int
    var withAtsFiles: Int
}

struct DashboardSources: Codable {
    var tracker: TrackerSource
    var packages: PackageSource
}

struct TrackerSource: Codable {
    var available: Bool
    var driver: String
    var readOnly: Bool
    var queryOnly: Bool
    var warnings: [String]
}

struct PackageSource: Codable {
    var available: Bool
    var scanned: Int
    var warnings: [String]
}

struct ApplicationSummary: Codable, Identifiable, Hashable {
    var id: String
    var packageName: String
    var date: String
    var company: String
    var role: String
    var location: String
    var status: String
    var nextActionDate: String
    var packageUrl: String?

    enum CodingKeys: String, CodingKey {
        case id
        case packageName
        case date
        case company
        case role
        case location
        case status
        case nextActionDate
        case packageUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeLossyString(forKey: .id)
        packageName = try container.decodeIfPresent(String.self, forKey: .packageName) ?? ""
        date = try container.decodeIfPresent(String.self, forKey: .date) ?? ""
        company = try container.decodeIfPresent(String.self, forKey: .company) ?? ""
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        location = try container.decodeIfPresent(String.self, forKey: .location) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        nextActionDate = try container.decodeIfPresent(String.self, forKey: .nextActionDate) ?? ""
        packageUrl = try container.decodeIfPresent(String.self, forKey: .packageUrl)
    }

    init(
        id: String,
        packageName: String,
        date: String,
        company: String,
        role: String,
        location: String,
        status: String,
        nextActionDate: String,
        packageUrl: String?
    ) {
        self.id = id
        self.packageName = packageName
        self.date = date
        self.company = company
        self.role = role
        self.location = location
        self.status = status
        self.nextActionDate = nextActionDate
        self.packageUrl = packageUrl
    }
}

struct ApplicationsResponse: Codable {
    var generatedAt: String
    var total: Int
    var limit: Int
    var offset: Int
    var applications: [ApplicationRecord]
    var sources: DashboardSources
}

struct ApplicationRecord: Codable, Identifiable, Hashable {
    var id: String
    var packageName: String
    var date: String
    var company: String
    var role: String
    var location: String
    var salary: String
    var status: String
    var nextActionDate: String
    var applicationDir: String
    var applyLink: String
    var sourceName: String
    var sourceId: String
    var notes: String
    var notesPreview: String
    var createdAt: String
    var updatedAt: String
    var source: ApplicationSource
    var health: PackageHealth
    var files: [PackageFile]
    var dbArtifacts: [JSONValue]

    enum CodingKeys: String, CodingKey {
        case id
        case packageName
        case date
        case company
        case role
        case location
        case salary
        case status
        case nextActionDate
        case applicationDir
        case applyLink
        case sourceName
        case sourceId
        case notes
        case notesPreview
        case createdAt
        case updatedAt
        case source
        case health
        case files
        case dbArtifacts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeLossyString(forKey: .id)
        packageName = try container.decodeIfPresent(String.self, forKey: .packageName) ?? ""
        date = try container.decodeIfPresent(String.self, forKey: .date) ?? ""
        company = try container.decodeIfPresent(String.self, forKey: .company) ?? ""
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        location = try container.decodeIfPresent(String.self, forKey: .location) ?? ""
        salary = try container.decodeIfPresent(String.self, forKey: .salary) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        nextActionDate = try container.decodeIfPresent(String.self, forKey: .nextActionDate) ?? ""
        applicationDir = try container.decodeIfPresent(String.self, forKey: .applicationDir) ?? ""
        applyLink = try container.decodeIfPresent(String.self, forKey: .applyLink) ?? ""
        sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        sourceId = try container.decodeIfPresent(String.self, forKey: .sourceId) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        notesPreview = try container.decodeIfPresent(String.self, forKey: .notesPreview) ?? ""
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        source = try container.decodeIfPresent(ApplicationSource.self, forKey: .source) ?? .empty
        health = try container.decodeIfPresent(PackageHealth.self, forKey: .health) ?? .empty
        files = try container.decodeIfPresent([PackageFile].self, forKey: .files) ?? []
        dbArtifacts = try container.decodeIfPresent([JSONValue].self, forKey: .dbArtifacts) ?? []
    }

    init(
        id: String,
        packageName: String,
        date: String,
        company: String,
        role: String,
        location: String,
        salary: String,
        status: String,
        nextActionDate: String,
        applicationDir: String,
        applyLink: String,
        sourceName: String,
        sourceId: String,
        notes: String,
        notesPreview: String,
        createdAt: String,
        updatedAt: String,
        source: ApplicationSource,
        health: PackageHealth,
        files: [PackageFile],
        dbArtifacts: [JSONValue]
    ) {
        self.id = id
        self.packageName = packageName
        self.date = date
        self.company = company
        self.role = role
        self.location = location
        self.salary = salary
        self.status = status
        self.nextActionDate = nextActionDate
        self.applicationDir = applicationDir
        self.applyLink = applyLink
        self.sourceName = sourceName
        self.sourceId = sourceId
        self.notes = notes
        self.notesPreview = notesPreview
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
        self.health = health
        self.files = files
        self.dbArtifacts = dbArtifacts
    }
}

struct ApplicationSource: Codable, Hashable {
    var tracker: Bool
    var package: Bool

    static let empty = ApplicationSource(tracker: false, package: false)
}

struct PackageResponse: Codable {
    var generatedAt: String
    var package: ApplicationPackage
    var application: ApplicationRecord?
    var statusEvents: [JSONValue]
    var sources: DashboardSources
}

struct ApplicationPackage: Codable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var applicationDir: String
    var metadata: [String: JSONValue]
    var files: [PackageFile]
    var tabs: [PackageTab]
    var artifactSummary: ArtifactSummary
    var health: PackageHealth

    var company: String {
        metadata["company"]?.stringValue ?? ""
    }

    var role: String {
        metadata["role"]?.stringValue ?? ""
    }
}

struct PackageFile: Codable, Identifiable, Hashable {
    var id: String { relativePath }
    var relativePath: String
    var label: String
    var kind: String
    var format: String
    var size: Int
    var modifiedAt: String
    var previewable: Bool
    var previewUrl: String?
    var rawUrl: String?
    var editable: Bool
}

struct PackageTab: Codable, Identifiable, Hashable {
    var id: String { key }
    var key: String
    var label: String
    var available: Bool
    var fileCount: Int
    var primaryFile: PackageFile?
    var files: [PackageFile]
}

struct ArtifactSummary: Codable, Hashable {
    var total: Int
    var previewable: Int
    var ats: Int
    var byFormat: [String: Int]
    var byKind: [String: Int]
}

struct PackageHealth: Codable, Hashable {
    var hasPosting: Bool
    var hasResumeSource: Bool
    var hasCoverLetterSource: Bool
    var hasInterviewPrep: Bool
    var artifactCount: Int
    var atsFileCount: Int
    var hasAtsReport: Bool?
    var hasAtsJson: Bool?
    var previewableCount: Int

    static let empty = PackageHealth(
        hasPosting: false,
        hasResumeSource: false,
        hasCoverLetterSource: false,
        hasInterviewPrep: false,
        artifactCount: 0,
        atsFileCount: 0,
        hasAtsReport: false,
        hasAtsJson: false,
        previewableCount: 0
    )
}

struct PackageTabPreviewResponse: Codable {
    var packageName: String
    var tab: PackageTab
    var file: PackagePreviewFile?
    var content: String?
}

struct PackageFilePreviewResponse: Codable, Hashable {
    var file: PackagePreviewFile
    var content: String
}

struct PackagePreviewFile: Codable, Hashable {
    var packageName: String
    var path: String
    var label: String
    var size: Int
    var modifiedAt: String
    var contentType: String
    var encoding: String?
}

struct ActionLogResponse: Codable {
    var generatedAt: String
    var localOnly: Bool
    var actions: [DashboardAction]
}

struct ActionResultResponse: Codable {
    var ok: Bool
    var action: DashboardAction
}

struct RealtimeInterviewKitResponse: Codable, Hashable {
    var ok: Bool
    var packageName: String
    var generatedAt: String
    var outputPaths: [String]
    var sessionConfigPath: String
    var transcriptPath: String
    var reviewPromptPath: String
    var wroteFiles: Bool
}

struct CodexStatusResponse: Codable, Hashable {
    var ok: Bool
    var userAgent: String
    var codexHome: String
    var account: CodexAccount?
    var requiresOpenaiAuth: Bool
    var authMethod: String?
    var localOnly: Bool
}

struct CodexAccount: Codable, Hashable {
    var type: String
    var email: String?
    var planType: String?
}

struct CodexLoginStartRequest: Encodable {
    var type: String
}

struct CodexLoginStartResponse: Codable, Hashable {
    var type: String
    var loginId: String?
    var authUrl: String?
    var verificationUrl: String?
    var userCode: String?
}

struct CodexChatRequest: Encodable {
    var packageName: String
    var message: String
    var threadId: String?
    var allowEdits: Bool
    var confirmed: Bool
}

struct CodexChatResponse: Codable, Hashable {
    var ok: Bool
    var threadId: String
    var turnId: String
    var status: String
    var message: String
    var diff: String
    var account: CodexAccount?
}

struct CodexChatMessage: Identifiable, Hashable {
    enum Role: String {
        case user
        case assistant
        case system
    }

    var id = UUID()
    var role: Role
    var text: String
}

struct JobDescriptionIntakeRequest: Equatable, Hashable {
    var company: String
    var role: String
    var postingText: String
    var sourceURL: String
    var sourceName: String
    var sourceID: String
    var location: String
    var salary: String
    var postedDate: String
    var jobType: String
    var workSettings: String

    init(
        company: String = "",
        role: String = "",
        postingText: String = "",
        sourceURL: String = "",
        sourceName: String = "pasted",
        sourceID: String = "",
        location: String = "",
        salary: String = "",
        postedDate: String = "",
        jobType: String = "",
        workSettings: String = ""
    ) {
        self.company = company
        self.role = role
        self.postingText = postingText
        self.sourceURL = sourceURL
        self.sourceName = sourceName
        self.sourceID = sourceID
        self.location = location
        self.salary = salary
        self.postedDate = postedDate
        self.jobType = jobType
        self.workSettings = workSettings
    }

    var trimmed: JobDescriptionIntakeRequest {
        JobDescriptionIntakeRequest(
            company: company.trimmingCharacters(in: .whitespacesAndNewlines),
            role: role.trimmingCharacters(in: .whitespacesAndNewlines),
            postingText: postingText.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceURL: sourceURL.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceName: sourceName.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyFallback("pasted"),
            sourceID: sourceID.trimmingCharacters(in: .whitespacesAndNewlines),
            location: location.trimmingCharacters(in: .whitespacesAndNewlines),
            salary: salary.trimmingCharacters(in: .whitespacesAndNewlines),
            postedDate: postedDate.trimmingCharacters(in: .whitespacesAndNewlines),
            jobType: jobType.trimmingCharacters(in: .whitespacesAndNewlines),
            workSettings: workSettings.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct DashboardAction: Codable, Identifiable, Hashable {
    var id: String
    var action: String
    var label: String
    var packageName: String
    var status: String
    var requestedAt: String
    var completedAt: String?
    var durationMs: Int
    var command: String?
    var outputPath: String?
    var exitCode: Int?
    var signal: String?
    var message: String
    var stdoutTail: String
    var stderrTail: String
}

enum DashboardDestination: String, CaseIterable, Identifiable {
    case overview
    case applications
    case packages
    case searches
    case resume
    case exports
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            return "Overview"
        case .applications:
            return "Applications"
        case .packages:
            return "Packages"
        case .searches:
            return "Job Searches"
        case .resume:
            return "Master Resume"
        case .exports:
            return "Exports"
        case .settings:
            return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            return "rectangle.grid.2x2"
        case .applications:
            return "list.bullet.rectangle"
        case .packages:
            return "shippingbox"
        case .searches:
            return "magnifyingglass"
        case .resume:
            return "person.text.rectangle"
        case .exports:
            return "square.and.arrow.down"
        case .settings:
            return "gearshape"
        }
    }
}

struct PackageHealthCheck: Identifiable, Hashable {
    var id: String { label }
    var label: String
    var isPassing: Bool

    static func items(for package: ApplicationPackage) -> [PackageHealthCheck] {
        [
            PackageHealthCheck(label: "Posting captured", isPassing: package.health.hasPosting),
            PackageHealthCheck(label: "Resume drafted", isPassing: package.health.hasResumeSource),
            PackageHealthCheck(label: "PDF generated", isPassing: package.files.contains { $0.format.lowercased() == "pdf" }),
            PackageHealthCheck(label: "DOCX generated", isPassing: package.files.contains { $0.format.lowercased() == "docx" }),
            PackageHealthCheck(
                label: "Extraction OK",
                isPassing: package.files.contains {
                    $0.relativePath.lowercased().hasSuffix(".pdf.txt")
                        || $0.relativePath.lowercased().hasSuffix(".docx.txt")
                }
            ),
            PackageHealthCheck(label: "ATS available", isPassing: package.health.atsFileCount > 0),
            PackageHealthCheck(label: "Interview prep", isPassing: package.health.hasInterviewPrep)
        ]
    }
}

enum PackageTabKey: String, CaseIterable, Identifiable {
    case review
    case posting
    case resumeSource = "resume-source"
    case notes
    case artifacts
    case ats
    case interviewPrep = "interview-prep"

    var id: String { rawValue }
}

enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        default:
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

extension KeyedDecodingContainer {
    func decodeLossyString(forKey key: Key) throws -> String {
        if let string = try? decode(String.self, forKey: key) {
            return string
        }
        if let integer = try? decode(Int.self, forKey: key) {
            return String(integer)
        }
        if let double = try? decode(Double.self, forKey: key) {
            return String(double)
        }
        return ""
    }
}
