import Foundation

/// One change Litmus can switch on at run time.
public struct Mutant: Sendable, Equatable {
    /// Path of the file the mutant lives in, inside the mutated project.
    public let filePath: String
    public let line: Int
    public let column: Int
    public let utf8Offset: Int
    public let `operator`: String

    /// Human readable summary, e.g. "changed && to ||".
    public let description: String

    /// Sits where Swift evaluates it once per process: a global or a static
    /// property's initial value. Whichever mutant is on the first time it is
    /// read is the one it keeps, so it needs a process of its own.
    public let evaluatedOnce: Bool

    public init(
        filePath: String,
        line: Int,
        column: Int,
        utf8Offset: Int,
        operator: String,
        description: String,
        evaluatedOnce: Bool = false
    ) {
        self.filePath = filePath
        self.line = line
        self.column = column
        self.utf8Offset = utf8Offset
        self.operator = `operator`
        self.description = description
        self.evaluatedOnce = evaluatedOnce
    }

    public var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }

    /// The environment variable that turns this mutant on.
    ///
    /// The injected source reads it with `ProcessInfo.processInfo.environment`,
    /// so the name here and the name written into the source have to agree
    /// exactly. Both are built from the same parts, in the same order.
    public var switchName: String {
        let stem = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        return [stem, `operator`, "\(line)", "\(column)", "\(utf8Offset)"].joined(separator: "_")
    }
}

public enum Verdict: String, Sendable {
    /// The suite failed, so something noticed the change.
    case killed
    /// The suite passed with the change applied. This is a hole.
    case survived
    /// The suite was stopped for running too long with the mutant on — most
    /// often a loop that no longer ends. Counted as caught: the suite did not
    /// pass. Shown apart, because a slow test can land here too.
    case timedOut = "timeout"
    /// The compiler rejected the mutant, so it was taken out before the run.
    ///
    /// Kept separate on purpose. A compiler rejecting a change is not evidence
    /// that the tests would have caught it, so it must not count as killed.
    case unviable
    /// The suite could not run for a reason Litmus could not pin down.
    case error
}

public struct MutantResult: Sendable {
    public let mutant: Mutant
    public let verdict: Verdict
    public let duration: TimeInterval
}
