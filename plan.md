# Nav Center Codex Managed Mode and Beta Reliability Implementation Plan

> **For Codex agents:** Implement this plan task-by-task in order. Use the checkbox (`- [ ]`) steps for tracking, keep commits scoped to each task, and run the listed verification commands before marking a task complete.

**Goal:** Update Nav Center so the in-app assistant uses Codex managed ChatGPT login through `codex app-server`, presents accurate auth choices, and removes the beta setup failures around missing Codex versions, package artifacts, export dependencies, and ATS tooling.

**Architecture:** Nav Center remains a local-first SwiftUI macOS app. The assistant path uses a local Codex app-server process over `stdio://`; Nav Center owns the UI, process lifecycle, status checks, and JSON-RPC calls, while Codex owns ChatGPT token storage and refresh. Package generation and export reliability are handled inside Nav Center Core so the app creates package-local source files, seeds export templates, preflights external tools, and reports actionable setup status before users hit failing actions.

**Tech Stack:** Swift 5.9, SwiftUI, Foundation `Process`, XCTest, Codex app-server JSON-RPC over JSONL stdio, Pandoc, Poppler `pdftotext`, Google Chrome headless PDF export, optional `atsim`.

---

## Ground Rules

- Do not implement direct native "OpenAI OAuth" in Nav Center. The supported ChatGPT sign-in path is Codex managed ChatGPT login through app-server.
- Treat `codex app-server` as an engine dependency, not a user-facing CLI workflow.
- Use `stdio://` for v1. Do not use WebSocket or Unix socket in the app update.
- Keep API key mode app-server backed for this update: Nav Center may collect the key once, send it to `account/login/start`, and then let Codex store it.
- Do not make Nav Center read, write, display, or copy `~/.codex/auth.json`.
- Keep all generated package artifacts inside `applications/<package>/artifacts/`.
- Keep commits scoped by task.

## Files And Responsibilities

- Modify `Sources/NavCenterApp/Services/NativeCodexBridge.swift`: app-server process lifecycle, JSON-RPC handshake, auth status, login start, stderr diagnostics, and version preflight enforcement.
- Create `Sources/NavCenterApp/Services/CodexAppServerPreflight.swift`: testable Codex binary discovery, version/help parsing, and user-facing install/update guidance.
- Modify `Sources/NavCenterApp/Views/CodexPanelView.swift`: product labels, sign-in mode controls, API key entry, browser/device-code flow, and missing/outdated Codex guidance.
- Modify `Sources/NavCenterApp/Stores/DashboardStore.swift`: auth mode state, API key login call, and clearer error propagation.
- Modify `Sources/NavCenterApp/Models/DashboardModels.swift`: login request payload and status fields for Codex preflight.
- Modify `Sources/NavCenterCore/WorkspaceManager.swift`: seed `templates/`, `templates/resume.css`, and `templates/cover-letter.css` during workspace initialization.
- Modify `Sources/NavCenterCore/ApplicationCreator.swift`: create package-local starter resume markdown and `artifacts/` at package creation time.
- Modify `Sources/NavCenterCore/ArtifactExporter.swift`: expose dependency preflight without running export and return structured missing-tool messages.
- Modify `Sources/NavCenterCore/PackageActionRunner.swift`: run refresh-resume through `ArtifactExporter` directly and block ATS scan with a clear `atsim` guidance message when missing.
- Modify `Sources/NavCenterCore/FeedbackDiagnostics.swift`: include sanitized Codex version/help status and export dependency status in diagnostic reports.
- Modify `Sources/NavCenterApp/Views/PackageDetailView.swift`: make Review usable when PDF artifacts are missing by showing source markdown and action guidance.
- Modify `README.md` and `docs/BETA.md`: document Codex Managed Mode, API Key Mode, required Codex version behavior, Homebrew dependency commands, and package artifact expectations.
- Add `Tests/NavCenterTests/CodexAppServerPreflightTests.swift`.
- Add `Tests/NavCenterTests/ApplicationCreatorScaffoldTests.swift`.
- Add `Tests/NavCenterTests/ArtifactExporterPreflightTests.swift`.
- Add `Tests/NavCenterTests/PackageActionRunnerDependencyTests.swift`.

---

## Task 1: Codex App-Server Preflight

**Files:**
- Create: `Sources/NavCenterApp/Services/CodexAppServerPreflight.swift`
- Modify: `Sources/NavCenterApp/Models/DashboardModels.swift`
- Modify: `Sources/NavCenterApp/Services/NativeCodexBridge.swift`
- Test: `Tests/NavCenterTests/CodexAppServerPreflightTests.swift`

- [ ] **Step 1: Write failing tests for version and help parsing**

Create `Tests/NavCenterTests/CodexAppServerPreflightTests.swift`:

