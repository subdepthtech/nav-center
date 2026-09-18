import XCTest
@testable import NavCenterCore

final class InertCSSValidationTests: XCTestCase {
    func testAllowedMediaQueriesAndPageStyles() {
        let stylesheets = [
            "@media print { body { font-size: 10pt } }",
            "@media (min-width: 600px) { body { color: #111 } }",
            "@media print and (min-width: 5in) { h1 { font-size: 20pt } }",
            "@page { size: Letter; margin: 0.65in } body { color: rgb(17,17,17) }",
            "@media (min-width: 5in) and (orientation: portrait) { body { color: #111 } }",
            "@MEDIA print AND (min-width: 5in) { @media (max-width: 8in) { p { color: rgba(17,17,17,0.5) } } }",
            "@media not (color) { body { width: calc(100% - 1in) } }",
            "@media (color) or (monochrome) { body { color: hsl(0,0%,10%) } }",
            "@page :first { margin: 1in } @media\n(min-width: 5in) { p { color: #111 } }"
        ]
        for css in stylesheets { XCTAssertNoThrow(try InertDocumentRenderer.validateCSS(css), css) }
    }

    func testMediaQueryStylesheetProducesDocumentWithInlineStyles() throws {
        let css = "@media print and (min-width: 5in) { h1 { font-size: 20pt } }"
        let html = try InertDocumentRenderer.document(
            fragment: "<h1 style=\"color: rgb(17,17,17)\">Synthetic résumé</h1>", css: css
        )
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("<style>" + css + "</style>"))
        XCTAssertTrue(html.contains("<h1 style=\"color: rgb(17,17,17)\">Synthetic résumé</h1>"))
    }

    func testDisallowedFunctionsRemainRejectedInDeclarationsAndInlineStyles() {
        let values = [
            "url(https://example.com/x.png)",
            "url( https://example.com/x.png )",
            "url (https://example.com/x.png)",
            "URL \t\n(https://example.com/x.png)",
            "expression(alert(1))",
            "expression (alert(1))",
            "expression (1)",
            "image-set('https://example.com/x.png' 1x)",
            "image-set ('https://example.com/x.png' 1x)",
            "element(#x)", "element (#x)",
            "attr(data-x)", "attr (data-x)",
            "repeat(2, 1fr)", "repeat (2, 1fr)",
            "var(--x)", "var (--x)",
            "translate(1px)", "translate (1px)",
            "media(1)", "media (1)", "and(1)", "and (1)",
            "unknown(1)", "unknown (1)",
            "calc(1 + unknown (1))"
        ]
        for value in values {
            let declaration = "background: " + value
            for css in [declaration, "p { " + declaration + " }", "@media (min-width: 5in) { p { " + declaration + " } }"] {
                XCTAssertThrowsError(try InertDocumentRenderer.validateCSS(css), css)
            }
            XCTAssertThrowsError(try InertDocumentRenderer.document(
                fragment: "<p style=\"" + declaration + "\">Synthetic text</p>", css: ""
            ), value)
        }
    }

    func testPreludeCannotHideActualFunctionsOrSpacedDeclarationFunctions() {
        let attacks = [
            "@media (min-width: attr(data-x)) { p { color: #111 } }",
            "@media print and(min-width: 5in) { p { color: #111 } }",
            "@media(min-width: 5in) { p { color: #111 } }",
            "@media (color) { p { content: '; @media ('; background: url (x) } }",
            "p { content: '; @media (' url (x) }",
            "p { content: '} @media (' url (x) }",
            "p { content: \"; @media (\" url (x) }",
            "p { content: '\u{0301}; @media (' url (x) }",
            "p { width: calc(1; @media (color) { url (x) }) }",
            "p { --x: [; @media (color) { url (x) }] }",
            "p { --x: { @media url (x) { } }; }",
            "p { --x\u{0301}: { @media url (x) { } }; }",
            "p { --😀: { @media url (x) { } }; }",
            "p { --x: { @media (color) { url (x) } }; }",
            "p { background: { @media url (x) { } }; }",
            "p { --x: calc({ ) ; @media url (x) { } }) }",
            "p { --x: [{ ] ; @media url (x) { } }] }",
            "background: url (x); @media (color) { p { color: #111 } }",
            "@media (color); background: url (x)",
            "@media (color) { p { color: #111 } } background: url (x)"
        ]
        for css in attacks { XCTAssertThrowsError(try InertDocumentRenderer.validateCSS(css), css) }
        for value in ["background: url&#x20;(x)", "background: u&#x72;l(x)", "background: expression&#x20;(1)", "--x: { @media url (x) { } }", "--😀: { @media url (x) { } }"] {
            XCTAssertThrowsError(try InertDocumentRenderer.document(
                fragment: "<p style=\"" + value + "\">Synthetic text</p>", css: ""
            ), value)
        }
    }

    func testOtherAtRulesAndForbiddenCharactersRemainRejected() {
        let attacks = [
            "@import 'https://example.com/style.css';",
            "@font-face { font-family: example; src: 'example' }",
            "@supports (color: #111) { p { color: #111 } }",
            "@IMPORT 'https://example.com/style.css';",
            "@media print { @supports (color: #111) { p { color: #111 } } }",
            "p { background: u\\72l(x) }",
            "p { color: /* comment */ #111 }",
            "p { color: #111 */ }",
            "p { content: '<' }",
            "p { color: \u{01}#111 }",
            "p { color: \u{00}#111 }"
        ]
        for css in attacks { XCTAssertThrowsError(try InertDocumentRenderer.validateCSS(css), css) }
    }

    func testStylesheetLimitIsMeasuredInUTF8Bytes() {
        XCTAssertNoThrow(try InertDocumentRenderer.validateCSS(String(repeating: " ", count: 64 * 1024)))
        XCTAssertThrowsError(try InertDocumentRenderer.validateCSS(String(repeating: " ", count: 64 * 1024 + 1)))
        XCTAssertThrowsError(try InertDocumentRenderer.validateCSS(String(repeating: "é", count: 32 * 1024 + 1)))
    }
}
