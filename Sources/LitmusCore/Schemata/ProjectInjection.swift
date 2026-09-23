import Foundation

/// Copies a project and writes every mutant into the copy.
///
/// The original is never touched. A run that is interrupted leaves the working
/// copy behind rather than a half-mutated source tree.
public struct ProjectInjection: Sendable {
    public struct Result: Sendable {
        public let workingCopy: URL
        public let mutants: [Mutant]
        /// Files that were read but produced nothing to mutate.
        public let untouched: Int
        /// Mutants dropped because no test reaches them.
        public let uncovered: Int
        /// Mutants dropped because the change did not touch them.
        public let unchanged: Int
        /// Files left alone because the tests are not aimed at them.
        public let outOfScope: Int
    }

    /// Directories the build makes for itself, and can make again.
    static let notCopied: Set<String> = [
        ".git", "build", "DerivedData", "node_modules",
    ]

    /// Dependency stores, linked to the original rather than copied.
    ///
    /// The build needs them and will not fetch them again on its own: left
    /// out, a Tuist project failed with "no such module 'Lottie'". Copied, it
    /// failed differently — Tuist writes the stores' absolute paths into the
    /// module maps it generates, so the copy saw two `Tuist/.build`s, its own
    /// through relative paths and the original through absolute ones, and
    /// clang found FBLPromises defined twice. A link makes both routes arrive
    /// at the same file.
    ///
    /// The build reads these and does not write to them, the same as when it
    /// runs in the original.
    static let linked: Set<String> = [".build", "Pods", "Carthage"]

    /// Directories that are copied or linked but never mutated.
    ///
    /// None of the dependency code is the code under test. Test code is here
    /// for a different reason: mutating it would let the suite grade itself.
    static let notMutated: Set<String> = notCopied.union(linked).union([
        ".swiftpm", "Tests", "Test",
    ])

    public let injector: SchemataInjector
    public let include: String?
    /// What the suite reached, if it was measured. Mutants outside it are never
    /// written: they would survive whatever the code did, and each one costs a
    /// run to learn nothing.
    public let coverage: Coverage?
    /// The lines a change touched, if a range was given. Everything else keeps
    /// the verdict it had on the last run, so re-earning it costs time and
    /// tells nobody anything.
    public let changed: ChangedLines?
    /// The files the tests are aimed at, in the original's paths. A file
    /// outside it is copied untouched: its mutants would survive whatever
    /// they did, and compiling them in only makes the build longer.
    public let scope: TestedScope?

    public init(
        injector: SchemataInjector = SchemataInjector(),
        include: String? = nil,
        coverage: Coverage? = nil,
        changed: ChangedLines? = nil,
        scope: TestedScope? = nil
    ) {
        self.injector = injector
        self.include = include
        self.coverage = coverage
        self.changed = changed
        self.scope = scope
    }

    public func callAsFunction(
        project: URL,
        workingCopy: URL,
        progress: (String) -> Void = { _ in }
    ) throws -> Result {
        try Self.clone(project, to: workingCopy)
        return try inject(project: project, workingCopy: workingCopy, progress: progress)
    }

    /// Writes the mutants into a working copy `clone` already made.
    ///
    /// Apart from the copy so something can run in it first: coverage is
    /// measured in the copy, before a single mutant is in it, when a scheme
    /// that only the copy has is the one that runs every test.
    public func inject(
        project: URL,
        workingCopy: URL,
        progress: (String) -> Void = { _ in }
    ) throws -> Result {

        var mutants: [Mutant] = []
        var untouched = 0
        var uncovered = 0
        var unchanged = 0
        var outOfScope = 0

        let files = try swiftFiles(in: workingCopy)
        let scope = scope?.rebased(from: project, to: workingCopy)

        // Coverage was measured on the original project, so its paths name the
        // original tree. Re-keying it onto the copy is what makes the lookup
        // below match anything at all.
        let coverage = coverage?.rebased(onto: files.map(\.path))
        let changed = changed?.rebased(onto: files.map(\.path))

        for file in files {
            if let include, !file.path.contains(include) { continue }

            if let scope, !scope.contains(file.path) {
                outOfScope += 1
                continue
            }

            let result = try injector(path: file.path)
            guard !result.mutants.isEmpty else {
                untouched += 1
                continue
            }

            // Filtered before the file is written, not after: a mutant no test
            // reaches would otherwise still be compiled in and still grow the
            // file, for a verdict that is known in advance.
            let touched = result.mutants.filter {
                changed?.includes(path: file.path, line: $0.line) ?? true
            }
            unchanged += result.mutants.count - touched.count

            let reachable = touched.filter {
                coverage?.reaches(path: file.path, line: $0.line) ?? true
            }
            uncovered += touched.count - reachable.count

            guard !reachable.isEmpty else {
                untouched += 1
                continue
            }

            try result.source.write(to: file, atomically: true, encoding: .utf8)
            mutants.append(contentsOf: reachable)
            progress("\(file.lastPathComponent): \(reachable.count)")
        }

        return Result(
            workingCopy: workingCopy,
            mutants: mutants,
            untouched: untouched,
            uncovered: uncovered,
            unchanged: unchanged,
            outOfScope: outOfScope
        )
    }

    /// Clones the project, leaving out what the build makes and linking what
    /// it depends on.
    ///
    /// Cloned rather than hardlinked. `rsync --link-dest` made every
    /// unchanged file in the copy the same inode as the original, so a test
    /// driver appended to a test file in the copy landed in the user's
    /// project. `copyItem` clones on APFS: bytes are shared until one side is
    /// written, then split. Across volumes it copies instead.
    public static func clone(_ project: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try clone(project, to: destination, depth: 0)
    }

    private static func clone(_ source: URL, to destination: URL, depth: Int) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)

        for name in try manager.contentsOfDirectory(atPath: source.path) {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)

            if Self.notCopied.contains(name) { continue }

            // SwiftPM's own build directory: `swift build` writes its products
            // here, and linking it would build mutants into the user's.
            if depth == 0, name == ".build" { continue }

            let values = try from.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isDirectory = values.isDirectory == true && values.isSymbolicLink != true

            if isDirectory, Self.linked.contains(name) {
                try manager.createSymbolicLink(at: to, withDestinationURL: from)
            } else if isDirectory {
                try clone(from, to: to, depth: depth + 1)
            } else {
                // A symlink is copied as the link, a file as a clone.
                try manager.copyItem(at: from, to: to)
            }
        }
    }

    public struct CopyFailure: Error, CustomStringConvertible {
        public let description: String
    }

    private func swiftFiles(in root: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var files: [URL] = []

        for case let url as URL in walker {
            if Self.notMutated.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }

            if url.pathExtension == "swift", url.lastPathComponent != "Package.swift" {
                files.append(url)
            }
        }

        return files.sorted { $0.path < $1.path }
    }
}
