# Clean-machine verification (WP12): 0.1.0-beta.1

WP12A: BLOCKED. No clean Apple-silicon macOS 26+ device or VM was available on 2026-09-23 (owner confirmed). The first tester cannot be invited until WP12A passes.

WP12B: Not started. Requires the published prerelease and a merged tap PR.

Any failure blocks WP13 rollout until fixed and re-verified through WP11–WP12.

## Gates

| Gate | Required coverage |
| --- | --- |
| WP12A (direct DMG; required before the first tester) | Sections 1–5; section 6 DMG-drag pass (6.1, 6.2, DMG half of 6.3, 6.4); 7.2; section 8. |
| WP12B (Homebrew; required before advertising the tap or expanding beyond the first tester) | `brew install --cask nav-center` from the merged tap; brew half of 6.3 with its own 6.4; 7.1. |

## Record

| Field | Value |
| --- | --- |
| Candidate version | 0.1.0-beta.1 |
| Build | 3 |
| DMG SHA-256 | Pending artifact-verification.md |
| Source SHA (first line of `BUILD.txt`) | ebe5448a2d6bc4e4b540d8125ab4d2c1e9316971 |
| macOS version and build (`sw_vers`) | Not recorded |
| Hardware model and chip | Not recorded |
| Tester | Not recorded |
| Date | Not recorded |
| Elapsed time | Not recorded |
| Codex CLI version, if tested | Not recorded |

## Prior-beta upgrade input

| Field | Observed on maintainer Mac |
| --- | --- |
| Asset | `NavCenter-0.1.0-beta-macos-arm64.dmg` from the `v0.1.0-beta` GitHub prerelease |
| Size | 4,722,837 bytes |
| SHA-256 | `7fd9ca0774f525b7adcaad94e88fedb6e2cfce42d83034217a31973356b51d87` matches the published `.sha256` digest and GitHub's asset digest; the sidecar names `dist/NavCenter-0.1.0-beta-macos-arm64.dmg` |
| Info.plist | No `CFBundleShortVersionString`, no `CFBundleVersion`, no `NavCenterVersion`; `LSMinimumSystemVersion` is 13.0; `CFBundleIdentifier` is `com.subdepthtech.navcenter` |
| Stapler | `xcrun stapler validate` on the DMG succeeded |
| Gatekeeper | `spctl -a -vv -t execute` on its mounted app said accepted, source=Notarized Developer ID, TeamIdentifier 3364PH2HE3 |

This input was prepared on the maintainer Mac, not the clean machine. Re-download it in a browser on the clean machine per step 6.1. In step 6.2, record the old build as absent. Step 6.4 passes when Settings shows 0.1.0-beta.1 build 3 and the synthetic data is intact.

## Synthetic fixtures

These are invented and contain no personal data. Paste them on the clean machine.

Import document:

```text
Jordan Sample
Platform reliability specialist
Northwind Synthetic Labs
Maintained test service dashboards and synthetic incident drills.
Documented recovery steps for a fictional platform.
Contoso Test Works
Built sample deployment checks for a training environment.
Reviewed invented reliability metrics with a mock team.
No real clients or production systems were involved.
```

Job posting:

```text
Northwind Synthetic Labs
Platform Reliability Engineer
Remote (synthetic)
This invented role maintains a simulated platform used for training and product tests. The engineer reviews sample service alerts, writes clear incident notes, and improves repeatable deployment checks. The work includes monitoring synthetic workloads, testing backup and restore procedures, and explaining proposed changes to a fictional team. Candidates should be comfortable with command-line tools, version control, and careful review of runbooks. All systems, users, and business details in this posting are imaginary.
```

Master-resume summary:

```text
Jordan Sample designs reliable test workflows and documents recovery steps for invented services.
```

## Results

### 1. Clean machine preconditions

| Step | Action | Gate | Pass/Fail | Observation |
| --- | --- | --- | --- | --- |
| 1.1 | `sw_vers` | WP12A | Not run | |
| 1.2 | `uname -m` | WP12A | Not run | |
| 1.3 | Check that `pandoc`, `pdftotext` and Google Chrome are absent | WP12A | Not run | |
| 1.4 | `test ! -e "$HOME/Library/Application Support/Nav Center" && echo absent` | WP12A | Not run | |
| 1.5 | Download the candidate DMG and `.sha256` in a browser; check the quarantine attribute | WP12A | Not run | |
| 1.6 | `shasum -a 256 -c NavCenter-<version>-macos-arm64.dmg.sha256` | WP12A | Not run | |

