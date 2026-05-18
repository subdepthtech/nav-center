import Foundation

public struct InterviewPrepResult: Equatable {
    public let outputURL: URL
    public let wroteFile: Bool
}

public final class InterviewPrepGenerator {
    private let repoRoot: URL

    public init(repoRoot: URL) {
        self.repoRoot = repoRoot
    }

    public func create(applicationPath: String, dryRun: Bool, overwrite: Bool) throws -> InterviewPrepResult {
        let packageURL = URL(fileURLWithPath: applicationPath, relativeTo: repoRoot).standardizedFileURL
        let packageName = packageURL.lastPathComponent
        guard PathSafety.repoRelativePath(root: repoRoot, url: packageURL).split(separator: "/").count == 2,
              PathSafety.repoRelativePath(root: repoRoot, url: packageURL).hasPrefix("applications/") else {
            throw NavCenterError.invalidPath("Expected an application package directory like applications/<application>: \(applicationPath)")
        }
        let resolved = try PathSafety.resolvePackage(root: repoRoot, packageName: packageName)
        let postingURL = resolved.packageURL.appendingPathComponent("posting.md")
        let prepURL = resolved.packageURL.appendingPathComponent("interview-prep.md")
        guard FileManager.default.fileExists(atPath: postingURL.path) else {
            throw NavCenterError.notFound("Missing posting.md in \(PathSafety.repoRelativePath(root: repoRoot, url: resolved.packageURL))")
        }
        try PathSafety.assertExistingRegularFile(postingURL, inside: resolved.packageURL, label: "posting.md")
        if FileManager.default.fileExists(atPath: prepURL.path), !overwrite, !dryRun {
            throw NavCenterError.invalidPath("Interview prep already exists: \(PathSafety.repoRelativePath(root: repoRoot, url: prepURL)) (use --overwrite to replace it)")
        }

        if dryRun {
            return InterviewPrepResult(outputURL: prepURL, wroteFile: false)
        }

        let posting = Markdown.parseFrontmatter(try String(contentsOf: postingURL))
        let resumeName = try findResumeFile(resolved.packageURL)
        let resumeContent = try resumeName.map {
            let url = resolved.packageURL.appendingPathComponent($0)
            try PathSafety.assertExistingRegularFile(url, inside: resolved.packageURL, label: "Resume source")
            return try String(contentsOf: url)
        } ?? ""
        let atsSummary = readAtsSummary(resolved.packageURL)
        var sourceFiles = ["posting.md"]
        if let resumeName { sourceFiles.append(resumeName) }
        if atsSummary.sourceFile != nil { sourceFiles.append("artifacts/ats-report.json") }

        let content = buildPrepContent(
            applicationName: resolved.packageName,
            metadata: posting.metadata,
            sourceFiles: sourceFiles,
            postingSignals: postingSignals(posting.body),
            resumeProof: resumeProof(resumeContent),
            atsSummary: atsSummary.summary
        )
        try PathSafety.assertWritablePath(prepURL, inside: resolved.packageURL, label: "Interview prep output")
        try content.write(to: prepURL, atomically: true, encoding: .utf8)
        return InterviewPrepResult(outputURL: prepURL, wroteFile: true)
    }

