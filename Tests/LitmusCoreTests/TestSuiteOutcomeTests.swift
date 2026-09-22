import Testing

@testable import LitmusCore

/// A mutant is killed when the suite *fails*, so these mappings read backwards
/// at first glance. Getting one of them wrong silently moves the score.
@Suite("Test suite outcome")
struct TestSuiteOutcomeTests {
    @Test("a failing swift-testing run killed the mutant")
    func swiftTestingFailure() {
        let log = """
        ◇ Test run started.
        ✘ Test "offline streaming is not offline" failed after 0.7 seconds.
        ✘ Test run with 75 tests in 9 suites failed after 4.0 seconds with 1 issue.
        ** TEST FAILED **
        """

        #expect(TestSuiteOutcome(log: log).verdict == .killed)
    }

    @Test("a passing swift-testing run let the mutant survive")
    func swiftTestingSuccess() {
        let log = """
        ◇ Test run started.
        ✔ Test run with 75 tests in 9 suites passed after 3.3 seconds.
        ** TEST SUCCEEDED **
        """

        #expect(TestSuiteOutcome(log: log).verdict == .survived)
    }

    @Test("an XCTest run with failures killed the mutant")
    func xctestFailure() {
        let log = "Executed 40 tests, with 2 failures (0 unexpected) in 1.2 seconds"

        #expect(TestSuiteOutcome(log: log).verdict == .killed)
    }

    @Test("an XCTest run with no failures let the mutant survive")
    func xctestSuccess() {
        let log = "Executed 40 tests, with 0 failures (0 unexpected) in 1.2 seconds"

        #expect(TestSuiteOutcome(log: log).verdict == .survived)
    }

    /// The compiler rejecting a mutant is not the test suite catching it.
    /// Counting this as killed is what lets a broken tool report a flattering score.
    @Test("a mutant that failed to build is an error, not a kill")
    func buildFailureIsNotAKill() {
        let log = """
        error: cannot convert value of type 'Bool' to expected argument type 'Int'
        Testing cancelled because the build failed.
        ** TEST FAILED **
        """

        #expect(TestSuiteOutcome(log: log).verdict == .error)
    }

    @Test("a log with nothing recognisable is an error")
    func emptyLog() {
        #expect(TestSuiteOutcome(log: "").verdict == .error)
    }
}
