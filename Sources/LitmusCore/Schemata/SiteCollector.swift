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

        // `+` joins strings and arrays as well as numbers, and `-` does
        // neither. A literal beside it settles which, without types.
        if token == .changeArithmeticOperator, element.sequence.joinsCollections {
            return .visitChildren
        }

        record(
            node,
            at: node.operator.startLocation(converter: converter),
            on: SourceSpan(element.sequence),
            description: "changed \(text) to \(replacement)",
            mutation: .swapOperator(element: element.index, replacement: replacement),
            region: element.sequence
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
            node,
            at: node.startLocation(converter: converter),
            on: SourceSpan(element.sequence),
            description: "swapped the branches of a ternary",
            mutation: .swapTernary(element: element.index),
            region: element.sequence
        )

        return .visitChildren
    }

    // MARK: - boolean literals

    override func visit(_ node: BooleanLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard `operator` == .flipBooleanLiteral, node.isRuntimeValue else { return .skipChildren }

        let flipped = node.literal.tokenKind == .keyword(.true) ? "false" : "true"
        record(
            node,
            at: node.startLocation(converter: converter),
            on: SourceSpan(node),
            description: "changed \(node.literal.text) to \(flipped)",
            mutation: .flipBoolean,
            region: node,
            replacement: flipped
        )

        return .skipChildren
    }

    // MARK: - negated conditions

    override func visit(_ node: ConditionElementSyntax) -> SyntaxVisitorContinueKind {
        guard `operator` == .negateCondition, case let .expression(condition) = node.condition else {
            return .visitChildren
        }

        record(
            node,
            at: node.startLocation(converter: converter),
            on: SourceSpan(node),
            description: "negated the condition",
            mutation: .negateCondition,
            region: condition,
            replacement: "!(\(condition.trimmedDescription))"
        )

        return .visitChildren
    }

    // MARK: - removed side effects

    override func visit(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind {
        guard `operator` == .removeSideEffects, node.isRemovableCall else {
            return .visitChildren
        }

        record(
            node,
            at: node.startLocation(converter: converter),
            on: SourceSpan(node),
            description: node.removedCallDescription,
            mutation: .removeStatement,
            region: node,
            replacement: ""
        )

        return .visitChildren
    }

    // MARK: - helpers

    private func record(
        _ node: some SyntaxProtocol,
        at location: SourceLocation,
        on span: SourceSpan,
        description: String,
        mutation: MutationSite.Mutation,
        region: some SyntaxProtocol,
        replacement: String? = nil
    ) {
        let position = SourcePosition(location)

        // The mutated text of a sequence comes from the mutation itself, so
        // the report shows exactly what the switch turns on.
        let mutated = replacement
            ?? region.as(SequenceExprSyntax.self).flatMap { mutation.apply(to: $0)?.trimmedDescription }
        let start = converter.location(for: region.positionAfterSkippingLeadingTrivia)
        let end = converter.location(for: region.endPositionBeforeTrailingTrivia)
        let change = mutated.map {
            Change(
                startLine: start.line, startColumn: start.column,
                endLine: end.line, endColumn: end.column,
                original: region.trimmedDescription, replacement: $0,
                function: node.enclosingDeclarationName
            )
        }

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
                mutation: mutation,
                evaluatedOnce: node.isEvaluatedOnce,
                change: change
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
    /// `removed the call to insert(_:at:)`, named the way Swift documentation
    /// names a function, so the report says what went missing.
    var removedCallDescription: String {
        guard case let .expr(expression) = item,
              let call = expression.as(FunctionCallExprSyntax.self)
        else { return "removed a call" }

        let base = call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
            ?? call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
        guard let base else { return "removed a call" }

        var labels = call.arguments.map { ($0.label?.text ?? "_") + ":" }
        if call.trailingClosure != nil { labels.append("_:") }
        return "removed the call to \(base)(\(labels.joined()))"
    }
}

private extension SyntaxProtocol {
    /// `Type.function(label:)`, `Type.property`, or `Type.init(label:)`,
    /// for the declaration the node sits in. Closures are looked through:
    /// a closure's code belongs to the function that wrote it.
    var enclosingDeclarationName: String? {
        var member: String?
        var types: [String] = []

        func labels(_ parameters: FunctionParameterListSyntax) -> String {
            parameters.map { $0.firstName.text + ":" }.joined()
        }

        var current = parent
        while let node = current {
            if member == nil {
                if let function = node.as(FunctionDeclSyntax.self) {
                    member = "\(function.name.text)(\(labels(function.signature.parameterClause.parameters)))"
                } else if let initializer = node.as(InitializerDeclSyntax.self) {
                    member = "init(\(labels(initializer.signature.parameterClause.parameters)))"
                } else if node.is(DeinitializerDeclSyntax.self) {
                    member = "deinit"
                } else if let subscriptDecl = node.as(SubscriptDeclSyntax.self) {
                    member = "subscript(\(labels(subscriptDecl.parameterClause.parameters)))"
                } else if let variable = node.as(VariableDeclSyntax.self),
                          variable.isMemberOrGlobal,
                          let name = variable.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                    // A local `let` is part of its function, not a name of its own.
                    member = name
                }
            }

            if let type = node.as(ClassDeclSyntax.self) { types.insert(type.name.text, at: 0) }
            else if let type = node.as(StructDeclSyntax.self) { types.insert(type.name.text, at: 0) }
            else if let type = node.as(EnumDeclSyntax.self) { types.insert(type.name.text, at: 0) }
            else if let type = node.as(ActorDeclSyntax.self) { types.insert(type.name.text, at: 0) }
            else if let type = node.as(ExtensionDeclSyntax.self) {
                types.insert(type.extendedType.trimmedDescription, at: 0)
            }

            current = node.parent
        }

        guard let member else { return types.isEmpty ? nil : types.joined(separator: ".") }
        return (types + [member]).joined(separator: ".")
    }
}

