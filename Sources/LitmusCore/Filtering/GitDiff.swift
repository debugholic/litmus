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
        // quotePath off: git otherwise writes a Korean path as octal escapes
        // in quotes, and not one of that file's lines matched.
        process.arguments = [
            "-c", "core.quotePath=false",
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

        return parse(String(data: data, encoding: .utf8) ?? "").relative(to: prefix(of: project))
    }

    /// What is not committed yet: the working tree against `HEAD`, and every
    /// line of a Swift file git does not track yet, which `git diff` never
    /// shows. A file written a minute ago is the one most worth checking.
    public static func uncommitted(in project: URL) throws -> ChangedLines {
        var lines = try changed(since: "HEAD", in: project).lines

        // Run in the project, ls-files lists only what is under it, by paths
        // from there: the keys the diff has once made relative.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["ls-files", "-z", "--others", "--exclude-standard", "--", "*.swift"]
        process.currentDirectoryURL = project

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw Failure(description: "git ls-files failed")
        }

        for path in String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init) {
            guard let text = try? String(contentsOf: project.appendingPathComponent(path), encoding: .utf8) else { continue }
            guard !text.isEmpty else { continue }
            let count = text.split(separator: "\n", omittingEmptySubsequences: false).count
                - (text.hasSuffix("\n") ? 1 : 0)
            lines[path] = Set(1...count)
        }

        return ChangedLines(lines: lines)
    }

    /// Where the project sits in its repository, `Packages/Player/` or empty
    /// at the root. The diff names paths from the repository's root; the
    /// copy is of the project.
    static func prefix(of project: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.quotePath=false", "rev-parse", "--show-prefix"]
        process.currentDirectoryURL = project
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `+++ b/<path>` names a file; `@@ -a,b +c,d @@` gives the lines it now
    /// has. A hunk with no count is one line.
    static func parse(_ diff: String) -> ChangedLines {
        var lines: [String: Set<Int>] = [:]
        var file: String?

        for line in diff.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("+++ ") {
                let path = Self.path(line.dropFirst(4))
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

    /// The path a `+++` line names. Git ends one with a space in it with a
    /// tab, and puts one it will not write plainly in quotes with C escapes —
    /// octal bytes for anything outside ASCII when `core.quotePath` is on.
    static func path(_ text: Substring) -> String {
        var text = text
        if text.hasSuffix("\t") { text = text.dropLast() }
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return String(text) }

        var bytes: [UInt8] = []
        var characters = Array(text.dropFirst().dropLast().utf8)[...]
        while let byte = characters.popFirst() {
            guard byte == UInt8(ascii: "\\"), let next = characters.popFirst() else {
                bytes.append(byte)
                continue
            }
            switch next {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(next - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let digit = characters.first, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) else { break }
                    value = value * 8 + Int(digit - UInt8(ascii: "0"))
                    characters.removeFirst()
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default: bytes.append(next)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
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
