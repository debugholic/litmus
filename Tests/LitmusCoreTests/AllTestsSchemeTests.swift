import Foundation
import Testing

@testable import LitmusCore

/// Writing a scheme of every unit test into a copy of the project.
@Suite("All tests scheme")
struct AllTestsSchemeTests {
    /// A workspace of two projects, one of them nested two groups deep.
    private final class Workspace {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("litmus-scheme-\(UUID().uuidString)")

        init() throws {
            try write("App.xcworkspace/contents.xcworkspacedata", """
            <?xml version="1.0" encoding="UTF-8"?>
            <Workspace version = "1.0">
               <Group location = "group:Projects" name = "Projects">
                  <FileRef location = "group:App/App.xcodeproj"></FileRef>
                  <Group location = "group:Domain" name = "Domain">
                     <FileRef location = "group:Settings/DomainSettings.xcodeproj"></FileRef>
                  </Group>
               </Group>
            </Workspace>
            """)
            try write("Projects/App/App.xcodeproj/project.pbxproj", Self.project([
                ("AAA", "App", "com.apple.product-type.application"),
                ("BBB", "AppUITests", "com.apple.product-type.bundle.ui-testing"),
                ("EEE", "AppTests", "com.apple.product-type.bundle.unit-test"),
            ]))
            try write("Projects/Domain/Settings/DomainSettings.xcodeproj/project.pbxproj", Self.project([
                ("CCC", "DomainSettings", "com.apple.product-type.library.static"),
                ("DDD", "DomainSettingsTests", "com.apple.product-type.bundle.unit-test"),
            ]))
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        var scheme: String? {
            try? String(
                contentsOf: root.appendingPathComponent(
                    "App.xcworkspace/xcshareddata/xcschemes/\(AllTestsScheme.name).xcscheme"
                ),
                encoding: .utf8
            )
        }

        static func project(_ targets: [(String, String, String)]) -> String {
            let objects = targets.map { id, name, type in
                "\(id) = {isa = PBXNativeTarget; name = \(name); productType = \"\(type)\";};"
            }.joined(separator: "\n")
            return "// !$*UTF8*$!\n{archiveVersion = 1; objects = {\n\(objects)\n}; rootObject = AAA;}"
        }
    }

    @Test("reads the projects a workspace lists through nested groups")
    func workspaceProjects() throws {
        let workspace = try Workspace()
        let data = try Data(contentsOf: workspace.root.appendingPathComponent(
            "App.xcworkspace/contents.xcworkspacedata"
        ))

        #expect(AllTestsScheme.projects(inWorkspace: data) == [
            "Projects/App/App.xcodeproj",
            "Projects/Domain/Settings/DomainSettings.xcodeproj",
        ])
    }

    @Test("names every unit test target, and no UI tests")
    func unitTestsOnly() throws {
        let workspace = try Workspace()

        #expect(try AllTestsScheme.prepare(in: workspace.root) == AllTestsScheme.name)

        let scheme = try #require(workspace.scheme)
        #expect(scheme.contains(#"BlueprintName = "DomainSettingsTests""#))
        #expect(scheme.contains(#"BlueprintIdentifier = "DDD""#))
        #expect(scheme.contains("container:Projects/Domain/Settings/DomainSettings.xcodeproj"))
        #expect(!scheme.contains("AppUITests"))
        #expect(scheme.contains(#"BlueprintName = "AppTests""#))
        #expect(scheme.components(separatedBy: "<TestableReference").count == 3)
    }

    @Test("writes nothing when there are no unit tests")
    func noTests() throws {
        let workspace = try Workspace()
        try workspace.write(
            "Projects/Domain/Settings/DomainSettings.xcodeproj/project.pbxproj",
            Workspace.project([("CCC", "DomainSettings", "com.apple.product-type.library.static")])
        )
        try workspace.write(
            "Projects/App/App.xcodeproj/project.pbxproj",
            Workspace.project([("AAA", "App", "com.apple.product-type.application")])
        )

        #expect(try AllTestsScheme.prepare(in: workspace.root) == nil)
        #expect(workspace.scheme == nil)
    }

    @Test("leaves a scheme it already wrote alone")
    func writesOnce() throws {
        let workspace = try Workspace()
        _ = try AllTestsScheme.prepare(in: workspace.root)
        try workspace.write(
            "App.xcworkspace/xcshareddata/xcschemes/\(AllTestsScheme.name).xcscheme", "kept"
        )

        _ = try AllTestsScheme.prepare(in: workspace.root)

        #expect(workspace.scheme == "kept")
    }

    @Test("reads failed targets and projects from a build log and a test run")
    func failures() {
        let log = """
        SwiftCompile normal arm64 /p/Other.swift (in target 'DomainOther' from project 'DomainOther')
        The following build commands failed:
        \tSwiftCompile normal arm64 /p/StoreTesting.swift (in target 'FeatureStoreTesting' from project 'FeatureStore')
        (1 failure)
        Failing tests:
        \tDomainSettingsTests.SettingsSuite/loads()
        ** TEST FAILED **
        """

        let failed = AllTestsScheme.failures(in: log)
        // Every compile step names its target; only the failed list counts.
        #expect(failed.projects == ["FeatureStore"])
        #expect(!failed.targets.contains("DomainOther"))
        #expect(failed.targets.contains("FeatureStoreTesting"))
        #expect(failed.targets.contains("DomainSettingsTests"))
    }

    @Test("takes a target out of the scheme when its project fails to build")
    func leavesOutBrokenProject() throws {
        let workspace = try Workspace()
        _ = try AllTestsScheme.prepare(in: workspace.root)

        let dropped = try AllTestsScheme.leaveOut(
            failedIn: """
            The following build commands failed:
            \tSwiftCompile x (in target 'DomainSettingsTesting' from project 'DomainSettings')
            (1 failure)
            """,
            in: workspace.root
        )

        #expect(dropped == ["DomainSettingsTests"])
        #expect(workspace.scheme?.contains("DomainSettingsTests") == false)
    }

    @Test("never takes out every target")
    func keepsOne() throws {
        let workspace = try Workspace()
        _ = try AllTestsScheme.prepare(in: workspace.root)

        let dropped = try AllTestsScheme.leaveOut(
            failedIn: """
            The following build commands failed:
            \tSwiftCompile x (in target 'DomainSettingsTests' from project 'DomainSettings')
            \tSwiftCompile y (in target 'App' from project 'App')
            """,
            in: workspace.root
        )

        #expect(dropped.isEmpty)
        #expect(workspace.scheme?.contains("DomainSettingsTests") == true)
    }

    @Test("leaves the scheme alone when the log names nothing in it")
    func leavesOutNothing() throws {
        let workspace = try Workspace()
        _ = try AllTestsScheme.prepare(in: workspace.root)
        let before = workspace.scheme

        #expect(try AllTestsScheme.leaveOut(failedIn: "error: something else", in: workspace.root).isEmpty)
        #expect(workspace.scheme == before)
    }
}
