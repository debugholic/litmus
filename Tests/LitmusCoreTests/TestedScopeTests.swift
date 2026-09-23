import Foundation
import Testing

@testable import LitmusCore

/// Working out which files a scheme's tests are aimed at, from the build.
///
/// Built on a fake DerivedData in a temporary folder: the shape is what
/// xcodebuild writes, and the real thing takes minutes to produce.
@Suite("Tested scope")
struct TestedScopeTests {
    private final class FakeBuild {
        let root: URL
        var derivedData: URL { root.appendingPathComponent("DerivedData") }
        var sources: URL { root.appendingPathComponent("Project With Space") }

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("litmus-scope-\(UUID().uuidString)")
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// Writes the sources and a SwiftFileList for one target.
        func target(_ name: String, files: [String: String]) throws {
            var listed: [String] = []
            for (path, text) in files {
                let url = sources.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try text.write(to: url, atomically: true, encoding: .utf8)
                listed.append(url.path.replacingOccurrences(of: " ", with: "\\ "))
            }

            let list = derivedData.appendingPathComponent(
                "Build/Intermediates.noindex/P.build/Debug-iphonesimulator/"
                    + "\(name).build/Objects-normal/arm64/\(name).SwiftFileList"
            )
            try FileManager.default.createDirectory(
                at: list.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try listed.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        }

        func xctestrun(_ plist: [String: Any]) throws -> URL {
            let url = derivedData.appendingPathComponent("Build/Products/App.xctestrun")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: url)
            return url
        }

        func path(_ relative: String) -> String {
            sources.appendingPathComponent(relative).path
        }
    }

    /// The case that cost a night: a feature's tests importing its test
    /// doubles rather than the feature, inside an app that links everything.
    @Test("keeps the module a test target is named after")
    func namedModule() throws {
        let build = try FakeBuild()
        try build.target("FeatureSetting", files: ["Setting/Sources/A.swift": ""])
        try build.target("FeatureGame", files: ["Game/Sources/B.swift": ""])
        try build.target("FeatureSettingTests", files: [
            "Setting/Tests/SettingTest.swift": "import FeatureSettingTesting\nimport Testing\n",
        ])

        let scope = try #require(TestedScope.from(
            xctestrun: try build.xctestrun(["FeatureSettingTests": ["TestHostPath": "x"]]),
            derivedData: build.derivedData
        ))

        #expect(scope.modules == ["FeatureSetting"])
        #expect(scope.contains(build.path("Setting/Sources/A.swift")))
        #expect(!scope.contains(build.path("Game/Sources/B.swift")))
    }

    @Test("adds modules imported with @testable")
    func testableImport() throws {
        let build = try FakeBuild()
        try build.target("Core", files: ["Core/A.swift": ""])
        try build.target("Other", files: ["Other/B.swift": ""])
        try build.target("AppTests", files: ["Tests/T.swift": "@testable import Core\nimport Other\n"])

        let scope = try #require(TestedScope.from(
            xctestrun: try build.xctestrun(["AppTests": ["TestHostPath": "x"]]),
            derivedData: build.derivedData
        ))

        #expect(scope.contains(build.path("Core/A.swift")))
        #expect(!scope.contains(build.path("Other/B.swift")))
    }

    @Test("reads the newer xctestrun layout")
    func formatTwo() {
        let names = TestedScope.testTargetNames(in: [
            "__xctestrun_metadata__": ["FormatVersion": 2],
            "TestConfigurations": [["TestTargets": [["BlueprintName": "AppTests"]]]],
        ])

        #expect(names == ["AppTests"])
    }

    @Test("reads the older xctestrun layout")
    func formatOne() {
        let names = TestedScope.testTargetNames(in: [
            "__xctestrun_metadata__": ["FormatVersion": 1],
            "FeatureSettingTests": ["TestHostPath": "x"],
        ])

        #expect(names == ["FeatureSettingTests"])
    }

    @Test("strips the test suffix to find the module")
    func moduleNames() {
        #expect(TestedScope.moduleName(forTestTarget: "FeatureSettingTests") == "FeatureSetting")
        #expect(TestedScope.moduleName(forTestTarget: "AppUITests") == "App")
        #expect(TestedScope.moduleName(forTestTarget: "Tests") == "Tests")
    }

    /// xcodebuild escapes spaces in the list. The project that exposed this
    /// lives under "Secret Friend".
    @Test("unescapes paths in a file list")
    func escapedPaths() {
        #expect(TestedScope.parseSwiftFileList("/Volumes/Secret\\ Friend/A.swift\n/b.swift\n")
            == ["/Volumes/Secret Friend/A.swift", "/b.swift"])
    }

    /// Guessing here would drop real mutants. Without a scope the run mutates
    /// what it was given.
    @Test("gives up when the tested module was not built")
    func unknownModule() throws {
        let build = try FakeBuild()
        try build.target("AppTests", files: ["Tests/T.swift": "import XCTest\n"])

        #expect(TestedScope.from(
            xctestrun: try build.xctestrun(["AppTests": ["TestHostPath": "x"]]),
            derivedData: build.derivedData
        ) == nil)
    }
}
