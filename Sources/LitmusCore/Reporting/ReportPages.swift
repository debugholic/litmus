import Foundation

/// The two pages litmus keeps for a project, a mutation run's and a flaky
/// run's, and the buttons between them.
///
/// Each run writes its own page, at its own time. A button to the other page
/// is written into both, but shown only once that page is there: a run
/// that finds it shows its own at once, and shows the one in the page
/// written before it.
public enum ReportPages {
    public static let mutation = "litmus-report.html"
    public static let flaky = "litmus-flaky-report.html"

    /// A button to the other page, and whether it is there yet. The address
    /// is the page's own, not one relative to this page, so a copy written
    /// with `--output` elsewhere goes to it as well.
    public struct Link: Sendable {
        public let href: String
        public let shown: Bool

        /// `<a class="button" …>`, hidden until the page it goes to is there.
        func button(_ label: String) -> String {
            "<a class=\"button\" href=\"\(StrykerReport.escape(href))\" \(Self.marker)\(shown ? "" : " hidden")>\(label)</a>"
        }

        static let marker = "data-litmus-link"
    }

    /// Where `litmus flaky` keeps its copy of a project: beside the mutation
    /// run's copy, in a folder of its own under the same name.
    public static func flakyFolder(besides mutationFolder: URL) -> URL {
        mutationFolder.deletingLastPathComponent()
            .appendingPathComponent("flaky")
            .appendingPathComponent(mutationFolder.lastPathComponent)
    }

    /// From a mutation run's page to the flaky run's of the same project.
    public static func linkToFlaky(from mutationFolder: URL) -> Link {
        let page = flakyFolder(besides: mutationFolder).appendingPathComponent(flaky)
        return Link(href: page.absoluteString, shown: exists(page))
    }

    /// From a flaky run's page back to the mutation run's.
    public static func linkToMutation(from flakyFolder: URL) -> Link {
        let page = flakyFolder.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(flakyFolder.lastPathComponent)
            .appendingPathComponent(mutation)
        return Link(href: page.absoluteString, shown: exists(page))
    }

    /// Shows the button in a page written before the one it goes to. A page
    /// that is not there, or has no such button, is left as it is.
    public static func reveal(in page: URL) throws {
        guard let html = try? String(contentsOf: page, encoding: .utf8) else { return }
        let hidden = "\(Link.marker) hidden>"
        guard html.contains(hidden) else { return }
        try html.replacingOccurrences(of: hidden, with: "\(Link.marker)>")
            .write(to: page, atomically: true, encoding: .utf8)
    }

    private static func exists(_ page: URL) -> Bool {
        FileManager.default.fileExists(atPath: page.path)
    }
}
