# Integration acceptance (local lane, dev machine)

Result: **pass**

Date (UTC): 2026-09-22T22:57:41.091210Z
Source SHA: 46de4cf33a100d9de1df47c3395b632c6bc8fe2d
macOS: 27.0 (26A428)
Architecture: arm64

## Tools

| Tool | State | Version |
| --- | --- | --- |
| atsim | found | present |
| export-tool | built-in |  |
| pandoc | found | pandoc 3.11 |
| pdftotext | found | pdftotext version 26.09.0 |
| chrome | found | Google Chrome 153.0.8010.53  |
| ruby | found | ruby 2.6.10p210 (2022-04-12 revision 67958) [universal.arm64e-darwin26] |
| codex | found | codex-cli 0.155.1 |

## Lanes

| Lane | Command | Exit | Executed | Skipped | Failures | Result |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| ats | `NAV_CENTER_TEST_ATSIM_BIN=<atsim> swift test --filter ATSActionReadinessTests` | 0 | 27 | 0 | 0 | pass |
| chrome | `NAV_CENTER_TEST_REAL_CHROME=1 swift test --filter RendererReadinessTests` | 0 | 6 | 0 | 0 | pass |
| export | `NAV_CENTER_TEST_REAL_EXPORT=1 swift test --filter ExportToolReadinessTests` | 0 | 1 | 0 | 0 | pass |
| cli-export | `NAV_CENTER_TEST_REAL_EXPORT=1 NAVCENTERCTL=<navcenterctl> python3 -B scripts/tests/test_cli.py -v CLITests.test_export_artifacts_real_tools_produce_complete_artifact_set` | 0 | 1 | 0 | 0 | pass |

The lane was run from the WP8 branch (source SHA above is its base, main `46de4cf`) with `scripts/integration-acceptance.sh <out>` on the maintainer's Apple silicon Mac with installed tools. Synthetic data only; no private documents.

## Missing-tool check

`NAV_CENTER_ATSIM_BIN=/nonexistent/atsim scripts/integration-acceptance.sh <out>` exited 1 before running any test lane and printed:

```
FAIL: atsim is required for the integration lane but is override-invalid (set NAV_CENTER_ATSIM_BIN)
```

Its summary recorded `"result": "fail"` with no lanes.

## Codex live acceptance (manual)

Not run yet. It needs a human with a signed-in Codex CLI session and follows the checklist in `docs/TESTING.md` ("Codex live acceptance (manual)"). Record the result and `codex --version` here when it is run on the beta candidate.
