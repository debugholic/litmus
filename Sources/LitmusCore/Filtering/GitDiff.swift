import Foundation

/// Reads which lines a branch changed, straight from `git diff`.
public enum GitDiff {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static func changed(since ref: String, in project: URL) throws -> ChangedLines {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // --merge-base answers "what does this branch add", which is what a
        // review looks at, and it reaches the working tree so uncommitted work
        // counts too.
        process.arguments = [
            "diff", "--unified=0", "--merge-base", ref, "--", "*.swift",
        ]
        process.currentDirectoryURL = project

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw Failure(description: "git diff against '\(ref)' failed")
        }

        return parse(String(data: data, encoding: .utf8) ?? "")
    }

    /// `+++ b/<path>` names a file; `@@ -a,b +c,d @@` gives the lines it now
    /// has. A hunk with no count is one line.
    static func parse(_ diff: String) -> ChangedLines {
        var lines: [String: Set<Int>] = [:]
        var file: String?

        for line in diff.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("+++ ") {
                let path = String(line.dropFirst(4))
                // /dev/null is a deletion: there is nothing left to mutate.
                file = path == "/dev/null" ? nil : String(path.dropFirst(2))
                continue
            }

            guard
                let file,
                line.hasPrefix("@@"),
                let range = hunk(line)
            else { continue }

            lines[file, default: []].formUnion(range)
        }

        return ChangedLines(lines: lines)
    }

    private static func hunk(_ line: Substring) -> Range<Int>? {
        guard
            let plus = line.dropFirst(2).firstIndex(of: "+"),
            let end = line[plus...].firstIndex(of: " ")
        else { return nil }

        let numbers = line[line.index(after: plus)..<end].split(separator: ",")

        guard let start = Int(numbers[0]) else { return nil }
        let count = numbers.count > 1 ? Int(numbers[1]) ?? 0 : 1

        // A hunk that only removes lines has a count of zero, and there is
        // nothing at that position to mutate.
        guard count > 0 else { return nil }

        return start..<(start + count)
    }
}
