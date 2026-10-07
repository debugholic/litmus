import Foundation
import LitmusCore

/// The part of the tree a run keeps, when it does not take all of it.
enum Narrowing {
    /// What changed since a ref, as a review sees it.
    case since(String)
    /// What is not committed yet, new files included.
    case uncommitted

    /// From `--since` and `--changed`; nil for the whole tree. Passing both is
    /// refused before this is asked.
    init?(since: String?, changed: Bool) {
        if let since {
            self = .since(since)
        } else if changed {
            self = .uncommitted
        } else {
            return nil
        }
    }

    static let conflict = "pass --since or --changed, not both"

    func lines(in project: URL) throws -> ChangedLines {
        switch self {
        case let .since(ref): try GitDiff.changed(since: ref, in: project)
        case .uncommitted: try GitDiff.uncommitted(in: project)
        }
    }

    /// What follows "changed": `since origin/develop`, `since the last commit`.
    var since: String {
        switch self {
        case let .since(ref): "since \(ref)"
        case .uncommitted: "since the last commit"
        }
    }

    /// What to say when it kept nothing. `--changed` on a clean checkout keeps
    /// nothing, and in a pipeline that passes having run nothing, so it also
    /// names the option a branch's changes want.
    func leaveOut(to whole: String) -> [String] {
        switch self {
        case .since:
            ["Leave out --since to \(whole)."]
        case .uncommitted:
            ["Leave out --changed to \(whole).", "For what a branch changed, pass --since <its base>."]
        }
    }
}
