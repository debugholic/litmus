import Foundation

/// Reads an xcodebuild log and decides what happened to the mutant.
///
/// A mutant is killed when the suite *fails* — that is the whole point, so the
/// mapping reads backwards at first glance.
struct TestSuiteOutcome {
    let verdict: Verdict

    init(_ output: TestOutput) {
        self.init(log: output.log)
    }

    init(log: String) {
        // swift-testing and XCTest print different summary lines, and a run can
        // end without either when the build or the runner fell over.
        if let line = Self.summaryLine(in: log) {
            verdict = line.contains("failed") ? .killed : .survived
        } else if log.contains("** TEST FAILED **") {
            // No summary but an explicit failure: the suite never got to run,
            // usually a compile error in the mutated source.
            verdict = .error
        } else if log.contains("** TEST SUCCEEDED **") {
            verdict = .survived
        } else {
            verdict = .error
        }
    }

    private static func summaryLine(in log: String) -> String? {
        for pattern in [
            // swift-testing: Test run with 73 tests in 9 suites passed after ...
            #"Test run with \d+ tests? in \d+ suites? (?:passed|failed)"#,
            // XCTest: Executed 73 tests, with 1 failure ...
            #"Executed \d+ tests?, with \d+ failures?"#,
        ] {
            guard let range = log.range(of: pattern, options: .regularExpression) else { continue }
            let line = String(log[range])

            // The XCTest line says "with 0 failures" when everything passed, so
            // normalise it to the same passed/failed vocabulary.
            if line.hasPrefix("Executed") {
                return line.contains("with 0 failures") ? "passed" : "failed"
            }

            return line
        }

        return nil
    }
}
