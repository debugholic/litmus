import Testing

@testable import LitmusCore

@Suite("Mutation switch")
struct MutationSwitchTests {
    /// The flag stands in for an environment variable whose name comes from the
    /// file stem, and a stem like `PlayerViewModel+Playback` is fine in a string
    /// literal but not in an identifier. Every branch of the sanitiser survived
    /// a mutation run, which is to say nothing checked that it sanitises.
    @Test("turns anything that is not a word character into an underscore")
    func sanitisesIdentifier() {
        let name = MutationSwitch.flagName("PlayerViewModel+Playback_SwapTernary_290_31_8247")

        #expect(name == "__litmus_PlayerViewModel_Playback_SwapTernary_290_31_8247")
    }

    @Test("keeps letters, digits and underscores")
    func keepsWordCharacters() {
        #expect(MutationSwitch.flagName("abc_XYZ_012") == "__litmus_abc_XYZ_012")
    }

    @Test("replaces every other character, not only the first")
    func replacesAll() {
        #expect(MutationSwitch.flagName("a+b-c.d") == "__litmus_a_b_c_d")
    }

    /// The declaration and the runner have to agree exactly: the identifier
    /// is sanitised, the name it compares against is not.
    @Test("declares the flag under the sanitised name and compares the raw id")
    func declaration() {
        let declaration = MutationSwitch.declaration(id: "A+B_ChangeLogicalConnector_1_2_3")

        #expect(declaration == "private var __litmus_A_B_ChangeLogicalConnector_1_2_3: Bool "
            + "{ __litmus_on(\"A+B_ChangeLogicalConnector_1_2_3\") }")
    }

    /// Read when evaluated, so a process can switch mutants between runs.
    /// ProcessInfo keeps its own copy of the environment and would never see
    /// the change.
    @Test("looks the active mutant up through getenv")
    func lookup() {
        #expect(MutationSwitch.lookup.contains("getenv(\"LITMUS_ACTIVE\")"))
        #expect(!MutationSwitch.lookup.contains("ProcessInfo"))
    }
}

@Suite("Mutation operator names")
struct MutationOperatorTests {
    @Test("resolves every operator by name")
    func resolvesByName() {
        #expect(MutationOperator(name: "SwapTernary") == .swapTernary)
        #expect(MutationOperator(name: "RemoveSideEffects") == .removeSideEffects)
        #expect(MutationOperator(name: "ChangeLogicalConnector") == .token(.changeLogicalConnector))
        #expect(
            MutationOperator(name: "RelationalOperatorReplacement")
                == .token(.relationalOperatorReplacement)
        )
    }

    @Test("does not resolve a name it does not know")
    func rejectsUnknown() {
        #expect(MutationOperator(name: "Nonsense") == nil)
        #expect(MutationOperator(name: "") == nil)
    }

    /// The CLI defaults to this list, so an operator missing from it is an
    /// operator that never runs.
    @Test("names every case")
    func namesAllCases() {
        #expect(Set(MutationOperator.allCases.map(\.name)) == [
            "ChangeLogicalConnector",
            "RelationalOperatorReplacement",
            "SwapTernary",
            "RemoveSideEffects",
            "ChangeArithmeticOperator",
            "FlipBooleanLiteral",
            "NegateCondition",
        ])
    }
}