```swift
import XCTest
@testable import NavCenterApp

final class CodexAppServerPreflightTests: XCTestCase {
    func testParsesModernCodexVersion() {
        let parsed = CodexAppServerPreflight.parseVersion("codex-cli 0.130.0\n")

        XCTAssertEqual(parsed?.major, 0)
        XCTAssertEqual(parsed?.minor, 130)
        XCTAssertEqual(parsed?.patch, 0)
    }

    func testRejectsMissingListenSupport() {
        let report = CodexAppServerPreflight.evaluate(
            command: "/opt/homebrew/bin/codex",
            versionOutput: "codex-cli 0.80.0\n",
            helpOutput: "Usage: codex app-server\n",
            versionExitCode: 0,
            helpExitCode: 0
        )

        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.reason, "installed-codex-too-old")
        XCTAssertTrue(report.message.contains("does not support `codex app-server --listen stdio://`"))
        XCTAssertTrue(report.installCommand.contains("brew upgrade --cask nav-center"))
    }

    func testAcceptsListenSupportEvenWhenVersionIsUnknown() {
        let report = CodexAppServerPreflight.evaluate(
            command: "/opt/homebrew/bin/codex",
            versionOutput: "codex dev\n",
            helpOutput: "--listen <URL>\nSupported values: `stdio://`",
            versionExitCode: 0,
            helpExitCode: 0
        )

        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.reason, "ok")
    }

    func testMissingCodexGivesInstallGuidance() {
        let report = CodexAppServerPreflight.evaluate(
            command: "codex",
            versionOutput: "",
            helpOutput: "",
            versionExitCode: 127,
            helpExitCode: 127
        )

        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.reason, "codex-not-found")
        XCTAssertTrue(report.message.contains("Install Codex"))
        XCTAssertTrue(report.installCommand.contains("codex"))
    }
}
```

- [ ] **Step 2: Run the new tests and verify they fail**

Run:

```sh
swift test --filter CodexAppServerPreflightTests
```

Expected: build fails because `CodexAppServerPreflight` does not exist.

- [ ] **Step 3: Add the preflight model and parser**

Create `Sources/NavCenterApp/Services/CodexAppServerPreflight.swift`:

```swift
import Foundation

struct CodexAppServerPreflightReport: Codable, Hashable {
    var ok: Bool
    var command: String
    var version: String
    var reason: String
    var message: String
    var installCommand: String
}

struct CodexAppServerVersion: Comparable, Hashable {
    var major: Int
    var minor: Int
    var patch: Int

