import XCTest
import PDFKit
@testable import NavCenterCore

final class RendererReadinessTests: XCTestCase {
    private let stylesheet = "@page { size: Letter; margin: 0.65in; } body { font-family: Helvetica, Arial, sans-serif; font-size: 11pt; } h1 { color: #114488; font-size: 24pt; } table { border-collapse: collapse; } td, th { border: 1px solid #999; padding: 5px; }"
    private let fragment = "<h1>Zoë García — Résumé</h1><p>Unicode café, naïve, Ελληνικά.</p><ul><li>Designed reliable systems.</li><li>Reviewed synthetic evidence.</li></ul><table><thead><tr><th>Skill</th><th>Experience</th></tr></thead><tbody><tr><td style=\"text-align: left;\">Swift</td><td>Five synthetic years</td></tr></tbody></table><p><a href=\"https://example.invalid/profile\">Profile link</a></p>"

    func testInertDocumentPreservesUnicodeTablesListsAndStyles() throws {
        let html = try InertDocumentRenderer.document(fragment: fragment, css: stylesheet)
        XCTAssertTrue(html.contains("Zoë García — Résumé"))
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("style=\"text-align: left;\""))
        XCTAssertTrue(html.contains("<style>" + stylesheet + "</style>"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("script-src 'none'"))
        XCTAssertTrue(html.contains("base-uri 'none'"))
    }

    func testActiveHTMLAndResourceNavigationAreRejected() {
        let attacks = [
            "<script>document.body.innerHTML='REPLACED';</script>",
            "<p onclick=\"location='https://example.invalid'\">Click</p>",
            "<img src=\"https://example.invalid/sentinel.png\" />",
            "<iframe src=\"file:///synthetic-sentinel.txt\"></iframe>",
            "<object data=\"file:///synthetic-sentinel.txt\"></object>",
            "<meta http-equiv=\"refresh\" content=\"0;url=file:///synthetic-sentinel.txt\" />",
            "<base href=\"file:///\" />",
            "<link rel=\"stylesheet\" href=\"https://example.invalid/style.css\" />",
            "<svg><script>1</script></svg>",
            "<form action=\"https://example.invalid\"><p>Form</p></form>",
            "<a href=\"file:///synthetic-sentinel.txt\">File</a>",
            "<a href=\"jav&#x61;script:alert(1)\">Script</a>",
            "<a href=\"java&#x0a;script:alert(1)\">Script</a>",
            "<a href=\"data:text/html,evil\">Data</a>",
            "<!DOCTYPE html [<!ENTITY x SYSTEM 'file:///synthetic-sentinel.txt'>]><p>&x;</p>",
            "<?xml-stylesheet href='file:///synthetic-sentinel.txt'?><p>Document</p>",
            "<p xmlns=\"http://www.w3.org/1999/xhtml\">Namespace</p>",
            "<p style=\"background: u&#x72;l(https://example.invalid)\">Entity CSS</p>"
        ]
        for attack in attacks {
            XCTAssertThrowsError(try InertDocumentRenderer.document(fragment: attack, css: stylesheet), attack) { error in
                XCTAssertTrue(error.localizedDescription.contains("not support"), error.localizedDescription)
            }
        }
    }

    func testCSSResourceLoadingEscapesAndCommentsFailClosed() {
        let attacks = [
            "p { background: url(https://example.invalid/a); }",
            "p { background: URL('file:///synthetic-sentinel.txt'); }",
            "p { background: u\\72l(https://example.invalid/a); }",
            "p { background: u/**/rl(https://example.invalid/a); }",
            "@import 'https://example.invalid/style.css';",
            "@\\69mport 'https://example.invalid/style.css';",
            "@/**/import 'https://example.invalid/style.css';",
            "@font-face { font-family: example; src: url(file:///synthetic-sentinel.txt); }",
            "p { background: image-set('https://example.invalid/a' 1x); }",
            "p { --image: url(https://example.invalid/a); background: var(--image); }",
            "p { width: expression(alert(1)); }",
            "p { color: red; } </style><script>1</script>"
        ]
        for css in attacks { XCTAssertThrowsError(try InertDocumentRenderer.document(fragment: "<p>Safe text</p>", css: css), css) }
    }

