import Foundation
import Darwin

public struct InlineApplicationSource: Equatable {
    public let content: String
    public let sourceURL: String
    public let title: String
    public let sourceName: String
    public let sourceID: String
    public let location: String
    public let salary: String
    public let postedDate: String
    public let jobType: String
    public let workSettings: String

    public init(
        content: String,
        sourceURL: String = "",
        title: String = "",
        sourceName: String = "pasted",
        sourceID: String = "",
        location: String = "",
        salary: String = "",
        postedDate: String = "",
        jobType: String = "",
        workSettings: String = ""
    ) {
        self.content = content
        self.sourceURL = sourceURL
        self.title = title
        self.sourceName = sourceName
        self.sourceID = sourceID
        self.location = location
        self.salary = salary
        self.postedDate = postedDate
        self.jobType = jobType
        self.workSettings = workSettings
    }
}

public enum ApplicationSource: Equatable {
    case job(String)
    case url(String)
    case payload(String)
    case inline(InlineApplicationSource)
}

public struct CreateApplicationOptions: Equatable {
    public let source: ApplicationSource
    public let company: String
    public let role: String
    public let date: String?
    public let dryRun: Bool
    public let overwrite: Bool
    public let allowLocalURL: Bool

    public init(source: ApplicationSource, company: String, role: String, date: String?, dryRun: Bool, overwrite: Bool, allowLocalURL: Bool) {
        self.source = source
        self.company = company
        self.role = role
        self.date = date
        self.dryRun = dryRun
        self.overwrite = overwrite
        self.allowLocalURL = allowLocalURL
    }
}

public struct CreateApplicationResult: Codable, Equatable {
    public let packageName: String
    public let packageURL: URL
    public let postingURL: URL
    public let dryRun: Bool

    public init(packageName: String, packageURL: URL, postingURL: URL, dryRun: Bool) {
        self.packageName = packageName
        self.packageURL = packageURL
        self.postingURL = postingURL
        self.dryRun = dryRun
    }
}

public final class ApplicationCreator {
    private let repoRoot: URL

    public init(repoRoot: URL) {
        self.repoRoot = repoRoot
    }

    public func create(options: CreateApplicationOptions) throws -> CreateApplicationResult {
        guard !options.company.isEmpty, !options.role.isEmpty else {
            throw NavCenterError.invalidPath("Both --company and --role are required.")
        }
        let date = options.date ?? currentDate()
        guard date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw NavCenterError.invalidPath("Invalid --date value: \(date)")
        }

        let packageName = "\(date)_\(TextUtil.slugify(options.company))_\(TextUtil.slugify(options.role))"
        let packageURL = PathSafety.applicationsRoot(repoRoot: repoRoot).appendingPathComponent(packageName, isDirectory: true)
        let postingURL = packageURL.appendingPathComponent("posting.md")
        let source = try readSource(options.source, allowLocalURL: options.allowLocalURL)
        try assertCompletePosting(source.content, label: source.url.isEmpty ? source.path : source.url)
        let posting = buildPosting(company: options.company, role: options.role, date: date, source: source)

