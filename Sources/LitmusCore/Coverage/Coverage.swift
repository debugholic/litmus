import Foundation

/// Which parts of which files the test suite actually ran.
///
/// A mutant on a line no test reaches cannot be killed. It will survive, and
/// the only thing running it buys is the minute it took. Litmus drops those
/// before they are written, so they cost neither build size nor a run.
public struct Coverage: Sendable {
    /// What a report said about one file.
    public enum File: Sendable, Equatable {
        /// Nothing in it ran.
        case unreached
        /// Some of it ran, line by line.
        case lines(covered: Set<Int>, accounted: Set<Int>)
        /// Some of it ran, but the report did not say which lines.
        case reached
    }

    // The cases are deliberately not called `none` and `some`. Those are
    // `Optional`'s own cases, and `switch` over an optional file matches those
    // first — `case .some` swallowed every entry, so the filter silently let
    // everything through and skipped nothing at all.

    let files: [String: File]

    public init(files: [String: File]) {
        self.files = files
    }

    public var isEmpty: Bool { files.isEmpty }

    /// How many files the report had nothing running in.
    public var deadFiles: Int { files.count { $0.value == .unreached } }

    /// Whether a mutation here is worth running.
    ///
    /// Anything the report does not speak to is kept. Dropping a mutant that
    /// could have been killed hides a hole, which is the failure this tool
    /// exists to prevent; keeping one that cannot costs a single run.
    public func reaches(path: String, line: Int) -> Bool {
        switch files[path] {
        case nil, .reached:
            return true
        case .unreached:
            return false
        case let .lines(covered, accounted):
            guard accounted.contains(line) else { return true }
            return covered.contains(line)
        }
    }
}

extension Coverage {
    /// Re-keys the report onto the paths a working copy uses.
    ///
    /// Coverage is measured on the original project and applied to a copy, so
    /// the two paths agree only from the project root down. Matching on the
    /// longest shared suffix keeps that from silently missing every file and
    /// filtering nothing.
    public func rebased(onto paths: [String]) -> Coverage {
        var rebased: [String: File] = [:]

        for path in paths {
            guard let source = bestMatch(for: path) else { continue }
            rebased[path] = files[source]
        }

        return Coverage(files: rebased)
    }

    private func bestMatch(for path: String) -> String? {
        let wanted = path.split(separator: "/").reversed().map(String.init)
        var best: (source: String, score: Int)?

        for source in files.keys {
            let candidate = source.split(separator: "/").reversed().map(String.init)

            var score = 0
            while score < wanted.count, score < candidate.count, wanted[score] == candidate[score] {
                score += 1
            }

            // A shared file name alone is not a match: two modules can both
            // hold a Configuration.swift.
            guard score > 1, score > (best?.score ?? 1) else { continue }
            best = (source, score)
        }

        return best?.source
    }
}