    private func findResumeFile(_ packageURL: URL) throws -> String? {
        try FileManager.default.contentsOfDirectory(atPath: packageURL.path)
            .filter { $0.range(of: #"^Resume_.*\.md$"#, options: .regularExpression) != nil }
            .sorted()
            .first
    }

    private func postingSignals(_ text: String) -> [String] {
        let pattern = #"responsibilit|required|preferred|qualification|experience|clearance|cissp|nist|rmf|stig|incident|vulnerabilit|security|architecture|cloud|governance|risk|compliance|lead|manage|brief|stakeholder"#
        return TextUtil.unique(TextUtil.splitSignals(text).filter { $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }, limit: 8)
    }

    private func resumeProof(_ text: String) -> [String] {
        let body = Markdown.parseFrontmatter(text).body
        let pattern = #"led|built|implemented|developed|architected|briefed|managed|reduced|improved|coordinated|trained|authored|secured|automated|infrastructure|reliability|optimization|performance|patch|vulnerability|continuity|architecture|governance|compliance|risk"#
        return TextUtil.unique(TextUtil.splitSignals(body).filter { $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }, limit: 6)
    }

    private func readAtsSummary(_ packageURL: URL) -> (sourceFile: String?, summary: String) {
        let atsURL = packageURL.appendingPathComponent("artifacts/ats-report.json")
        guard FileManager.default.fileExists(atPath: atsURL.path),
              (try? PathSafety.assertExistingRegularFile(atsURL, inside: packageURL, label: "ATS report")) != nil,
              let data = try? Data(contentsOf: atsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, "No ATS report found yet. Run `atsim scan applications/<application>` if keyword alignment needs another pass before interview prep.")
        }
        let score = json["score"] ?? json["overall_score"] ?? (json["summary"] as? [String: Any])?["score"] ?? ""
        let warnings = (json["warnings"] as? [Any])?.count
        let warningText = warnings.map { "\($0) warning(s)" } ?? "no warnings recorded"
        return ("artifacts/ats-report.json", "\(score)" == "" ? "ATS report found with \(warningText)." : "ATS report found: score \(score); \(warningText).")
    }

    private func buildPrepContent(applicationName: String, metadata: [String: String], sourceFiles: [String], postingSignals: [String], resumeProof: [String], atsSummary: String) -> String {
        let company = metadata["company"] ?? "Unknown Company"
        let role = metadata["role"] ?? "Unknown Role"
        let sourceFileLines = sourceFiles.map { "  - \(Markdown.yamlString($0))" }.joined(separator: "\n")
        return """
        ---
        type: "interview-prep"
        company: \(Markdown.yamlString(company))
        role: \(Markdown.yamlString(role))
        application: \(Markdown.yamlString(applicationName))
        generated: \(Markdown.yamlString(ISO8601DateFormatter().string(from: Date())))
        source_files:
        \(sourceFileLines)
        status: "draft"
        ---

        # Interview Prep - \(company) \(role)

        ## Interview Snapshot

        - Company: \(company)
        - Role: \(role)
        - Location: \(metadata["location"] ?? "Not captured")
        - Work Settings: \(metadata["work_settings"] ?? "Not captured")
        - Salary: \(metadata["salary"] ?? "Not captured")
        - Source URL: \(metadata["source_url"]?.isEmpty == false ? metadata["source_url"]! : "Not captured")
        - ATS Context: \(atsSummary)
        - Prep Status: Draft. Review and personalize before the interview.

        ## Role Match Themes

        \(bullets(postingSignals, fallback: "Review `posting.md` and add the top 3 role requirements in plain language."))

        ## 60-Second Pitch

        - Draft: I am a cybersecurity and systems leader with active TS/SCI clearance and hands-on experience turning cyber requirements into operational outcomes. For this role, I would emphasize the overlap between the posting signals above and the strongest proof points from the tailored resume.
        - Practice: Keep this under 60 seconds and end with why this company/mission is interesting.

        ## Proof Map

        \(bullets(resumeProof, fallback: "Add 3 to 5 resume-backed proof points that directly support this role."))

        ## STAR Story Bank

        - Mission impact story: Situation, task, action, result.
        - Technical depth story: Problem, constraints, implementation, measurable outcome.
        - Leadership/conflict story: Stakeholders, tension, decision, result.
        - Learning/adaptation story: New domain, ramp-up method, outcome.

        ## Technical Drill

        - Rehearse the most likely technical topics from the posting signals.
        - Prepare one architecture/governance example and one hands-on troubleshooting example.
        - Be ready to explain tradeoffs, not just tools used.

        ## Recruiter Screen

        - Availability: Confirm timing, remote/hybrid/on-site constraints, and clearance fit.
        - Compensation: Use the salary notes below; avoid naming a number before confirming scope when possible.
        - Close: Ask about interview stages, decision timeline, and what success looks like in the first 90 days.

        ## Questions to Ask

        - What are the top priorities for this role in the first 90 days?
        - What security, compliance, or delivery problems prompted this opening?
        - How does this team measure success?
        - What is the interview process after this conversation?

        ## Salary/Compensation Notes

        - Posted range or salary signal: \(metadata["salary"] ?? "Not captured")
        - Target position: Anchor on scope, clearance value, leadership responsibility, and market range before negotiating.
        - Do not finalize compensation expectations until role level, location expectations, benefits, and bonus/equity context are clear.

        ## Logistics

        - Interview date/time:
        - Interviewer(s):
        - Meeting link/location:
        - Materials to have open: posting.md, tailored resume, ATS report, this prep file.

        ## Follow-Up Notes

        - Thank-you note angle:
        - New information learned:
        - Follow-up date:

        """
    }

    private func bullets(_ items: [String], fallback: String) -> String {
        (items.isEmpty ? [fallback] : items).map { "- \($0)" }.joined(separator: "\n")
    }
}
