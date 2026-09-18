# atsim

`atsim` is the ATS-style resume parser and job-description matcher used by the
job-hunt workflow. It is installed as a standalone CLI so agents can run it from
any working directory.

## Install

```bash
make install-local
```

This installs the Python package into the shared CLI virtual environment at
`/Users/tucker/projects/cli/.venv` and writes an `atsim` wrapper to
`~/.local/bin/atsim`.

For guarded LLM diff drafting, install the Node helper dependencies once:

```bash
npm install
```

## Configuration

By default, `atsim` uses `/Users/tucker/projects/job-hunt` as the job-hunt data
root. Override it for tests or alternate checkouts with:

```bash
ATSIM_JOB_HUNT_ROOT=/path/to/job-hunt atsim --json doctor
```

The OpenCode SDK runner defaults to the package-local
`atsim/scripts/atsim_opencode_sdk.mjs`. Override it with
`ATSIM_OPENCODE_SDK_RUNNER` only when testing another runner.

## Common Commands

```bash
atsim --json doctor
atsim --json applications list --limit 10
atsim --json applications resolve <application>
atsim scan applications/<application>
atsim scan applications/<application> --out applications/<application>/artifacts/ats-report.json
atsim suggest applications/<application>
atsim draft-diffs applications/<application>
atsim verify-diffs applications/<application> --diffs applications/<application>/artifacts/ats-llm-diffs.raw.json
atsim --json artifact read applications/<application>/artifacts/ats-report.json
```

The score is a parseability and job-description alignment simulation, not a
claim that a resume will pass or fail any specific ATS.

## Test

```bash
make test
```

## Related Notes

- `/Users/tucker/vault/03-projects/cli/README.md`
- `/Users/tucker/vault/03-projects/job-hunt/wiki/ats-v2-guarded-diffs-2026-04-24.md`
