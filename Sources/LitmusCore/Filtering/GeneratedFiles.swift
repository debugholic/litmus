import Foundation

/// Code a tool writes, which nobody fixes by hand: a mutant that survives in
/// it says nothing anyone can act on, and one in a value Swift computes once
/// costs a launch of its own to say it.
///
/// Told apart without knowing the tool. Git says which files it was told to
/// leave alone, by `.gitignore`, or to treat as generated, by
/// `linguist-generated` in `.gitattributes`. A generated file that is
/// committed anyway mostly says so in its first comment, as SwiftGen,
/// Sourcery, protobuf and Apollo write; Tuist's bundle accessor does not, and
/// is caught by being ignored.
public enum GeneratedFiles {
    /// Which of `paths`, relative to `project`, are generated.
    ///
    /// Asked of the original: the working copy has no `.git`. Outside a
    /// repository only the comment is read.
    public static func among(_ paths: [String], in project: URL) -> Set<String> {
        var generated: Set<String> = []

        // In batches on the command line rather than through stdin: git
        // outside a repository exits before reading, and writing to it then
        // took the whole process down with SIGPIPE.
        for batch in stride(from: 0, to: paths.count, by: 500).map({ paths[$0..<min($0 + 500, paths.count)] }) {
            // A tracked file is never reported ignored, whatever .gitignore
            // says: someone keeps it. One path a line, as -z needs --stdin; a
            // name git would quote only goes unnoticed.
            let ignored = String(decoding: git(["check-ignore", "--"] + batch, in: project), as: UTF8.self)
            generated.formUnion(ignored.split(separator: "\n").map(String.init))

            // Path, attribute, value, three to a file.
            let attributes = fields(git(["check-attr", "-z", "linguist-generated", "--"] + batch, in: project))
            for index in stride(from: 0, to: attributes.count - 2, by: 3)
            where ["true", "set"].contains(attributes[index + 2]) {
                generated.insert(attributes[index])
            }
        }

        for path in paths where !generated.contains(path) {
            guard let source = try? String(contentsOf: project.appendingPathComponent(path), encoding: .utf8) else {
                continue
            }
            if saysGenerated(source) { generated.insert(path) }
        }

        return generated
    }

    /// Whether the comment a file opens with says a tool wrote it.
    ///
    /// Only that comment: further down, "generated" is as likely to be about
    /// what the code makes.
    static func saysGenerated(_ source: String) -> Bool {
        for line in source.split(separator: "\n", omittingEmptySubsequences: false).prefix(30) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            guard text.hasPrefix("//") || text.hasPrefix("/*") || text.hasPrefix("*") else { return false }
            if text.range(of: marker, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        }
        return false
    }

    static let marker = #"@generated|generated (using|by)|do not (edit|modify)"#

    private static func fields(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
    }

    /// What git printed, or nothing when it could not run here at all.
    private static func git(_ arguments: [String], in directory: URL) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.quotePath=false"] + arguments
        process.currentDirectoryURL = directory

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return Data() }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // check-ignore exits 1 when nothing is ignored; 128 is no repository.
        return process.terminationStatus == 128 ? Data() : data
    }
}
