import Foundation
import Testing

@testable import LitmusCore

/// The two harnesses, driven against a stand-in executable.
///
/// Both take the path to the tool they run, so a shell script that prints a
/// canned log and exits with a chosen status stands in for `xcodebuild` and
/// `swift`. What is being checked is what Litmus passes in and what it makes of
/// what comes back — not that Xcode works.
@Suite("Harnesses")
struct HarnessTests {
    /// A script that echoes its arguments and a fixed body, then exits.
    private final class FakeTool {
        let directory: URL
        var path: String { directory.appendingPathComponent("tool").path }

        init(printing body: String = "", exiting status: Int32 = 0) throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("litmus-tool-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let script = """
            #!/bin/sh
            echo "ARGS: $@"
            echo "SWITCHES: $(env | grep -c '^LITMUS_PROBE_')"
            cat <<'BODY'
            \(body)
            BODY
            exit \(status)
            """

            let url = URL(fileURLWithPath: path)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: path
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private var workingDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
    }

    // MARK: - swift package

    @Test("runs the package's tests without building them again")
    func swiftPackageSkipsBuild() throws {
        let tool = try FakeTool(printing: "Test run with 3 tests in 1 suites passed after 0.1 seconds.")
        let package = SwiftPackage(executable: tool.path, workingDirectory: workingDirectory)

        let output = try package.test(BuiltTests(), lane: "worker 1", switchOn: nil)

        #expect(output.log.contains("ARGS: test --skip-build"))
        #expect(output.status == 0)
    }

    /// There is no runner in between here, so the variable goes straight onto
    /// the test process rather than through a `TEST_RUNNER_` prefix.
    @Test("puts the mutant's variable on the test process itself")
    func swiftPackageEnvironment() throws {
        let tool = try FakeTool()
        let package = SwiftPackage(executable: tool.path, workingDirectory: workingDirectory)

        let output = try package.test(
            BuiltTests(),
            lane: "worker 1",
            switchOn: "LITMUS_PROBE_Sample_ChangeLogicalConnector_1_2_3"
        )

        #expect(output.log.contains("SWITCHES: 1"))
    }

    @Test("sets no variable for the baseline")
    func swiftPackageBaseline() throws {
        let tool = try FakeTool()
        let package = SwiftPackage(executable: tool.path, workingDirectory: workingDirectory)

        let output = try package.test(BuiltTests(), lane: "worker 1", switchOn: nil)

        #expect(output.log.contains("SWITCHES: 0"))
    }

    @Test("carries a bad exit status back rather than swallowing it")
    func swiftPackageStatus() throws {
        let tool = try FakeTool(exiting: 1)
        let package = SwiftPackage(executable: tool.path, workingDirectory: workingDirectory)

        #expect(try package.test(BuiltTests(), lane: "worker 1", switchOn: nil).status == 1)
    }

    /// A build that failed has to stop the run. Carrying on would measure
    /// mutants against a binary that was never rebuilt.
    @Test("throws when the build fails")
    func swiftPackageBuildFailure() throws {
        let tool = try FakeTool(printing: "error: build failed", exiting: 1)
        let package = SwiftPackage(executable: tool.path, workingDirectory: workingDirectory)

        #expect(throws: SwiftPackage.Failure.self) {
            try package.build(lane: "worker 1")
        }
    }

    @Test("builds the tests before running them")
    func swiftPackageBuild() throws {
        let tool = try FakeTool()
        let package = SwiftPackage(executable: tool.path, workingDirectory: workingDirectory)

        _ = try package.build(lane: "worker 1")
        // Nothing to carry: --skip-build finds the products by itself.
        #expect(try package.build(lane: "worker 1").artifact == nil)
    }

    // MARK: - xcodebuild

    /// `man xcodebuild` documents `TEST_RUNNER_<VAR>` as the way to pass a
    /// variable into the test runner process; the prefix is stripped on the way
    /// in. Setting the bare name would never reach the simulator.
    @Test("passes the mutant's variable with the TEST_RUNNER_ prefix")
    func xcodebuildEnvironment() throws {
        let tool = try FakeTool()
        let xcodebuild = Xcodebuild(
            executable: tool.path,
            workingDirectory: workingDirectory,
            scheme: "MyApp",
            derivedDataPath: workingDirectory
        )

        let output = try xcodebuild.testWithoutBuilding(
            xctestrun: URL(fileURLWithPath: "/tmp/App.xctestrun"),
            destination: "platform=iOS Simulator,id=UDID",
            switchOn: "LITMUS_PROBE_Sample_ChangeLogicalConnector_1_2_3"
        )

        // The script counts variables named LITMUS_PROBE_*, so a prefixed one
        // does not match: seeing zero is what proves the prefix was added.
        #expect(output.log.contains("SWITCHES: 0"))
    }

    @Test("runs the built tests against the xctestrun it was given")
    func xcodebuildArguments() throws {
        let tool = try FakeTool(printing: "** TEST SUCCEEDED **")
        let xcodebuild = Xcodebuild(
            executable: tool.path,
            workingDirectory: workingDirectory,
            scheme: "MyApp",
            derivedDataPath: workingDirectory
        )

        let output = try xcodebuild.testWithoutBuilding(
            xctestrun: URL(fileURLWithPath: "/tmp/App.xctestrun"),
            destination: "platform=iOS Simulator,id=UDID"
        )

        #expect(output.log.contains("test-without-building"))
        #expect(output.log.contains("-xctestrun /tmp/App.xctestrun"))
        #expect(output.log.contains("-destination platform=iOS Simulator,id=UDID"))
    }

    @Test("narrows the run when asked to")
    func xcodebuildOnlyTesting() throws {
        let tool = try FakeTool()
        let xcodebuild = Xcodebuild(
            executable: tool.path,
            workingDirectory: workingDirectory,
            scheme: "MyApp",
            derivedDataPath: workingDirectory
        )

        let output = try xcodebuild.testWithoutBuilding(
            xctestrun: URL(fileURLWithPath: "/tmp/App.xctestrun"),
            destination: "id=UDID",
            onlyTesting: ["AppTests/BookmarkTests"]
        )

        #expect(output.log.contains("-only-testing:AppTests/BookmarkTests"))
    }

    /// The build writes an `.xctestrun`, and there is nothing to run without it.
    @Test("reports when the build produced no xctestrun")
    func xcodebuildMissingXctestrun() throws {
        let tool = try FakeTool()
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("litmus-dd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: empty.appendingPathComponent("Build/Products"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: empty) }

        let xcodebuild = Xcodebuild(
            executable: tool.path,
            workingDirectory: workingDirectory,
            scheme: "MyApp",
            derivedDataPath: empty
        )

        #expect(throws: Xcodebuild.Failure.self) {
            try xcodebuild.build(lane: "id=UDID")
        }
    }

    @Test("finds the xctestrun the build left behind")
    func xcodebuildFindsXctestrun() throws {
        let tool = try FakeTool()
        let derived = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("litmus-dd-\(UUID().uuidString)")
        let products = derived.appendingPathComponent("Build/Products")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: derived) }

        for name in ["App_iphonesimulator.xctestrun", "notes.txt"] {
            try "".write(
                to: products.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }

        let xcodebuild = Xcodebuild(
            executable: tool.path,
            workingDirectory: workingDirectory,
            scheme: "MyApp",
            derivedDataPath: derived
        )

        let built = try xcodebuild.build(lane: "id=UDID")

        #expect(built.artifact?.lastPathComponent == "App_iphonesimulator.xctestrun")
    }

    @Test("refuses to run without a build")
    func xcodebuildNeedsBuild() throws {
        let tool = try FakeTool()
        let xcodebuild = Xcodebuild(
            executable: tool.path,
            workingDirectory: workingDirectory,
            scheme: "MyApp",
            derivedDataPath: workingDirectory
        )

        #expect(throws: Xcodebuild.Failure.self) {
            try xcodebuild.test(BuiltTests(), lane: "id=UDID", switchOn: nil)
        }
    }
}

/// What a failed coverage run says.
///
/// Mutation testing needs a green baseline, so a red suite stops the run at
/// the coverage step. Dumping the xcodebuild log there buries the one thing
/// worth reading: which tests are failing.
@Suite("Coverage failures")
struct CoverageFailureTests {
    @Test("names the failing tests")
    func namesFailures() {
        let message = Xcodebuild.suiteFailure(in: """
        2026-09-22 17:55:57.225 xcodebuild[19568:1701291] [MT] 303.243 sec -- end

        Failing tests:
        \tExceedWordbookLimitPopOverViewControllerTests.hostingControllerIsNotNilAfterLoad()
        \tOtherTests.somethingElse()

        ** TEST FAILED **
        """)

        #expect(message.contains("the test suite is failing"))
        #expect(message.contains("ExceedWordbookLimitPopOverViewControllerTests"))
        #expect(message.contains("OtherTests.somethingElse()"))
        #expect(!message.contains("IDETestOperationsObserverDebug"))
    }

    @Test("falls back to the error lines when no test is named")
    func noNamedFailures() {
        let message = Xcodebuild.suiteFailure(in: """
        Noise about something.
        error: Scheme MyApp is not configured for testing
        ** TEST FAILED **
        """)

        #expect(message.contains("did not finish"))
        #expect(message.contains("not configured for testing"))
        #expect(!message.contains("Noise about"))
    }
}
