import Foundation

public struct RealtimeInterviewKitResult: Equatable {
    public let sessionConfigURL: URL
    public let transcriptURL: URL
    public let reviewPromptURL: URL
    public let outputURLs: [URL]
    public let wroteFiles: Bool
}

public final class RealtimeInterviewKitGenerator {
    private let repoRoot: URL
    private let model: String
    private let voice: String
    private let reasoningEffort: String

    public init(repoRoot: URL, model: String = "gpt-realtime-2", voice: String = "marin", reasoningEffort: String = "low") {
        self.repoRoot = repoRoot
        self.model = model
        self.voice = voice
        self.reasoningEffort = reasoningEffort
    }

    public func create(applicationPath: String, dryRun: Bool, overwrite: Bool) throws -> RealtimeInterviewKitResult {
        let resolved = try resolveApplicationPath(applicationPath)
        let urls = kitURLs(packageURL: resolved.packageURL)

        if !overwrite && !dryRun {
            for url in [urls.session, urls.reviewPrompt] where FileManager.default.fileExists(atPath: url.path) {
                throw NavCenterError.invalidPath("Realtime interview kit already exists: \(PathSafety.repoRelativePath(root: repoRoot, url: url)) (use --overwrite to replace it)")
            }
        }

        let context = try loadContext(resolved: resolved)
        if dryRun {
            return RealtimeInterviewKitResult(
                sessionConfigURL: urls.session,
                transcriptURL: urls.transcript,
                reviewPromptURL: urls.reviewPrompt,
                outputURLs: outputURLs(urls: urls, includeTranscript: !FileManager.default.fileExists(atPath: urls.transcript.path)),
                wroteFiles: false
            )
        }

        let shouldWriteTranscript = !FileManager.default.fileExists(atPath: urls.transcript.path)
        let sessionJSON = try prettyJSON(sessionClientSecretPayload(context: context))
        let transcript = transcriptTemplate(context: context)
        let reviewPrompt = codexReviewPrompt(context: context)

        try write(sessionJSON, to: urls.session, inside: resolved.packageURL)
        if shouldWriteTranscript {
            try write(transcript, to: urls.transcript, inside: resolved.packageURL)
        }
        try write(reviewPrompt, to: urls.reviewPrompt, inside: resolved.packageURL)

        return RealtimeInterviewKitResult(
            sessionConfigURL: urls.session,
            transcriptURL: urls.transcript,
            reviewPromptURL: urls.reviewPrompt,
            outputURLs: outputURLs(urls: urls, includeTranscript: shouldWriteTranscript),
            wroteFiles: true
        )
    }

    public func reviewPrompt(applicationPath: String) throws -> String {
        try codexReviewPrompt(context: loadContext(resolved: resolveApplicationPath(applicationPath)))
    }

    public func sessionClientSecretPayload(applicationPath: String) throws -> [String: Any] {
        try sessionClientSecretPayload(context: loadContext(resolved: resolveApplicationPath(applicationPath)))
    }

    private struct KitURLs {
        var session: URL
        var transcript: URL
        var reviewPrompt: URL
    }

    private struct InterviewContext {
        var packageName: String
        var packageRelativePath: String
        var metadata: [String: String]
        var postingBody: String
        var resumeFile: String?
        var resumeBody: String
        var prepBody: String
        var atsSummary: String

        var company: String {
            metadata["company"] ?? "Unknown Company"
        }

        var role: String {
            metadata["role"] ?? "Unknown Role"
        }
    }

    private func resolveApplicationPath(_ applicationPath: String) throws -> ResolvedPackage {
        let packageURL = URL(fileURLWithPath: applicationPath, relativeTo: repoRoot).standardizedFileURL
        let relative = PathSafety.repoRelativePath(root: repoRoot, url: packageURL)
        guard relative.split(separator: "/").count == 2, relative.hasPrefix("applications/") else {
            throw NavCenterError.invalidPath("Expected an application package directory like applications/<application>: \(applicationPath)")
        }
        return try PathSafety.resolvePackage(root: repoRoot, packageName: packageURL.lastPathComponent)
    }

