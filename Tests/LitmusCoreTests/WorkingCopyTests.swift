import Foundation
import Testing

@testable import LitmusCore

@Suite("Working copy")
struct WorkingCopyTests {
    private let caches = URL(fileURLWithPath: "/Users/someone/Library/Caches")

    @Test("keeps every copy under one folder in the caches")
    func oneFolder() {
        let copy = WorkingCopy.location(
            for: URL(fileURLWithPath: "/Volumes/Work/Git/your-project"), caches: caches
        )

        #expect(copy.deletingLastPathComponent().path == "/Users/someone/Library/Caches/litmus")
        #expect(copy.lastPathComponent.hasPrefix("your-project-"))
        #expect(copy.lastPathComponent.count == "your-project-".count + 6)
    }

    @Test("gives the same project the same copy on every run")
    func stable() {
        let project = URL(fileURLWithPath: "/Volumes/Work/Git/app")

        #expect(WorkingCopy.location(for: project, caches: caches) == WorkingCopy.location(for: project, caches: caches))
        #expect(WorkingCopy.identifier(for: "/Volumes/Work/Git/app") == WorkingCopy.identifier(for: "/Volumes/Work/Git/app"))
    }

    @Test("keeps two projects of the same name apart")
    func sameName() {
        let one = WorkingCopy.location(for: URL(fileURLWithPath: "/Volumes/A/app"), caches: caches)
        let two = WorkingCopy.location(for: URL(fileURLWithPath: "/Users/someone/app"), caches: caches)

        #expect(one != two)
    }
}
