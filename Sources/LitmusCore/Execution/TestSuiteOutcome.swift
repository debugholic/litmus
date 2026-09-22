import Foundation

/// Reads a test run and decides what happened to the mutant.
///
/// A mutant is killed when the suite *fails* — that is the whole point, so the
/// mapping reads backwards at first glance.
struct TestSuiteOutcome {
    let verdict: Verdict

    init(_ output: TestOutput) {
        self.init(log: output.log, status: output.status)
    }

    init(log: String, status: Int32) {
        // The compiler rejecting a mutant is not the suite catching it, and it
        // is checked first because everything below reads a bad exit as a kill.
        // Counting this as killed is what lets a broken tool report a
        // flattering score.
        if Self.failedToBuild(log) {
            verdict = .error
            return
        }

        // A trap in the mutated code takes the process down before the testing
        // library prints anything, so the crash is read next. It is a kill: the
        // suite ran into the change rather than past it.
        if Self.crashed(log) {
            verdict = .killed
            return
        }

        if let failed = Self.summarySaysFailed(in: log) {
            verdict = failed ? .killed : .survived
            return
        }

        // No summary at all. The exit status is the only evidence left, and a
        // run that ended badly is not a run that passed.
        //
        // This used to fall through to `.error` on a non-zero exit, which read
        // a crashed run as "the mutant could not be built" and left it out of
        // the score entirely.
        if log.contains("** TEST FAILED **") || status != 0 {
            verdict = .killed
        } else if log.contains("** TEST SUCCEEDED **") {
            verdict = .survived
        } else {
            verdict = .error
        }
    }

    /// Whether a summary line says the run failed, or `nil` when there is none.
    private static func summarySaysFailed(in log: String) -> Bool? {
        // swift-testing: Test run with 73 tests in 9 suites passed after ...
        if let range = log.range(
            of: #"Test run with \d+ tests? in \d+ suites? (?:passed|failed)"#,
            options: .regularExpression
        ) {
            return log[range].contains("failed")
        }

        // XCTest: Executed 73 tests, with 1 failure ...
        //
        // SwiftPM prints this for the XCTest bundle even when every test is a
        // swift-testing test and the bundle is empty. "Executed 0 tests, with
        // 0 failures" was being read as a pass, which turned every crashing
        // mutant into a survivor — a hole reported as covered.
        for match in log.matches(
            of: #"Executed (\d+) tests?, with (\d+) failures?"#
        ) where match.tests > 0 {
            return match.failures > 0
        }

        return nil
    }

    private static func failedToBuild(_ log: String) -> Bool {
        for marker in [
            "Testing cancelled because the build failed",
            "** BUILD FAILED **",
            "error: build failed",
        ] where log.contains(marker) {
            return true
        }

        return false
    }

    private static func crashed(_ log: String) -> Bool {
        for marker in [
            "Fatal error:",
            "Swift runtime failure",
            "Crashed:",
            "signal SIGABRT",
            "signal SIGSEGV",
        ] where log.contains(marker) {
            return true
        }

        return false
    }
}

private extension String {
    /// Every `Executed N tests, with M failures` line, in order.
    func matches(of pattern: String) -> [(tests: Int, failures: Int)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        return regex
            .matches(in: self, range: NSRange(startIndex..., in: self))
            .compactMap { match in
                guard
                    let tests = group(match, 1).flatMap(Int.init),
                    let failures = group(match, 2).flatMap(Int.init)
                else { return nil }

                return (tests, failures)
            }
    }

    private func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
        guard let range = Range(match.range(at: index), in: self) else { return nil }
        return String(self[range])
    }
}
