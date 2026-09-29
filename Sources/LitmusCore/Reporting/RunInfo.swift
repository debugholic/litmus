import Foundation

/// What was run, when and on what: so a report read a week later, or next to
/// another, says which code and which litmus it measured.
public struct RunInfo: Sendable {
    public let date: Date
    public let commit: String?
    public let branch: String?
    public let version: String
    public let operators: [String]
    /// `xcode, scheme litmus-all-tests, 1 simulator`, or `swift test, 1 process`.
    public let harness: String

    public init(
        date: Date,
        commit: String?,
        branch: String?,
        version: String,
        operators: [String],
        harness: String
    ) {
        self.date = date
        self.commit = commit
        self.branch = branch
        self.version = version
        self.operators = operators
        self.harness = harness
    }

    /// The short commit and the branch the project is on, when it is in git.
    public static func git(in project: URL) -> (commit: String?, branch: String?) {
        func ask(_ arguments: [String]) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = project
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return process.terminationStatus == 0 && !text.isEmpty ? text : nil
        }
        return (ask(["rev-parse", "--short", "HEAD"]), ask(["rev-parse", "--abbrev-ref", "HEAD"]))
    }

    /// `2026-09-29 17:05 · a1b2c3d on main · litmus 0.4.0 · xcode, 1 simulator`
    public var line: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var parts = [formatter.string(from: date)]
        if let commit { parts.append(branch.map { "\(commit) on \($0)" } ?? commit) }
        parts.append("litmus \(version)")
        parts.append(harness)
        return parts.joined(separator: " · ")
    }
}
