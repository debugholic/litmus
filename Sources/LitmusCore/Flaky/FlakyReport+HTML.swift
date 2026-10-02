import Foundation

extension FlakyReport {
    /// One page in the look of the mutation report's front: what was run,
    /// what was not stable and why, what ran once for reaching a server, and
    /// what passed every time.
    func html() -> String {
        func escape(_ text: String) -> String { StrykerReport.escape(text) }

        let unstable = self.unstable
        let servers = self.servers
        let steady = runs.flatMap { run in run.verdicts.filter(\.isStable).map { (run.target, $0) } }
        let several = runs.count > 1

        func card(_ value: String, _ label: String, _ note: String, _ grade: String = "") -> String {
            """
            <div class="card"><div class="value \(grade)">\(value)</div>\
            <div class="label">\(label)</div><div class="muted">\(note)</div></div>
            """
        }
        func place(_ target: String, _ verdict: FlakyRun.Verdict) -> String {
            [several ? target : nil, verdict.file].compactMap { $0 }.map(escape).joined(separator: " · ")
        }

        var body: [String] = []
        let scopeLine = scope.map { "\(testCount) test(s) \($0)" } ?? "\(testCount) test(s)"
        let together = scope == nil ? "the suite" : "them together"
        body.append("<div class=\"top\"><h1>Flaky<span>Litmus</span></h1>"
            + "<div class=\"actions\">\(mutation?.button("← Summary") ?? "")</div></div>")
        body.append("<p class=\"muted\">\(escape(scopeLine)) in \(runs.count) target(s): each alone before, "
            + "\(together) \(asked) time(s), each alone again after</p>")

        body.append("<div class=\"cards\">")
        body.append(card("\(testCount)", "Tests run", "chosen for reaching something that can vary"))
        body.append(card("\(unstable.count)", "Not stable", "a result that changed between runs",
                         unstable.isEmpty ? "good" : "bad"))
        body.append(card("\(servers.count)", "Reached a server", "run alone once, not again",
                         servers.isEmpty ? "" : "warn"))
        body.append(card("\(asked)", "Runs together", scope == nil ? "the whole suite each time" : "the changed tests each time"))
        body.append("</div>")

        if !unstable.isEmpty {
            body.append("<h2>Not stable</h2>")
            body.append("<div class=\"frame\"><table class=\"fixed\"><tr><th>Test</th><th>Why</th><th>Where</th></tr>")
            for (target, verdict) in unstable {
                body.append("<tr><td><code>\(escape(verdict.name))</code></td>"
                    + "<td>\(escape(verdict.reasons.joined(separator: "; ")))"
                    + verdict.fixes.map { "<div class=\"muted\">\(escape($0))</div>" }.joined() + "</td>"
                    + "<td class=\"muted\">\(place(target, verdict))</td></tr>")
            }
            body.append("</table></div>")
        }

        if !servers.isEmpty {
            body.append("<h2>Reached a server</h2>")
            body.append("<p class=\"muted\">Each rerun would be a request to it; <code>--allow-server</code> reruns them anyway. "
                + "\(escape(FlakyRun.Fix.server))</p>")
            body.append("<div class=\"frame\"><table class=\"fixed\"><tr><th>Test</th><th>Where</th></tr>")
            for (target, verdict) in servers {
                body.append("<tr><td><code>\(escape(verdict.name))</code></td><td class=\"muted\">\(place(target, verdict))</td></tr>")
            }
            body.append("</table></div>")
        }

        if !steady.isEmpty {
            body.append("<h2>Passed every time</h2>")
            body.append("<details><summary>\(steady.count) test(s)</summary><table>")
            for (target, verdict) in steady {
                body.append("<tr><td><code>\(escape(verdict.name))</code> <span class=\"muted\">\(place(target, verdict))</span></td></tr>")
            }
            body.append("</table></details>")
        }

        var stops: [String] = []
        for run in runs {
            if let stop = run.stop {
                let what = stop.hung ? "stopped: a pass hung" : "the test process went down"
                let at = run.stoppedIn.map { "while \(run.names[$0] ?? $0) ran on its own" }
                    ?? "in \(stop.phase.rawValue) pass \(stop.index + 1)"
                stops.append("\(run.target): \(what) \(at); the passes after it did not run")
            } else if run.suiteRuns < asked {
                stops.append("\(run.target): ran together \(run.suiteRuns) of \(asked) time(s)")
            }
        }
        if !stops.isEmpty {
            body.append("<h2>Cut short</h2>")
            stops.forEach { body.append("<p class=\"bad\">\(escape($0))</p>") }
        }

        if !calm.isEmpty || !skipped.isEmpty {
            body.append("<h2>Left out</h2>")
            if !calm.isEmpty {
                body.append("<details><summary>\(calm.count) changed test(s) that reach nothing that can vary</summary><table>")
                calm.forEach { body.append("<tr><td><code>\(escape($0))</code></td></tr>") }
                body.append("</table></details>")
            }
            skipped.forEach { body.append("<p class=\"muted\">\(escape($0.target)) — \(escape($0.reason))</p>") }
        }

        body.append("<h2>Run</h2>")
        if let run { body.append("<p class=\"muted\">\(escape(run.line))</p>") }
        if duration > 0 {
            var parts = build > 0 ? ["build \(Report.duration(build))"] : []
            if runs.count == 1, let only = runs.first { parts += Self.timing(only) }
            body.append("<p class=\"muted\">took \(Report.duration(duration))"
                + (parts.isEmpty ? "" : " — " + escape(parts.joined(separator: ", "))) + "</p>")
            if several {
                for run in runs {
                    body.append("<p class=\"muted\">\(escape(run.target)): \(escape(Self.timing(run).joined(separator: ", ")))</p>")
                }
            }
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Litmus flaky report</title>
        \(StrykerReport.frontStyle)
        <style>body { margin: 0; padding: 0 16px; }</style>
        </head>
        <body>
        <main class="litmus">
        \(body.joined(separator: "\n"))
        </main>
        <script>
        if (window.matchMedia && matchMedia("(prefers-color-scheme: dark)").matches) {
          document.querySelector(".litmus").dataset.theme = "dark";
          document.body.style.background = "oklch(0.21 0.006 285.885)";
        }
        </script>
        </body>
        </html>
        """
    }
}
