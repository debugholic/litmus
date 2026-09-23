import SwiftParser
import SwiftSyntax

/// A mutation that swaps one operator token for another.
///
/// `&&` becomes `||`, `==` becomes `!=`, and so on. These are the changes a
/// test suite ought to notice immediately, which makes a survivor a sharp
/// signal rather than a curiosity.
///
/// Adapted from Muter (MIT) — see NOTICE.
public enum TokenOperator: String, CaseIterable, Sendable {
    case changeLogicalConnector = "ChangeLogicalConnector"
    case relationalOperatorReplacement = "RelationalOperatorReplacement"
    case changeArithmeticOperator = "ChangeArithmeticOperator"

    /// What each token turns into.
    var replacements: [String: String] {
        switch self {
        case .changeLogicalConnector:
            return ["&&": "||", "||": "&&"]
        case .relationalOperatorReplacement:
            return ["==": "!=", "!=": "==", ">=": "<", "<=": ">", "<": ">=", ">": "<="]
        case .changeArithmeticOperator:
            // Each stays in its own precedence group, so the unfolded sequence
            // folds the same way with the swap in it.
            return ["+": "-", "-": "+", "*": "/", "/": "*", "%": "*"]
        }
    }

    func describe(_ before: String, _ after: String) -> String {
        "changed \(before) to \(after)"
    }
}
