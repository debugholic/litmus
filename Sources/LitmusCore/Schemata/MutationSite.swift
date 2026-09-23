import SwiftSyntax

/// One change Litmus can make, and where it sits.
struct MutationSite {
    /// Matches `Mutant.switchName`; the runner rebuilds this string to turn the
    /// mutation on, so the two have to be assembled the same way.
    let id: String
    let position: SourcePosition
    let `operator`: String
    let description: String
    let mutation: Mutation
    /// See `Mutant.evaluatedOnce`.
    let evaluatedOnce: Bool
    /// See `Mutant.change`.
    let change: Change?
}

extension MutationSite {
    /// What to change.
    enum Mutation {
        /// `&&` to `||`, `==` to `!=`, and so on.
        case swapOperator(element: Int, replacement: String)
        /// `a ? b : c` to `a ? c : b`.
        case swapTernary(element: Int)
        /// Drops a call whose result is discarded. If nothing fails, nothing
        /// was checking that the call happened.
        case removeStatement
        /// `true` to `false`, or `false` to `true`.
        case flipBoolean
        /// A condition's expression to its negation.
        case negateCondition
    }
}

/// Where a node sits in the original file, and what kind of node it is.
///
/// Sites are keyed by span rather than by node, because identity does not
/// survive a rewrite: every edit produces fresh nodes. Offsets taken from the
/// original tree keep matching while it is being rebuilt around them.
///
/// The kind is part of the key because offsets alone do not separate a
/// statement from the expression that fills it — `self != .none` as a getter's
/// only statement spans exactly the same bytes either way, and the expression's
/// mutation would be applied a second time as a statement guard.
struct SourceSpan: Hashable {
    let kind: SyntaxKind
    let start: Int
    let end: Int

    init(_ node: some SyntaxProtocol) {
        kind = node.kind
        start = node.position.utf8Offset
        end = node.endPosition.utf8Offset
    }
}
