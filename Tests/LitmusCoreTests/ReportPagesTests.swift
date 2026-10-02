import Foundation
import Testing

@testable import LitmusCore

@Suite("Report pages")
struct ReportPagesTests {
    /// The caches folder, with a project's mutation copy in it.
    private let caches = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("litmus-pages-\(UUID().uuidString)")
    private var mutation: URL { caches.appendingPathComponent("My App-1a2b3c") }
    private var flaky: URL { ReportPages.flakyFolder(besides: mutation) }

    private func mutationPage() throws -> String {
        try Report(
            MutationRun.Summary(results: [], duration: 1),
            flaky: ReportPages.linkToFlaky(from: mutation)
        ).rendered(as: .html)
    }

    private func flakyPage() throws -> String {
        try FlakyReport(runs: [], asked: 1, mutation: ReportPages.linkToMutation(from: flaky)).rendered(as: .html)
    }

    @Test("keeps the flaky run's copy beside the mutation run's, under the same name")
    func folders() {
        #expect(flaky == caches.appendingPathComponent("flaky").appendingPathComponent("My App-1a2b3c"))
    }

    @Test("links each page to the other, hidden until it is there")
    func hiddenUntilThere() throws {
        defer { try? FileManager.default.removeItem(at: caches) }
        try FileManager.default.createDirectory(at: mutation, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: flaky, withIntermediateDirectories: true)

        let first = try mutationPage()
        #expect(first.contains("Flaky →"))
        #expect(first.contains("href=\"\(flaky.appendingPathComponent(ReportPages.flaky).absoluteString)\""))
        #expect(first.contains("data-litmus-link hidden>Flaky →"))
        let firstPage = mutation.appendingPathComponent(ReportPages.mutation)
        try first.write(to: firstPage, atomically: true, encoding: .utf8)

        // The flaky run, after: its own button shows at once, and it shows
        // the one in the page written before it.
        let second = try flakyPage()
        #expect(second.contains("<h1>Flaky<span>Litmus</span></h1>"))
        #expect(second.contains("href=\"\(firstPage.absoluteString)\""))
        #expect(second.contains("data-litmus-link>← Summary"))
        try ReportPages.reveal(in: firstPage)

        let revealed = try String(contentsOf: firstPage, encoding: .utf8)
        #expect(revealed.contains("data-litmus-link>Flaky →"))
        #expect(revealed == first.replacingOccurrences(of: "data-litmus-link hidden>", with: "data-litmus-link>"))
    }

    @Test("leaves a page that is not there alone")
    func revealNothing() throws {
        try ReportPages.reveal(in: mutation.appendingPathComponent(ReportPages.mutation))
        #expect(!FileManager.default.fileExists(atPath: mutation.path))
    }
}
