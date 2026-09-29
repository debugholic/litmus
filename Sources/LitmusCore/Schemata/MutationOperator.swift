import Foundation

/// The kinds of change Litmus knows how to make.
public enum MutationOperator: Equatable, Sendable, CaseIterable {
    case token(TokenOperator)
    case swapTernary
    case removeSideEffects
    /// `true` to `false`, and back.
    case flipBooleanLiteral
    /// `if x` to `if !x`, and the same for `guard` and `while`.
    case negateCondition
    /// `return x` to `return nil`, `false`, `0`, `""`, `[]` or `[:]`, by the
    /// declared return type.
    case replaceReturnValue

    public static var allCases: [MutationOperator] {
        TokenOperator.allCases.map(MutationOperator.token)
            + [.swapTernary, .removeSideEffects, .flipBooleanLiteral, .negateCondition, .replaceReturnValue]
    }

    public var name: String {
        switch self {
        case let .token(tokenOperator): return tokenOperator.rawValue
        case .swapTernary: return "SwapTernary"
        case .removeSideEffects: return "RemoveSideEffects"
        case .flipBooleanLiteral: return "FlipBooleanLiteral"
        case .negateCondition: return "NegateCondition"
        case .replaceReturnValue: return "ReplaceReturnValue"
        }
    }

    public init?(name: String) {
        if let token = TokenOperator(rawValue: name) {
            self = .token(token)
        } else if name == "SwapTernary" {
            self = .swapTernary
        } else if name == "RemoveSideEffects" {
            self = .removeSideEffects
        } else if name == "FlipBooleanLiteral" {
            self = .flipBooleanLiteral
        } else if name == "NegateCondition" {
            self = .negateCondition
        } else if name == "ReplaceReturnValue" {
            self = .replaceReturnValue
        } else {
            return nil
        }
    }
}
