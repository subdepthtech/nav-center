import Foundation
import XCTest

final class PluginManifestTests: XCTestCase {
    private let pluginRoot = "plugins/nav-center"

    func testCodexPluginManifestPublishesNavCenterSkills() throws {
        let manifest: CodexPluginManifest = try decodeJSON("\(pluginRoot)/.codex-plugin/plugin.json")

        XCTAssertEqual(manifest.name, "nav-center")
        XCTAssertEqual(manifest.skills, "./skills/")
        XCTAssertEqual(manifest.repository, "https://github.com/subdepthtech/nav-center")
        XCTAssertEqual(manifest.interface.displayName, "Nav Center")
        XCTAssertTrue(manifest.interface.defaultPrompt.contains { $0.contains("nav-center-codex-setup") })
        XCTAssertTrue(manifest.interface.defaultPrompt.contains { $0.contains("nav-center-beta-feedback") })
    }

    func testClaudePluginManifestPointsAtPublicRepo() throws {
        let manifest: ClaudePluginManifest = try decodeJSON("\(pluginRoot)/.claude-plugin/plugin.json")

        XCTAssertEqual(manifest.name, "nav-center")
        XCTAssertEqual(manifest.repository, "https://github.com/subdepthtech/nav-center")
        XCTAssertEqual(manifest.license, "MIT")
    }

    func testPluginPackageContainsOnlyInstallableSkills() throws {
        let root = repositoryRoot().appendingPathComponent(pluginRoot)
        let skillRoot = root.appendingPathComponent("skills")

        XCTAssertTrue(FileManager.default.fileExists(atPath: skillRoot.appendingPathComponent("nav-center-codex-setup/SKILL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillRoot.appendingPathComponent("nav-center-beta-feedback/SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Tests").path))
    }

    private func decodeJSON<T: Decodable>(_ relativePath: String) throws -> T {
        let url = repositoryRoot().appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }
}

private struct CodexPluginManifest: Decodable {
    var name: String
    var skills: String
    var repository: String
    var interface: CodexPluginInterface
}

private struct CodexPluginInterface: Decodable {
    var displayName: String
    var defaultPrompt: [String]
}

private struct ClaudePluginManifest: Decodable {
    var name: String
    var repository: String
    var license: String
}
