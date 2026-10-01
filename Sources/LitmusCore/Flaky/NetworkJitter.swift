import Foundation
import SwiftParser
import SwiftSyntax

/// Holds every network response back a random while, so a test that only
/// passes when the network answers fast, or in the order it was asked, shows
/// it.
///
/// A stub answers at once and in order, every run, and a race between two
/// requests never comes out the other way. A real server varies, but also
/// fails, limits and changes its data, and each rerun is another request to
/// it. Here the call still goes wherever it went — a stub, a mock, a server —
/// and only its answer is late, by a different amount each time.
///
/// By name, without types: an awaited `data(for:)`, `data(from:)`,
/// `upload(for:…)`, `download(for:)`, `download(from:)`, `bytes(for:)` or
/// `bytes(from:)`. Another API spelled the same is held back too, which costs
/// a wait and nothing else.
public enum NetworkJitter {
    /// The async `URLSession` calls, by name and first label.
    static let calls: [String: Set<String>] = [
        "data": ["for", "from"],
        "upload": ["for"],
        "download": ["for", "from"],
        "bytes": ["for", "from"],
    ]

    static let helperName = "__litmus_jitter"

    /// After the answer, not before the request: a late answer is what the
    /// code has to cope with. In the caller's isolation, so a call on the
    /// main actor stays there.
    static let helper = """
    private func \(helperName)<T>(
        _ upTo: UInt64,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> sending T
    ) async rethrows -> sending T {
        let value = try await body()
        try? await Task.sleep(nanoseconds: UInt64.random(in: 0...upTo) * 1_000_000)
        return value
    }
    """

    /// The source with each call held back up to `milliseconds`, and how many
    /// were.
    ///
    /// Edited as text at the positions the parse gives, latest first, so an
    /// edit never moves one still to make, and the rest of the file is left
    /// exactly as it was.
    public static func apply(to source: String, upTo milliseconds: Int) -> (source: String, calls: Int) {
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(Parser.parse(source: source))
        guard !finder.found.isEmpty else { return (source, 0) }

        var bytes = Array(source.utf8)
        for (site, hasTry) in finder.found.reversed() {
            // The `try` stays outside, on the helper, which rethrows: Swift
            // reads `try await x` as a try around the await. The call in the
            // closure needs one of its own.
            let start = site.positionAfterSkippingLeadingTrivia.utf8Offset
            let end = site.endPositionBeforeTrailingTrivia.utf8Offset
            let original = String(decoding: bytes[start..<end], as: UTF8.self)
            let body = hasTry ? original : "try " + original
            // In the parentheses, not trailing: in a `guard` or `if`
            // condition a trailing closure reads as the statement's body.
            let held = "await \(helperName)(\(milliseconds), { \(body) })"
            bytes.replaceSubrange(start..<end, with: Array(held.utf8))
        }

        let rewritten = String(decoding: bytes, as: UTF8.self)
        return (rewritten + "\n\n// Litmus: network responses held back.\n\(helper)\n", finder.found.count)
    }

    /// Every Swift file under `directory`, rewritten in place. Returns how
    /// many calls were held back, by file.
    public static func apply(under directory: URL, upTo milliseconds: Int) throws -> [String: Int] {
        var held: [String: Int] = [:]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return held
        }

        for case let url as URL in walker {
            if [".build", "build", "DerivedData", "Pods", "Carthage", "checkouts"].contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard url.pathExtension == "swift", let source = try? String(contentsOf: url, encoding: .utf8) else { continue }

            let (rewritten, calls) = apply(to: source, upTo: milliseconds)
            guard calls > 0 else { continue }
            try rewritten.write(to: url, atomically: true, encoding: .utf8)
            held[url.path] = calls
        }
        return held
    }

    private final class Finder: SyntaxVisitor {
        var found: [(site: AwaitExprSyntax, hasTry: Bool)] = []

        override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind {
            let inner = node.expression
            let call = inner.as(FunctionCallExprSyntax.self)
                ?? inner.as(TryExprSyntax.self)?.expression.as(FunctionCallExprSyntax.self)
            if let call, NetworkJitter.isNetworkCall(call) {
                found.append((node, inner.is(TryExprSyntax.self)))
                // A call inside its arguments would be inside the closure
                // already, and an edit inside an edit.
                return .skipChildren
            }
            return .visitChildren
        }
    }

    static func isNetworkCall(_ call: FunctionCallExprSyntax) -> Bool {
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              let labels = calls[member.declName.baseName.text],
              let first = call.arguments.first?.label?.text
        else { return false }
        return labels.contains(first)
    }
}
