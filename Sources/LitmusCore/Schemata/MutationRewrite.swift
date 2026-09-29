import SwiftParser
import SwiftSyntax

/// Applies every mutation in one pass, leaving each one switched off.
struct MutationRewrite {
    let sites: [SourceSpan: [MutationSite]]
    /// Sites to switch by copying their expression; see `OperatorCall`.
    var copied: Set<String> = []

    func callAsFunction(_ tree: SourceFileSyntax) -> SourceFileSyntax {
        Rewriter(sites: sites, copied: copied).rewrite(tree).as(SourceFileSyntax.self) ?? tree
    }
}

/// `SyntaxRewriter` already walks the original tree and builds a new one, so
/// calling `super.visit` first gives bottom-up order for free: by the time a
/// node is switched, its children carry their own switches. The node handed to
/// `visit` is still the original, which is why a span taken from it keeps
/// matching.
private final class Rewriter: SyntaxRewriter {
    private let sites: [SourceSpan: [MutationSite]]
    private let copied: Set<String>

    init(sites: [SourceSpan: [MutationSite]], copied: Set<String>) {
        self.sites = sites
        self.copied = copied
    }

    override func visit(_ node: SequenceExprSyntax) -> ExprSyntax {
        let span = SourceSpan(node)
        let base = super.visit(node)

        guard let found = sites[span], !found.isEmpty else { return base }

        return MutationSwitch.expression(found, around: base, copied: copied)
    }

    override func visit(_ node: BooleanLiteralExprSyntax) -> ExprSyntax {
        let span = SourceSpan(node)
        let base = super.visit(node)

        guard
            let site = sites[span]?.first,
            case .flipBoolean = site.mutation,
            let literal = base.as(BooleanLiteralExprSyntax.self)
        else { return base }

        let flipped = literal.with(
            \.literal,
            .keyword(literal.literal.tokenKind == .keyword(.true) ? .false : .true)
        )
        return MutationSwitch.replacing(site, original: base, with: ExprSyntax(flipped))
    }

    override func visit(_ node: ConditionElementSyntax) -> ConditionElementSyntax {
        let span = SourceSpan(node)
        let base = super.visit(node)

        guard
            let site = sites[span]?.first,
            case .negateCondition = site.mutation,
            case let .expression(expression) = base.condition
        else { return base }

        let switched = OperatorCall.call(OperatorCall.negationHelper, site, [expression])
            .with(\.leadingTrivia, expression.leadingTrivia)
            .with(\.trailingTrivia, expression.trailingTrivia)
        return base.with(\.condition, .expression(switched))
    }

    override func visit(_ node: ReturnStmtSyntax) -> StmtSyntax {
        let span = SourceSpan(node)
        let base = super.visit(node)

        guard
            let site = sites[span]?.first,
            case let .replaceReturn(text) = site.mutation,
            let statement = base.as(ReturnStmtSyntax.self),
            let expression = statement.expression
        else { return base }

        var parser = Parser(text)
        let empty = ExprSyntax.parse(from: &parser)
        let switched = MutationSwitch.replacing(site, original: expression, with: empty)
        return StmtSyntax(statement.with(\.expression, switched))
    }

    override func visit(_ node: CodeBlockItemSyntax) -> CodeBlockItemSyntax {
        let span = SourceSpan(node)
        let base = super.visit(node)

        // One statement can only be removed once, so extra sites on the same
        // span would be the same mutation twice.
        guard
            let site = sites[span]?.first,
            case .removeStatement = site.mutation
        else { return base }

        return MutationSwitch.statement(site, around: base)
    }
}
