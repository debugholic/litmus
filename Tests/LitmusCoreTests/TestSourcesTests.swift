import Foundation
import Testing

@testable import LitmusCore

@Suite("Test sources")
struct TestSourcesTests {
    private final class Tree {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("litmus-sources-\(UUID().uuidString)")

        init(_ files: [String: String]) throws {
            for (path, text) in files {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test("says yes when every test imports Testing and none is XCTest")
    func swiftTestingOnly() throws {
        let tree = try Tree([
            "Tests/AppTests/A.swift": "import Testing\n@Test func a() {}\n",
            "Projects/Domain/Settings/Tests/Sources/B.swift": "import Testing\n",
            "Sources/App/C.swift": "final class NotATest: XCTestCase {}\n",
        ])

        #expect(TestSources.allSwiftTesting(in: tree.root))
    }

    @Test("says no when any unit test is an XCTestCase")
    func xctest() throws {
        let tree = try Tree([
            "Tests/AppTests/A.swift": "import Testing\n",
            "Tests/LegacyTests/B.swift": "import XCTest\nfinal class B: XCTestCase {}\n",
        ])

        #expect(!TestSources.allSwiftTesting(in: tree.root))
    }

    @Test("leaves UI tests out, since they are XCTest by necessity")
    func uiTests() throws {
        let tree = try Tree([
            "Tests/AppTests/A.swift": "import Testing\n",
            "AppUITests/B.swift": "import XCTest\nfinal class B: XCTestCase { let app = XCUIApplication() }\n",
        ])

        #expect(TestSources.allSwiftTesting(in: tree.root))
    }

    @Test("says no when it finds no tests, and skips dependency folders")
    func nothingFound() throws {
        let tree = try Tree([
            "Sources/App/A.swift": "struct A {}\n",
            "Pods/Some/Tests/X.swift": "import Testing\n",
        ])

        #expect(!TestSources.allSwiftTesting(in: tree.root))
    }
}
