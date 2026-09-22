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
}
