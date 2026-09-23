import Foundation

/// What a project's tests are written with, read from the source before
/// anything is built.
public enum TestSources {
    /// Whether every unit test in the tree is Swift Testing.
    ///
    /// Then the coverage run is not worth its minutes: each Swift Testing
    /// target is probed in process, test by test, which says which mutants
    /// any test reaches more precisely than line coverage does. An XCTest
    /// target has no probe, and each of its mutants costs a launch, so any
    /// XCTest case keeps the coverage run. UI tests are left out: they are
    /// XCTest by necessity and never run against a mutant.
    ///
    /// False when no test source is found, since nothing is then known.
    public static func allSwiftTesting(in root: URL) -> Bool {
        var sawSwiftTesting = false

        for file in testFiles(in: root) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if text.contains("XCUIApplication") { continue }
            if TestedScope.declaresXCTestCase(in: text) { return false }
            if text.contains("import Testing") { sawSwiftTesting = true }
        }

        return sawSwiftTesting
    }

    /// Swift files under a folder whose name ends in "Tests" or "Test".
    static func testFiles(in root: URL) -> [URL] {
        let skipped: Set<String> = [
            ".git", ".build", "build", "DerivedData", "node_modules", "Pods", "Carthage", ".swiftpm",
        ]
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if skipped.contains(name) || name.hasSuffix(".noindex") {
                walker.skipDescendants()
                continue
            }
            guard url.pathExtension == "swift" else { continue }

            let relative = url.path.dropFirst(root.path.count).split(separator: "/").dropLast()
            if relative.contains(where: { $0.hasSuffix("Tests") || $0 == "Test" }) {
                files.append(url)
            }
        }
        return files
    }
}
