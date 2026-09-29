import Foundation

/// What a surviving mutant says is missing from the tests.
public enum GapKind: String, Sendable, CaseIterable {
    /// `<` became `>=`: nothing checks the case where the two sides are equal.
    case boundary
    /// `==` became `!=`: nothing checks a case where the two sides differ.
    case comparison
    /// A condition, a ternary or `&&` changed: one side of it is never checked.
    case branch
    /// A call was removed: nothing checks that it happens.
    case sideEffect = "side-effect"
    /// Arithmetic or a literal changed: nothing checks the value it makes.
    case value
    /// No test runs this code at all.
    case unreached

    /// What to add, in a sentence.
    public var hint: String {
        switch self {
        case .boundary: return "add a case where the two sides are equal"
        case .comparison: return "add a case where the two sides differ"
        case .branch: return "add a case for the other side of this condition"
        case .sideEffect: return "check that this call happens, with the right arguments"
        case .value: return "check the value this computes"
        case .unreached: return "no test runs this code; call it from a test"
        }
    }
}

extension MutantResult {
    /// What this result says is missing: the mutant's own kind, or that no
    /// test reached it at all.
    public var gapKind: GapKind {
        verdict == .noCoverage ? .unreached : mutant.gapKind
    }
}

extension Mutant {
    public var gapKind: GapKind {
        switch `operator` {
        case "RelationalOperatorReplacement":
            return description.hasPrefix("changed ==") || description.hasPrefix("changed !=")
                ? .comparison
                : .boundary
        case "RemoveSideEffects":
            return .sideEffect
        case "ChangeArithmeticOperator", "FlipBooleanLiteral", "ReplaceReturnValue":
            return .value
        default:
            return .branch
        }
    }
}

/// A function the tests do not pin down, and the mutants that show it.
public struct FunctionGap: Sendable {
    public enum Status: String, Sendable {
        /// Not one of its mutants was caught: nothing tests it.
        case untested = "UNTESTED"
        /// Some were caught: it is tested, but not in these cases.
        case partial = "PARTIAL"
    }

    public let filePath: String
    /// `Type.function(label:)`, or the file name for code at file scope.
    public let name: String
    public let caught: Int
    public let scored: Int
    public let survivors: [MutantResult]

    public var status: Status { caught == 0 ? .untested : .partial }

    /// Functions with a survivor, untested ones first, then by how many
    /// survived.
    public static func find(in results: [MutantResult]) -> [FunctionGap] {
        let groups = Dictionary(grouping: results) { result in
            "\(result.mutant.filePath)\u{0}\(result.mutant.change?.function ?? result.mutant.fileName)"
        }

        return groups.values
            .compactMap { results -> FunctionGap? in
                let survivors = results.filter { $0.verdict == .survived || $0.verdict == .noCoverage }
                guard let first = results.first, !survivors.isEmpty else { return nil }

                let caught = results.count { $0.verdict == .killed || $0.verdict == .timedOut }
                return FunctionGap(
                    filePath: first.mutant.filePath,
                    name: first.mutant.change?.function ?? first.mutant.fileName,
                    caught: caught,
                    scored: caught + survivors.count,
                    survivors: survivors.sorted { $0.mutant.line < $1.mutant.line }
                )
            }
            .sorted {
                ($0.status == .untested ? 0 : 1, -$0.survivors.count, $0.name)
                    < ($1.status == .untested ? 0 : 1, -$1.survivors.count, $1.name)
            }
    }
}

/// What to test, in the order worth reading it.
///
/// A mutant no test reaches and one a test runs through without noticing
/// are different news. Listed together, one project's report named 702
/// functions over 3,700 lines, and the dozen whose tests run but check
/// nothing were somewhere in the middle. Those come first, in full; code no
/// test reaches is counted by file.
public struct TestPlan: Sendable {
    /// A function a test runs through where a change went unnoticed.
    public struct Entry: Sendable {
        /// With only the survivors a test ran through.
        public let gap: FunctionGap
        /// The tests that ran through them, each once, in the order met.
        public let passedBy: [TestRef]
        /// Its other mutants, the ones no test reaches.
        public let unreached: Int
    }

    /// Untested ones first.
    public let unchecked: [Entry]
    /// Mutants no test reaches, by file, most first.
    public let unreached: [(path: String, count: Int)]

    public init(_ results: [MutantResult]) {
        unchecked = FunctionGap.find(in: results).compactMap { gap in
            let survived = gap.survivors.filter { $0.verdict == .survived }
            guard !survived.isEmpty else { return nil }

            var passedBy: [TestRef] = []
            for test in survived.flatMap(\.coveredBy) where !passedBy.contains(where: { $0.id == test.id }) {
                passedBy.append(test)
            }
            return Entry(
                gap: FunctionGap(
                    filePath: gap.filePath,
                    name: gap.name,
                    caught: gap.caught,
                    scored: gap.caught + survived.count,
                    survivors: survived
                ),
                passedBy: passedBy,
                unreached: gap.survivors.count - survived.count
            )
        }

        unreached = Dictionary(grouping: results.filter { $0.verdict == .noCoverage }, by: \.mutant.filePath)
            .map { (path: $0.key, count: $0.value.count) }
            .sorted { ($0.count, $1.path) > ($1.count, $0.path) }
    }

    public var unreachedTotal: Int { unreached.reduce(0) { $0 + $1.count } }
}
