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
        import http.server,sys
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                with open(sys.argv[2], 'a') as f: f.write(self.path+'\n')
                if self.path=='/redirect':
                    self.send_response(302);self.send_header('Location','/secret');self.end_headers();return
                body=('<html><title>Synthetic</title>Responsibilities and requirements. '+'Experience building synthetic systems. '*30+'</html>').encode()
                self.send_response(200);self.end_headers();self.wfile.write(body)
            def log_message(self,*args): pass
        server=http.server.HTTPServer(('127.0.0.1',0),Handler)
        open(sys.argv[1],'w').write(str(server.server_port))
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
        let port = try String(contentsOf: portFile)
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
}
