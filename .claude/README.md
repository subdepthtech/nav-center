# Claude Code configuration

Repository-scoped automation for agents working in this tree. It encodes rules
that already exist in `AGENTS.md`, `CLAUDE.md` and `docs/`, as file-tool guardrails and repeatable checks. These hooks are not a sandbox.

| Path | What it does |
| --- | --- |
| `settings.json` | Registers the two hooks below. |
| `hooks/guard-protected-paths.py` | `PreToolUse`. Blocks matched file-tool writes into the fixed `vendor/atsim` snapshot and matched file-tool access to the default Application Support workspace, a configured vault, or recognized Codex authentication filenames. |
| `hooks/swift-quality.py` | `PostToolUse`. Reports new correctness SwiftLint findings to the agent and the `swift-format` style baseline (advisory) after a Swift file edit; it cannot undo the completed edit. |
| `skills/ci-gate/` | `/ci-gate` — runs the native and script checks locally in a disposable directory and reports pass/fail/blocked per gate. |
| `skills/release-evidence/` | `/release-evidence` — checks a packaged DMG against the distribution gates and lists what it cannot establish. |
| `agents/path-safety-reviewer.md` | Read-only reviewer for the `PathSafety`, confinement and confirmation boundary. |

The guard covers only the file tools listed in `settings.json`; Bash, search, MCP
tools, and other processes are outside its coverage. It does not discover private
workspaces at arbitrary custom paths. Shared policy still applies to every tool.
The vendor override file records a local exception; it does not grant authorization.

Both skills set `disable-model-invocation: true`: they are expensive or
release-facing, so a person invokes them.

Hooks load when a Claude Code session starts. After changing anything here,
restart the session and confirm with `/hooks`. The hook scripts need `python3`,
which this repository's tooling already requires; `swiftlint` and `swift-format`
are skipped silently when absent (install the pinned build with
`python3 scripts/bootstrap-tools.py --tool swiftlint --directory .tools`).

An authorized `vendor/atsim` snapshot update is unblocked by creating
`.claude/ALLOW_VENDOR_SNAPSHOT_UPDATE` for the duration of that task and removing
it afterwards. `scripts/verify-vendor.py` remains the actual integrity check.
