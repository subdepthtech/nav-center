# Clean-machine verification (WP12)

A human runs this checklist on a clean supported Mac (a VM or a device) against the exact downloaded beta candidate. Record every step pass or fail, with the artifact SHA-256 and the macOS build. Any failure blocks rollout (WP13).

Write the filled record, the pass/fail tables, and the sign-off to `docs/setup-evidence/beta-<version>/clean-machine-verification.md`. Screenshots in that directory contain no personal data. Use only synthetic data: invented names, companies, and posting text. Do not import a real resume or a real application.

`<version>` is the candidate version (the release example is `0.1.0-beta.1`, which writes `docs/setup-evidence/beta-0.1.0-beta.1/clean-machine-verification.md`).

## Gates: WP12A and WP12B

Run the two passes on separate clean machine states and record each result. The split removes a circular dependency in the plan and waives neither gate.

| Gate | Required coverage |
| --- | --- |
| WP12A (direct DMG; before the first tester) | Sections 1–5; section 6 DMG-drag pass (6.1, 6.2, DMG half of 6.3, 6.4); 7.2; section 8. |
| WP12B (Homebrew; before advertising the tap or expanding beyond the first tester) | `brew install --cask nav-center` from the merged tap; brew half of 6.3 with its own 6.4; 7.1. |

## Record

| Field | Value |
| --- | --- |
| Candidate version | |
| Build | |
| DMG SHA-256 | |
| Source SHA (first line of `BUILD.txt`) | |
| macOS version and build (`sw_vers`) | |
| Hardware model and chip | |
| Tester | |
| Date | |
| Elapsed time | |
| Codex CLI version, if tested | |

Commands for the record:

```sh
sw_vers
sysctl -n hw.model
sysctl -n machdep.cpu.brand_string
uname -m
shasum -a 256 NavCenter-<version>-macos-arm64.dmg
codex --version
```

Run `codex --version` only when the Codex CLI row in section 3 is Found. Copy the source SHA from the first line of the candidate's `BUILD.txt`.

## 1. Clean machine preconditions

The advertised minimum is macOS 26 or later (the latest two major macOS releases); see the Support matrix in `docs/BETA.md`. This beta is Apple silicon only.

| Step | Action | Expected | Pass/Fail |
| --- | --- | --- | --- |
| 1.1 | `sw_vers` | ProductVersion is 26.0 or newer (the advertised minimum in the docs/BETA.md support matrix). | |
| 1.2 | `uname -m` | `arm64` | |
| 1.3 | `command -v pandoc`; `command -v pdftotext`; `test ! -e "/Applications/Google Chrome.app" && echo absent` | `pandoc` and `pdftotext` are not on PATH. Chrome prints `absent`. No Homebrew pandoc, poppler, or Chrome. | |
| 1.4 | `test ! -e "$HOME/Library/Application Support/Nav Center" && echo absent` | `absent`. No prior Nav Center support directory. | |
| 1.5 | In a browser, download the candidate DMG and its `.sha256` from the published GitHub prerelease or, for WP12A before publication, an authorized staging point (a draft GitHub prerelease while signed in, or an equivalent browser-download location). Then `xattr -p com.apple.quarantine NavCenter-<version>-macos-arm64.dmg` | The command prints a quarantine value. | |
| 1.6 | `shasum -a 256 -c NavCenter-<version>-macos-arm64.dmg.sha256` | The command prints `OK`. | |

## 2. Gatekeeper and offline first launch

| Step | Action | Expected | Pass/Fail |
| --- | --- | --- | --- |
| 2.1 | `spctl -a -vv -t open --context context:primary-signature NavCenter-<version>-macos-arm64.dmg` | The output says accepted and contains `Notarized Developer ID`. | |
| 2.2 | `open NavCenter-<version>-macos-arm64.dmg` | The image opens. `LICENSE` and `THIRD_PARTY_NOTICES.md` are visible at the image root. | |
| 2.3 | Drag `Nav Center.app` to `/Applications`. | The app is at `/Applications/Nav Center.app`. | |
| 2.4 | Turn networking off. Launch `/Applications/Nav Center.app`. | The first launch shows no "cannot verify" dialog and no "damaged" dialog. The stapled ticket is enough. | |
| 2.5 | `spctl -a -vv -t execute "/Applications/Nav Center.app"` | The output says accepted. | |

Turn networking back on after step 2.5 is recorded. Later steps that install Pandoc, Poppler, and Chrome need the network.

## 3. First launch outcome