    static func < (lhs: CodexAppServerVersion, rhs: CodexAppServerVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

enum CodexAppServerPreflight {
    static func parseVersion(_ output: String) -> CodexAppServerVersion? {
        let pattern = #"(\d+)\.(\d+)\.(\d+)"#
        guard let match = output.range(of: pattern, options: .regularExpression) else { return nil }
        let parts = output[match].split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return CodexAppServerVersion(major: parts[0], minor: parts[1], patch: parts[2])
    }

    static func evaluate(
        command: String,
        versionOutput: String,
        helpOutput: String,
        versionExitCode: Int32,
        helpExitCode: Int32
    ) -> CodexAppServerPreflightReport {
        let version = versionOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let supportsListen = helpExitCode == 0
            && helpOutput.contains("--listen")
            && helpOutput.contains("stdio://")
        if versionExitCode == 127 || helpExitCode == 127 {
            return CodexAppServerPreflightReport(
                ok: false,
                command: command,
                version: version,
                reason: "codex-not-found",
                message: "Install Codex before using Codex Managed Mode. Nav Center needs a local Codex app-server binary, but users do not need to operate the CLI UI.",
                installCommand: "brew install --cask nav-center"
            )
        }
        if !supportsListen {
            return CodexAppServerPreflightReport(
                ok: false,
                command: command,
                version: version,
                reason: "installed-codex-too-old",
                message: "The installed Codex binary does not support `codex app-server --listen stdio://`. Update Codex/Nav Center before signing in.",
                installCommand: "brew update && brew upgrade --cask nav-center"
            )
        }
        return CodexAppServerPreflightReport(
            ok: true,
            command: command,
            version: version,
            reason: "ok",
            message: "Codex app-server is available.",
            installCommand: ""
        )
    }
}
```

- [ ] **Step 4: Add preflight to status response**

Modify `Sources/NavCenterApp/Models/DashboardModels.swift`:

```swift
struct CodexStatusResponse: Codable, Hashable {
    var ok: Bool
    var userAgent: String
    var codexHome: String
    var account: CodexAccount?
    var requiresOpenaiAuth: Bool
    var authMethod: String?
    var localOnly: Bool
    var preflight: CodexAppServerPreflightReport?
}
```

Update every `CodexStatusResponse(...)` construction in tests and services to include `preflight: nil` until Task 2 wires real data.

- [ ] **Step 5: Wire NativeCodexBridge to run the preflight before spawning**

In `Sources/NavCenterApp/Services/NativeCodexBridge.swift`, add:

```swift
private var cachedPreflight: CodexAppServerPreflightReport?

private func preflight() -> CodexAppServerPreflightReport {
    if let cachedPreflight { return cachedPreflight }
    let version = runCodexProbe([command, "--version"])
    let help = runCodexProbe([command, "app-server", "--help"])
    let report = CodexAppServerPreflight.evaluate(
        command: command,
        versionOutput: version.stdout + version.stderr,
        helpOutput: help.stdout + help.stderr,
        versionExitCode: version.status,
        helpExitCode: help.status
    )
    cachedPreflight = report
    return report
}

private func runCodexProbe(_ arguments: [String]) -> ProcessResult {
    let executable = command.hasPrefix("/") ? command : "/usr/bin/env"
    let args = command.hasPrefix("/") ? Array(arguments.dropFirst()) : arguments
    return (try? ProcessRunner.run(executable, args, cwd: repoRoot)) ?? ProcessResult(status: 127, stdout: "", stderr: "")
}
```

Then call it at the start of `start()`:

```swift
let report = preflight()
guard report.ok else {
    throw DashboardAPIError.serverUnavailable(report.message)
}
```

- [ ] **Step 6: Run the focused tests**

Run:

```sh
swift test --filter CodexAppServerPreflightTests
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```sh
git add Sources/NavCenterApp/Services/CodexAppServerPreflight.swift Sources/NavCenterApp/Models/DashboardModels.swift Sources/NavCenterApp/Services/NativeCodexBridge.swift Tests/NavCenterTests
git commit -m "fix: preflight codex app-server compatibility"
```

---

## Task 2: Correct App-Server Handshake And Auth Calls

**Files:**
- Modify: `Sources/NavCenterApp/Services/NativeCodexBridge.swift`
- Modify: `Sources/NavCenterApp/Models/DashboardModels.swift`
- Modify: `Sources/NavCenterApp/Stores/DashboardStore.swift`
- Test: `Tests/NavCenterTests/DashboardModelsTests.swift`

- [ ] **Step 1: Write failing model tests for API key login payload**

Add to `Tests/NavCenterTests/DashboardModelsTests.swift`:

```swift
func testCodexLoginStartRequestEncodesApiKeyWhenPresent() throws {
    let request = CodexLoginStartRequest(type: "apiKey", apiKey: "sk-test")
    let data = try JSONEncoder().encode(request)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    XCTAssertEqual(object?["type"] as? String, "apiKey")
    XCTAssertEqual(object?["apiKey"] as? String, "sk-test")
}

func testCodexLoginStartRequestOmitsEmptyApiKey() throws {
    let request = CodexLoginStartRequest(type: "chatgpt", apiKey: "")
    let data = try JSONEncoder().encode(request)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    XCTAssertEqual(object?["type"] as? String, "chatgpt")
    XCTAssertNil(object?["apiKey"])
}
```

- [ ] **Step 2: Run the focused model tests and verify they fail**

Run:

```sh
swift test --filter DashboardModelsTests/testCodexLoginStartRequest
```

Expected: build fails because `apiKey` is not part of `CodexLoginStartRequest`.

- [ ] **Step 3: Update login request model**

Modify `Sources/NavCenterApp/Models/DashboardModels.swift`:

```swift
struct CodexLoginStartRequest: Encodable {
    var type: String
    var apiKey: String?

    enum CodingKeys: String, CodingKey {
        case type
        case apiKey
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        if let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            try container.encode(apiKey, forKey: .apiKey)
        }
    }
}
```

- [ ] **Step 4: Replace undocumented auth status usage**

In `Sources/NavCenterApp/Services/NativeCodexBridge.swift`, replace:

```swift
let auth = try request("getAuthStatus", params: ["includeToken": false, "refreshToken": false])
```

with:

```swift
let authMethod = Self.codexAccount(account["account"])?.type
```

Set `authMethod: authMethod` in the returned `CodexStatusResponse`.

- [ ] **Step 5: Send the required initialized notification**

In `start()`, after the `initialize` request succeeds, add:

```swift
initialized = try request("initialize", params: [
    "clientInfo": ["name": "nav-center", "title": "Nav Center", "version": "0.1.0"]
])
try writeJSON(["method": "initialized", "params": [:]])
```

This keeps the wire sequence aligned with the Codex app-server docs: `initialize`, then `initialized`, then account/thread/turn calls.

- [ ] **Step 6: Support API key login through app-server**

Change the bridge method signature:

```swift
func loginStart(type: String, apiKey: String? = nil) throws -> CodexLoginStartResponse
```

Build params like this:

```swift
var params: [String: Any] = ["type": type]
if type == "apiKey",
   let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
   !apiKey.isEmpty {
    params["apiKey"] = apiKey
}
let result = try request("account/login/start", params: params)
```

Update `DashboardServicing.startCodexLogin` and `DashboardStore.startCodexLogin` signatures to accept `apiKey: String?`.

- [ ] **Step 7: Run the model tests and full test suite**

Run:

```sh
swift test --filter DashboardModelsTests/testCodexLoginStartRequest
swift test
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

```sh
git add Sources/NavCenterApp/Services/NativeCodexBridge.swift Sources/NavCenterApp/Models/DashboardModels.swift Sources/NavCenterApp/Stores/DashboardStore.swift Tests/NavCenterTests/DashboardModelsTests.swift
git commit -m "fix: align codex app-server auth flow"
```

---

## Task 3: Auth UI Labels And API Key Mode

**Files:**
- Modify: `Sources/NavCenterApp/Views/CodexPanelView.swift`
- Modify: `Sources/NavCenterApp/Stores/DashboardStore.swift`
- Modify: `README.md`
- Modify: `docs/BETA.md`

- [ ] **Step 1: Rename the UI labels**

In `Sources/NavCenterApp/Views/CodexPanelView.swift`, use these user-facing labels:

```swift
private enum CodexAuthMode: String, CaseIterable, Identifiable {
    case codexManaged
    case deviceCode
    case apiKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codexManaged: return "Codex Managed"
        case .deviceCode: return "Device Code"
        case .apiKey: return "API Key"
        }
    }

