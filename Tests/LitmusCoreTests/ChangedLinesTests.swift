import Foundation
import Testing

@testable import LitmusCore

/// Reading a diff into the lines it touched.
///
/// The whole tree is the right scope for a nightly job. For a review it is
/// thousands of mutants on code nobody changed, whose verdicts were settled on
/// the last run.
@Suite("Changed lines")
struct ChangedLinesTests {
    private let diff = """
    diff --git a/Sources/App/Edited.swift b/Sources/App/Edited.swift
    index 1111111..2222222 100644
    --- a/Sources/App/Edited.swift
    +++ b/Sources/App/Edited.swift
    @@ -10,2 +10,3 @@ func f() {
    -    let old = a && b
    +    let new = a || b
    +    log(new)
    @@ -40 +41 @@ func g() {
    -    return x == y
    +    return x != y
    diff --git a/Sources/App/Added.swift b/Sources/App/Added.swift
    new file mode 100644
    --- /dev/null
    +++ b/Sources/App/Added.swift
    @@ -0,0 +1,3 @@
    +func h() {}
    """

    @Test("reads the lines a hunk added")
    func parsesHunks() {
        let changed = GitDiff.parse(diff)

        #expect(changed.includes(path: "Sources/App/Edited.swift", line: 10))
        #expect(changed.includes(path: "Sources/App/Edited.swift", line: 12))
        #expect(!changed.includes(path: "Sources/App/Edited.swift", line: 13))
    }

    /// A hunk with no count is a single line, not zero.
    @Test("reads a one-line hunk")
    func parsesSingleLineHunk() {
        let changed = GitDiff.parse(diff)

        #expect(changed.includes(path: "Sources/App/Edited.swift", line: 41))
        #expect(!changed.includes(path: "Sources/App/Edited.swift", line: 42))
    }

    @Test("reads a file the change added outright")
    func parsesNewFile() {
        let changed = GitDiff.parse(diff)

        #expect(changed.includes(path: "Sources/App/Added.swift", line: 1))
        #expect(changed.includes(path: "Sources/App/Added.swift", line: 3))
        #expect(changed.fileCount == 2)
    }

    /// Unlike coverage, silence here is an answer: nothing in that file moved.
    @Test("excludes a file the diff never mentions")
    func excludesUntouchedFile() {
        #expect(!GitDiff.parse(diff).includes(path: "Sources/App/Other.swift", line: 1))
    }

    /// A deletion leaves nothing at that position to mutate.
    @Test("ignores a hunk that only removed lines")
    func ignoresDeletion() {
        let changed = GitDiff.parse("""
        --- a/Sources/App/Trimmed.swift
        +++ b/Sources/App/Trimmed.swift
        @@ -10,3 +9,0 @@ func f() {
        -    let gone = a && b
        """)

        #expect(changed.isEmpty)
    }

    @Test("ignores a file the change deleted")
    func ignoresDeletedFile() {
        let changed = GitDiff.parse("""
        --- a/Sources/App/Gone.swift
        +++ /dev/null
        @@ -1,3 +0,0 @@
        -func gone() {}
        """)

        #expect(changed.isEmpty)
    }

    /// The diff names paths from the repository root and Litmus works in a
    /// copy, so without this the lookup misses every file and nothing runs.
    @Test("matches the copy's paths to the diff's")
    func rebases() {
        let changed = GitDiff.parse(diff)
            .rebased(onto: ["/tmp/copy-99/Sources/App/Edited.swift"])

        #expect(changed.includes(path: "/tmp/copy-99/Sources/App/Edited.swift", line: 10))
        #expect(!changed.includes(path: "/tmp/copy-99/Sources/App/Edited.swift", line: 13))
    }

    /// Git puts a path it will not write plainly in quotes with octal
    /// escapes, and ends one with a space in it with a tab. Read as written,
    /// a Korean file name matched nothing and its changes were never mutated.
    @Test("reads a quoted, escaped or tab-ended path from the diff")
    func quotedPaths() {
        #expect(GitDiff.path("\"b/\\355\\225\\234\\352\\270\\200.swift\"") == "b/한글.swift")
        #expect(GitDiff.path("b/한글 파일.swift\t") == "b/한글 파일.swift")
        #expect(GitDiff.path("\"b/say \\\"hi\\\".swift\"") == "b/say \"hi\".swift")
        #expect(GitDiff.path("b/Plain.swift") == "b/Plain.swift")
    }

    @Test("finds the changed lines of a file with a Korean name and a space")
    func koreanFileName() throws {
        let repo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("litmus-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "user.name=t", "-c", "user.email=t@t"] + arguments
            process.currentDirectoryURL = repo
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }

        try git("init", "-q")
        try git("commit", "-q", "--allow-empty", "-m", "base")
        try git("branch", "base")
        try "let a = 1\nlet b = a > 0\n".write(to: repo.appendingPathComponent("재생 설정.swift"), atomically: true, encoding: .utf8)
        try git("add", "-A")
        try git("commit", "-q", "-m", "change")

        let changed = try GitDiff.changed(since: "base", in: repo)

        #expect(changed.includes(path: "재생 설정.swift", line: 2))
    }

    /// Matching by shared ending needs two components to agree, and a file
    /// at the project's root has one.
    @Test("matches a file at the project's root by its path under the copy")
    func rootFile() {
        let changed = ChangedLines(lines: ["Main.swift": [3], "Sources/App/Main.swift": [9]])
        let copy = URL(fileURLWithPath: "/tmp/copy")

        let rebased = changed.rebased(onto: ["/tmp/copy/Main.swift", "/tmp/copy/Sources/App/Main.swift"], root: copy)

        #expect(rebased.includes(path: "/tmp/copy/Main.swift", line: 3))
        #expect(rebased.includes(path: "/tmp/copy/Sources/App/Main.swift", line: 9))
        #expect(!rebased.includes(path: "/tmp/copy/Main.swift", line: 9))
    }

    @Test("keys a project in a folder of its repository from its own root")
    func projectInFolder() {
        let changed = ChangedLines(lines: ["Packages/Player/Sources/A.swift": [1], "App/B.swift": [2]])
            .relative(to: "Packages/Player/")

        #expect(changed.includes(path: "Sources/A.swift", line: 1))
        #expect(changed.fileCount == 1)
    }
}
