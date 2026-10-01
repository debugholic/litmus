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
/// By name, without types, four ways a `URLSession` answers:
/// - awaited: `data(for:)`, `data(from:)`, `upload(for:…)`, `download(for:)`,
///   `download(from:)`, `bytes(for:)`, `bytes(from:)`, and any of them as the
///   value of an `async let`
/// - a completion handler on `dataTask(with:)`, `downloadTask(with:)` or
///   `uploadTask(with:…)`
/// - `dataTaskPublisher(for:)`
///
/// Another API spelled the same is held back too, which costs a wait and
/// nothing else. A task with no handler answers its delegate, which is left
/// alone.
public enum NetworkJitter {
    /// The async `URLSession` calls, by name and first label.
    static let calls: [String: Set<String>] = [
        "data": ["for", "from"],
        "upload": ["for"],
        "download": ["for", "from"],
        "bytes": ["for", "from"],
    ]
    static let tasks: Set<String> = ["dataTask", "downloadTask", "uploadTask"]
    static let publisher = "dataTaskPublisher"

    static let helperName = "__litmus_jitter"
    static let handlerHelperName = "__litmus_jitter_handler"
    static let publisherHelperName = "__litmus_jitter_publisher"

    /// Where the helpers note that a call went to a server, for the flaky
    /// driver to leave its test out of the reruns.
    static let serverVariable = "LITMUS_FLAKY_SERVER"

    /// A session of the project's own making goes to a server unless a
    /// `URLProtocol` of the project's stands in front of it. The shared one
    /// is the driver's to judge: a stub registered with `registerClass` is
    /// not in its configuration.
    static let serverCheck = """
    private func __litmus_note_server(_ via: Any?) {
        guard let session = via as? URLSession, session !== URLSession.shared,
              let path = ProcessInfo.processInfo.environment["\(serverVariable)"],
              !(session.configuration.protocolClasses ?? []).contains(where: {
                  let name = NSStringFromClass($0)
                  return !name.hasPrefix("_NS") && !name.hasPrefix("NS")
              })
        else { return }
        FileManager.default.createFile(atPath: path, contents: Data())
    }
    """

    /// After the answer, not before the request: a late answer is what the
    /// code has to cope with. In the caller's isolation, so a call on the
    /// main actor stays there.
    static let helper = """
    private func \(helperName)<T>(
        _ upTo: UInt64,
        _ via: Any?,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> sending T
    ) async rethrows -> sending T {
        __litmus_note_server(via)
        let value = try await body()
        if upTo > 0 {
            try? await Task.sleep(nanoseconds: UInt64.random(in: 0...upTo) * 1_000_000)
        }
        return value
    }
    """

    /// The handler is called a random while after the session would have
    /// called it, off the main thread as the session's own queue is. What it
    /// is handed crosses to that queue unchecked: the session hands it over
    /// once and never touches it again.
    static let handlerHelper = """
    private func \(handlerHelperName)<A, B, C>(
        _ upTo: UInt64,
        _ via: Any?,
        _ handler: @escaping @Sendable (A, B, C) -> Void
    ) -> @Sendable (A, B, C) -> Void {
        __litmus_note_server(via)
        return { a, b, c in
            nonisolated(unsafe) let answer = (a, b, c)
            let wait = upTo > 0 ? Double(UInt64.random(in: 0...upTo)) / 1000 : 0
            DispatchQueue.global().asyncAfter(deadline: .now() + wait) {
                handler(answer.0, answer.1, answer.2)
            }
        }
    }
    """

    /// Its answer a random while late, on a background queue, as the session
    /// delivers it: one wait for the request, and its value and its end
    /// handed on in order after it. The subscription and every demand pass
    /// at once. Combine's own operators were tried first: a `flatMap` holds a
    /// lock while it delivers, which a `switchToLatest` cancelling it from
    /// another thread waited on, and a `delay` hands on the subscription
    /// late too, which left a `switchToLatest` waiting for an answer it had
    /// not asked for.
    static let publisherHelper = """
    private func \(publisherHelperName)<P: Publisher>(
        _ upTo: UInt64,
        _ via: Any?,
        _ upstream: P
    ) -> __LitmusDelayed<P> {
        __litmus_note_server(via)
        return __LitmusDelayed(upstream: upstream, wait: upTo > 0 ? Int.random(in: 0...Int(upTo)) : 0)
    }

    private struct __LitmusDelayed<Upstream: Publisher>: Publisher {
        typealias Output = Upstream.Output
        typealias Failure = Upstream.Failure

        let upstream: Upstream
        let wait: Int

        func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            upstream.subscribe(Relay(downstream: subscriber, wait: wait))
        }

        private final class Relay<S: Subscriber>: Subscriber, Subscription, @unchecked Sendable
        where S.Input == Output, S.Failure == Failure {
            let downstream: S
            let wait: Int
            let queue = DispatchQueue(label: "litmus.jitter")
            let lock = NSLock()
            var subscription: (any Subscription)?
            var cancelled = false

            init(downstream: S, wait: Int) {
                self.downstream = downstream
                self.wait = wait
            }

            func receive(subscription: any Subscription) {
                lock.lock(); self.subscription = subscription; lock.unlock()
                downstream.receive(subscription: self)
            }

            func request(_ demand: Subscribers.Demand) {
                lock.lock(); let subscription = self.subscription; lock.unlock()
                subscription?.request(demand)
            }

            func cancel() {
                lock.lock(); cancelled = true; let subscription = self.subscription; self.subscription = nil; lock.unlock()
                subscription?.cancel()
            }

            private var isCancelled: Bool {
                lock.lock(); defer { lock.unlock() }
                return cancelled
            }

            func receive(_ input: Output) -> Subscribers.Demand {
                nonisolated(unsafe) let value = input
                queue.asyncAfter(deadline: .now() + .milliseconds(wait)) {
                    guard !self.isCancelled else { return }
                    let more = self.downstream.receive(value)
                    if more > 0 { self.request(more) }
                }
                return .none
            }

            func receive(completion: Subscribers.Completion<Failure>) {
                nonisolated(unsafe) let end = completion
                queue.asyncAfter(deadline: .now() + .milliseconds(wait)) {
                    guard !self.isCancelled else { return }
                    self.downstream.receive(completion: end)
                }
            }
        }
    }
    """