    var description: String {
        switch self {
        case .codexManaged:
            return "Sign in with ChatGPT through local Codex app-server."
        case .deviceCode:
            return "Use a browser device code when callback login is brittle."
        case .apiKey:
            return "Use an OpenAI Platform API key through Codex app-server."
        }
    }
}
```

- [ ] **Step 2: Add state for mode and API key**

Add near the other `@State` values:

```swift
@State private var authMode: CodexAuthMode = .codexManaged
@State private var apiKey = ""
@State private var revealApiKey = false
```

- [ ] **Step 3: Replace Sign In and Code buttons with a mode picker**

In `accountStrip`, when not signed in, render:

```swift
Picker("Mode", selection: $authMode) {
    ForEach(CodexAuthMode.allCases) { mode in
        Text(mode.title).tag(mode)
    }
}
.pickerStyle(.segmented)

Text(authMode.description)
    .font(.caption2)
    .foregroundStyle(.secondary)

if authMode == .apiKey {
    SecureField("OpenAI API key", text: $apiKey)
        .textFieldStyle(.roundedBorder)
}

Button(authMode == .apiKey ? "Use API Key" : "Sign In") {
    Task {
        switch authMode {
        case .codexManaged:
            await store.startCodexLogin(type: "chatgpt", apiKey: nil)
        case .deviceCode:
            await store.startCodexLogin(type: "chatgptDeviceCode", apiKey: nil)
        case .apiKey:
            await store.startCodexLogin(type: "apiKey", apiKey: apiKey)
            apiKey = ""
        }
    }
}
.disabled(store.isCodexLoading || (authMode == .apiKey && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
```

- [ ] **Step 4: Improve login instructions**

In `CodexLoginInstructions`, keep the URL text selectable, but add an explicit button:

```swift
if let url = loginURL {
    Button("Open Sign-In Page") {
        NSWorkspace.shared.open(url)
    }
}
```

For device code, keep the code visible and selectable.

- [ ] **Step 5: Add outdated Codex guidance to the error banner**

If `store.codexErrorMessage` contains `--listen stdio://`, render a secondary line:

```swift
Text("Update Nav Center/Codex, then reopen the app. Current beta install: `brew update && brew upgrade --cask nav-center`")
    .font(.caption2)
    .foregroundStyle(.secondary)
```

- [ ] **Step 6: Document the modes**

Add a README section under "Requirements":

```markdown
### Assistant Auth Modes

- Codex Managed Mode: Nav Center starts local `codex app-server --listen stdio://` and lets Codex manage ChatGPT login and token refresh.
- Device Code Mode: same Codex managed account, but uses a verification URL and user code.
- API Key Mode: Nav Center sends the key once to Codex app-server with `account/login/start`; Codex stores it for API-backed Codex requests.

Nav Center does not implement direct OpenAI OAuth and does not read `~/.codex/auth.json`.
```

- [ ] **Step 7: Build the app**

Run:

```sh
swift build
```

Expected: build succeeds.

- [ ] **Step 8: Commit**

```sh
git add Sources/NavCenterApp/Views/CodexPanelView.swift Sources/NavCenterApp/Stores/DashboardStore.swift README.md docs/BETA.md
git commit -m "feat: clarify codex managed auth modes"
```

---

## Task 4: Package Scaffolding And Export Templates

**Files:**
- Modify: `Sources/NavCenterCore/WorkspaceManager.swift`
- Modify: `Sources/NavCenterCore/ApplicationCreator.swift`
- Test: `Tests/NavCenterTests/WorkspaceFeatureTests.swift`
- Test: `Tests/NavCenterTests/ApplicationCreatorScaffoldTests.swift`

- [ ] **Step 1: Write failing workspace template tests**

Add to `Tests/NavCenterTests/WorkspaceFeatureTests.swift`:

```swift
func testInitializesExportTemplates() throws {
    let temp = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: temp) }
    let workspace = temp.appendingPathComponent("Workspace", isDirectory: true)

    try WorkspaceManager(workspaceRoot: workspace).initialize()

    let resumeCSS = workspace.appendingPathComponent("templates/resume.css")
    let coverLetterCSS = workspace.appendingPathComponent("templates/cover-letter.css")
    XCTAssertTrue(FileManager.default.fileExists(atPath: resumeCSS.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: coverLetterCSS.path))
    XCTAssertTrue(try String(contentsOf: resumeCSS).contains("font-family"))
    XCTAssertTrue(try String(contentsOf: coverLetterCSS).contains("font-family"))
}
```

- [ ] **Step 2: Write failing package scaffold tests**

Create `Tests/NavCenterTests/ApplicationCreatorScaffoldTests.swift`:

```swift
import XCTest
@testable import NavCenterCore