        if options.dryRun {
            return CreateApplicationResult(packageName: packageName, packageURL: packageURL, postingURL: postingURL, dryRun: true)
        }
        if FileManager.default.fileExists(atPath: packageURL.path) {
            _ = try PathSafety.resolvePackage(root: repoRoot, packageName: packageName)
        } else {
            let applications = PathSafety.applicationsRoot(repoRoot: repoRoot)
            try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
            try PathSafety.assertNoSymlinkSegments(applications, root: repoRoot, label: "applications root")
        }
        if FileManager.default.fileExists(atPath: postingURL.path), !options.overwrite {
            throw NavCenterError.invalidPath("Posting already exists: \(PathSafety.repoRelativePath(root: repoRoot, url: postingURL)) (use --overwrite to replace it)")
        }
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        _ = try PathSafety.resolvePackage(root: repoRoot, packageName: packageName)
        try PathSafety.assertWritablePath(postingURL, inside: packageURL, label: "posting.md")
        try posting.write(to: postingURL, atomically: true, encoding: .utf8)
        return CreateApplicationResult(packageName: packageName, packageURL: packageURL, postingURL: postingURL, dryRun: false)
    }

    private struct Source {
        var type: String
        var path: String
        var url: String
        var title: String
        var sourceName: String
        var sourceID: String
        var location: String
        var salary: String
        var postedDate: String
        var jobType: String
        var workSettings: String
        var content: String
    }

    private func readSource(_ source: ApplicationSource, allowLocalURL: Bool) throws -> Source {
        switch source {
        case .job(let path):
            let url = URL(fileURLWithPath: path, relativeTo: repoRoot).standardizedFileURL
            try PathSafety.assertExistingRegularFile(url, inside: repoRoot, label: "Source job file")
            return Source(type: "local_file", path: PathSafety.repoRelativePath(root: repoRoot, url: url), url: "", title: "", sourceName: "", sourceID: "", location: "", salary: "", postedDate: "", jobType: "", workSettings: "", content: try String(contentsOf: url))
        case .inline(let inline):
            return Source(
                type: "pasted_text",
                path: "",
                url: inline.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines),
                title: inline.title.trimmingCharacters(in: .whitespacesAndNewlines),
                sourceName: inline.sourceName.trimmingCharacters(in: .whitespacesAndNewlines),
                sourceID: inline.sourceID.trimmingCharacters(in: .whitespacesAndNewlines),
                location: inline.location.trimmingCharacters(in: .whitespacesAndNewlines),
                salary: inline.salary.trimmingCharacters(in: .whitespacesAndNewlines),
                postedDate: inline.postedDate.trimmingCharacters(in: .whitespacesAndNewlines),
                jobType: inline.jobType.trimmingCharacters(in: .whitespacesAndNewlines),
                workSettings: inline.workSettings.trimmingCharacters(in: .whitespacesAndNewlines),
                content: inline.content
            )
        case .payload(let path):
            let url = URL(fileURLWithPath: path, relativeTo: repoRoot).standardizedFileURL
            if PathSafety.isInside(url, parent: repoRoot) {
                try PathSafety.assertExistingRegularFile(url, inside: repoRoot, label: "Payload file")
            }
            let data = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            return Source(
                type: "payload",
                path: sanitizedPayloadSourcePath((json["source_path"] as? String) ?? repoRelativePathOrEmpty(url)),
                url: string(json, "url", "source_url", "apply_url"),
                title: string(json, "title"),
                sourceName: string(json, "source", "source_name"),
                sourceID: string(json, "id", "job_id", "jrtk", "source_id"),
                location: string(json, "location"),
                salary: string(json, "salary"),
                postedDate: string(json, "posted_date", "postedDate"),
                jobType: string(json, "job_type", "jobType"),
                workSettings: string(json, "work_settings", "workSettings"),
                content: string(json, "description", "content", "posting")
            )
        case .url(let value):
            let url = try safeFetchURL(value, allowLocalURL: allowLocalURL)
            let data = try Data(contentsOf: url)
            let html = String(data: data, encoding: .utf8) ?? ""
            return Source(type: "url", path: "", url: url.absoluteString, title: extractTitle(html), sourceName: "", sourceID: "", location: "", salary: "", postedDate: "", jobType: "", workSettings: "", content: htmlToText(html))
        }
    }

    private func buildPosting(company: String, role: String, date: String, source: Source) -> String {
        var lines = [
            "---",
            "type: \"job-posting\"",
            "company: \(Markdown.yamlString(company))",
            "role: \(Markdown.yamlString(role))",
            "captured: \(Markdown.yamlString(date))",
            "source_type: \(Markdown.yamlString(source.type))",
            "source_path: \(Markdown.yamlString(source.path))",
            "source_url: \(Markdown.yamlString(source.url))",
            "source_name: \(Markdown.yamlString(source.sourceName))",
            "source_id: \(Markdown.yamlString(source.sourceID))",
            "location: \(Markdown.yamlString(source.location))",
            "salary: \(Markdown.yamlString(source.salary))",
            "posted_date: \(Markdown.yamlString(source.postedDate))",
            "job_type: \(Markdown.yamlString(source.jobType))",
            "work_settings: \(Markdown.yamlString(source.workSettings))",
            "status: \"sourced\"",
            "---",
            "",
            "# \(company) - \(role)",
            ""
        ]
        if !source.url.isEmpty { lines += ["Source URL: \(source.url)", ""] }
        if !source.path.isEmpty { lines += ["Source File: \(source.path)", ""] }
        if !source.title.isEmpty { lines += ["Captured Page Title: \(source.title)", ""] }
        if source.type == "url" {
            lines += ["> Captured from the live page with best-effort HTML-to-text extraction. Review the live posting before tailoring.", ""]
        }
        lines += ["## Posting Content", "", source.content.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        return lines.joined(separator: "\n")
    }

    private func assertCompletePosting(_ content: String, label: String) throws {
        let normalized = content.lowercased()
        let signals = ["responsibilities", "qualifications", "requirements", "required", "preferred", "experience", "clearance", "salary", "job summary", "about the job", "about the role"]
        let blockers = ["please sign in", "sign in to continue", "enable cookies", "captcha", "verify you are human", "access denied"]
        let signalCount = signals.filter { normalized.contains($0) }.count
        if content.count < 300 || signalCount < 2 || blockers.contains(where: { normalized.contains($0) }) {
            throw NavCenterError.invalidPath("Source \(label) does not look like a complete job posting.")
        }
    }

    private func repoRelativePathOrEmpty(_ url: URL) -> String {
        let relative = PathSafety.repoRelativePath(root: repoRoot, url: url)
        return relative == "." || relative.hasPrefix("../") || relative == "tmp" || relative.hasPrefix("tmp/") ? "" : relative
    }

    private func sanitizedPayloadSourcePath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed == "tmp" || trimmed.hasPrefix("tmp/") || trimmed.contains("..") {
            return ""
        }
        return trimmed
    }

    private func safeFetchURL(_ value: String, allowLocalURL: Bool) throws -> URL {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host(percentEncoded: false) else {
            throw NavCenterError.invalidPath("URL must use http or https: \(value)")
        }
        if allowLocalURL {
            return url
        }
        let hostname = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if hostname == "localhost" || hostname.hasSuffix(".localhost") || isUnsafeIPAddress(hostname) {
            throw NavCenterError.invalidPath("Refusing local or private URL destination: \(value)")
        }
        let addresses = try resolveHost(hostname)
        if addresses.contains(where: isUnsafeIPAddress) {
            throw NavCenterError.invalidPath("Refusing local or private URL destination: \(value)")
        }
        return url
    }

    private func resolveHost(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0 else {
            throw NavCenterError.invalidPath("Could not resolve URL host: \(host)")
        }
        defer { freeaddrinfo(result) }
        var addresses: [String] = []
        var cursor = result
        while cursor != nil {
            if let address = cursor?.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, cursor!.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.append(String(cString: buffer))
                }
            }
            cursor = cursor?.pointee.ai_next
        }
        return addresses
    }

    private func isUnsafeIPAddress(_ address: String) -> Bool {
        if let ipv4 = IPv4Address(address) {
            let parts = ipv4.octets
            let a = parts[0], b = parts[1]
            return a == 0
                || a == 10
                || a == 127
                || (a == 100 && (64...127).contains(b))
                || (a == 169 && b == 254)
                || (a == 172 && (16...31).contains(b))
                || (a == 192 && b == 168)
                || a >= 224
        }
        let lower = address.lowercased()
        return lower == "::"
            || lower == "::1"
            || lower.hasPrefix("fc")
            || lower.hasPrefix("fd")
            || lower.hasPrefix("fe8")
            || lower.hasPrefix("fe9")
            || lower.hasPrefix("fea")
            || lower.hasPrefix("feb")
            || lower.hasPrefix("ff")
    }
}

private struct IPv4Address {
    let octets: [UInt8]

    init?(_ value: String) {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var parsed: [UInt8] = []
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            parsed.append(octet)
        }
        octets = parsed
    }
}

private func string(_ json: [String: Any], _ keys: String...) -> String {
    for key in keys {
        if let value = json[key] as? String, !value.isEmpty { return value }
        if let value = json[key] { return String(describing: value) }
    }
    return ""
}

private func currentDate() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
}

private func extractTitle(_ html: String) -> String {
    guard let range = html.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive]) else { return "" }
    return html[range].replacingOccurrences(of: #"</?title[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
}

private func htmlToText(_ html: String) -> String {
    html
        .replacingOccurrences(of: #"<script[\s\S]*?</script>|<style[\s\S]*?</style>|<[^>]+>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
