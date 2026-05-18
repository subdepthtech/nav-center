import XCTest
@testable import NavCenterApp

final class DashboardModelsTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testDecodesDashboardHealthResponse() throws {
        let json = """
        {
          "ok": true,
          "service": "nav-center",
          "localOnly": true,
          "features": {
            "codexAppServer": true
          },
          "generatedAt": "2026-05-06T13:00:00.000Z",
          "repoRoot": "/tmp/nav-center-workspace",
          "tracker": {
            "available": true,
            "driver": "sqlite3-cli",
            "readOnly": true,
            "queryOnly": true,
            "warnings": []
          },
          "packages": {
            "available": true,
            "scanned": 4,
            "warnings": []
          }
        }
        """

        let health = try decoder.decode(DashboardHealth.self, from: Data(json.utf8))

        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.service, "nav-center")
        XCTAssertTrue(health.localOnly)
        XCTAssertEqual(health.features?.codexAppServer, true)
        XCTAssertEqual(health.repoRoot, "/tmp/nav-center-workspace")
    }

    func testDecodesSummaryResponseFromNativeDashboard() throws {
        let json = """
        {
          "generatedAt": "2026-05-06T13:00:00.000Z",
          "localOnly": true,
          "totals": {
            "applications": 4,
            "trackerRows": 3,
            "packageOnly": 1,
            "packages": 4,
            "artifacts": 12,
            "nextActionsDue": 2,
            "pursueNow": 3,
            "generated": 2,
            "submitted": 1,
            "interviews": 1
          },
          "statusCounts": {
            "Generated": 2,
            "Submitted": 1,
            "Interview": 1
          },
          "upcomingActions": [
            {
              "id": 7,
              "packageName": "2026-05-05_Example_Security_Engineer",
              "date": "2026-05-05",
              "company": "Example",
              "role": "Security Engineer",
              "location": "Remote",
              "status": "Generated",
              "nextActionDate": "2026-05-06",
              "packageUrl": "native-package:2026-05-05_Example_Security_Engineer"
            }
          ],
          "recentApplications": [],
          "packageHealth": {
            "withPosting": 4,
            "withResumeSource": 3,
            "withInterviewPrep": 2,
            "withArtifacts": 4,
            "withAtsFiles": 1
          },
          "sources": {
            "tracker": {
              "available": true,
              "driver": "sqlite",
              "readOnly": true,
              "queryOnly": true,
              "warnings": []
            },
            "packages": {
              "available": true,
              "scanned": 4,
              "warnings": []
            }
          }
        }
        """

        let summary = try decoder.decode(DashboardSummary.self, from: Data(json.utf8))

        XCTAssertTrue(summary.localOnly)
        XCTAssertEqual(summary.totals.pursueNow, 3)
        XCTAssertEqual(summary.statusCounts["Generated"], 2)
        XCTAssertEqual(summary.upcomingActions.first?.id, "7")
        XCTAssertEqual(summary.packageHealth.withAtsFiles, 1)
        XCTAssertTrue(summary.sources.tracker.queryOnly)
    }

    func testDecodesApplicationsResponseFromNativeDashboard() throws {
        let json = """
        {
          "generatedAt": "2026-05-06T13:00:00.000Z",
          "total": 1,
          "limit": 500,
          "offset": 0,
          "applications": [
            {
              "id": "app_1",
              "packageName": "2026-05-05_Example_Security_Engineer",
              "date": "2026-05-05",
              "company": "Example",
              "role": "Security Engineer",
              "location": "Remote",
              "salary": "$120k",
              "status": "Generated",
              "nextActionDate": "2026-05-06",
              "applicationDir": "applications/2026-05-05_Example_Security_Engineer",
              "applyLink": "https://example.test/jobs/1",
              "sourceName": "Example Careers",
              "sourceId": "req-1",
              "notes": "Private detailed notes",
              "notesPreview": "Private detailed notes",
              "createdAt": "2026-05-05T13:00:00.000Z",
              "updatedAt": "2026-05-06T13:00:00.000Z",
              "source": { "tracker": true, "package": true },
              "health": {
                "hasPosting": true,
                "hasResumeSource": true,
                "hasCoverLetterSource": false,
                "hasInterviewPrep": true,
                "artifactCount": 3,
                "atsFileCount": 1,
                "hasAtsReport": true,
                "hasAtsJson": true,
                "previewableCount": 4
              },
              "files": [],
              "dbArtifacts": []
            }
          ],
          "sources": {
            "tracker": {
              "available": true,
              "driver": "sqlite",
              "readOnly": true,
              "queryOnly": true,
              "warnings": []
            },
            "packages": {
              "available": true,
              "scanned": 1,
              "warnings": []
            }
          }
        }
        """

        let response = try decoder.decode(ApplicationsResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.total, 1)
        XCTAssertEqual(response.applications.first?.company, "Example")
        XCTAssertEqual(response.applications.first?.source.tracker, true)
        XCTAssertEqual(response.applications.first?.health.hasAtsReport, true)
    }

    func testDecodesPackageAndActionResponsesFromNativeDashboard() throws {
        let packageJson = """
        {
          "generatedAt": "2026-05-06T13:00:00.000Z",
          "package": {
            "name": "2026-05-05_Example_Security_Engineer",
            "applicationDir": "applications/2026-05-05_Example_Security_Engineer",
            "metadata": { "company": "Example", "role": "Security Engineer" },
            "files": [
              {
                "relativePath": "posting.md",
                "label": "posting.md",
                "kind": "posting",
                "format": "md",
                "size": 55,
                "modifiedAt": "2026-05-06T13:00:00.000Z",
                "previewable": true,
                "previewUrl": "native-preview:posting.md",
                "rawUrl": null,
                "editable": true
              }
            ],
            "tabs": [
              {
                "key": "posting",
                "label": "Posting",
                "available": true,
                "fileCount": 1,
                "primaryFile": {
                  "relativePath": "posting.md",
                  "label": "posting.md",
                  "kind": "posting",
                  "format": "md",
                  "size": 55,
                  "modifiedAt": "2026-05-06T13:00:00.000Z",
                  "previewable": true,
                  "previewUrl": "native-preview:posting.md",
                  "rawUrl": null,
                  "editable": true
                },
                "files": []
              }
            ],
            "artifactSummary": {
              "total": 2,
              "previewable": 1,
              "ats": 1,
              "byFormat": { "json": 1, "pdf": 1 },
              "byKind": { "ats": 1, "resume": 1 }
            },
            "health": {
              "hasPosting": true,
              "hasResumeSource": true,
              "hasCoverLetterSource": false,
              "hasInterviewPrep": false,
              "artifactCount": 2,
              "atsFileCount": 1,
              "hasAtsReport": true,
              "hasAtsJson": true,
              "previewableCount": 2
            }
          },
          "application": null,
          "statusEvents": [],
          "sources": {
            "tracker": {
              "available": true,
              "driver": "sqlite",
              "readOnly": true,
              "queryOnly": true,
              "warnings": []
            },
            "packages": {
              "available": true,
              "scanned": 1,
              "warnings": []
            }
          }
        }
        """
        let actionJson = """
        {
          "generatedAt": "2026-05-06T13:00:00.000Z",
          "localOnly": true,
          "actions": [
            {
              "id": "action_1",
              "action": "ats-scan",
              "label": "Run ATS Scan",
              "packageName": "2026-05-05_Example_Security_Engineer",
              "status": "succeeded",
              "requestedAt": "2026-05-06T13:00:00.000Z",
              "completedAt": "2026-05-06T13:00:02.000Z",
              "durationMs": 2000,
              "command": "atsim scan applications/pkg --out applications/pkg/artifacts/ats-report.json",
              "outputPath": "applications/pkg/artifacts/ats-report.json",
              "exitCode": 0,
              "signal": null,
              "message": "ATS scan completed and ats-report.json was refreshed.",
              "stdoutTail": "",
              "stderrTail": ""
            }
          ]
        }
        """

        let package = try decoder.decode(PackageResponse.self, from: Data(packageJson.utf8))
        let actions = try decoder.decode(ActionLogResponse.self, from: Data(actionJson.utf8))

        XCTAssertEqual(package.package.name, "2026-05-05_Example_Security_Engineer")
        XCTAssertEqual(package.package.tabs.first?.primaryFile?.relativePath, "posting.md")
        XCTAssertEqual(package.package.artifactSummary.byFormat["json"], 1)
        XCTAssertEqual(actions.actions.first?.status, "succeeded")
        XCTAssertEqual(actions.actions.first?.exitCode, 0)
    }

    func testDecodesCodexAppServerResponses() throws {
        let statusJson = """
        {
          "ok": true,
          "userAgent": "Codex Desktop/0.128.0",
          "codexHome": "/tmp/nav-center-codex-home",
          "account": {
            "type": "chatgpt",
            "email": "tester@example.com",
            "planType": "pro"
          },
          "requiresOpenaiAuth": false,
          "authMethod": "chatgpt",
          "localOnly": true
        }
        """
        let loginJson = """
        {
          "type": "chatgptDeviceCode",
          "loginId": "login_1",
          "verificationUrl": "https://chatgpt.com/activate",
          "userCode": "ABCD-EFGH"
        }
        """
        let chatJson = """
        {
          "ok": true,
          "threadId": "thread_1",
          "turnId": "turn_1",
          "status": "completed",
          "message": "Package reviewed.",
          "diff": "",
          "account": {
            "type": "chatgpt",
            "email": "tester@example.com",
            "planType": "pro"
          }
        }
        """

        let status = try decoder.decode(CodexStatusResponse.self, from: Data(statusJson.utf8))
        let login = try decoder.decode(CodexLoginStartResponse.self, from: Data(loginJson.utf8))
        let chat = try decoder.decode(CodexChatResponse.self, from: Data(chatJson.utf8))

        XCTAssertEqual(status.account?.email, "tester@example.com")
        XCTAssertEqual(status.authMethod, "chatgpt")
        XCTAssertEqual(login.userCode, "ABCD-EFGH")
        XCTAssertEqual(chat.threadId, "thread_1")
        XCTAssertEqual(chat.message, "Package reviewed.")
    }
}
