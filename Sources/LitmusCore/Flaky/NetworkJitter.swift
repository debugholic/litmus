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

    /// Where the helper notes that a call went to a server, for the flaky
    /// driver to leave its test out of the reruns.
    static let serverVariable = "LITMUS_FLAKY_SERVER"

    /// After the answer, not before the request: a late answer is what the
    /// code has to cope with. In the caller's isolation, so a call on the
    /// main actor stays there.
    ///
    /// A session of the project's own making goes to a server unless a
    /// `URLProtocol` of the project's stands in front of it. The shared one
    /// is the driver's to judge: a stub registered with `registerClass` is
    /// not in its configuration.
    static let helper = """
    private func \(helperName)<T>(
        _ upTo: UInt64,
        _ via: Any?,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> sending T
    ) async rethrows -> sending T {
        if let session = via as? URLSession, session !== URLSession.shared,
           let path = ProcessInfo.processInfo.environment["\(serverVariable)"],
           !(session.configuration.protocolClasses ?? []).contains(where: {
               let name = NSStringFromClass($0)
               return !name.hasPrefix("_NS") && !name.hasPrefix("NS")
           }) {
            FileManager.default.createFile(atPath: path, contents: Data())
        }
        let value = try await body()
        if upTo > 0 {
            try? await Task.sleep(nanoseconds: UInt64.random(in: 0...upTo) * 1_000_000)
        }
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
        for (site, via, hasTry) in finder.found.reversed() {
            // The `try` stays outside, on the helper, which rethrows: Swift
            // reads `try await x` as a try around the await. The call in the
            // closure needs one of its own.
            let start = site.positionAfterSkippingLeadingTrivia.utf8Offset
            let end = site.endPositionBeforeTrailingTrivia.utf8Offset
            let original = String(decoding: bytes[start..<end], as: UTF8.self)
            let body = hasTry ? original : "try " + original
            // In the parentheses, not trailing: in a `guard` or `if`
            // condition a trailing closure reads as the statement's body.
            let held = "await \(helperName)(\(milliseconds), \(via ?? "nil"), { \(body) })"
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
        /// `via` is the session the call is made on, when naming it again
        /// costs nothing: a name or a chain of names, never a call.
        var found: [(site: AwaitExprSyntax, via: String?, hasTry: Bool)] = []

        override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind {
            // `try await x.data(for:)` parses as an await around the call, or
            // around a `try` around it.
            let inner = node.expression
            if let call = NetworkJitter.networkCall(heading: inner) {
                let base = call.calledExpression.as(MemberAccessExprSyntax.self)?.base
                found.append((node, base.flatMap(NetworkJitter.plainName), inner.is(TryExprSyntax.self)))
                // A call inside its arguments would be inside the closure
                // already, and an edit inside an edit.
                return .skipChildren
            }
            return .visitChildren
        }
    }

    /// The network call an awaited expression starts with: the call itself,
    /// or what follows it — `.0`, `!`, `?.count` — read back to it. The whole
    /// expression goes in the closure, so what follows still applies.
    static func networkCall(heading expression: ExprSyntax) -> FunctionCallExprSyntax? {
        if let call = expression.as(FunctionCallExprSyntax.self) {
            if isNetworkCall(call) { return call }
            return networkCall(heading: call.calledExpression)
        }
        if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base {
            return networkCall(heading: base)
        }
        if let attempt = expression.as(TryExprSyntax.self) { return networkCall(heading: attempt.expression) }
        if let forced = expression.as(ForceUnwrapExprSyntax.self) { return networkCall(heading: forced.expression) }
        if let chained = expression.as(OptionalChainingExprSyntax.self) { return networkCall(heading: chained.expression) }
        if let subscripted = expression.as(SubscriptCallExprSyntax.self) { return networkCall(heading: subscripted.calledExpression) }
        return nil
    }

    /// `session`, `self.session`, `URLSession.shared`: read twice, they are
    /// the same thing. Anything else — a call, a subscript — is left unnamed.
    static func plainName(_ expression: ExprSyntax) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        if expression.is(SuperExprSyntax.self) { return nil }
        if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base,
           let name = plainName(base) {
            return "\(name).\(member.declName.baseName.text)"
        }
        return nil
    }

    static func isNetworkCall(_ call: FunctionCallExprSyntax) -> Bool {
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              let labels = calls[member.declName.baseName.text],
              let first = call.arguments.first?.label?.text
        else { return false }
        return labels.contains(first)
    }
}