    func testMalformedOrExcessivelyNestedHTMLIsRejected() {
        XCTAssertThrowsError(try InertDocumentRenderer.document(fragment: "<p><img src='file:///x'></p>", css: stylesheet))
        XCTAssertThrowsError(try InertDocumentRenderer.document(fragment: String(repeating: "<div>", count: 70) + "text" + String(repeating: "</div>", count: 70), css: stylesheet))
        XCTAssertThrowsError(try InertDocumentRenderer.document(fragment: String(repeating: "a", count: 256 * 1024 + 1), css: stylesheet))
    }

    func testRendererArgumentsUseDataOriginFreshProfileAndKeepSandbox() throws {
        let root = try workspace()
        let html = try InertDocumentRenderer.document(fragment: fragment, css: stylesheet)
        let arguments = InertDocumentRenderer.chromeArguments(document: html, pdfURL: root.appendingPathComponent("output.pdf"), profile: root.appendingPathComponent("fresh-profile"))
        XCTAssertTrue(arguments.last?.hasPrefix("data:text/html;charset=utf-8;base64,") == true)
        XCTAssertFalse(arguments.contains(where: { $0.hasPrefix("file:") || $0.contains("--no-sandbox") || $0.contains("--disable-setuid-sandbox") }))
        XCTAssertTrue(arguments.contains("--proxy-bypass-list=<-loopback>"))
        XCTAssertTrue(arguments.contains("--host-resolver-rules=MAP * ~NOTFOUND"))
        XCTAssertTrue(html.contains("script-src 'none'"))
        XCTAssertTrue(arguments.contains("--user-data-dir=" + root.appendingPathComponent("fresh-profile").path))
    }

    func testInstalledChromeRendersStyledUnicodeDocumentWithPrivateProfile() throws {
        guard ProcessInfo.processInfo.environment["NAV_CENTER_TEST_REAL_CHROME"] == "1" else { throw XCTSkip("Set NAV_CENTER_TEST_REAL_CHROME=1 for the installed-Chrome integration check.") }
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        guard FileManager.default.isExecutableFile(atPath: chrome) else {
            XCTFail("NAV_CENTER_TEST_REAL_CHROME=1 but Google Chrome is not executable at \(chrome).")
            return
        }
        let root = try workspace()
        let html = try InertDocumentRenderer.document(fragment: fragment, css: stylesheet)
        let pdf = root.appendingPathComponent("styled-unicode.pdf")
        try InertDocumentRenderer.render(document: html, pdfURL: pdf, staging: root, chromePath: chrome)
        let document = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertGreaterThan(document.pageCount, 0)
        let text = try XCTUnwrap(document.string)
        XCTAssertTrue(text.contains("Zoë García"), text)
        XCTAssertTrue(text.contains("Résumé"), text)
        XCTAssertTrue(text.contains("Ελληνικά"), text)
        XCTAssertTrue(text.contains("Designed reliable systems"), text)
        XCTAssertTrue(text.contains("Five synthetic years"), text)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix("chrome-profile-") }))
        if let evidence = ProcessInfo.processInfo.environment["NAV_CENTER_RENDERER_EVIDENCE_DIR"] {
            let output = URL(fileURLWithPath: evidence, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try Data(contentsOf: pdf).write(to: output.appendingPathComponent("styled-unicode.pdf"))
            try html.write(to: output.appendingPathComponent("styled-unicode.html"), atomically: true, encoding: .utf8)
            try text.write(to: output.appendingPathComponent("styled-unicode.txt"), atomically: true, encoding: .utf8)
            if let page = document.page(at: 0), let tiff = page.thumbnail(of: NSSize(width: 850, height: 1100), for: .mediaBox).tiffRepresentation,
               let image = NSBitmapImageRep(data: tiff), let png = image.representation(using: .png, properties: [:]) {
                try png.write(to: output.appendingPathComponent("styled-unicode.png"))
            }
        }
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nav-center-renderer-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
}
