import Foundation
import os

/// What xcodebuild is doing, read from its output as it streams.
///
/// A coverage run over seventy test targets is twenty minutes of one command.
/// The time alone does not say whether it is still compiling or halfway
/// through the tests, so the log is read line by line for the target being
/// built, the suite being tested, and how many tests have finished.
///
/// No count of targets: xcodebuild names every target of the build up front,
/// in the steps that plan it, so a count reached its total in the first
/// minute and sat there for the next thirty.
public final class XcodebuildActivity: Sendable {
    private struct State {
        var building: String?
        var testing: String?
        var testsRun = 0
        var testsFailed = 0

        mutating func read(_ line: String) -> String? {
            // Once tests are running, a stray build line is not a return to
            // building.
            if testing == nil, testsRun == 0,
               let target = XcodebuildActivity.capture(#"\(in target '([^']+)' from project '[^']+'\)"#, in: line) {
                guard target != building else { return nil }
                building = target
                return summary
            }

            // Swift Testing, as xcodebuild prints it: `◇ Suite SettingTests started.`
            if let suite = XcodebuildActivity.capture(#"^◇ Suite (.+) started\."#, in: line) {
                testing = suite
                return summary
            }

            // XCTest: `Test Suite 'SettingTests' started at …`, but not the
            // wrapper suites every run opens with.
            if let suite = XcodebuildActivity.capture(#"^Test [Ss]uite '([^']+)' started"#, in: line),
               suite != "All tests", suite != "Selected tests", !suite.hasSuffix(".xctest") {
                testing = suite
                return summary
            }

            // `✔ Test "name" passed after …` and `✘ Test "name" failed after …`,
            // not the `Test run with 5 tests …` summary.
            if line.hasPrefix("✔ Test ") || line.hasPrefix("✘ Test "), !line.contains("Test run with") {
                testsRun += 1
                if line.hasPrefix("✘") { testsFailed += 1 }
                return summary
            }

            if let verdict = XcodebuildActivity.capture(#"^Test [Cc]ase '.*' (passed|failed)"#, in: line) {
                testsRun += 1
                if verdict == "failed" { testsFailed += 1 }
                return summary
            }

            return nil
        }

        var summary: String? {
            if testsRun > 0 || testing != nil {
                let bundle = testing.map { "testing \($0) · " } ?? "testing · "
                return bundle + "\(testsRun) test(s) run, \(testsFailed) failed"
            }
            if let building {
                return "building \(building)"
            }
            return nil
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Reads one line, and returns the new summary when it changed.
    @discardableResult
    public func read(_ line: String) -> String? {
        state.withLock { $0.read(line) }
    }

    public var summary: String? {
        state.withLock { $0.summary }
    }

    fileprivate static func capture(_ pattern: String, in line: String) -> String? {
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: line)
        else { return nil }
        return String(line[range])
    }
}
