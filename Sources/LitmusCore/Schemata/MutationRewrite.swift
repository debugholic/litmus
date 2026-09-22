import SwiftSyntax

/// Applies every mutation in one pass, leaving each one switched off.
struct MutationRewrite {
    let sites: [SourceSpan: [MutationSite]]

    func callAsFunction(_ tree: SourceFileSyntax) -> SourceFileSyntax {
        Rewriter(sites: sites).rewrite(tree).as(SourceFileSyntax.self) ?? tree
    }
}

/// `SyntaxRewriter` already walks the original tree and builds a new one, so
/// calling `super.visit` first gives bottom-up order for free: by the time a
/// node is switched, its children carry their own switches. The node handed to
/// `visit` is still the original, which is why a span taken from it keeps
/// matching.
private final class Rewriter: SyntaxRewriter {
    private let sites: [SourceSpan: [MutationSite]]

    init(sites: [SourceSpan: [MutationSite]]) {
        self.sites = sites
    }

    override func visit(_ node: SequenceExprSyntax) -> ExprSyntax {
        let span = SourceSpan(node)
        let base = super.visit(node)

        guard let found = sites[span], !found.isEmpty else { return base }

        return MutationSwitch.expression(found, around: base)
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
