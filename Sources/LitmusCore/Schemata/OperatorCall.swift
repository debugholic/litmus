import SwiftOperators
import SwiftSyntax

/// Switches an operator where it stands, by calling a function that picks it.
///
/// `a - b * c` with both operators mutated used to become the whole
/// expression three times over, nested in ternaries:
///
/// ```swift
/// (f1 ? (a + b * c) : (f2 ? (a - b / c) : (a - b * c)))
/// ```
///
/// Each mutant added a copy, and the type checker solves every copy's
/// literals together. A layout line with seven operators came to eight
/// copies, and Swift gave up on it after twenty seconds on every run, taking
/// all seven mutants with it. Here the expression is written once:
///
/// ```swift
/// __litmus_sub(f1, a, __litmus_mul(f2, b, c))
/// ```
///
/// The line type-checks in a tenth of the time the copies took. The helpers
/// are typed by protocol — numbers, `Comparable`, `Equatable` — because
/// passing the operator itself as a function made the checker try every
/// overload of `+` at once and give up again. An operand of some other type,
/// `Date - TimeInterval`, does not fit them; that mutant goes back to the
/// copy when the build says so.
enum OperatorCall {
    /// The helper for an operator. What it turns the operator into is
    /// `TokenOperator.replacements`, written out in the helper's body.
    static let helperNames: [String: String] = [
        "+": "__litmus_add", "-": "__litmus_sub", "*": "__litmus_mul", "/": "__litmus_div", "%": "__litmus_rem",
        "==": "__litmus_eq", "!=": "__litmus_ne",
        "<": "__litmus_lt", "<=": "__litmus_le", ">": "__litmus_gt", ">=": "__litmus_ge",
        "&&": "__litmus_and", "||": "__litmus_or",
    ]

    static let ternaryHelper = "__litmus_swap"
    /// A condition, negated when on. The condition is written once, rather
    /// than once as it is and once behind `!`.
    static let negationHelper = "__litmus_not"

    /// Helpers whose right side is evaluated only when needed, as `&&`, `||`
    /// and a ternary's branches are. An autoclosure cannot hold `await`, and a
    /// `try` inside one needs a `try` on the call.
    private static let lazy: Set<String> = ["__litmus_and", "__litmus_or", ternaryHelper]

    /// Declared once per file, beside the switches.
    static let helpers = """
    private func __litmus_add<T: AdditiveArithmetic>(_ on: Bool, _ a: T, _ b: T) -> T { on ? a - b : a + b }
    private func __litmus_sub<T: AdditiveArithmetic>(_ on: Bool, _ a: T, _ b: T) -> T { on ? a + b : a - b }
    private func __litmus_mul<T: FloatingPoint>(_ on: Bool, _ a: T, _ b: T) -> T { on ? a / b : a * b }
    private func __litmus_mul<T: BinaryInteger>(_ on: Bool, _ a: T, _ b: T) -> T { on ? a / b : a * b }
    private func __litmus_div<T: FloatingPoint>(_ on: Bool, _ a: T, _ b: T) -> T { on ? a * b : a / b }
    private func __litmus_div<T: BinaryInteger>(_ on: Bool, _ a: T, _ b: T) -> T { on ? a * b : a / b }
    private func __litmus_rem<T: BinaryInteger>(_ on: Bool, _ a: T, _ b: T) -> T { on ? a * b : a % b }
    private func __litmus_eq<T: Equatable>(_ on: Bool, _ a: T, _ b: T) -> Bool { on ? a != b : a == b }
    private func __litmus_eq<T>(_ on: Bool, _ a: T?, _ b: _OptionalNilComparisonType) -> Bool { on ? a != nil : a == nil }
    private func __litmus_eq<T>(_ on: Bool, _ a: _OptionalNilComparisonType, _ b: T?) -> Bool { on ? nil != b : nil == b }
    private func __litmus_ne<T: Equatable>(_ on: Bool, _ a: T, _ b: T) -> Bool { on ? a == b : a != b }
    private func __litmus_ne<T>(_ on: Bool, _ a: T?, _ b: _OptionalNilComparisonType) -> Bool { on ? a == nil : a != nil }
    private func __litmus_ne<T>(_ on: Bool, _ a: _OptionalNilComparisonType, _ b: T?) -> Bool { on ? nil == b : nil != b }
    private func __litmus_lt<T: Comparable>(_ on: Bool, _ a: T, _ b: T) -> Bool { on ? a >= b : a < b }
    private func __litmus_le<T: Comparable>(_ on: Bool, _ a: T, _ b: T) -> Bool { on ? a > b : a <= b }
    private func __litmus_gt<T: Comparable>(_ on: Bool, _ a: T, _ b: T) -> Bool { on ? a <= b : a > b }
    private func __litmus_ge<T: Comparable>(_ on: Bool, _ a: T, _ b: T) -> Bool { on ? a < b : a >= b }
    private func __litmus_and(_ on: Bool, _ a: Bool, _ b: @autoclosure () throws -> Bool) rethrows -> Bool { on ? try (a || b()) : try (a && b()) }
    private func __litmus_or(_ on: Bool, _ a: Bool, _ b: @autoclosure () throws -> Bool) rethrows -> Bool { on ? try (a && b()) : try (a || b()) }
    private func __litmus_not(_ on: Bool, _ c: Bool) -> Bool { on ? !c : c }
    private func __litmus_swap<T>(_ on: Bool, _ c: Bool, _ x: @autoclosure () throws -> T, _ y: @autoclosure () throws -> T) rethrows -> T { (c != on) ? try x() : try y() }
    """

