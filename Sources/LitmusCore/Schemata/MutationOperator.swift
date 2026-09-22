import Foundation

/// The kinds of change Litmus knows how to make.
public enum MutationOperator: Equatable, Sendable, CaseIterable {
    case token(TokenOperator)
    case swapTernary
    case removeSideEffects

    public static var allCases: [MutationOperator] {
        TokenOperator.allCases.map(MutationOperator.token) + [.swapTernary, .removeSideEffects]
    }

    public var name: String {
        switch self {
        case let .token(tokenOperator): return tokenOperator.rawValue
        case .swapTernary: return "SwapTernary"
        case .removeSideEffects: return "RemoveSideEffects"
        }
    }

    public init?(name: String) {
        if let token = TokenOperator(rawValue: name) {
            self = .token(token)
        } else if name == "SwapTernary" {
            self = .swapTernary
        } else if name == "RemoveSideEffects" {
            self = .removeSideEffects
        } else {
            return nil
        }
    }
}