final class ApplicationCreatorScaffoldTests: XCTestCase {
    func testCreateApplicationCreatesResumeSourceAndArtifactsDirectory() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try WorkspaceManager(workspaceRoot: temp).initialize()

        let result = try ApplicationCreator(repoRoot: temp).create(options: CreateApplicationOptions(
            source: .inline(InlineApplicationSource(
                content: String(repeating: "Responsibilities requirements qualifications preferred experience clearance. ", count: 12),
                sourceURL: "https://example.com/job",
                title: "Security Engineer",
                sourceName: "example"
            )),
            company: "Example Corp",
            role: "Security Engineer",
            date: "2099-01-01",
            dryRun: false,
            overwrite: false,
            allowLocalURL: false
        ))

        let resume = result.packageURL.appendingPathComponent("Resume_\(result.packageName).md")
        let artifacts = result.packageURL.appendingPathComponent("artifacts", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resume.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.path))
        XCTAssertTrue(try String(contentsOf: resume).contains("# Example Corp - Security Engineer"))
    }

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nav-center-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 3: Run scaffold tests and verify they fail**

Run:

```sh
swift test --filter WorkspaceFeatureTests/testInitializesExportTemplates
swift test --filter ApplicationCreatorScaffoldTests
```

Expected: tests fail because templates and starter resume source are not created.

- [ ] **Step 4: Seed templates in WorkspaceManager**

Add `"templates"` to `WorkspaceManager.requiredDirectories`.

Add:

```swift
private var resumeCSS: String {
    """
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif;
      max-width: 760px;
      margin: 36px auto;
      color: #1f2933;
      line-height: 1.45;
    }
    h1, h2, h3 {
      color: #111827;
      line-height: 1.18;
    }
    h1 {
      font-size: 28px;
      margin-bottom: 6px;
    }
    h2 {
      font-size: 17px;
      margin-top: 24px;
      border-bottom: 1px solid #d8dee9;
      padding-bottom: 4px;
    }
    ul {
      padding-left: 20px;
    }
    """
}

private var coverLetterCSS: String {
    """
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif;
      max-width: 720px;
      margin: 42px auto;
      color: #1f2933;
      line-height: 1.55;
    }
    h1 {
      font-size: 24px;
      margin-bottom: 18px;
    }
    p {
      margin: 0 0 14px;
    }
    """
}
```

In `initialize()`, after the master resume seed, write template files only when missing:

```swift
try writeIfMissing("templates/resume.css", contents: resumeCSS)
try writeIfMissing("templates/cover-letter.css", contents: coverLetterCSS)
```

Add:

```swift
private func writeIfMissing(_ relativePath: String, contents: String) throws {
    let url = workspaceRoot.appendingPathComponent(relativePath)
    if !fileManager.fileExists(atPath: url.path) {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 5: Create starter resume and artifacts directory in ApplicationCreator**

In `ApplicationCreator.create(options:)`, after writing `posting.md`, create:

```swift
let artifactsURL = packageURL.appendingPathComponent("artifacts", isDirectory: true)
try FileManager.default.createDirectory(at: artifactsURL, withIntermediateDirectories: true)
try PathSafety.assertNoSymlinkSegments(artifactsURL, root: packageURL, label: "artifacts")

let resumeURL = packageURL.appendingPathComponent("Resume_\(packageName).md")
if !FileManager.default.fileExists(atPath: resumeURL.path) {
    try starterResume(company: options.company, role: options.role, packageName: packageName, date: date)
        .write(to: resumeURL, atomically: true, encoding: .utf8)
}
```

Add:

```swift
private func starterResume(company: String, role: String, packageName: String, date: String) -> String {
    """
    ---
    type: "resume"
    package: "\(packageName)"
    company: \(Markdown.yamlString(company))
    role: \(Markdown.yamlString(role))
    created: \(Markdown.yamlString(date))
    status: "draft"
    ---

    # \(company) - \(role)

    ## Summary

    Draft resume source created by Nav Center. Replace this section with verified details from `master-resumes/master_primary.yaml` before export.

    ## Experience

    - Add only experience supported by the master resume and job posting.

    ## Skills

    - Add only skills supported by source material.
    """
}
```

- [ ] **Step 6: Run scaffold tests**

Run:

```sh
swift test --filter WorkspaceFeatureTests/testInitializesExportTemplates
swift test --filter ApplicationCreatorScaffoldTests
```

Expected: all focused tests pass.

- [ ] **Step 7: Commit**

```sh
git add Sources/NavCenterCore/WorkspaceManager.swift Sources/NavCenterCore/ApplicationCreator.swift Tests/NavCenterTests/WorkspaceFeatureTests.swift Tests/NavCenterTests/ApplicationCreatorScaffoldTests.swift
git commit -m "feat: scaffold package resume sources"
```

---

## Task 5: Export And ATS Dependency Preflight

**Files:**
- Modify: `Sources/NavCenterCore/ArtifactExporter.swift`
- Modify: `Sources/NavCenterCore/PackageActionRunner.swift`
- Test: `Tests/NavCenterTests/ArtifactExporterPreflightTests.swift`
- Test: `Tests/NavCenterTests/PackageActionRunnerDependencyTests.swift`

- [ ] **Step 1: Write failing exporter preflight tests**

Create `Tests/NavCenterTests/ArtifactExporterPreflightTests.swift`:

```swift
import XCTest
@testable import NavCenterCore