    /// The sequence with every site it can take switched by a call, and the
    /// sites it could not take: an operator it has no helper for, an operand
    /// a lazy helper cannot hold, or one the build already sent back.
    ///
    /// Nil when the sequence does not fold — an operator the standard table
    /// does not know — and every site stays a copy.
    static func rewrite(
        _ sequence: SequenceExprSyntax,
        sites: [MutationSite],
        copied: Set<String>
    ) -> (expression: ExprSyntax, left: [MutationSite])? {
        var byElement: [Int: MutationSite] = [:]
        for site in sites where !copied.contains(site.id) {
            switch site.mutation {
            case let .swapOperator(element, _), let .swapTernary(element):
                byElement[element] = site
            default:
                break
            }
        }
        guard !byElement.isEmpty,
              let folded = try? OperatorTable.standardOperators.foldSingle(sequence)
        else { return nil }

        var builder = Builder(byElement: byElement)
        let expression = builder.rebuild(folded)

        // Every element counted once, or the indices went astray and a
        // switch would land on the wrong operator.
        guard builder.counter == sequence.elements.count else { return nil }

        let taken = builder.taken
        return (expression, sites.filter { !taken.contains($0.id) })
    }

    private struct Builder {
        let byElement: [Int: MutationSite]
        /// The sequence element the walk has reached. In order, a folded
        /// tree gives its elements back in the order the sequence had them.
        var counter = 0
        var taken: Set<String> = []

        mutating func rebuild(_ expression: ExprSyntax) -> ExprSyntax {
            if let infix = expression.as(InfixOperatorExprSyntax.self) {
                let left = rebuild(infix.leftOperand)
                let index = counter
                counter += 1
                let right = rebuild(infix.rightOperand)

                if let site = byElement[index],
                   let token = infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text,
                   let name = OperatorCall.helperNames[token],
                   OperatorCall.fits(name, lazily: [right]) {
                    taken.insert(site.id)
                    // The spaces around it kept: beside an operator left as
                    // written, `…skipped)+ separate` made `+` a postfix
                    // operator and the line no longer parsed.
                    return OperatorCall.call(name, site, [left, right])
                        .with(\.leadingTrivia, infix.leadingTrivia)
                        .with(\.trailingTrivia, infix.trailingTrivia)
                }
                return ExprSyntax(infix.with(\.leftOperand, left).with(\.rightOperand, right))
            }

            if let ternary = expression.as(TernaryExprSyntax.self) {
                let condition = rebuild(ternary.condition)
                let index = counter
                counter += 1
                let otherwise = rebuild(ternary.elseExpression)

                if let site = byElement[index], case .swapTernary = site.mutation,
                   OperatorCall.fits(OperatorCall.ternaryHelper, lazily: [ternary.thenExpression, otherwise]) {
                    taken.insert(site.id)
                    return OperatorCall.call(
                        OperatorCall.ternaryHelper, site, [condition, ternary.thenExpression, otherwise]
                    )
                    .with(\.leadingTrivia, ternary.leadingTrivia)
                    .with(\.trailingTrivia, ternary.trailingTrivia)
                }
                return ExprSyntax(ternary.with(\.condition, condition).with(\.elseExpression, otherwise))
            }

            // `x as T` and `x is T` were three elements: the value, the
            // keyword and the type.
            if let cast = expression.as(AsExprSyntax.self) {
                let inner = rebuild(cast.expression)
                counter += 2
                return ExprSyntax(cast.with(\.expression, inner))
            }
            if let check = expression.as(IsExprSyntax.self) {
                let inner = rebuild(check.expression)
                counter += 2
                return ExprSyntax(check.with(\.expression, inner))
            }

            counter += 1
            return expression
        }
    }

    private static func fits(_ name: String, lazily operands: [ExprSyntax]) -> Bool {
        guard lazy.contains(name) else { return true }
        return !operands.contains { operand in
            operand.tokens(viewMode: .sourceAccurate).contains {
                $0.tokenKind == .keyword(.try) || $0.tokenKind == .keyword(.await)
            }
        }
    }

    /// `name(flag, operands…)`, the flag first so it sits on the line the
    /// call starts on, where a compiler error on the call points.
    static func call(_ name: String, _ site: MutationSite, _ operands: [ExprSyntax]) -> ExprSyntax {
        let arguments = [MutationSwitch.flag(site.id)] + operands.map { $0.trimmed }
        return ExprSyntax(
            FunctionCallExprSyntax(
                calledExpression: ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier(name))),
                leftParen: .leftParenToken(),
                arguments: LabeledExprListSyntax(
                    arguments.enumerated().map { index, argument in
                        LabeledExprSyntax(
                            expression: argument,
                            trailingComma: index < arguments.count - 1 ? .commaToken(trailingTrivia: .space) : nil
                        )
                    }
                ),
                rightParen: .rightParenToken()
            )
        )
    }
}
