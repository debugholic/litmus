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

    public static var allCases: [MutationOperator] {
        TokenOperator.allCases.map(MutationOperator.token)
            + [.swapTernary, .removeSideEffects, .flipBooleanLiteral, .negateCondition]
    }

    public var name: String {
        switch self {
        case let .token(tokenOperator): return tokenOperator.rawValue
        case .swapTernary: return "SwapTernary"
        case .removeSideEffects: return "RemoveSideEffects"
        case .flipBooleanLiteral: return "FlipBooleanLiteral"
        case .negateCondition: return "NegateCondition"
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
        } else {
            return nil
        }
    }
}
