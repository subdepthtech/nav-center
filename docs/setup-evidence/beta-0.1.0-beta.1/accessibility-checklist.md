# GUI and accessibility gate (WP7): 0.1.0-beta.1

Status: in progress (2026-09-23). Not accepted until every row is Pass and every critical row is Pass on the signed candidate.

| Field | Value |
| --- | --- |
| Candidate version | 0.1.0-beta.1 |
| Candidate build | 3 |
| Source SHA | ebe5448a2d6bc4e4b540d8125ab4d2c1e9316971 |
| Preliminary build | local unsigned release preview from the same SHA (build 1, ad-hoc signed, never distributed) |
| Signed candidate | Beta Release run 35874925804 (result pending) |
| macOS | 27.0 (26A428) |
| Hardware | Mac14,10, Apple M2 Pro |
| Tester | Not recorded |
| Date | 2026-09-23 |
| Workspace | disposable synthetic workspace (invented data only) |

## Method

Human rows are observed by the maintainer (VoiceOver on where the row says VoiceOver). Automated rows drive the app with synthetic keyboard events or accessibility queries and read back state. No row is inferred from `swift test`.

## Results

| # | Check | Expected result | Critical | Method | Preview (build 1) | Signed candidate (build 3) | Observations |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | VoiceOver sidebar and toolbar tab order | Each of the seven sections, search field, and refresh control is reachable and named. | No | Human | Not run | Not run |  |
| 2 | VoiceOver package rail tab order | Rail actions, confirmation primary/cancel controls, and status buttons are reachable and named. | No | Human | Not run | Not run |  |
| 3 | VoiceOver status history | Status changes are read in order with old and new status and timestamp. | No | Human | Not run | Not run |  |
| 4 | VoiceOver cleanup sheet | Preview, Remove, sheet Cancel, and sheet Remove are reachable; the removal consequence is announced. | Yes | Human | Not run | Not run |  |
| 5 | VoiceOver Codex panel | Launcher, account controls, input, edit toggles, Send, Stop when present, and Close are reachable and named. | No | Human | Not run | Not run |  |
| 6 | Rail, status, cleanup, and Codex announcements | Rail confirmation, status update, cleanup sheet, and Codex control purpose/state are understandable when spoken. | Yes | Human | Not run | Not run |  |
| 7 | ⌘1 Overview | Opens Overview and closes package detail. | No | To be determined | Not run | Not run |  |
| 8 | ⌘2 Applications | Opens Applications and closes package detail. | No | To be determined | Not run | Not run |  |
| 9 | ⌘3 Packages | Opens Packages and closes package detail. | No | To be determined | Not run | Not run |  |
| 10 | ⌘4 Job Searches | Opens Job Searches and closes package detail. | No | To be determined | Not run | Not run |  |
| 11 | ⌘5 Master Resume | Opens Master Resume and closes package detail. | No | To be determined | Not run | Not run |  |
| 12 | ⌘6 Exports | Opens Exports and closes package detail. | No | To be determined | Not run | Not run |  |
| 13 | ⌘7 Settings | Opens Settings and closes package detail. | No | To be determined | Not run | Not run |  |
| 14 | ⌘, Settings | Opens the Settings destination in the same window. | No | To be determined | Not run | Not run |  |
| 15 | ⌘[ Back to List | Closes package detail; unavailable without an open package. | No | To be determined | Not run | Not run |  |
| 16 | ⇧⌘F Search Applications | Focuses the toolbar application search. | No | To be determined | Not run | Not run |  |
| 17 | ⌘⇧C Toggle Codex Panel | Opens or closes the panel; input is focused on open. | No | To be determined | Not run | Not run |  |
| 18 | ⌘⇧A Run ATS Scan… | Opens the package rail confirmation and focuses its primary button; does not run the scan. | Yes | To be determined | Not run | Not run |  |
| 19 | ⌘⇧E Export Artifacts… | Opens the package rail confirmation and focuses its primary button; does not export. | Yes | To be determined | Not run | Not run |  |
| 20 | ⌘R Refresh Dashboard | Refreshes local dashboard data. | No | To be determined | Not run | Not run |  |
| 21 | Help → Copy Redacted Diagnostics | Copies redacted JSON and shows a transient confirmation; no private workspace path or document contents appear. | Yes | To be determined | Not run | Not run |  |
| 22 | 820×620 minimum window | Review pane and Codex panel remain visible without clipping; scrollable content stays reachable. The on-screen check is the authority. | No | Human | Not run | Not run |  |
| 23 | Close and reopen window | Closing the window leaves the app running; clicking its Dock icon reopens a window. | Yes | To be determined | Not run | Not run |  |
| 24 | Single window controls | File has no New Window item; no tab bar or plus control can open a second window. | No | To be determined | Not run | Not run |  |
| 25 | Quit with unsaved master-resume edits | Quit prompts to save or discard; Cancel keeps the app running with the edits. | Yes | To be determined | Not run | Not run |  |
| 26 | Reduce Motion | Codex open and close remain usable with reduced animation. | No | Human | Not run | Not run |  |
| 27 | Full Keyboard Access | Every actionable control, including menus, sheets, and icon buttons, can be reached and operated. | Yes | Human | Not run | Not run |  |

## Sign-off

Accepted only when every row is Pass (or each failure has an issue link and an explicit owner decision) and every critical row is Pass on the signed candidate.

Tester: Not recorded

Date: Not recorded
