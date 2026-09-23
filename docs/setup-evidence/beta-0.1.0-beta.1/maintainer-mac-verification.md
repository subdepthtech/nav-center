# Maintainer Mac verification at the macOS 26 deployment target (WP9)

Run on 2026-09-22 on the maintainer's Apple silicon Mac against WP9 head `00ae54e` (the code is identical to the merged WP9 head; later commits are docs only). Synthetic data only.

## Toolchain

- macOS 27.0 (26A428), arm64
- Xcode 27.0 (27A266a), Apple Swift 6.4 (swiftlang-6.4.0.34.1)
- Package deployment target: macOS 26 (`.macOS("26.0")`)

## Section 5 checks (`docs/MACOS-BETA-MILESTONE.md`)

| Check | Result |
| --- | --- |
| `swift build` | pass |
| `swift test` | 268 tests, 4 opt-in skips, 0 failures |
| `swift test --scratch-path .build-asan --sanitize=address` | 268 tests, 4 opt-in skips, 0 failures |
| `swift test --scratch-path .build-tsan --sanitize=thread` | first run: 268 tests, 2 failure assertions in one test, `CreatorReadinessTests.testURLPrivateVariantsAreBlockedAndOptInDoesNotFollowRedirects` (its loopback listener was not reached). The test then passed 6/6 in isolation, and a full re-run gave 268 tests, 4 opt-in skips, 0 failures. The intermittent listener flake predates WP9 and is tracked as a follow-up |
| `NAVCENTERCTL=… python3 -B scripts/tests/test_cli.py -v` | 15 ran, 1 opt-in skip |
| `python3 -B -m unittest discover -s scripts/tests -v` | 98 ran, OK (15 CLI opt-in skips) |
| committed-range `git log --check`, `bash -n scripts/*.sh` | clean |

## Real-tool integration lane (`scripts/integration-acceptance.sh`)

Result: **pass**

Date (UTC): 2026-09-23T01:40:01.982094Z
Source SHA: 00ae54edbdb75e3b4d6c787d8c53b4d64b4c3f71
macOS: 27.0 (26A428)
Architecture: arm64

## Tools

| Tool | State | Version |
| --- | --- | --- |
| atsim | found | present |
| export-tool | built-in |  |
| pandoc | found | pandoc 3.11 |
| pdftotext | found | pdftotext version 26.09.0 |
| chrome | found | Google Chrome 153.0.8010.53 |
| ruby | found | ruby 2.6.10p210 (2022-04-12 revision 67958) [universal.arm64e-darwin26] |
| codex | found | codex-cli 0.155.1 |

## Lanes

| Lane | Command | Exit | Executed | Skipped | Failures | Result |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| ats | `NAV_CENTER_TEST_ATSIM_BIN=<atsim> swift test --filter ATSActionReadinessTests` | 0 | 27 | 0 | 0 | pass |
| chrome | `NAV_CENTER_TEST_REAL_CHROME=1 swift test --filter RendererReadinessTests` | 0 | 6 | 0 | 0 | pass |
| export | `NAV_CENTER_TEST_REAL_EXPORT=1 swift test --filter ExportToolReadinessTests` | 0 | 1 | 0 | 0 | pass |
| cli-export | `NAV_CENTER_TEST_REAL_EXPORT=1 NAVCENTERCTL=<navcenterctl> python3 -B scripts/tests/test_cli.py -v CLITests.test_export_artifacts_real_tools_produce_complete_artifact_set` | 0 | 1 | 0 | 0 | pass |

No `$HOME` path appears in the summary or in any of the four lane logs.
