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

Not run yet. It needs a human with a signed-in Codex CLI session and follows the checklist in `docs/TESTING.md` ("Codex live acceptance (manual)"). Record the result and `codex --version` here when it is run on the beta candidate.
