import SwiftSyntax

/// Walks a file and records every place an operator can change something.
///
/// Sites are grouped by the node that will carry the switch: the expression an
/// operator sits in, or the statement to be dropped.
final class SiteCollector: SyntaxVisitor {
    private let `operator`: MutationOperator
    private let fileName: String
    private let converter: SourceLocationConverter

    private(set) var sites: [SourceSpan: [MutationSite]] = [:]

    init(operator: MutationOperator, fileName: String, converter: SourceLocationConverter) {
        self.operator = `operator`
        self.fileName = fileName
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - token swaps

    override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard case let .token(token) = `operator` else { return .visitChildren }

        let text = node.operator.text
        guard
            let replacement = token.replacements[text],
            let element = sequenceElement(of: node)
        else {
            return .visitChildren
        }

        record(
            at: node.operator.startLocation(converter: converter),
            on: SourceSpan(element.sequence),
            description: "changed \(text) to \(replacement)",
            mutation: .swapOperator(element: element.index, replacement: replacement)
        )

        return .visitChildren
    }

    // MARK: - ternary swaps

    override func visit(_ node: UnresolvedTernaryExprSyntax) -> SyntaxVisitorContinueKind {
        guard
            `operator` == .swapTernary,
            let element = sequenceElement(of: node)
        else {
            return .visitChildren
        }

        record(
            at: node.startLocation(converter: converter),
            on: SourceSpan(element.sequence),
            description: "swapped the branches of a ternary",
            mutation: .swapTernary(element: element.index)
        )

        return .visitChildren
    }

    // MARK: - removed side effects

    override func visit(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind {
        guard `operator` == .removeSideEffects, node.isRemovableCall else {
            return .visitChildren
        }

        record(
            at: node.startLocation(converter: converter),
            on: SourceSpan(node),
            description: "removed a call whose result is unused",
            mutation: .removeStatement
        )

        return .visitChildren
    }

    // MARK: - helpers

    private func record(
        at location: SourceLocation,
        on span: SourceSpan,
        description: String,
        mutation: MutationSite.Mutation
    ) {
        let position = SourcePosition(location)

        sites[span, default: []].append(
            MutationSite(
                id: MutationSite.switchName(
                    fileName: fileName,
                    operator: `operator`.name,
                    position: position
                ),
                position: position,
                operator: `operator`.name,
                description: description,
                mutation: mutation
            )
        )
    }

    /// Where the node sits in the sequence it belongs to.
    ///
    /// `Parser.parse` leaves operators unfolded, so an operator and a ternary
    /// are both plain elements of a `SequenceExprSyntax` rather than nodes with
    /// operands of their own. An index into that list is what a mutation needs,
    /// and it stays valid after the children are rebuilt.
    private func sequenceElement(
        of node: some SyntaxProtocol
    ) -> (sequence: SequenceExprSyntax, index: Int)? {
        guard
            let list = node.parent?.as(ExprListSyntax.self),
            let sequence = list.parent?.as(SequenceExprSyntax.self),
            let index = list.enumerated().first(where: { $0.element.id == node.id })?.offset
        else {
            return nil
        }

        return (sequence, index)
    }
}

private extension CodeBlockItemSyntax {
    /// A call this operator can guard.
    ///
    /// The call has to stand alone as a statement — its value goes nowhere, so
    /// the only reason it is there is the effect it has — and guarding it has
    /// to leave something that still compiles. A mutant that fails to build
    /// tells the suite nothing and costs a run to find out.
    var isRemovableCall: Bool {
        guard case let .expr(expression) = item,
              let call = expression.as(FunctionCallExprSyntax.self),
              !call.isInitializerDelegation,
              !call.neverReturns,
              !isSoleValue
        else { return false }

        return true
    }

    /// Whether the block would lose its value if this statement were guarded.
    ///
    /// A block whose only statement is an expression is an implicit return:
    /// the statement *is* the block's value, so wrapping it in `if` leaves a
    /// getter or a closure with nothing to return. Swift settles this with
    /// types Litmus does not have, so only the cases that are unambiguous from
    /// syntax alone are treated as safe.
    var isSoleValue: Bool {
        guard let list = parent?.as(CodeBlockItemListSyntax.self), list.count == 1 else {
            return false
        }

        return !(list.parent?.as(CodeBlockSyntax.self)?.neverYieldsValue ?? false)
    }
}

private extension CodeBlockSyntax {
    /// Bodies that cannot stand in for a value, whatever their contents.
    var neverYieldsValue: Bool {
        guard let owner = parent else { return false }

        if let function = owner.as(FunctionDeclSyntax.self) {
            return function.signature.returnClause == nil
        }

        if let accessor = owner.as(AccessorDeclSyntax.self) {
            return accessor.accessorSpecifier.tokenKind != .keyword(.get)
        }

        return owner.is(InitializerDeclSyntax.self)
            || owner.is(DeinitializerDeclSyntax.self)
            || owner.is(ForStmtSyntax.self)
            || owner.is(WhileStmtSyntax.self)
            || owner.is(RepeatStmtSyntax.self)
            || owner.is(DeferStmtSyntax.self)
    }
}

private extension FunctionCallExprSyntax {
    /// `super.init(...)` and `self.init(...)`.
    ///
    /// An initializer has to reach its delegation on every path, so putting one
    /// behind a flag does not compile.
    var isInitializerDelegation: Bool {
        guard let member = calledExpression.as(MemberAccessExprSyntax.self) else { return false }
        return member.declName.baseName.tokenKind == .keyword(.`init`)
    }

    /// A call that never returns.
    ///
    /// Guarding one changes what happens *after* it, not just whether it runs.
    /// An initializer whose body is `fatalError(...)` satisfies the compiler
    /// because it cannot finish; behind a flag it can, and then it returns
    /// without having initialized anything. Litmus has no types here, so the
    /// standard library's traps are recognised by name.
    var neverReturns: Bool {
        let trapping: Set<String> = [
            "fatalError", "preconditionFailure", "abort", "exit",
        ]

        let name = calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
            ?? calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text

        return name.map(trapping.contains) ?? false
    }
}
