import Foundation
import XCTest
@testable import NavCenterCore

final class DocumentImporterSourcePathTests: XCTestCase {
    private var fixture: URL!
    private var workspace: URL { fixture.appendingPathComponent("workspace") }
    private var sourceDirectory: URL { fixture.appendingPathComponent("sources") }
    private var linkedDirectory: URL { fixture.appendingPathComponent("linked-sources") }
    private var manifestURL: URL { workspace.appendingPathComponent("imports/manifest.jsonl") }
    private var importer: DocumentImporter {
        DocumentImporter(workspaceRoot: workspace, now: { Date(timeIntervalSince1970: 0) })
    }

    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("nav-center-import-source-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: sourceDirectory)
    }

    override func tearDownWithError() throws {
        if let fixture { try FileManager.default.removeItem(at: fixture) }
    }

    func testImportThroughSymlinkedParentPreservesBytesMarkdownAndManifest() throws {
        let bytes = Data("  Synthetic résumé — source text.\n".utf8)
        try bytes.write(to: sourceDirectory.appendingPathComponent("source.txt"))
        let source = linkedDirectory.appendingPathComponent("source.txt")

        let first = try XCTUnwrap(importer.importDocuments([source]).first)
        try assertImported(first, source: source, bytes: bytes, base: "source")
        let firstManifest = try Data(contentsOf: manifestURL)
        let second = try XCTUnwrap(importer.importDocuments([source]).first)
        try assertImported(second, source: source, bytes: bytes, base: "source_1")
        XCTAssertTrue(try Data(contentsOf: manifestURL).starts(with: firstManifest))
        XCTAssertEqual(try manifestEntries(), [first, second])
    }

    func testImportThroughSymlinkedGrandparentSucceeds() throws {
        let nested = sourceDirectory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let bytes = Data("Synthetic grandparent document.\n".utf8)
        try bytes.write(to: nested.appendingPathComponent("source.txt"))
        let source = linkedDirectory.appendingPathComponent("nested/source.txt")

        let result = try XCTUnwrap(importer.importDocuments([source]).first)
        try assertImported(result, source: source, bytes: bytes, base: "source")
        XCTAssertEqual(try manifestEntries(), [result])
    }

    func testSourceFinalSymlinkIsRejectedEvenThroughSymlinkedParent() throws {
        let target = sourceDirectory.appendingPathComponent("target.txt")
        let bytes = Data("Synthetic symlink target remains unchanged.".utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: sourceDirectory.appendingPathComponent("source.txt"), withDestinationURL: target)

        XCTAssertThrowsError(try importer.importDocuments([linkedDirectory.appendingPathComponent("source.txt")])) { error in
            XCTAssertTrue(error.localizedDescription.contains("must not contain a symbolic link"))
        }
        try assertNoImports()
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testOversizedSourceThroughSymlinkedParentIsRejected() throws {
        let source = sourceDirectory.appendingPathComponent("oversized.txt")
        try Data().write(to: source)
        let handle = try FileHandle(forWritingTo: source)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(32 * 1024 * 1024 + 1))

        XCTAssertThrowsError(try importer.importDocuments([linkedDirectory.appendingPathComponent("oversized.txt")])) { error in
            XCTAssertEqual(error as? NavCenterError, .invalidPath("source document must be a regular file no larger than 33554432 bytes."))
        }
        try assertNoImports()
    }

    func testInvalidSecondSourceThroughSymlinkedParentKeepsBatchAtomic() throws {
        let good = linkedDirectory.appendingPathComponent("good.txt")
        let bad = linkedDirectory.appendingPathComponent("bad.txt")
        let goodBytes = Data("Synthetic valid UTF-8 document.".utf8)
        let badBytes = Data([0xff, 0xfe, 0x01])
        try goodBytes.write(to: sourceDirectory.appendingPathComponent("good.txt"))
        try badBytes.write(to: sourceDirectory.appendingPathComponent("bad.txt"))

        XCTAssertThrowsError(try importer.importDocuments([good, bad])) { error in
            XCTAssertEqual(error as? NavCenterError, .invalidPath("bad.txt is not valid UTF-8 text. No files from this import batch were saved."))
        }
        try assertNoImports()
        XCTAssertEqual(try Data(contentsOf: good), goodBytes)
        XCTAssertEqual(try Data(contentsOf: bad), badBytes)
    }

    private func assertImported(_ result: ImportedDocument, source: URL, bytes: Data, base: String) throws {
        XCTAssertEqual(result.sourceURL, source)
        XCTAssertEqual(result.originalRelativePath, "imports/originals/\(base).txt")
        XCTAssertEqual(result.markdownRelativePath, "imports/markdown/\(base).md")
        XCTAssertEqual(result.sourceKind, "txt")
        XCTAssertEqual(result.importedAt, "1970-01-01T00:00:00Z")
        XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent(result.originalRelativePath)), bytes)
        let expectedMarkdown = """
        ---
        source_file: "source.txt"
        source_kind: "txt"
        imported_at: "1970-01-01T00:00:00Z"
        review_status: "needs-review"
        ---

        # source

        \(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        """
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent(result.markdownRelativePath), encoding: .utf8), expectedMarkdown)
    }

    private func manifestEntries() throws -> [ImportedDocument] {
        try Data(contentsOf: manifestURL).split(separator: 10).map {
            try JSONDecoder().decode(ImportedDocument.self, from: Data($0))
        }
    }

    private func assertNoImports() throws {
        for directory in ["imports/originals", "imports/markdown"] {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: workspace.appendingPathComponent(directory).path).isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
    }
}