final class ArtifactExporterPreflightTests: XCTestCase {
    func testPreflightReportsMissingTemplates() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let report = ArtifactExporter.preflight(
            repoRoot: temp,
            environment: [
                "PANDOC_BIN": "/bin/echo",
                "PDFTOTEXT_BIN": "/bin/echo",
                "CHROME_BIN": "/bin/echo"
            ],
            commandHook: { _, _, _, _ in ProcessResult(status: 0, stdout: "", stderr: "") }
        )

        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.missing.contains("templates/resume.css"))
        XCTAssertTrue(report.missing.contains("templates/cover-letter.css"))
    }

    func testPreflightPassesWhenToolsAndTemplatesExist() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try WorkspaceManager(workspaceRoot: temp).initialize()

        let report = ArtifactExporter.preflight(
            repoRoot: temp,
            environment: [
                "PANDOC_BIN": "/bin/echo",
                "PDFTOTEXT_BIN": "/bin/echo",
                "CHROME_BIN": "/bin/echo"
            ],
            commandHook: { _, _, _, _ in ProcessResult(status: 0, stdout: "", stderr: "") }
        )

        XCTAssertTrue(report.ok)
        XCTAssertTrue(report.missing.isEmpty)
    }

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nav-center-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 2: Write failing package action dependency tests**

Create `Tests/NavCenterTests/PackageActionRunnerDependencyTests.swift`:

```swift
import XCTest
@testable import NavCenterCore

final class PackageActionRunnerDependencyTests: XCTestCase {
    func testAtsScanMissingBinaryFailsWithInstallMessage() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let package = try createPackage(in: temp)
        let runner = PackageActionRunner(repoRoot: temp, environment: ["NAV_CENTER_ATSIM_BIN": "/missing/atsim"])

        let entry = try runner.run(packageName: package, actionKey: "ats-scan", confirmed: true) { executable, _, _, _ in
            XCTAssertEqual(executable, "/missing/atsim")
            return ProcessResult(status: 127, stdout: "", stderr: "command not found")
        }

        XCTAssertEqual(entry.status, "failed")
        XCTAssertTrue(entry.message.contains("atsim is not installed"))
    }

    private func createPackage(in root: URL) throws -> String {
        try WorkspaceManager(workspaceRoot: root).initialize()
        let result = try ApplicationCreator(repoRoot: root).create(options: CreateApplicationOptions(
            source: .inline(InlineApplicationSource(content: String(repeating: "Responsibilities requirements qualifications preferred experience clearance. ", count: 12))),
            company: "Example Corp",
            role: "Security Engineer",
            date: "2099-01-01",
            dryRun: false,
            overwrite: false,
            allowLocalURL: false
        ))
        return result.packageName
    }

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nav-center-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 3: Run dependency tests and verify they fail**

Run:

```sh
swift test --filter ArtifactExporterPreflightTests
swift test --filter PackageActionRunnerDependencyTests
```

Expected: tests fail because preflight is not exposed and exit 127 is not specialized.

- [ ] **Step 4: Add exporter dependency report**

In `Sources/NavCenterCore/ArtifactExporter.swift`, add:

```swift
public struct ArtifactExportPreflightReport: Codable, Equatable {
    public let ok: Bool
    public let missing: [String]
    public let message: String
}
```

Add a static preflight:

```swift
public static func preflight(
    repoRoot: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    commandHook: PackageActionRunner.CommandHook? = nil
) -> ArtifactExportPreflightReport {
    let pandoc = environment["PANDOC_BIN"].flatMap { $0.isEmpty ? nil : $0 } ?? "pandoc"
    let pdftotext = environment["PDFTOTEXT_BIN"].flatMap { $0.isEmpty ? nil : $0 } ?? "pdftotext"
    let chrome = environment["CHROME_BIN"].flatMap { $0.isEmpty ? nil : $0 } ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    var missing: [String] = []
    let run = commandHook ?? ProcessRunner.run
    if (try? run(pandoc, ["--version"], repoRoot, [:]).status) != 0 { missing.append("pandoc") }
    if (try? run(pdftotext, ["-v"], repoRoot, [:]).status) != 0 { missing.append("pdftotext") }
    if !FileManager.default.fileExists(atPath: chrome) { missing.append("Google Chrome") }
    for template in ["templates/resume.css", "templates/cover-letter.css"] {
        if !FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(template).path) {
            missing.append(template)
        }
    }
    return ArtifactExportPreflightReport(
        ok: missing.isEmpty,
        missing: missing,
        message: missing.isEmpty
            ? "Export dependencies are available."
            : "Missing export dependencies: \(missing.joined(separator: ", ")). Install Homebrew packages with `brew install pandoc poppler` and install Google Chrome."
    )
}
```

- [ ] **Step 5: Specialize ATS missing binary errors**

In `PackageActionRunner.run`, after process result:

```swift
if action == "ats-scan", result.status == 127 {
    entry.status = "failed"
    entry.message = "atsim is not installed or is not executable. Install it or set NAV_CENTER_ATSIM_BIN to the correct binary before running ATS Scan."
} else {
    entry.status = result.status == 0 ? "succeeded" : "failed"
    entry.message = actionMessage(action: action, status: entry.status, exitCode: result.status)
}
```

- [ ] **Step 6: Replace refresh-resume external command with ArtifactExporter**

Change `refresh-resume` execution so it runs:

```swift
let source = "applications/\(resolved.packageName)/Resume_\(resolved.packageName).md"
let report = ArtifactExporter.preflight(repoRoot: repoRoot, environment: environment)
guard report.ok else {
    throw NavCenterError.notFound(report.message)
}
_ = try ArtifactExporter(repoRoot: repoRoot, environment: environment.merging(["NAV_CENTER_SKIP_VAULT_SYNC": "1"]) { _, new in new })
    .export(markdownPaths: [source])