| Step | Action | Expected | Pass/Fail |
| --- | --- | --- | --- |
| 3.1 | In Finder, open `~/Library/Application Support/Nav Center/Workspace`. | These directories exist: `applications/`, `master-resumes/`, `tracking/`, `imports/originals/`, `imports/markdown/`, `backups/`, `logs/`, `feedback/`, and `templates/`. `master-resumes/master_primary.yaml` exists. | |
| 3.2 | Open Settings. | About shows the candidate version and build. | |
| 3.3 | Read Settings > External Tools. | The table lists all 7 tools, in this order: atsim, Export tool, Pandoc, pdftotext, Google Chrome, Ruby, Codex CLI. atsim is Missing and names `NAV_CENTER_ATSIM_BIN`. Export tool is Built-in and names `NAV_CENTER_EXPORT_BIN`. Pandoc is Missing and names `PANDOC_BIN`. pdftotext is Missing and names `PDFTOTEXT_BIN`. Google Chrome is Missing and names `CHROME_BIN`. Ruby is Found and the summary contains `/usr/bin/ruby`. Codex CLI is Missing and names `DASHBOARD_CODEX_BIN`, unless the CLI is installed; if it is Found, record `codex --version` in the Record table. Each Missing row has an install line. | |
| 3.4 | `/Applications/Nav\ Center.app/Contents/MacOS/navcenterctl doctor` | The tool table matches step 3.3, including Ruby at `/usr/bin/ruby`. The last line is: Finder-launched apps do not see your shell PATH. Tools in /opt/homebrew/bin, /usr/local/bin, or ~/.local/bin are found automatically; otherwise set the variable with `launchctl setenv NAME /absolute/path` before opening Nav Center. | |

## 4. Core flows on synthetic data

Leave Source URL empty when creating a package. Leave Codex automation off. One flow per step.

| Step | Action | Expected | Pass/Fail |
| --- | --- | --- | --- |
| 4.1 | On Overview, choose Import Source Docs and import one synthetic file you created (invented text only). | The app reports the import. Copies exist under `imports/originals/` and `imports/markdown/`. | |
| 4.2 | Paste a synthetic posting of at least 300 characters, with an invented company and role, and choose Create Package. | A package directory `applications/<YYYY-MM-DD>_<Company>_<Role>/` exists and contains `posting.md`. | |
| 4.3 | Open Master Resume, change a visible field to invented text, choose Save, then Reload. | The editor shows the saved text after Reload. | |
| 4.4 | On the package, choose Applied, then Interview. Refresh and reopen the package. | The stored statuses are Submitted, then Interview. The Status History list shows both changes, newest first. (requires WP6) | |
| 4.5 | Rename that package directory so the `YYYY-MM-DD` prefix is a real date more than 7 days before today (`date -v-8d +%F`). Refresh. On Overview, in 7-Day Cleanup, choose Preview. | The review sheet lists every candidate, including this package. There is no truncated "+ N more" row. | |
| 4.6 | Confirm removal in the review sheet (`Remove N Packages`). | The package directory is gone. Note the new directory under `Workspace/tmp/package-cleanup/`. Its `manifest.json` is the restore manifest. The on-screen backup name may be `applications.sqlite.backup` when a tracker exists; the manifest still lives in that stamp directory. | |
| 4.7 | `/Applications/Nav\ Center.app/Contents/MacOS/navcenterctl restore-cleanup --workspace "$HOME/Library/Application Support/Nav Center/Workspace" --manifest "tmp/package-cleanup/<stamp>/manifest.json" --confirm` | Output begins with `Restored`. The package directory is back under `applications/`. | |
| 4.8 | With atsim absent, open the package, choose Run ATS Scan, and confirm. | The Action Log message starts with `ATS scan needs atsim` and names `NAV_CENTER_ATSIM_BIN`. | |
| 4.9 | With Pandoc, Chrome, and pdftotext absent, read Export Artifacts on the package rail. | Export Artifacts is disabled. The reason is `Export needs Pandoc, pdftotext, and Google Chrome. See Settings > External Tools.` (requires WP5) | |
| 4.10 | `brew install pandoc poppler`. Install Google Chrome so `/Applications/Google Chrome.app` exists. In Settings > External Tools, choose Re-check Tools. | Pandoc, pdftotext, and Google Chrome show Found. | |
| 4.11 | Choose Export Artifacts and confirm. Open the Artifacts tab. | The command writes the HTML, DOCX, PDF, and two text files (`*.docx.txt` and `*.pdf.txt`) into the package's `artifacts/`. The Artifacts tab shows them. (requires WP5) | |

## 5. Diagnostics privacy

