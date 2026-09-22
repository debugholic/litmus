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
    }

    /// Directories that never hold code worth mutating, and would make the copy
    /// enormous.
    static let skipped: Set<String> = [
        ".build", ".git", ".swiftpm", "build", "DerivedData",
        "Pods", "Carthage", "node_modules",
    ]

    public let injector: SchemataInjector
    public let include: String?

    public init(injector: SchemataInjector = SchemataInjector(), include: String? = nil) {
        self.injector = injector
        self.include = include
    }

    public func callAsFunction(
        project: URL,
        workingCopy: URL,
        progress: (String) -> Void = { _ in }
    ) throws -> Result {
        try copy(project, to: workingCopy)

        var mutants: [Mutant] = []
        var untouched = 0

        for file in try swiftFiles(in: workingCopy) {
            if let include, !file.path.contains(include) { continue }

            let result = try injector(path: file.path)
            guard !result.mutants.isEmpty else {
                untouched += 1
                continue
            }

            try result.source.write(to: file, atomically: true, encoding: .utf8)
            mutants.append(contentsOf: result.mutants)
            progress("\(file.lastPathComponent): \(result.mutants.count)")
        }

        return Result(workingCopy: workingCopy, mutants: mutants, untouched: untouched)
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

        for case let url as URL in walker {
            if Self.skipped.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }

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
