import Foundation

/// Tests that are built and ready to run again without being rebuilt.
public struct BuiltTests: Sendable {
    /// Whatever the harness needs in order to run without building: an
    /// `.xctestrun` for xcodebuild, nothing for a Swift package, whose products
    /// stay where `swift build` left them.
    public let artifact: URL?

    public init(artifact: URL? = nil) {
        self.artifact = artifact
    }
}

/// What one test run produced.
///
/// The exit status is part of the evidence, not a detail. A mutant that makes
/// the code trap kills the process before the testing library prints its
/// summary, and a log with no summary is not a log of a passing run.
public struct TestOutput: Sendable {
    public let log: String
    public let status: Int32
    /// Stopped for running past its time. A mutant that turns a loop
    /// infinite never finishes, and would otherwise hold the run forever.
    public let timedOut: Bool

    public init(log: String, status: Int32, timedOut: Bool = false) {
        self.log = log
        self.status = status
        self.timedOut = timedOut
    }
}

/// A build that did not compile, with the whole log.
///
/// The log is kept rather than just the lines shown, because the errors in it
/// say which mutants to take out before building again.
public struct BuildFailure: Error, CustomStringConvertible {
    public let log: String

    public init(log: String) { self.log = log }

    public var description: String {
        """
        the build failed:

        \(Xcodebuild.errorLines(in: log))
        """
    }
}

/// A coverage run whose suite did not pass or did not build, with the log.
public struct SuiteFailure: Error, CustomStringConvertible {
    public let log: String

    public init(log: String) { self.log = log }

    public var description: String { Xcodebuild.suiteFailure(in: log) }
}

/// A way of building and running a project's tests.
///
/// The split matters more than it looks. Every mutant is compiled into the
/// binary at once, so Litmus builds a single time and then runs that same build
/// once per mutant. A harness that rebuilt on each run would throw away the
/// whole point.
public protocol TestHarness: Sendable {
    /// A short description of the lanes this harness runs in, for the CLI.
    var laneNoun: String { get }

    /// Builds the tests once, with every mutant compiled in but switched off.
    func build(lane: String) throws -> BuiltTests

    /// Runs the built tests, with at most one mutant switched on, stopping
    /// them after `timeout` seconds when one is given. `onlyTesting` names
    /// the one test target to run, where the harness can narrow to one.
    func test(
        _ built: BuiltTests,
        lane: String,
        switchOn mutantSwitch: String?,
        timeout: TimeInterval?,
        onlyTesting target: String?
    ) throws -> TestOutput

    /// Runs the suite once with coverage on, and reports what it reached.
    ///
    /// Measured on the project as written, before any mutant exists: the
    /// positions in a plan are positions in the original file, and injection
    /// moves every line below it.
    func coverage(lane: String) throws -> Coverage

    /// The source files the built tests are aimed at, or nil when the harness
    /// cannot tell. Mutants outside it are not run.
    func testedScope(_ built: BuiltTests) -> TestedScope?

    /// The scope of the build the coverage run just made, so mutants outside
    /// it are never written — and never compiled into the working copy.
    func coverageScope() -> TestedScope?
}

extension TestHarness {
    public func test(_ built: BuiltTests, lane: String, switchOn mutantSwitch: String?) throws -> TestOutput {
        try test(built, lane: lane, switchOn: mutantSwitch, timeout: nil, onlyTesting: nil)
    }

    public func testedScope(_ built: BuiltTests) -> TestedScope? { nil }
    public func coverageScope() -> TestedScope? { nil }
}

/// A harness that can run many mutants in one test process.
public protocol BatchingHarness: TestHarness {
    /// Adds the driver to these test targets and rebuilds the tests once.
    func prepareBatch(_ built: BuiltTests, targets: [TestedScope.TestTarget], lane: String) throws -> Batch.Plan

    /// Runs the batch in one test target to the end, relaunching past any
    /// mutant that takes the process down, and returns a verdict for every id.
    func runBatch(
        _ plan: Batch.Plan,
        target: String,
        lane: String,
        ids: [String],
        timeouts: Batch.Timeouts,
        onEvent: (Batch.Event) -> Void
    ) throws -> [String: Verdict]
}