### 2. Gatekeeper and offline first launch

| Step | Action | Gate | Pass/Fail | Observation |
| --- | --- | --- | --- | --- |
| 2.1 | `spctl` open assessment of the candidate DMG | WP12A | Not run | |
| 2.2 | `open NavCenter-<version>-macos-arm64.dmg` | WP12A | Not run | |
| 2.3 | Drag `Nav Center.app` to `/Applications`. | WP12A | Not run | |
| 2.4 | Turn networking off | WP12A | Not run | |
| 2.5 | `spctl -a -vv -t execute "/Applications/Nav Center.app"` | WP12A | Not run | |

### 3. First launch outcome

| Step | Action | Gate | Pass/Fail | Observation |
| --- | --- | --- | --- | --- |
| 3.1 | In Finder, open `~/Library/Application Support/Nav Center/Workspace`. | WP12A | Not run | |
| 3.2 | Open Settings. | WP12A | Not run | |
| 3.3 | Read Settings > External Tools. | WP12A | Not run | |
| 3.4 | `/Applications/Nav\ Center.app/Contents/MacOS/navcenterctl doctor` | WP12A | Not run | |

### 4. Core flows on synthetic data

| Step | Action | Gate | Pass/Fail | Observation |
| --- | --- | --- | --- | --- |
| 4.1 | Import one synthetic document from Overview | WP12A | Not run | |
| 4.2 | Create a package from a pasted synthetic posting | WP12A | Not run | |
| 4.3 | Open Master Resume, change a visible field to invented text, choose Save, then Reload. | WP12A | Not run | |
| 4.4 | On the package, choose Applied, then Interview | WP12A | Not run | |
| 4.5 | Backdate the package more than 7 days, refresh, and preview cleanup | WP12A | Not run | |
| 4.6 | Confirm removal in the review sheet (`Remove N Packages`). | WP12A | Not run | |
| 4.7 | `navcenterctl restore-cleanup` from the manifest | WP12A | Not run | |
| 4.8 | With atsim absent, open the package, choose Run ATS Scan, and confirm. | WP12A | Not run | |
| 4.9 | With Pandoc, Chrome, and pdftotext absent, read Export Artifacts on the package rail. | WP12A | Not run | |
| 4.10 | `brew install pandoc poppler` | WP12A | Not run | |
| 4.11 | Choose Export Artifacts and confirm | WP12A | Not run | |

### 5. Diagnostics privacy

| Step | Action | Gate | Pass/Fail | Observation |
| --- | --- | --- | --- | --- |
| 5.1 | `/Applications/Nav\ Center.app/Contents/MacOS/navcenterctl feedback-diagnostics` | WP12A | Not run | |
| 5.2 | Help > Copy Redacted Diagnostics, if that item is present | WP12A | Not run | |

### 6. Upgrade from v0.1.0-beta

| Step | Action | Gate | Pass/Fail | Observation |
| --- | --- | --- | --- | --- |
| 6.1 | From the `v0.1.0-beta` GitHub prerelease, download that DMG in a browser | WP12A | Not run | |
| 6.2 | Install `v0.1.0-beta` (drag to `/Applications` for the DMG pass) | WP12A | Not run | |
| 6.3 (DMG pass) | Drag the candidate app over `v0.1.0-beta` in `/Applications` | WP12A | Not run | |
| 6.3 (Homebrew pass) | `brew update` and `brew upgrade --cask nav-center` on separate prior-beta state | WP12B | Not run | |
| 6.4 (DMG pass) | Relaunch | WP12A | Not run | |
| 6.4 (Homebrew pass) | Relaunch | WP12B | Not run | |
| WP12B install | `brew install --cask nav-center` from the merged tap | WP12B | Not run | |

### 7. Uninstall

| Step | Action | Gate | Pass/Fail | Observation |
| --- | --- | --- | --- | --- |
| 7.1 | `brew uninstall --cask --zap nav-center` | WP12B | Not run | |
| 7.2 | Manual DMG uninstall with the `docs/BETA.md` commands | WP12A | Not run | |

### 8. Sign-off

| Step | Action | Gate | Pass/Fail | Observation |
| --- | --- | --- | --- | --- |
| 8.1 | Review sections 1–7. | WP12A | Not run | |
| 8.2 | Fill tester and date in the Record table, and copy them into the evidence file. | WP12A | Not run | |
| 8.3 | Copy the WP13 blocking sentence into the evidence file | WP12A | Not run | |

## Sign-off

Tester: Not recorded

Date: Not recorded