```

Keep the action log `command` as:

```swift
"navcenter export \(source)"
```

- [ ] **Step 7: Run dependency tests**

Run:

```sh
swift test --filter ArtifactExporterPreflightTests
swift test --filter PackageActionRunnerDependencyTests
```

Expected: all focused tests pass.

- [ ] **Step 8: Commit**

```sh
git add Sources/NavCenterCore/ArtifactExporter.swift Sources/NavCenterCore/PackageActionRunner.swift Tests/NavCenterTests/ArtifactExporterPreflightTests.swift Tests/NavCenterTests/PackageActionRunnerDependencyTests.swift
git commit -m "fix: preflight export and ats tools"
```

---

## Task 6: Review Pane Fallbacks And Action Guidance

**Files:**
- Modify: `Sources/NavCenterApp/Views/PackageDetailView.swift`
- Modify: `Sources/NavCenterApp/Views/SharedViews.swift`
- Test: `Tests/NavCenterTests/MasterResumeLayoutTests.swift`

- [ ] **Step 1: Make Review pane usable without generated PDF**

In `ReviewWorkspace.resumePane`, change PDF mode behavior:

```swift
if resumeMode == "pdf", let resumePDF {
    RawDocumentPreview(
        file: resumePDF,
        openPDFFile: resumePDF,
        fallbackMessage: "No generated resume preview found yet."
    )
    .frame(minHeight: 420, maxHeight: .infinity)
} else if let resumeSource {
    FileTextPreview(file: resumeSource, rendered: true, loadOnAppear: true)
        .frame(minHeight: 420, maxHeight: .infinity)
} else {
    EmptyStateView(title: "No resume source", message: "Create or refresh Resume_<package>.md before exporting a PDF.")
}
```

This makes the first beta package immediately reviewable after Task 4 creates starter resume markdown.

- [ ] **Step 2: Improve PDF missing copy**

Change the missing artifact message to:

```swift
EmptyStateView(
    title: fallbackMessage,
    message: "Expected package artifacts: artifacts/Resume_<package>.html and artifacts/Resume_<package>.pdf. Use Refresh Resume PDF after installing Pandoc, Poppler, and Chrome."
)
```

- [ ] **Step 3: Keep pane height bounded**

Verify `ReviewWorkspace` still uses:

```swift
.frame(
    minHeight: fillAvailableHeight ? 420 : 660,
    maxHeight: fillAvailableHeight ? .infinity : nil
)
```

Do not reintroduce fixed viewport heights that hide the chat bubble.

- [ ] **Step 4: Run UI-adjacent tests**

Run:

```sh
swift test --filter MasterResumeLayoutTests
swift test --filter DashboardParityTests
```

Expected: tests pass.

- [ ] **Step 5: Commit**

```sh
git add Sources/NavCenterApp/Views/PackageDetailView.swift Sources/NavCenterApp/Views/SharedViews.swift Tests/NavCenterTests/MasterResumeLayoutTests.swift
git commit -m "fix: keep review pane usable before export"
```

---

## Task 7: Diagnostics And Beta Docs

**Files:**
- Modify: `Sources/NavCenterCore/FeedbackDiagnostics.swift`
- Modify: `README.md`
- Modify: `docs/BETA.md`
- Modify: `plugins/nav-center/skills/nav-center-codex-setup/SKILL.md`
- Test: `Tests/NavCenterTests/WorkspaceFeatureTests.swift`

- [ ] **Step 1: Add diagnostic expectations**

Extend `testFeedbackDiagnosticsRedactsHomePathAndReportsWorkspaceHealth` so the encoded report contains export dependency keys but no private home path:

```swift
XCTAssertTrue(json.contains("exportDependencies"))
XCTAssertFalse(json.contains("/Users/tucker"))
```

- [ ] **Step 2: Add export dependency status to FeedbackDiagnostics**

In `FeedbackDiagnostics.report(redact:)`, add a field named `exportDependencies` with this shape:

```swift
public struct ExportDependencyDiagnostics: Codable, Equatable {
    public var ok: Bool
    public var missing: [String]
    public var message: String
}
```

Populate it with:

```swift
let exportReport = ArtifactExporter.preflight(repoRoot: workspaceRoot)
```

Do not include raw environment values or secret-bearing paths.

- [ ] **Step 3: Document Homebrew dependencies**

Add to `docs/BETA.md`:

````markdown
## Optional Local Tools

Resume PDF export needs:

```sh
brew install pandoc poppler
```

It also needs Google Chrome installed at:

```text
/Applications/Google Chrome.app/Contents/MacOS/Google Chrome
```

ATS scan needs `atsim`. If it is not installed, Nav Center will keep the action local and report the missing binary instead of running a broken scan.
````

- [ ] **Step 4: Document Codex version behavior**

Add to `docs/BETA.md`:

````markdown
## Codex Assistant

Nav Center uses Codex Managed Mode by starting:

```sh
codex app-server --listen stdio://
```

The tester does not need to use the Codex CLI interface. The installed Codex binary must support `app-server --listen stdio://`; if it does not, update Nav Center/Codex with:

