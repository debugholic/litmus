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

    /// Quick specs and cases on a project's own base class are XCTest too;
    /// read as Swift Testing, they were never run against a mutant.
    @Test("counts a Quick spec and a subclass of a base case as XCTest")
    func xctestInDisguise() {
        #expect(TestedScope.declaresXCTestCase(in: """
        import Quick
        import Nimble
        final class PlayerSpec: QuickSpec {
            override class func spec() {}
        }
        """))
        #expect(TestedScope.declaresXCTestCase(in: """
        @testable import App
        import XCTest
        final class LoginTests: BaseTestCase {
            func testLogin() {}
        }
        """))
        #expect(!TestedScope.declaresXCTestCase(in: """
        import Testing
        import Nimble
        struct PlayerTests {
            @Test func plays() { expect(1).to(equal(1)) }
        }
        """))
        // Helpers that import XCTest but declare no case.
        #expect(!TestedScope.declaresXCTestCase(in: """
        import XCTest
        extension Double { var rounded2: Double { (self * 100).rounded() / 100 } }
        """))
    }

    @Test("sees UIKit however it is imported")
    func uikitImports() {
        #expect(PlatformHints.importsUIKit("import UIKit\n"))
        #expect(PlatformHints.importsUIKit("import Foundation\n@preconcurrency import UIKit\n"))
        #expect(PlatformHints.importsUIKit("import class UIKit.UIView\n"))
        #expect(!PlatformHints.importsUIKit("import SwiftUI\n// import UIKit later\n"))
        #expect(!PlatformHints.importsUIKit("import UIKitExtras\n"))
    }

    @Test("reads a package for iOS alone from its manifest")
    func iOSOnly() {
        #expect(PlatformHints.iOSOnly("platforms: [.iOS(.v15)],"))
        #expect(!PlatformHints.iOSOnly("platforms: [.iOS(.v15), .macOS(.v13)],"))
        #expect(!PlatformHints.iOSOnly("name: \"Tool\","))
    }
}
