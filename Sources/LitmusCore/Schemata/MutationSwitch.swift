import SwiftSyntax

/// Puts a mutation behind an environment flag, in the place it happens.
///
/// An operator swap becomes a ternary around the expression it sits in, and a
/// removed statement becomes a guarded statement:
///
/// ```swift
/// guard (__litmus_x ? (a || b) : (a && b)) else { return }
/// if !__litmus_y { actions.addBookmark(duration) }
/// ```
///
/// Everything is compiled once and selected at run time, so a suite of mutants
/// costs one build rather than one build each.
///
/// The earlier version wrapped the whole enclosing block instead, one copy per
/// mutant. That was Muter's shape, and it had to be: wrapping a single
/// statement would trap a `let` inside a branch where the rest of the block
/// could not see it. An expression binds nothing, so it can be switched where
/// it stands — and the cost stops multiplying through nested blocks.
///
/// Adapted from Muter (MIT) — see NOTICE.
enum MutationSwitch {
    /// `(flag ? (mutated) : (original))`
    static func expression(_ sites: [MutationSite], around base: ExprSyntax) -> ExprSyntax {
        guard let sequence = base.as(SequenceExprSyntax.self) else { return base }

        // Trivia belongs to the wrapper, not to the copies inside it.
        let bare = sequence.with(\.leadingTrivia, []).with(\.trailingTrivia, [])

        // Built from the inside out, so the original ends up as the last else.
        var result = parenthesized(ExprSyntax(bare))

        for site in sites.reversed() {
            guard let mutated = site.mutation.apply(to: bare) else { continue }

            result = parenthesized(
                ExprSyntax(
                    TernaryExprSyntax(
                        condition: flag(site.id),
                        questionMark: .infixQuestionMarkToken(
                            leadingTrivia: .space,
                            trailingTrivia: .space
                        ),
                        thenExpression: parenthesized(ExprSyntax(mutated)),
                        colon: .colonToken(leadingTrivia: .space, trailingTrivia: .space),
                        elseExpression: result
                    )
                )
            )
        }

        return result
            .with(\.leadingTrivia, sequence.leadingTrivia)
            .with(\.trailingTrivia, sequence.trailingTrivia)
    }

    /// `if !flag { statement }`
    ///
    /// Guarding the statement costs one line. Copying the block to leave the
    /// statement out of one copy would cost the whole block.
    static func statement(
        _ site: MutationSite,
        around base: CodeBlockItemSyntax
    ) -> CodeBlockItemSyntax {
        let negated = PrefixOperatorExprSyntax(
            operator: .prefixOperator("!"),
            expression: flag(site.id).with(\.trailingTrivia, .space)
        )

        let guarded = IfExprSyntax(
            ifKeyword: .keyword(.if, leadingTrivia: base.leadingTrivia, trailingTrivia: .space),
            conditions: ConditionElementListSyntax([
                ConditionElementSyntax(condition: .expression(ExprSyntax(negated))),
            ]),
            body: CodeBlockSyntax(
                leftBrace: .leftBraceToken(trailingTrivia: .space),
                statements: CodeBlockItemListSyntax([
                    base.with(\.leadingTrivia, []).with(\.trailingTrivia, .space),
                ]),
                rightBrace: .rightBraceToken()
            )
        )

        return CodeBlockItemSyntax(item: .expr(ExprSyntax(guarded)))
            .with(\.trailingTrivia, base.trailingTrivia)
    }

    /// The variable that names the mutant switched on.
    ///
    /// One variable holding a name, rather than one variable per mutant, so a
    /// process can move from one mutant to the next by setting it again.
    static let activeVariable = "LITMUS_ACTIVE"

    /// `private var <flag>: Bool { __litmus_on("<id>") }`
    ///
    /// Read each time it is evaluated, not once at launch. A launch is most of
    /// what a mutant costs on a simulator — installing the app and starting
    /// the runner came to 85 of 115 seconds — so the tests now run many
    /// mutants in one process, switching between them as they go.
    static func declaration(id: String) -> String {
        "private var \(flagName(id)): Bool { __litmus_on(\"\(id)\") }"
    }

    /// The lookup every switch in a file goes through.
    ///
    /// `getenv` rather than `ProcessInfo`: ProcessInfo's copy of the
    /// environment does not see a later `setenv`, and later is the point.
    static let lookup = """
    private func __litmus_on(_ id: String) -> Bool {
        guard let active = getenv("\(activeVariable)") else { return false }
        return String(cString: active) == id
    }
    """

    /// The identifier standing in for a mutant's environment variable.
    ///
    /// A file stem can contain `+`, which is fine inside a string literal and
    /// not fine in an identifier, so anything that is not a word character
    /// becomes an underscore.
    static func flagName(_ id: String) -> String {
        let sanitized = id.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
        return "__litmus_" + String(sanitized)
    }

    private static func flag(_ id: String) -> ExprSyntax {
        ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier(flagName(id))))
    }

    private static func parenthesized(_ expression: ExprSyntax) -> ExprSyntax {
        ExprSyntax(
            TupleExprSyntax(
                elements: LabeledExprListSyntax([
                    LabeledExprSyntax(expression: expression),
                ])
            )
        )
    }
}

extension MutationSite.Mutation {
    /// Applies the change to a sequence whose children have already been
    /// rewritten.
    ///
    /// Elements are addressed by index. `Parser.parse` leaves operators
    /// unfolded, so `a && b` arrives as the three elements of a sequence and an
    /// index into them stays valid however the children are rebuilt.
    func apply(to sequence: SequenceExprSyntax) -> SequenceExprSyntax? {
        var elements = Array(sequence.elements)

        switch self {
        case let .swapOperator(element, replacement):
            guard
                element < elements.count,
                let original = elements[element].as(BinaryOperatorExprSyntax.self)
            else { return nil }

            elements[element] = ExprSyntax(
                original.with(
                    \.operator,
                    .binaryOperator(
                        replacement,
                        leadingTrivia: original.operator.leadingTrivia,
                        trailingTrivia: original.operator.trailingTrivia
                    )
                )
            )

        case let .swapTernary(element):
            // The else branch is the sequence element after the `? then :`, so
            // the swap moves it inside and pushes the then branch out.
            guard
                element + 1 < elements.count,
                let ternary = elements[element].as(UnresolvedTernaryExprSyntax.self)
            else { return nil }

            let thenExpression = ternary.thenExpression
            let elseExpression = elements[element + 1]

            elements[element] = ExprSyntax(
                ternary.with(
                    \.thenExpression,
                    elseExpression
                        .with(\.leadingTrivia, thenExpression.leadingTrivia)
                        .with(\.trailingTrivia, thenExpression.trailingTrivia)
                )
            )
            elements[element + 1] = thenExpression
                .with(\.leadingTrivia, elseExpression.leadingTrivia)
                .with(\.trailingTrivia, elseExpression.trailingTrivia)

        case .removeStatement:
            return nil
        }

        return sequence.with(\.elements, ExprListSyntax(elements))
    }
}