    private func kitURLs(packageURL: URL) -> KitURLs {
        KitURLs(
            session: packageURL.appendingPathComponent("interview-realtime-session.json"),
            transcript: packageURL.appendingPathComponent("interview-transcript.md"),
            reviewPrompt: packageURL.appendingPathComponent("interview-review-prompt.md")
        )
    }

    private func outputURLs(urls: KitURLs, includeTranscript: Bool) -> [URL] {
        var output = [urls.session, urls.reviewPrompt]
        if includeTranscript {
            output.append(urls.transcript)
        }
        return output.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func loadContext(resolved: ResolvedPackage) throws -> InterviewContext {
        let postingURL = resolved.packageURL.appendingPathComponent("posting.md")
        try PathSafety.assertExistingRegularFile(postingURL, inside: resolved.packageURL, label: "posting.md")
        let posting = Markdown.parseFrontmatter(try String(contentsOf: postingURL))

        let resumeFile = try FileManager.default.contentsOfDirectory(atPath: resolved.packageURL.path)
            .filter { $0.range(of: #"^Resume_.*\.md$"#, options: .regularExpression) != nil }
            .sorted()
            .first
        let resumeBody = try resumeFile.map { file in
            let url = resolved.packageURL.appendingPathComponent(file)
            try PathSafety.assertExistingRegularFile(url, inside: resolved.packageURL, label: "Resume source")
            return Markdown.parseFrontmatter(try String(contentsOf: url)).body
        } ?? ""
        let prepURL = resolved.packageURL.appendingPathComponent("interview-prep.md")
        let prepBody: String
        if FileManager.default.fileExists(atPath: prepURL.path) {
            try PathSafety.assertExistingRegularFile(prepURL, inside: resolved.packageURL, label: "interview-prep.md")
            prepBody = Markdown.parseFrontmatter(try String(contentsOf: prepURL)).body
        } else {
            prepBody = ""
        }

        return InterviewContext(
            packageName: resolved.packageName,
            packageRelativePath: PathSafety.repoRelativePath(root: repoRoot, url: resolved.packageURL),
            metadata: posting.metadata,
            postingBody: posting.body,
            resumeFile: resumeFile,
            resumeBody: resumeBody,
            prepBody: prepBody,
            atsSummary: readAtsSummary(resolved.packageURL)
        )
    }

    private func sessionClientSecretPayload(context: InterviewContext) -> [String: Any] {
        [
            "session": [
                "type": "realtime",
                "model": model,
                "output_modalities": ["audio", "text"],
                "reasoning": [
                    "effort": reasoningEffort
                ],
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24000
                        ],
                        "turn_detection": [
                            "type": "server_vad"
                        ]
                    ],
                    "output": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24000
                        ],
                        "voice": voice
                    ]
                ],
                "instructions": realtimeInstructions(context: context)
            ]
        ]
    }

    private func realtimeInstructions(context: InterviewContext) -> String {
        let postingSignals = TextUtil.unique(TextUtil.splitSignals(context.postingBody), limit: 8)
        let resumeProof = TextUtil.unique(TextUtil.splitSignals(context.resumeBody), limit: 8)
        let prepSignals = TextUtil.unique(TextUtil.splitSignals(context.prepBody), limit: 6)
        return """
        # Role and Objective
        You are a realistic interviewer for \(context.company)'s \(context.role) interview. Run a focused mock interview that helps the candidate practice for this exact package.

        # Interview Context
        Package: \(context.packageRelativePath)
        Company: \(context.company)
        Role: \(context.role)
        Location: \(context.metadata["location"] ?? "Not captured")
        Salary: \(context.metadata["salary"] ?? "Not captured")
        ATS context: \(context.atsSummary)

        # Role Signals
        \(bullets(postingSignals, fallback: "Use the posting to infer role requirements."))

        # Candidate Proof Points
        \(bullets(resumeProof, fallback: "Use the tailored resume and interview-prep file for proof points."))

        # Prepared Practice Notes
        \(bullets(prepSignals, fallback: "No interview-prep.md content was found. Emphasize role requirements from the posting and grounded resume evidence."))

        # Conversation Flow
        1. Open with one concise greeting and confirm this is a mock interview for \(context.role).
        2. Ask one question at a time.
        3. Ask targeted follow-ups when an answer is vague, missing evidence, or skips tradeoffs.
        4. Cover recruiter fit, technical depth, leadership, role motivation, and candidate questions.
        5. End after 8 substantive questions or when the candidate asks to stop.
        6. At the end, give a brief spoken wrap-up and tell the candidate to save the transcript for Codex review.

        # Interviewer Behavior
        Ask one question at a time. Keep questions concise and realistic. Do not answer for the candidate. Do not invent candidate experience. Push for STAR structure, metrics, constraints, tradeoffs, and role-specific examples. If audio is unclear, ask for a short clarification instead of guessing.

        # After-Action Review Boundary
        Do not provide a long coaching report during the live interview. The after-action review is handled by Codex after the transcript is saved in \(context.packageRelativePath)/interview-transcript.md.
        """
    }

    private func transcriptTemplate(context: InterviewContext) -> String {
        """
        ---
        type: "interview-transcript"
        company: \(Markdown.yamlString(context.company))
        role: \(Markdown.yamlString(context.role))
        application: \(Markdown.yamlString(context.packageName))
        model: \(Markdown.yamlString(model))
        status: "draft"
        created: \(Markdown.yamlString(ISO8601DateFormatter().string(from: Date())))
        ---

        # Mock Interview Transcript - \(context.company) \(context.role)

        ## Session

        - Package: \(context.packageRelativePath)
        - Model: \(model)
        - Voice: \(voice)
        - Reasoning Effort: \(reasoningEffort)
        - Interview Date:

        ## Transcript

        - Interviewer:
        - Candidate:

        ## Immediate Notes

        - Strong answers:
        - Answers to tighten:
        - Follow-up practice:
        """
    }

    private func codexReviewPrompt(context: InterviewContext) -> String {
        """
        # Codex After-Action Interview Review

        Work only in this local package: \(context.packageRelativePath)

        Read:
        - \(context.packageRelativePath)/posting.md
        - \(context.resumeFile.map { "\(context.packageRelativePath)/\($0)" } ?? "\(context.packageRelativePath)/Resume_*.md")
        - \(context.packageRelativePath)/interview-prep.md if present
        - \(context.packageRelativePath)/interview-transcript.md

        Write `interview-review.md` in the same package. Do not edit generated artifacts, tracker files, vault mirrors, docs, config, scripts, or git history.

        The review should include:
        - Overall readiness: one short paragraph.
        - Best answers to keep: bullets tied to exact transcript evidence.
        - Answers to tighten: bullets with a concrete replacement framing.
        - Missing proof: role requirements from `posting.md` that did not show up in answers.
        - Next practice loop: 5 targeted practice questions.
        - Follow-up note angle: concise thank-you/follow-up positioning if this were a real interview.

        Keep feedback direct, specific, and grounded in the transcript. Do not add new resume claims.
        """
    }

    private func readAtsSummary(_ packageURL: URL) -> String {
        let atsURL = packageURL.appendingPathComponent("artifacts/ats-report.json")
        guard FileManager.default.fileExists(atPath: atsURL.path),
              (try? PathSafety.assertExistingRegularFile(atsURL, inside: packageURL, label: "ATS report")) != nil,
              let data = try? Data(contentsOf: atsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "No ATS report found."
        }
        let score = json["score"] ?? json["overall_score"] ?? (json["summary"] as? [String: Any])?["score"] ?? ""
        return "\(score)" == "" ? "ATS report found." : "ATS score \(score)."
    }

    private func write(_ text: String, to url: URL, inside packageURL: URL) throws {
        try PathSafety.assertWritablePath(url, inside: packageURL, label: url.lastPathComponent)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func prettyJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }

    private func bullets(_ items: [String], fallback: String) -> String {
        (items.isEmpty ? [fallback] : items).map { "- \($0)" }.joined(separator: "\n")
    }
}
