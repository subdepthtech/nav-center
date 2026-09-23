import Foundation
import XCTest
@testable import NavCenterCore

final class CreatorReadinessTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("navcenter-url-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func options(_ source: ApplicationSource, local: Bool = false) -> CreateApplicationOptions {
        CreateApplicationOptions(source: source, company: "Synthetic Café", role: "Engineer", date: "2026-09-04", dryRun: false, overwrite: false, allowLocalURL: local)
    }

    func testLocalJobUsesWorkspaceRootWithoutDirectoryURLHintAndRejectsBinary() throws {
        let root = try fixture()
        let source = root.appendingPathComponent("job.md")
        try Data(("Responsibilities and requirements. " + String(repeating: "Experience building synthetic systems. ", count: 30)).utf8).write(to: source)
        let creator = ApplicationCreator(repoRoot: URL(fileURLWithPath: root.path, isDirectory: false))
        let result = try creator.create(options: options(.job("job.md")))
        XCTAssertTrue(try String(contentsOf: result.postingURL).contains("Synthetic Café"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.packageURL.appendingPathComponent("Resume_" + result.packageName + ".md").path))
        try Data([0xff, 0xfe, 0x80]).write(to: source)
        XCTAssertThrowsError(try creator.create(options: options(.job("job.md"))))
    }

    func testURLPrivateVariantsAreBlockedAndOptInDoesNotFollowRedirects() throws {
        let root = try fixture()
        let portFile = root.appendingPathComponent("port")
        let hitsFile = root.appendingPathComponent("hits")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", #"""
        import http.server,os,sys
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                with open(sys.argv[2], 'a') as f: f.write(self.path+'\n')
                if self.path=='/redirect':
                    self.send_response(302);self.send_header('Location','/secret');self.end_headers();return
                body=('<html><title>Synthetic</title>Responsibilities and requirements. '+'Experience building synthetic systems. '*30+'</html>').encode()
                self.send_response(200);self.end_headers();self.wfile.write(body)
            def log_message(self,*args): pass
        server=http.server.HTTPServer(('127.0.0.1',0),Handler)
        # HTTPServer binds and listens in its constructor; atomic rename publishes readiness.
        with open(sys.argv[1]+'.tmp','w') as f: f.write(str(server.server_port))
        os.replace(sys.argv[1]+'.tmp',sys.argv[1])
        server.serve_forever()
        """#, portFile.path, hitsFile.path]
        let errors = Pipe()
        server.standardError = errors
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: portFile.path), server.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard FileManager.default.fileExists(atPath: portFile.path) else {
            XCTFail("Synthetic HTTP listener did not start: " + String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)); return
        }
        let rawPort = (try? String(contentsOf: portFile)) ?? "<unreadable>"
        guard let port = UInt16(rawPort.trimmingCharacters(in: .whitespacesAndNewlines)), port != 0 else {
            if server.isRunning { server.terminate(); server.waitUntilExit() }
            XCTFail("Synthetic HTTP listener published invalid port \(String(reflecting: rawPort)): "
                + String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            return
        }
        let creator = ApplicationCreator(repoRoot: root)
        for host in ["127.0.0.1", "127.1", "2130706433", "0x7f000001", "localhost", "[::1]", "[::ffff:127.0.0.1]", "[::ffff:7f00:1]", "169.254.169.254", "10.0.0.1", "[fc00::1]"] {
            XCTAssertThrowsError(try creator.create(options: options(.url("http://\(host):\(port)/blocked"))), host)
        }
        for address in ["file:///etc/passwd", "http://user:password@127.0.0.1:\(port)/", "http://127.0.0.1:\(port)/#fragment"] {
            XCTAssertThrowsError(try creator.create(options: options(.url(address), local: true)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: hitsFile.path))
        XCTAssertThrowsError(try creator.create(options: options(.url("http://localhost:\(port)/redirect"), local: true)))
        XCTAssertEqual(try String(contentsOf: hitsFile), "/redirect\n")
        let result = try creator.create(options: options(.url("HTTP://localhost:\(port)/positive"), local: true))
        XCTAssertTrue(try String(contentsOf: result.postingURL).contains("Experience building synthetic systems"))
        XCTAssertEqual(try String(contentsOf: hitsFile), "/redirect\n/positive\n")
    }

    func testOversizedPayloadIsRejected() throws {
        let root = try fixture()
        try Data(count: 4_194_305).write(to: root.appendingPathComponent("payload.json"))
        let creator = ApplicationCreator(repoRoot: root)

        XCTAssertThrowsError(try creator.create(options: options(.payload("payload.json")))) { error in
            XCTAssertTrue(error.localizedDescription.contains("4194304"), error.localizedDescription)
        }
        let applications = root.appendingPathComponent("applications")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? []
        XCTAssertTrue(names.isEmpty, names.joined(separator: ", "))
    }

    func testPayloadOutsideWorkspaceUnderSymlinkedTemporaryDirectoryIsRead() throws {
        let root = try fixture()
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("navcenter-payload-link-" + UUID().uuidString, isDirectory: true)
        let realdir = base.appendingPathComponent("realdir", isDirectory: true)
        let linkdir = base.appendingPathComponent("linkdir", isDirectory: true)
        try FileManager.default.createDirectory(at: realdir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkdir, withDestinationURL: realdir)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        try validPayloadData().write(to: realdir.appendingPathComponent("payload.json"))
        let creator = ApplicationCreator(repoRoot: root)

        let result = try creator.create(options: options(.payload(linkdir.appendingPathComponent("payload.json").path)))
        let posting = try String(contentsOf: result.postingURL)
        XCTAssertTrue(posting.contains("Synthetic Café"))
        XCTAssertTrue(posting.contains("source_type: \"payload\""))
        XCTAssertTrue(posting.contains("Synthetic Payload Title"))
        XCTAssertTrue(posting.contains("https://example.test/jobs/synthetic"))
        XCTAssertTrue(posting.contains("synthetic-board"))
        XCTAssertTrue(posting.contains("job-42"))
        XCTAssertTrue(posting.contains("Remote"))
        XCTAssertTrue(posting.contains("100000"))
        XCTAssertTrue(posting.contains("captures/synthetic.json"))
        XCTAssertTrue(posting.contains("Experience building synthetic systems"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.packageURL.appendingPathComponent("Resume_" + result.packageName + ".md").path))
    }

    func testOversizedPayloadOutsideWorkspaceIsRejected() throws {
        let root = try fixture()
        let outside = try outsidePayloadDirectory()
        try Data(count: 4_194_305).write(to: outside.appendingPathComponent("payload.json"))
        let creator = ApplicationCreator(repoRoot: root)

        XCTAssertThrowsError(try creator.create(options: options(.payload(outside.appendingPathComponent("payload.json").path)))) { error in
            XCTAssertTrue(error.localizedDescription.contains("4194304"), error.localizedDescription)
        }
        let applications = root.appendingPathComponent("applications")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? []
        XCTAssertTrue(names.isEmpty, names.joined(separator: ", "))
    }

    func testSymlinkedPayloadFileOutsideWorkspaceIsRefused() throws {
        let root = try fixture()
        let outside = try outsidePayloadDirectory()
        let real = outside.appendingPathComponent("real-payload.json")
        try validPayloadData().write(to: real)
        let link = outside.appendingPathComponent("payload.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let creator = ApplicationCreator(repoRoot: root)

        XCTAssertThrowsError(try creator.create(options: options(.payload(link.path)))) { error in
            XCTAssertTrue(error.localizedDescription.contains("symbolic link"), error.localizedDescription)
        }
        let applications = root.appendingPathComponent("applications")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? []
        XCTAssertTrue(names.isEmpty, names.joined(separator: ", "))
    }

    private func outsidePayloadDirectory() throws -> URL {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("navcenter-payload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        return outside
    }

    private func validPayloadData() throws -> Data {
        let description = "Responsibilities and requirements. " + String(repeating: "Experience building synthetic systems. ", count: 30)
        let object: [String: String] = [
            "title": "Synthetic Payload Title",
            "url": "https://example.test/jobs/synthetic",
            "source": "synthetic-board",
            "id": "job-42",
            "location": "Remote",
            "salary": "100000",
            "posted_date": "2026-09-01",
            "job_type": "full-time",
            "work_settings": "remote",
            "source_path": "captures/synthetic.json",
            "description": description
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }
}
