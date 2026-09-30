import Foundation

/// What a run tells GitHub Actions when it runs in one: a summary on the
/// job's page, and annotations on the lines a pull request shows.
///
/// Nothing to ask for: the variables Actions sets say it is there, and
/// anywhere else they are absent and nothing is written.
public enum GitHubActions {
    public struct Step: Sendable {
        /// The file whose Markdown becomes the job's summary.
        public let summary: URL?
        /// The checkout, which an annotation's path is relative to.
        public let workspace: URL
    }

    /// The step this runs in, or nil outside Actions.
    public static func current(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Step? {
        guard environment["GITHUB_ACTIONS"] == "true" else { return nil }
        return Step(
            summary: environment["GITHUB_STEP_SUMMARY"].map { URL(fileURLWithPath: $0) },
            workspace: URL(fileURLWithPath: environment["GITHUB_WORKSPACE"] ?? FileManager.default.currentDirectoryPath)
        )
    }

    /// Actions shows ten annotations of a kind per step and drops the rest,
    /// so the ones worth seeing go first and the rest are not written.
    public static let annotationLimit = 10

    public enum Level: String, Sendable {
        case notice, warning, error
    }

    /// `::warning file=Sources/A.swift,line=12,title=…::message`
    public static func annotation(_ level: Level, file: String?, line: Int?, title: String, message: String) -> String {
        var properties: [String] = []
        if let file { properties.append("file=\(escapeProperty(file))") }
        if let line { properties.append("line=\(line)") }
        properties.append("title=\(escapeProperty(title))")
        return "::\(level.rawValue) \(properties.joined(separator: ","))::\(escapeData(message))"
    }

    /// Adds to the job's summary, after whatever an earlier step wrote.
    public static func append(_ markdown: String, to step: Step) throws {
        guard let file = step.summary else { return }
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((markdown + "\n").utf8))
    }

    /// A path as the checkout names it; as given when it is outside it.
    public static func relative(_ path: String, to workspace: URL) -> String {
        let root = canonical(workspace.path) + "/"
        let resolved = canonical(path)
        return resolved.hasPrefix(root) ? String(resolved.dropFirst(root.count)) : path
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// A Markdown table cell: a pipe would end it, a line break the row.
    static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    private static func escapeData(_ text: String) -> String {
        text.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    private static func escapeProperty(_ text: String) -> String {
        escapeData(text)
            .replacingOccurrences(of: ":", with: "%3A")
            .replacingOccurrences(of: ",", with: "%2C")
    }
}
