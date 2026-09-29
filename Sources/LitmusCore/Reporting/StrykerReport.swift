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
    let run: RunInfo?

    public init(_ summary: MutationRun.Summary, workingCopy: URL, project: URL, run: RunInfo? = nil) {
        self.summary = summary
        self.workingCopy = workingCopy
        self.project = project
        self.run = run
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
        \(Self.frontStyle)
        </head>
        <body>
        \(front())
        <mutation-test-report-app title-postfix="Litmus"></mutation-test-report-app>
        <script>
        document.querySelector("mutation-test-report-app").report = \(embedded);
        </script>
        </body>
        </html>

        """
    }

    // MARK: - what to read first

    /// Above the viewer: the two scores, what to test, and what makes the run
    /// slow. The viewer is a file tree; it does not say where to start, and
    /// its bar of counts runs its numbers together when one kind is most of
    /// the run.
    func front() -> String {
        let plan = TestPlan(summary.results)
        let caught = summary.killed + summary.timedOut
        var parts: [String] = []

        // Scores, and a bar of only what the tests reach.
        let strength = summary.testStrength.map { "\(Int($0.rounded()))%" } ?? "—"
        let whole = summary.mutationScore.map { "\(Int($0.rounded()))%" } ?? "—"
        let reached = caught + summary.survived
        let share = reached > 0 ? Double(caught) / Double(reached) * 100 : 0
        parts.append("""
        <section class="scores">
        <div><b>\(strength)</b><span>test strength</span><small>caught \(caught) of the \(reached) mutants the tests reach</small></div>
        <div><b>\(whole)</b><span>mutation score</span><small>caught \(caught) of all \(caught + summary.survived + summary.noCoverage)</small></div>
        </section>
        \(reached > 0 ? """
        <div class="bar" title="caught \(caught), survived \(summary.survived)"><i style="width: \(String(format: "%.1f", share))%"></i></div>
        """ : "")
        <p class="counts">caught \(caught) · survived \(summary.survived) · no test reaches \(summary.noCoverage)\(summary.unviable > 0 ? " · did not build \(summary.unviable)" : "")</p>
        \([run.map { Self.escape($0.line) }, Report.took(summary)].compactMap { $0 }.map { "<p class=\"run\">\($0)</p>" }.joined(separator: "\n"))
        """)

        let areas = summary.areas
        if areas.count > 1 {
            let rows = areas.map { area in
                let score = area.score.map { "\(Int($0.rounded()))%" } ?? "—"
                return """
                <tr><td>\(Self.escape(area.name))</td><td class="num">\(score)</td><td class="num">\(area.count(.killed) + area.count(.timedOut))</td>\
                <td class="num">\(area.count(.survived))</td><td class="num">\(area.count(.noCoverage))</td></tr>
                """
            }.joined(separator: "\n")
            parts.append("""
            <h2>By \(summary.areasAreModules ? "module" : "folder") <small>weakest first</small></h2>
            <table class="areas"><thead><tr><th></th><th>score</th><th>caught</th><th>survived</th><th>no test reaches</th></tr></thead>
            <tbody>\(rows)</tbody></table>
            """)
        }

        if !plan.unchecked.isEmpty {
            var rows: [String] = []
            for group in plan.groups {
                let passing = group.passedBy
                let passedBy = passing.isEmpty ? "" : """
                <p class="tests">passed by \(passing.prefix(3).map { Self.escape($0.name) }.joined(separator: ", "))\(passing.count > 3 ? " and \(passing.count - 3) more" : "")</p>
                """
                let functions = group.entries.map { entry in
                    let gap = entry.gap
                    let member = TestPlan.split(gap.name).member ?? gap.name
                    let survivors = gap.survivors.map { survivor in
                        """
                        <li><a href="\(link(to: survivor.mutant.filePath))">\(Self.escape(survivor.mutant.fileName)):\(survivor.mutant.line)</a> \
                        <em>\(survivor.gapKind.rawValue)</em> <code>\(Self.escape(Report.what(survivor.mutant)))</code> \
                        <small>\(survivor.gapKind.hint)</small></li>
                        """
                    }.joined(separator: "\n")
                    let more = entry.unreached > 0
                        ? "<li><small>and \(entry.unreached) more in it no test reaches</small></li>" : ""
                    return """
                    <h4><span class="\(gap.status == .untested ? "untested" : "partial")">\(gap.status.rawValue)</span> \
                    \(Self.escape(member)) <small>\(gap.caught) of \(gap.scored) caught</small></h4>
                    <ul>\(survivors)\(more)</ul>
                    """
                }.joined(separator: "\n")
                rows.append("<article><h3>\(Self.escape(group.owner))</h3>\n\(passedBy)\n\(functions)</article>")
            }
            parts.append("""
            <h2>What to test <small>tests run through these and do not notice the change</small></h2>
            \(rows.joined(separator: "\n"))
            """)
        }

        if !plan.unreached.isEmpty {
            let row = { (file: (path: String, count: Int)) in
                "<li><b>\(file.count)</b> <a href=\"\(self.link(to: file.path))\">\(Self.escape(self.relative(file.path)))</a></li>"
            }
            let shown = plan.unreached.prefix(10).map(row).joined(separator: "\n")
            let rest = plan.unreached.dropFirst(10)
            let more = rest.isEmpty ? "" : """
            <details><summary>\(rest.count) more file(s)</summary><ul class="files">\(rest.map(row).joined(separator: "\n"))</ul></details>
            """
            parts.append("""
            <h2>No test reaches <small>\(plan.unreachedTotal) mutant(s) in \(plan.unreached.count) file(s)</small></h2>
            <ul class="files">\(shown)</ul>\(more)
            """)
        }

        let costly = summary.tests.filter { $0.cost != nil }.prefix(5)
        if !costly.isEmpty {
            let rows = costly.map { score in
                let cost = Report.seconds(score.cost ?? 0)
                let each = Report.seconds(score.test.duration ?? 0)
                return "<li><b>\(cost)</b> \(each) × \(score.reached) \(Self.escape(score.test.name))</li>"
            }.joined(separator: "\n")
            parts.append("""
            <h2>Slowest tests <small>each runs once for every mutant it reaches</small></h2>
            <ul class="files">\(rows)</ul>
            """)
        }

        return "<header class=\"litmus\">\n\(parts.joined(separator: "\n"))\n</header>"
    }

    /// The viewer's route to a file. Encoded: a `#`, a space or a `%` in the
    /// path would end the route or be read as an escape.
    ///
    /// Under the folder every file shares, as the viewer names them: it
    /// drops that folder from its routes, and `#mutant/Sources/…` opened
    /// nothing.
    private func link(to path: String) -> String {
        let shared = viewerRoot
        let relative = relative(path)
        let named = relative.hasPrefix(shared) ? String(relative.dropFirst(shared.count)) : relative
        let route = named.addingPercentEncoding(withAllowedCharacters: Self.routeAllowed) ?? named
        return "#mutant/" + Self.escape(route)
    }

    /// The folder every file in the report shares, with its trailing slash.
    private var viewerRoot: String {
        MutationRun.Summary.commonDirectory(of: Array(Set(summary.results.map { relative($0.mutant.filePath) })))
    }

    private static let routeAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "#?%"))

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static let frontStyle = """
    <style>
    .litmus { --fg: #1f2328; --muted: #656d76; --line: #d0d7de; --ok: #1a7f37; --bad: #cf222e; --warn: #9a6700;
      font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: var(--fg);
      max-width: 1100px; margin: 24px auto 8px; padding: 0 16px; }
    @media (prefers-color-scheme: dark) {
      .litmus { --fg: #e6edf3; --muted: #8d96a0; --line: #30363d; --ok: #3fb950; --bad: #f85149; --warn: #d29922; }
    }
    .litmus .scores { display: flex; gap: 40px; flex-wrap: wrap; }
    .litmus .scores div { display: flex; flex-direction: column; }
    .litmus .scores b { font-size: 32px; line-height: 1.1; }
    .litmus .scores span { font-weight: 600; }
    .litmus small { color: var(--muted); font-weight: normal; }
    .litmus .bar { height: 8px; border-radius: 4px; background: var(--bad); margin: 16px 0 4px; overflow: hidden; }
    .litmus .bar i { display: block; height: 100%; background: var(--ok); }
    .litmus .counts { color: var(--muted); margin: 0 0 8px; }
    .litmus .run { color: var(--muted); font-size: 12px; margin: 0; }
    .litmus h2 { font-size: 18px; margin: 28px 0 8px; border-bottom: 1px solid var(--line); padding-bottom: 4px; }
    .litmus h3 { font-size: 15px; margin: 18px 0 2px; }
    .litmus h4 { font-size: 14px; margin: 8px 0 2px 12px; }
    .litmus article ul { margin-left: 12px; }
    .litmus h4 span { font-size: 11px; padding: 1px 6px; border-radius: 4px; color: #fff; vertical-align: 2px; }
    .litmus .untested { background: var(--bad); }
    .litmus .partial { background: var(--warn); }
    .litmus ul { margin: 4px 0; padding-left: 20px; }
    .litmus ul.files { list-style: none; padding-left: 0; }
    .litmus ul.files b { display: inline-block; min-width: 56px; text-align: right; margin-right: 8px; }
    .litmus li em { color: var(--warn); font-style: normal; margin: 0 6px; }
    .litmus code { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; overflow-wrap: anywhere; }
    .litmus .tests { color: var(--muted); margin: 0; }
    .litmus a { color: inherit; }
    .litmus details summary { cursor: pointer; color: var(--muted); }
    .litmus table.areas { border-collapse: collapse; }
    .litmus table.areas th, .litmus table.areas td { padding: 2px 16px 2px 0; text-align: left; }
    .litmus table.areas th { color: var(--muted); font-weight: normal; }
    .litmus table.areas td.num, .litmus table.areas th:not(:first-child) { text-align: right; }
    </style>
    """

    // MARK: -

    func payload() -> [String: Any] {
        let gaps = FunctionGap.find(in: summary.results)
        var gapByMutant: [String: FunctionGap] = [:]
        for gap in gaps {
            for survivor in gap.survivors { gapByMutant[survivor.mutant.switchName] = gap }
        }

        // Compared with links resolved: /tmp and /private/tmp are one place
        // spelled two ways, and a missed match shows the mutated copy.
        var files: [String: Any] = [:]

        for (path, results) in Dictionary(grouping: summary.results, by: \.mutant.filePath) {
            let relative = relative(path)
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

        var framework: [String: Any] = ["name": "Litmus"]
        if let version = run?.version { framework["version"] = version }

        var report: [String: Any] = [
            "schemaVersion": "2",
            "thresholds": ["high": 80, "low": 60],
            "framework": framework,
            "files": files,
        ]
        // The schema's own names for the three parts of a run, in milliseconds.
        if summary.duration > 0 {
            report["performance"] = [
                "setup": Int(summary.phases.build * 1000),
                "initialRun": Int(summary.phases.baseline * 1000),
                "mutation": Int(summary.mutantTime * 1000),
            ]
        }
        let tests = testFiles()
        if !tests.isEmpty { report["testFiles"] = tests }
        return report
    }

    /// Every test that reached a mutant, grouped by the file it is in, so
    /// the viewer can list them and say which mutants each one caught.
    private func testFiles() -> [String: Any] {
        let tests = Set(summary.results.flatMap { $0.coveredBy + $0.killedBy })
        return Dictionary(grouping: tests) { $0.file ?? "tests" }.mapValues { tests in
            [
                "tests": tests.sorted { $0.id < $1.id }.map { ["id": $0.id, "name": $0.name] },
            ] as [String: Any]
        }
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
        if !result.coveredBy.isEmpty { entry["coveredBy"] = result.coveredBy.map(\.id) }
        if !result.killedBy.isEmpty { entry["killedBy"] = result.killedBy.map(\.id) }

        var description = "[\(result.gapKind.rawValue)] \(mutant.description)"
        if let gap {
            description += " — \(gap.status.rawValue) \(gap.name), \(gap.caught) of \(gap.scored) caught"
        }
        entry["description"] = description
        if result.verdict == .survived || result.verdict == .noCoverage { entry["statusReason"] = result.gapKind.hint }

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

    /// A mutant's file as the viewer names it: under the working copy.
    private func relative(_ path: String) -> String {
        let root = Self.canonical(workingCopy.path) + "/"
        let resolved = Self.canonical(path)
        return resolved.hasPrefix(root) ? String(resolved.dropFirst(root.count)) : path
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
        case .noCoverage: return "NoCoverage"
        case .error: return "RuntimeError"
        }
    }
}
