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
    /// To the flaky run's page, beside "Show details".
    let flaky: ReportPages.Link?

    public init(
        _ summary: MutationRun.Summary,
        workingCopy: URL,
        project: URL,
        run: RunInfo? = nil,
        flaky: ReportPages.Link? = nil
    ) {
        self.summary = summary
        self.workingCopy = workingCopy
        self.project = project
        self.run = run
        self.flaky = flaky
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
        <nav class="litmus-back" hidden><a class="button" href="#summary">← Summary</a></nav>
        <mutation-test-report-app title-postfix="Litmus"></mutation-test-report-app>
        <script>
        document.querySelector("mutation-test-report-app").report = \(embedded);
        </script>
        \(Self.pageScript)
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
        let reached = caught + summary.survived
        let total = caught + summary.survived + summary.noCoverage
        var parts: [String] = []

        parts.append("""
        <div class="top"><h1>Summary<span>Litmus</span></h1><div class="actions">\
        <a class="button" href="#mutant">Show details →</a>\(flaky?.button("Flaky →") ?? "")</div></div>
        """)

        // The two scores, in cards coloured by the report's own thresholds.
        func card(_ value: Double?, _ label: String, _ hint: String) -> String {
            let text = value.map { "\(Int($0.rounded()))%" } ?? "—"
            return """
            <div class="card"><div class="value \(Self.grade(value))">\(text)</div>\
            <div class="label">\(label)</div><div class="muted">\(hint)</div></div>
            """
        }
        parts.append("""
        <div class="cards">
        \(card(summary.testStrength, "Test strength", "caught \(caught) of the \(reached) mutants the tests reach"))
        \(card(summary.mutationScore, "Mutation score", "caught \(caught) of all \(total)"))
        </div>
        """)

        // The viewer's bar, of what the tests reach only: with every mutant in
        // it, the few they reach were slivers whose numbers ran together.
        if reached > 0 {
            let share = Double(caught) / Double(reached) * 100
            parts.append("""
            <div class="bar" title="caught \(caught), survived \(summary.survived)">\
            <div class="caught" style="width: \(String(format: "%.1f", share))%">\(caught > 0 ? "\(caught)" : "")</div>\
            <div class="survived" style="width: \(String(format: "%.1f", 100 - share))%">\(summary.survived > 0 ? "\(summary.survived)" : "")</div>\
            </div>
            """)
        }

        var meta = ["caught \(caught) · survived \(summary.survived) · no test reaches \(summary.noCoverage)"
            + (summary.unviable > 0 ? " · did not build \(summary.unviable)" : "")]
        if let run { meta.append(Self.escape(run.line)) }
        if let took = Report.took(summary) { meta.append(took) }
        parts.append(meta.map { "<p class=\"muted\">\($0)</p>" }.joined(separator: "\n"))

        // Beside the scores, because it is about them.
        if !summary.failedAlone.isEmpty {
            let unsure = summary.unsureKills
            let rows = summary.failedAlone.map { test in
                let resting = unsure.count { $0.killedBy.contains { $0.id == test.id } }
                return """
                <tr><td>\(Self.escape(test.name))</td><td>\(Self.escape(test.file ?? ""))</td>\
                <td class="num">\(resting)</td></tr>
                """
            }.joined(separator: "\n")
            parts.append(Self.table(
                title: "Fail when run again",
                note: "pass in the suite, fail on their own after it — they depend on state left behind, or are flaky; "
                    + "\(unsure.count) kill(s) rest on them alone and may not be the mutant's doing",
                head: ["Test", "File", "Kills resting on it"],
                numbers: [2],
                rows: rows
            ))
        }

        let areas = summary.areas
        if areas.count > 1 {
            let rows = areas.map { area in
                """
                <tr><td>\(Self.escape(area.name))</td>\
                <td class="num \(Self.grade(area.score))">\(area.score.map { "\(Int($0.rounded()))%" } ?? "—")</td>\
                <td class="num">\(area.count(.killed) + area.count(.timedOut))</td>\
                <td class="num">\(area.count(.survived))</td><td class="num">\(area.count(.noCoverage))</td></tr>
                """
            }.joined(separator: "\n")
            parts.append(Self.table(
                title: "By \(summary.areasAreModules ? "module" : "folder")", note: "weakest first",
                head: [summary.areasAreModules ? "Module" : "Folder", "Score", "Caught", "Survived", "No coverage"],
                numbers: [1, 2, 3, 4],
                rows: rows
            ))
        }

        if !plan.unchecked.isEmpty {
            var rows: [String] = []
            for group in plan.groups {
                let passing = group.passedBy
                let passedBy = passing.isEmpty ? "" : """
                <span class="muted">passed by \(passing.prefix(3).map { Self.escape($0.name) }.joined(separator: ", "))\
                \(passing.count > 3 ? " and \(passing.count - 3) more" : "")</span>
                """
                rows.append("<tr class=\"group\"><td colspan=\"4\"><b>\(Self.escape(group.owner))</b>\(passedBy)</td></tr>")

                for entry in group.entries {
                    let gap = entry.gap
                    let member = TestPlan.split(gap.name).member ?? gap.name
                    // An initialiser with fourteen labels ran over two lines;
                    // cut, with the whole name on hover.
                    let shown = member.count > 60 ? String(member.prefix(57)) + "…" : member
                    rows.append("""
                    <tr class="function"><td colspan="4">\
                    <span class="badge \(gap.status == .untested ? "bad" : "warn")">\(gap.status.rawValue)</span>\
                    <span title="\(Self.escape(member))">\(Self.escape(shown))</span> \
                    <span class="muted">\(gap.caught) of \(gap.scored) caught</span></td></tr>
                    """)
                    for survivor in gap.survivors {
                        rows.append("""
                        <tr class="line"><td><a href="\(link(to: survivor.mutant.filePath))">\
                        \(Self.escape(survivor.mutant.fileName)):\(survivor.mutant.line)</a></td>\
                        <td>\(survivor.gapKind.rawValue)</td>\
                        <td><code>\(Self.escape(Report.what(survivor.mutant).replacingOccurrences(of: "`", with: "")))</code></td>\
                        <td class="muted">\(survivor.gapKind.hint)</td></tr>
                        """)
                    }
                    if entry.unreached > 0 {
                        rows.append("<tr class=\"line\"><td colspan=\"4\" class=\"muted\">and \(entry.unreached) more in it no test reaches</td></tr>")
                    }
                }
            }
            parts.append(Self.table(
                title: "What to test", note: "tests run through these and do not notice the change",
                head: ["Where", "Kind", "Change", "What to add"],
                widths: [26, 12, 32, 30],
                rows: rows.joined(separator: "\n")
            ))
        }

        if !plan.unreached.isEmpty {
            let row = { (file: (path: String, count: Int)) in
                """
                <tr><td><a href="\(self.link(to: file.path))">\(Self.escape(self.relative(file.path)))</a></td>\
                <td class="num">\(file.count)</td></tr>
                """
            }
            let shown = plan.unreached.prefix(10).map(row)
            let rest = plan.unreached.dropFirst(10)
            let more = rest.isEmpty ? [] : ["""
                <tr><td colspan="2"><details><summary>\(rest.count) more file(s)</summary>\
                <table>\(rest.map(row).joined(separator: "\n"))</table></details></td></tr>
                """]
            parts.append(Self.table(
                title: "No test reaches", note: "\(plan.unreachedTotal) mutant(s) in \(plan.unreached.count) file(s)",
                head: ["File", "Mutants"],
                numbers: [1],
                rows: (shown + more).joined(separator: "\n")
            ))
        }

        let costly = summary.tests.filter { $0.cost != nil }.prefix(5)
        if !costly.isEmpty {
            let rows = costly.map { score in
                """
                <tr><td>\(Self.escape(score.test.name))</td>\
                <td class="num">\(Report.seconds(score.test.duration ?? 0))</td>\
                <td class="num">\(score.reached)</td><td class="num"><b>\(Report.seconds(score.cost ?? 0))</b></td></tr>
                """
            }.joined(separator: "\n")
            parts.append(Self.table(
                title: "Slowest tests", note: "each runs once for every mutant it reaches",
                head: ["Test", "Alone", "Mutants", "Cost"],
                numbers: [1, 2, 3],
                rows: rows
            ))
        }

        return "<div class=\"litmus\">\n\(parts.joined(separator: "\n"))\n</div>"
    }

    /// A section as the viewer draws its file table: a heading, then a table
    /// in a rounded border.
    ///
    /// `widths` fixes the columns, for a table whose rows are not all
    /// alike: sized by their contents, the columns of each part of it
    /// fell in different places.
    private static func table(
        title: String,
        note: String,
        head: [String],
        numbers: Set<Int> = [],
        widths: [Int]? = nil,
        rows: String
    ) -> String {
        let cells = head.enumerated().map { index, name in
            "<th\(numbers.contains(index) ? " class=\"num\"" : "")>\(name)</th>"
        }.joined()
        let columns = widths.map { "<colgroup>" + $0.map { "<col style=\"width: \($0)%\">" }.joined() + "</colgroup>" } ?? ""
        return """
        <h2>\(title) <small>\(escape(note))</small></h2>
        <div class="frame"><table\(widths == nil ? "" : " class=\"fixed\"")>\(columns)<thead><tr>\(cells)</tr></thead><tbody>
        \(rows)
        </tbody></table></div>
        """
    }

    /// The report's thresholds: 80 and up is good, under 60 bad.
    private static func grade(_ score: Double?) -> String {
        guard let score else { return "" }
        return score >= 80 ? "good" : score >= 60 ? "warn" : "bad"
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

    /// The viewer's look, so the page reads as one: its container, which
    /// widens in steps, here centred for both; its type,
    /// palette, borders and bar; and its light or dark theme, which the
    /// script below follows when its switch is pressed.
    static let frontStyle = """
    <style>
    .litmus {
      --fg: oklch(0.274 0.006 286.033); --muted: oklch(0.552 0.016 285.938); --line: oklch(0.92 0.004 286.32);
      --bg: #fff; --head: oklch(0.967 0.001 286.375);
      --good: oklch(0.627 0.194 149.214); --warn: oklch(0.681 0.162 75.834); --bad: oklch(0.577 0.245 27.325);
      width: 100%; box-sizing: border-box; padding-bottom: 16px; background: var(--bg); color: var(--fg);
      font: 14px/1.5 -apple-system, system-ui, "Segoe UI", Roboto, "Helvetica Neue", "Noto Sans", Arial, sans-serif;
    }
    .litmus[data-theme="dark"] {
      --fg: oklch(0.967 0.001 286.375); --muted: oklch(0.705 0.015 286.067); --line: oklch(0.37 0.013 285.805);
      --bg: oklch(0.21 0.006 285.885); --head: oklch(0.274 0.006 286.033);
    }
    /* The viewer's container widens in steps and keeps to the left; its
       element, which can be styled from outside, is given the same steps
       and centred, so the viewer, the summary and the back link share one
       centred column however wide the window is. */
    .litmus, .litmus-back, mutation-test-report-app { display: block; margin-left: auto; margin-right: auto; }
    .litmus[hidden], .litmus-back[hidden] { display: none; }
    @media (min-width: 640px) { .litmus, .litmus-back, mutation-test-report-app { max-width: 640px; } }
    @media (min-width: 768px) { .litmus, .litmus-back, mutation-test-report-app { max-width: 768px; } }
    @media (min-width: 1024px) { .litmus, .litmus-back, mutation-test-report-app { max-width: 1024px; } }
    @media (min-width: 1280px) { .litmus, .litmus-back, mutation-test-report-app { max-width: 1280px; } }
    @media (min-width: 1536px) { .litmus, .litmus-back, mutation-test-report-app { max-width: 1536px; } }
    .litmus h1 { margin: 16px 0; font-size: 48px; line-height: 1; font-weight: 700; letter-spacing: -0.025em; }
    .litmus h1 span { margin-left: 16px; font-size: 38.4px; font-weight: 300; color: var(--muted); }
    .litmus h2 { margin: 32px 0 12px; font-size: 24px; font-weight: 700; letter-spacing: -0.015em; }
    .litmus small, .litmus .muted { color: var(--muted); font-weight: 400; font-size: 14px; }
    .litmus p.muted { margin: 4px 0; }
    .litmus .cards { display: flex; gap: 16px; flex-wrap: wrap; margin-bottom: 16px; }
    .litmus .card { flex: 1 1 240px; border: 1px solid var(--line); border-radius: 6px; padding: 16px; }
    .litmus .card .value { font-size: 36px; font-weight: 700; line-height: 1.1; }
    .litmus .card .label { font-weight: 700; margin: 4px 0 2px; }
    .litmus .good { color: var(--good); } .litmus .warn { color: var(--warn); } .litmus .bad { color: var(--bad); }
    .litmus .bar { display: flex; height: 32px; border-radius: 4px; overflow: hidden; margin: 16px 0 8px; }
    .litmus .bar div { display: flex; align-items: center; padding-left: 8px; font-size: 16px; overflow: hidden; }
    .litmus .bar .caught { background: var(--good); } .litmus .bar .survived { background: var(--bad); }
    .litmus .frame { overflow-x: auto; border: 1px solid var(--line); border-radius: 6px; }
    .litmus table { width: 100%; border-collapse: collapse; }
    .litmus th { padding: 12px 16px; font-weight: 700; text-align: left; white-space: nowrap; }
    .litmus td { padding: 8px 16px; border-top: 1px solid var(--line); vertical-align: middle; }
    .litmus table.fixed { table-layout: fixed; }
    .litmus table.fixed td { overflow-wrap: anywhere; }
    .litmus tr.function td { padding-left: 16px; }
    .litmus tr.line td:first-child { padding-left: 40px; }
    .litmus .num { text-align: right; white-space: nowrap; }
    .litmus tr.group td { background: var(--head); }
    .litmus tr.group .muted { margin-left: 12px; }
    .litmus tr.function td { font-weight: 600; }
    .litmus .badge { display: inline-block; margin-right: 8px; padding: 0 6px; border-radius: 4px;
      font-size: 11px; font-weight: 700; color: #fff; }
    .litmus .badge.bad { background: var(--bad); } .litmus .badge.warn { background: var(--warn); }
    .litmus code { font: 13px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; overflow-wrap: anywhere; }
    .litmus a { color: inherit; text-decoration: none; } .litmus a:hover { text-decoration: underline; }
    .litmus details summary { cursor: pointer; color: var(--muted); }
    .litmus details table td { border-top: 0; padding: 4px 0; }
    .litmus .top { display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-wrap: wrap; }
    .litmus .button, .litmus-back .button { display: inline-block; padding: 8px 14px; border: 1px solid var(--line);
      border-radius: 6px; font-weight: 600; text-decoration: none; }
    .litmus .button[hidden] { display: none; }
    .litmus .actions { display: flex; gap: 8px; flex-wrap: wrap; }
    .litmus .button:hover, .litmus-back .button:hover { background: var(--head); text-decoration: none; }
    .litmus-back { padding: 16px 0 0; font: 14px/1.5 -apple-system, system-ui, "Segoe UI", Roboto, sans-serif; }
    .litmus-back .button { --line: oklch(0.92 0.004 286.32); --head: oklch(0.967 0.001 286.375); color: oklch(0.274 0.006 286.033); }
    .litmus-back[data-theme="dark"] .button { --line: oklch(0.37 0.013 285.805); --head: oklch(0.274 0.006 286.033); color: oklch(0.967 0.001 286.375); }
    </style>
    """

    /// Two views of one page: the summary, first, and the viewer, behind
    /// "Show details". A line in the summary opens its file in the viewer;
    /// "← Summary" comes back. The viewer puts `#mutant` in the address as
    /// soon as it loads, so only a route to a file or a test opens it
    /// without a click. And both follow the viewer's theme switch, which
    /// paints only the viewer, so the page behind is painted here too.
    static let pageScript = """
    <script>
    (function () {
      var app = document.querySelector("mutation-test-report-app");
      var front = document.querySelector(".litmus");
      var back = document.querySelector(".litmus-back");
      if (!app || !front || !back) return;
      var toFile = /^#(mutant|test)\\/./;
      var detail = toFile.test(location.hash);
      function show() {
        front.hidden = detail;
        back.hidden = !detail;
        app.style.display = detail ? "" : "none";
        window.scrollTo(0, 0);
      }
      document.addEventListener("click", function (event) {
        var link = event.target.closest && event.target.closest("a");
        if (!link) return;
        var href = link.getAttribute("href") || "";
        if (href === "#summary") {
          event.preventDefault();
          detail = false;
          location.hash = "#mutant";
          show();
        } else if (front.contains(link) && /^#(mutant|test)/.test(href)) {
          detail = true;
          show();
        }
      });
      window.addEventListener("hashchange", function () {
        if (toFile.test(location.hash) && !detail) { detail = true; show(); }
      });
      function theme() {
        var dark = (app.getAttribute("theme") || "") === "dark";
        front.setAttribute("data-theme", dark ? "dark" : "light");
        back.setAttribute("data-theme", dark ? "dark" : "light");
        document.documentElement.style.background = dark ? "oklch(0.21 0.006 285.885)" : "";
      }
      new MutationObserver(theme).observe(app, { attributes: true, attributeFilter: ["theme"] });
      theme();
      show();
    })();
    </script>
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
        // Its setup is everything before the first test run.
        if summary.duration > 0 {
            let setup = summary.phases.setup + summary.phases.coverage + summary.phases.build
            report["performance"] = [
                "setup": Int(setup * 1000),
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