private extension SequenceExprSyntax {
    /// Has a string, array or dictionary literal among its operands.
    var joinsCollections: Bool {
        elements.contains {
            $0.is(StringLiteralExprSyntax.self)
                || $0.is(ArrayExprSyntax.self)
                || $0.is(DictionaryExprSyntax.self)
        }
    }
}

private extension BooleanLiteralExprSyntax {
    /// A literal that is a value at run time, rather than something the
    /// compiler reads.
    ///
    /// `#if true`, an attribute's argument and an enum's raw value have to
    /// stay literals. A default argument can be read from a public function's
    /// signature, where a file's private switch is out of reach. A pattern is
    /// matched rather than evaluated.
    var isRuntimeValue: Bool {
        var current = parent
        while let node = current {
            if node.is(IfConfigClauseSyntax.self)
                || node.is(AttributeSyntax.self)
                || node.is(EnumCaseElementSyntax.self)
                || node.is(FunctionParameterSyntax.self)
                || node.is(EnumCaseParameterSyntax.self)
                || node.is(ExpressionPatternSyntax.self)
                || node.is(MacroExpansionExprSyntax.self) {
                return false
            }
            if node.is(CodeBlockSyntax.self) || node.is(MemberBlockSyntax.self) {
                return true
            }
            current = node.parent
        }
        return true
    }
}

private extension SyntaxProtocol {
    /// Inside the initial value of a global or a static property.
    ///
    /// Swift runs those once, the first time they are read, and keeps the
    /// result. Anything a function, an initializer or an accessor runs is run
    /// again on every call, so reaching one of those first means no. Closures
    /// do not stop the walk: `static let x = { … }()` runs its body once too.
    var isEvaluatedOnce: Bool {
        var current = parent
        while let node = current {
            if node.is(FunctionDeclSyntax.self)
                || node.is(InitializerDeclSyntax.self)
                || node.is(DeinitializerDeclSyntax.self)
                || node.is(SubscriptDeclSyntax.self)
                || node.is(AccessorBlockSyntax.self) {
                return false
            }

            if let variable = node.as(VariableDeclSyntax.self),
               variable.isStatic || variable.isGlobal {
                return true
            }

            current = node.parent
        }

        return false
    }
}

private extension VariableDeclSyntax {
    var isStatic: Bool {
        modifiers.contains {
            $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
        }
    }

    /// Declared at file scope.
    /// A type's property, or a global: something a reader would look up by name.
    var isMemberOrGlobal: Bool {
        parent?.is(MemberBlockItemSyntax.self) == true || isGlobal
    }

    var isGlobal: Bool {
        parent?.as(CodeBlockItemSyntax.self)?
            .parent?.as(CodeBlockItemListSyntax.self)?
            .parent?.is(SourceFileSyntax.self) ?? false
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
