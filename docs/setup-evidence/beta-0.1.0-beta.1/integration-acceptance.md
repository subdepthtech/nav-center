# Integration acceptance (local lane, dev machine)

Result: **pass**

Date (UTC): 2026-09-22T23:16:46.220168Z
Source SHA: 7ee73a7f9c70f9c35bdee8bc8d53811111d36ab4
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

The lane was run with `scripts/integration-acceptance.sh <out>` at the source SHA above: the WP8 branch commit whose script produced this summary. The machine was the maintainer's Apple silicon Mac with installed tools. Only synthetic data was used; no private documents. The lane logs contained no home-directory paths.

## Missing-tool check

`NAV_CENTER_ATSIM_BIN=/nonexistent/atsim scripts/integration-acceptance.sh <out>` exited 1 before running any test lane and printed:

```
FAIL: atsim is required for the integration lane but is override-invalid (set NAV_CENTER_ATSIM_BIN)
```

Its summary recorded `"result": "fail"` and no lanes.

## Codex live acceptance (manual)

Status: in progress (2026-09-23). Not accepted until every row below is Pass.

| Field | Value |
| --- | --- |
| Codex CLI version | codex-cli 0.156.1 |
| Candidate | 0.1.0-beta.1 build 3, source ebe5448a2d6bc4e4b540d8125ab4d2c1e9316971 |
| Preliminary build | local unsigned release preview built from the same SHA (build 1, ad-hoc signed, never distributed) |
| Machine | macOS 27.0 (26A428), arm64, Apple M2 Pro |
| Tester | Not recorded |
| Date | 2026-09-23 |
| Data | disposable synthetic workspace and package with invented company, role and text; no private data |

| # | Check | Method | Preview (build 1) | Signed candidate (build 3) | Evidence |
| --- | --- | --- | --- | --- | --- |
| 1 | Record `codex --version` in the evidence. | Automated | Not run | Not run | |
| 2 | A signed-in `codex app-server` starts from the Codex panel. | Human | Not run | Not run | |
| 3 | One chat without edits completes. | Human | Not run | Not run | |
| 4 | One chat proposing edits requires confirmation, then applies only to package Markdown. | Human | Not run | Not run | |
| 5 | The staging directory has mode 0700. | Automated observation (sampler) | Not run | Not run | |
| 6 | The server is stopped before changes are applied. | Automated observation (sampler) | Not run | Not run | |
| 7 | Compare `ls -la ~/.codex` before and after; Nav Center does not modify it. | Automated (metadata listing only; contents never read) | Not run | Not run | |
| 8 | No private data is used. | Attestation | Not run | Not run | |

Method notes: the sampler polls every 0.1 s and records the mode of `$(getconf DARWIN_USER_TEMP_DIR)nav-center-codex-*`, whether the app's `codex app-server` child process is alive, and the modification times of the synthetic package's Markdown files; ordering is judged from those timestamps. The `~/.codex` comparison lists names, sizes and modification times only; the Codex CLI itself writes its own session, history and log files there during a chat, so the check is that no entry is created or changed that the Codex process does not own.