| Step | Action | Expected | Pass/Fail |
| --- | --- | --- | --- |
| 5.1 | `/Applications/Nav\ Center.app/Contents/MacOS/navcenterctl feedback-diagnostics` | The JSON contains no home path, no user name (`whoami`), and no synthetic document text. `recentLogs` is an empty array. | |
| 5.2 | Help > Copy Redacted Diagnostics, if that item is present. Paste into a text editor and compare with step 5.1. | The paste matches the redacted CLI output: no home path, no user name, no document content, and no log lines. (requires WP7) | |

## 6. Upgrade from v0.1.0-beta

Run this before the candidate is installed, on a second clean machine state, or record it as a separate pass. Sections 1–5 already put the candidate on the machine. Do not use that install for the "before" half of this section.

Do the DMG-drag upgrade and the Homebrew upgrade as two passes. Each pass starts from `v0.1.0-beta` plus its own synthetic data.

The DMG-drag pass (6.1, 6.2, the DMG half of 6.3, and 6.4) belongs to WP12A. The Homebrew half of 6.3 with its own 6.4 belongs to WP12B.

| Step | Action | Expected | Pass/Fail |
| --- | --- | --- | --- |
| 6.1 | From the `v0.1.0-beta` GitHub prerelease, download that DMG in a browser. `shasum -a 256 <v0.1.0-beta.dmg>` | The digest equals the published `.sha256` digest. Compare the digest only. That sidecar is path-prefixed (`dist/…`), so `shasum -c` does not see the downloaded basename. | |
| 6.2 | Install `v0.1.0-beta` (drag to `/Applications` for the DMG pass). Create a synthetic package and edit the master resume with invented text. Read the build: `/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "/Applications/Nav Center.app/Contents/Info.plist"` | Synthetic package and master-resume text are on disk. The old build number is recorded. `v0.1.0-beta`'s Info.plist has no `CFBundleVersion` (PlistBuddy prints `Does Not Exist`); record the old build as absent. | |
| 6.3 | Install the candidate over that app by dragging the candidate DMG's `Nav Center.app` to `/Applications` and replacing. On a separate `v0.1.0-beta` state, after the tap PR is merged: `brew update` and `brew upgrade --cask nav-center`. | Each method leaves the app installed. The brew pass uses the updated `subdepthtech/nav-center` cask. | |
| 6.4 | Relaunch. Open the synthetic package and Master Resume. Open Settings. | The synthetic package and master-resume text are intact. Settings shows the candidate version and a build number present and greater than the `v0.1.0-beta` build from step 6.2, or the old build was absent. | |

## 7. Uninstall

Run `brew uninstall --cask --zap nav-center` on a Homebrew install, and the manual steps on a DMG install. Reinstall between the two if you have only one machine.

Before either removal, pick a vault directory outside the app and the support directory, for example `$HOME/nav-center-vault-synthetic`. Put a marker file in it. Point the app at it with `launchctl setenv NAV_CENTER_VAULT_DIR "$HOME/nav-center-vault-synthetic"` and relaunch once.

The manual DMG uninstall in 7.2 belongs to WP12A. The Homebrew zap in 7.1 belongs to WP12B.

| Step | Action | Expected | Pass/Fail |
| --- | --- | --- | --- |
| 7.1 | `brew uninstall --cask --zap nav-center` | The app, `~/Library/Application Support/Nav Center`, and the AppKit window state files are gone. Those files may already be absent: `~/Library/Preferences/com.subdepthtech.navcenter.plist` and `~/Library/Saved Application State/com.subdepthtech.navcenter.savedState`. The vault marker file is still there. Pandoc, Poppler, and Google Chrome are still installed. | |
| 7.2 | On a DMG install, quit Nav Center, move `/Applications/Nav Center.app` to Trash, then run the manual commands in `docs/BETA.md`: `rm -rf "$HOME/Library/Application Support/Nav Center"`; `rm -f "$HOME/Library/Preferences/com.subdepthtech.navcenter.plist"`; `rm -rf "$HOME/Library/Saved Application State/com.subdepthtech.navcenter.savedState"`. | The same three locations are gone (the plist and saved-state directory may not exist). No other Nav Center path from `docs/BETA.md` remains. The vault marker file is still there. | |

## 8. Sign-off

| Step | Action | Expected | Pass/Fail |
| --- | --- | --- | --- |
| 8.1 | Review sections 1–7. | Every step is Pass, or each failure ID is listed with a link to an issue. | |
| 8.2 | Fill tester and date in the Record table, and copy them into the evidence file. | The evidence file names the tester and the date. | |
| 8.3 | Copy this sentence into the evidence file: `Any failure blocks WP13 rollout until fixed and re-verified through WP11–WP12.` | The evidence file contains that sentence. | |
