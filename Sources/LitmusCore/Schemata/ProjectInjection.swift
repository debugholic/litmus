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
    }

    /// Directories that never hold code worth mutating, and would make the copy
    /// enormous. Applied once, when the copy is made.
    static let skipped: Set<String> = [
        ".build", ".git", ".swiftpm", "build", "DerivedData",
        "Pods", "Carthage", "node_modules",
    ]

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

    public init(
        injector: SchemataInjector = SchemataInjector(),
        include: String? = nil,
        coverage: Coverage? = nil,
        changed: ChangedLines? = nil
    ) {
        self.injector = injector
        self.include = include
        self.coverage = coverage
        self.changed = changed
    }

    public func callAsFunction(
        project: URL,
        workingCopy: URL,
        progress: (String) -> Void = { _ in }
    ) throws -> Result {
        try copy(project, to: workingCopy)

        var mutants: [Mutant] = []
        var untouched = 0
        var uncovered = 0
        var unchanged = 0

        let files = try swiftFiles(in: workingCopy)

        // Coverage was measured on the original project, so its paths name the
        // original tree. Re-keying it onto the copy is what makes the lookup
        // below match anything at all.
        let coverage = coverage?.rebased(onto: files.map(\.path))
        let changed = changed?.rebased(onto: files.map(\.path))

        for file in files {
            if let include, !file.path.contains(include) { continue }

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
            unchanged: unchanged
        )
    }

    private func copy(_ project: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // rsync keeps this quick and lets the skip list stay in one place;
        // FileManager would copy the build directories first and prune after.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments = ["-a"]
            + Self.skipped.sorted().flatMap { ["--exclude", $0] }
            + ["\(project.path)/", "\(destination.path)/"]

        try process.run()
        process.waitUntilExit()
    }

    private func swiftFiles(in root: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var files: [URL] = []

        // Nothing here re-checks the skip list: rsync already left those
        // directories out of the copy, so this walk cannot reach one. A
        // mutation run found the check — deleting it broke no test.
        for case let url as URL in walker {
            // Test code is the thing being measured, so mutating it would make
            // the suite grade itself.
            if url.lastPathComponent == "Tests" || url.lastPathComponent == "Test" {
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
