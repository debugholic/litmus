import Foundation
import Testing

@testable import LitmusCore

@Suite("Injection check")
struct InjectionCheckTests {
    private func mutant(_ offset: Int, in path: String) -> Mutant {
        Mutant(
            filePath: path, line: 1, column: 2, utf8Offset: offset,
            operator: "RelationalOperatorReplacement", description: "changed == to !="
        )
    }

    /// `…_1_2_3` is inside `…_1_2_34`: found bare, a mutant never written
    /// passed as there and was scored as a survivor.
    @Test("does not take one mutant's switch for another's that starts the same")
    func exactSwitch() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("A-\(UUID().uuidString).swift")
        defer { try? FileManager.default.removeItem(at: file) }

        let written = mutant(34, in: file.path)
        let missing = mutant(3, in: file.path)
        try MutationSwitch.declaration(id: written.switchName).write(to: file, atomically: true, encoding: .utf8)

        let outcome = InjectionCheck()([written, missing])

        #expect(written.switchName.hasPrefix(missing.switchName))
        #expect(outcome.injected == [written])
        #expect(outcome.missing == [missing])
    }
}
