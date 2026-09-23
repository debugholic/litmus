import Foundation

/// The mutation testing report format Stryker defined, and its viewer.
///
/// An open schema (`mutation-testing-report-schema`, Apache-2.0) that any
/// mutation testing tool can write, with a web component that shows each
/// file's source and every mutant on the line it changed. Reading survivors
/// in place, next to the code, is what makes it obvious what to test.
public struct StrykerReport: Sendable {
    public static let viewer = "https://cdn.jsdelivr.net/npm/mutation-testing-elements@3.9.0/dist/mutation-test-elements.js"

    let summary: MutationRun.Summary
    /// Where the mutated files are, and where their untouched originals are.
    /// The report shows the original: the copy has every switch written in.
    let workingCopy: URL
    let project: URL

    public init(_ summary: MutationRun.Summary, workingCopy: URL, project: URL) {
        self.summary = summary
        self.workingCopy = workingCopy
        self.project = project
    }

    public func json() throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: payload(),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    public func html() throws -> String {
        let compact = try JSONSerialization.data(withJSONObject: payload(), options: [.sortedKeys])
        // Inside a <script>, "</" would end it early.
        let embedded = String(decoding: compact, as: UTF8.self)
            .replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Litmus report</title>
        <script src="\(Self.viewer)"></script>
        </head>
        <body>
        <mutation-test-report-app title-postfix="Litmus"></mutation-test-report-app>
        <script>
        document.querySelector("mutation-test-report-app").report = \(embedded);
        </script>
        </body>
        </html>

        """
    }

    // MARK: -

    func payload() -> [String: Any] {
        let gaps = FunctionGap.find(in: summary.results)
        var gapByMutant: [String: FunctionGap] = [:]
        for gap in gaps {
            for survivor in gap.survivors { gapByMutant[survivor.mutant.switchName] = gap }
        }

        // Compared with links resolved: /tmp and /private/tmp are one place
        // spelled two ways, and a missed match shows the mutated copy.
        let root = Self.canonical(workingCopy.path) + "/"
        var files: [String: Any] = [:]

        for (path, results) in Dictionary(grouping: summary.results, by: \.mutant.filePath) {
            let resolved = Self.canonical(path)
            let relative = resolved.hasPrefix(root) ? String(resolved.dropFirst(root.count)) : path
            let original = project.appendingPathComponent(relative)
            guard let source = (try? String(contentsOf: original, encoding: .utf8))
                ?? (try? String(contentsOfFile: path, encoding: .utf8))
            else { continue }

            let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            files[relative] = [
                "language": "swift",
                "source": source,
                "mutants": results
                    .sorted { ($0.mutant.line, $0.mutant.column) < ($1.mutant.line, $1.mutant.column) }
                    .map { mutant($0, lines: lines, gap: gapByMutant[$0.mutant.switchName]) },
            ] as [String: Any]
        }

        return [
            "schemaVersion": "2",
            "thresholds": ["high": 80, "low": 60],
            "framework": ["name": "Litmus"],
            "files": files,
        ]
    }

    private func mutant(_ result: MutantResult, lines: [String], gap: FunctionGap?) -> [String: Any] {
        let mutant = result.mutant
        let change = mutant.change

        let start = (change?.startLine ?? mutant.line, change?.startColumn ?? mutant.column)
        let end = (change?.endLine ?? mutant.line, change?.endColumn ?? mutant.column + 1)

        var entry: [String: Any] = [
            "id": mutant.switchName,
            "mutatorName": mutant.operator,
            "location": [
                "start": ["line": start.0, "column": Self.column(start.1, onLine: start.0, of: lines)],
                "end": ["line": end.0, "column": Self.column(end.1, onLine: end.0, of: lines)],
            ],
            "status": Self.status(result.verdict),
        ]

        if let replacement = change?.replacement { entry["replacement"] = replacement }

        var description = "[\(mutant.gapKind.rawValue)] \(mutant.description)"
        if let gap {
            description += " — \(gap.status.rawValue) \(gap.name), \(gap.caught) of \(gap.scored) caught"
        }
        entry["description"] = description
        if result.verdict == .survived { entry["statusReason"] = mutant.gapKind.hint }

        return entry
    }

    /// SwiftSyntax counts columns in UTF-8 bytes; the viewer counts them in
    /// characters as JavaScript sees them. They differ on any line with
    /// Korean on it before the mutant, and the highlight lands in the wrong
    /// place.
    static func column(_ utf8Column: Int, onLine line: Int, of lines: [String]) -> Int {
        guard line >= 1, line <= lines.count else { return utf8Column }
        let bytes = Array(lines[line - 1].utf8)
        let prefix = bytes.prefix(max(0, utf8Column - 1))
        return String(decoding: prefix, as: UTF8.self).utf16.count + 1
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func status(_ verdict: Verdict) -> String {
        switch verdict {
        case .killed: return "Killed"
        case .survived: return "Survived"
        case .timedOut: return "Timeout"
        case .unviable: return "CompileError"
        case .error: return "RuntimeError"
        }
    }
}
