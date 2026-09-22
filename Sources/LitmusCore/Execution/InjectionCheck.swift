import Foundation

/// Confirms that a mutant is really in the source before Litmus runs it.
///
/// A plan lists what the schemata step *intended* to write. If a mutant was
/// listed but never injected, running it proves nothing: the build succeeds,
/// the tests pass, and the mutant looks like it survived. That reads as a hole
/// in the test suite when the truth is that nothing was ever changed.
///
/// The switch name is written into the source verbatim, so its presence is a
/// cheap and exact check.
public struct InjectionCheck: Sendable {
    public struct Outcome: Sendable {
        public let injected: [Mutant]
        public let missing: [Mutant]
        /// Files named in the plan that could not be read at all.
        public let unreadable: [String]
    }

    public init() {}

    public func callAsFunction(_ mutants: [Mutant]) -> Outcome {
        var injected: [Mutant] = []
        var missing: [Mutant] = []
        var unreadable: Set<String> = []
        var sourceByPath: [String: String] = [:]

        for mutant in mutants {
            let source: String
            if let cached = sourceByPath[mutant.filePath] {
                source = cached
            } else if let loaded = try? String(contentsOfFile: mutant.filePath, encoding: .utf8) {
                sourceByPath[mutant.filePath] = loaded
                source = loaded
            } else {
                unreadable.insert(mutant.filePath)
                missing.append(mutant)
                continue
            }

            if source.contains(mutant.switchName) {
                injected.append(mutant)
            } else {
                missing.append(mutant)
            }
        }

        return Outcome(
            injected: injected,
            missing: missing,
            unreadable: unreadable.sorted()
        )
    }
}