```sh
brew update
brew upgrade --cask nav-center
```
````

- [ ] **Step 5: Update the setup skill**

In `plugins/nav-center/skills/nav-center-codex-setup/SKILL.md`, include these checks:

```markdown
- Verify `codex --version`.
- Verify `codex app-server --help` includes `--listen` and `stdio://`.
- Verify export tools with `pandoc --version`, `pdftotext -v`, and the Chrome binary path.
- Verify package folders contain `posting.md`, `Resume_<package>.md`, and `artifacts/`.
```

- [ ] **Step 6: Run diagnostics tests**

Run:

```sh
swift test --filter WorkspaceFeatureTests/testFeedbackDiagnosticsRedactsHomePathAndReportsWorkspaceHealth
```

Expected: test passes.

- [ ] **Step 7: Commit**

```sh
git add Sources/NavCenterCore/FeedbackDiagnostics.swift README.md docs/BETA.md plugins/nav-center/skills/nav-center-codex-setup/SKILL.md Tests/NavCenterTests/WorkspaceFeatureTests.swift
git commit -m "docs: document beta assistant prerequisites"
```

---

## Task 8: End-To-End Verification

**Files:**
- No planned source edits.
- Verification outputs stay out of git unless a failure report is explicitly requested.

- [ ] **Step 1: Run formatting and tests**

Run:

```sh
swift test
```

Expected: all tests pass.

- [ ] **Step 2: Build the app**

Run:

```sh
swift build
```

Expected: build succeeds.

- [ ] **Step 3: Build and launch development bundle**

Run:

```sh
scripts/build-and-run.sh
```

Expected: `dist/Nav Center.app` is staged and launches.

- [ ] **Step 4: Verify Codex preflight manually**

Run:

```sh
codex --version
codex app-server --help | rg -- '--listen|stdio://'
```

Expected: version prints and help contains both `--listen` and `stdio://`.

- [ ] **Step 5: Verify package scaffold manually**

Create a package through the app intake UI. Expected files:

```text
applications/<package>/posting.md
applications/<package>/Resume_<package>.md
applications/<package>/artifacts/
```

- [ ] **Step 6: Verify export preflight manually**

Run:

```sh
pandoc --version
pdftotext -v
test -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
```

Expected: tools are available or Nav Center reports exactly which dependency is missing.

- [ ] **Step 7: Verify git status**

Run:

```sh
git status --short
```

Expected: no uncommitted changes after all task commits.

---

## Acceptance Criteria

- Codex panel no longer presents direct "OpenAI OAuth" as a product claim.
- Codex panel labels the ChatGPT path as Codex Managed Mode.
- App sends `initialize`, then `initialized`, before auth/thread/turn calls.
- App no longer calls undocumented `getAuthStatus`.
- Missing or outdated Codex produces an actionable message instead of raw `unexpected argument '--listen'`.
- API key mode works through app-server without Nav Center persisting the key.
- New packages include `posting.md`, `Resume_<package>.md`, and `artifacts/`.
- Workspace initialization creates `templates/resume.css` and `templates/cover-letter.css`.
- Refresh Resume PDF uses `ArtifactExporter` directly and reports missing Pandoc, Poppler, Chrome, or templates clearly.
- ATS scan reports missing `atsim` clearly instead of only exit code 127.
- Review pane remains usable before PDF export by showing the package resume source.
- Feedback diagnostics include sanitized tool readiness data.
- `swift test` and `swift build` pass.

## Rollback Plan

- If Codex Managed Mode regresses, revert Tasks 1 through 3 together because they share the app-server contract.
- If package scaffolding creates unwanted files, revert Task 4 only; existing package reading remains compatible with posting-only packages.
- If export behavior regresses, revert Task 5; the old `NAV_CENTER_EXPORT_BIN` path can be temporarily restored while keeping Task 4 templates.
- If UI fallback causes layout regression, revert Task 6 only and keep the backend reliability work.