    /// One change to make: a span of the source and what goes there.
    struct Edit {
        let start: Int
        let end: Int
        let text: String
        let kind: Kind

        enum Kind { case awaited, handler, publisher }
    }

    /// The source with each call held back up to `milliseconds`, and how many
    /// were.
    ///
    /// Edited as text at the positions the parse gives, latest first, so an
    /// edit never moves one still to make, and the rest of the file is left
    /// exactly as it was.
    public static func apply(to source: String, upTo milliseconds: Int) -> (source: String, calls: Int) {
        let finder = Finder(source: Array(source.utf8), upTo: milliseconds)
        finder.walk(Parser.parse(source: source))
        guard !finder.edits.isEmpty else { return (source, 0) }

        var bytes = Array(source.utf8)
        for edit in finder.edits.sorted(by: { $0.start > $1.start }) {
            bytes.replaceSubrange(edit.start..<edit.end, with: Array(edit.text.utf8))
        }
        var rewritten = String(decoding: bytes, as: UTF8.self)

        let kinds = Set(finder.edits.map(\.kind))
        var helpers = [serverCheck]
        if kinds.contains(.awaited) { helpers.append(helper) }
        if kinds.contains(.handler) { helpers.append(handlerHelper) }
        if kinds.contains(.publisher) {
            helpers.append(publisherHelper)
            // The publisher helper names Combine's types; a file that only
            // reaches them through Foundation has not imported it.
            if !rewritten.contains("import Combine") { rewritten = "import Combine\n" + rewritten }
        }
        return (rewritten + "\n\n// Litmus: network responses held back.\n" + helpers.joined(separator: "\n") + "\n", finder.edits.count)
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
        let source: [UInt8]
        let upTo: Int
        var edits: [Edit] = []

        init(source: [UInt8], upTo: Int) {
            self.source = source
            self.upTo = upTo
            super.init(viewMode: .sourceAccurate)
        }

        private func text(_ node: some SyntaxProtocol) -> String {
            String(decoding: source[node.positionAfterSkippingLeadingTrivia.utf8Offset..<node.endPositionBeforeTrailingTrivia.utf8Offset], as: UTF8.self)
        }

        private func via(_ call: FunctionCallExprSyntax) -> String {
            call.calledExpression.as(MemberAccessExprSyntax.self)?.base.flatMap(NetworkJitter.plainName) ?? "nil"
        }

        private func replace(_ node: some SyntaxProtocol, with text: String, _ kind: Edit.Kind) {
            edits.append(Edit(
                start: node.positionAfterSkippingLeadingTrivia.utf8Offset,
                end: node.endPositionBeforeTrailingTrivia.utf8Offset,
                text: text,
                kind: kind
            ))
        }

        override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind {
            // `try await x.data(for:)` parses as an await around the call, or
            // around a `try` around it.
            let inner = node.expression
            guard let call = NetworkJitter.networkCall(heading: inner) else { return .visitChildren }

            // The `try` stays outside, on the helper, which rethrows. The
            // call in the closure needs one of its own. In the parentheses,
            // not trailing: in a `guard` or `if` condition a trailing closure
            // reads as the statement's body.
            let original = text(node)
            let body = inner.is(TryExprSyntax.self) ? original : "try " + original
            replace(node, with: "await \(helperName)(\(upTo), \(via(call)), { \(body) })", .awaited)
            // A call inside its arguments would be inside the closure
            // already, and an edit inside an edit.
            return .skipChildren
        }

        /// `async let x = s.data(for: r)`: the value is awaited where `x` is.
        override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
            guard node.modifiers.contains(where: { $0.name.tokenKind == .keyword(.async) }) else { return .visitChildren }
            for binding in node.bindings {
                guard let value = binding.initializer?.value,
                      !value.is(AwaitExprSyntax.self), !value.is(TryExprSyntax.self),
                      let call = NetworkJitter.networkCall(heading: value)
                else { continue }
                replace(value, with: "\(helperName)(\(upTo), \(via(call)), { try await \(text(value)) })", .awaited)
            }
            return .visitChildren
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else { return .visitChildren }
            let name = member.declName.baseName.text
            let first = node.arguments.first?.label?.text

            if name == NetworkJitter.publisher, first == "for" {
                replace(node, with: "\(publisherHelperName)(\(upTo), \(via(node)), \(text(node)))", .publisher)
                return .skipChildren
            }

            guard NetworkJitter.tasks.contains(name), first == "with" else { return .visitChildren }

            // The handler as an argument, or trailing. Either way it goes
            // into the parentheses, wrapped.
            if let labelled = node.arguments.first(where: { $0.label?.text == "completionHandler" }) {
                replace(labelled.expression, with: "\(handlerHelperName)(\(upTo), \(via(node)), \(text(labelled.expression)))", .handler)
                return .skipChildren
            }
            guard let trailing = node.trailingClosure else { return .visitChildren }
            let arguments = node.arguments.map { text($0) }.joined(separator: " ")
            let wrapped = "\(text(node.calledExpression))(\(arguments), completionHandler: "
                + "\(handlerHelperName)(\(upTo), \(via(node)), \(text(trailing))))"
            replace(node, with: wrapped, .handler)
            return .skipChildren
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
