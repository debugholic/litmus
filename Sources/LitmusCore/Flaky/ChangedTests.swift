import Foundation
import SwiftParser
import SwiftSyntax

/// The tests a change touched, as spans of lines the driver picks tests by.
///
/// A test's id ends in the file and line it was declared on, so a span that
/// covers a `@Test` function, attributes and all, picks it out.
public enum ChangedTests {
    public struct Span: Sendable, Equatable {
        /// The file's name alone, as a test id carries it.
        public let file: String
        public let lines: ClosedRange<Int>

        public init(file: String, lines: ClosedRange<Int>) {
            self.file = file
            self.lines = lines
        }

        /// How the driver reads it: `File.swift`, first line, last line.
        var line: String { "\(file)\t\(lines.lowerBound)\t\(lines.upperBound)" }
    }

    /// A `@Test` function a change touched.
    public struct Picked {
        public let span: Span
        public let function: FunctionDeclSyntax

        /// `first()`, or `Suite.first()` inside a type.
        public var name: String {
            let base = "\(function.name.text)()"
            return FlakyRisk.enclosingType(of: Syntax(function)).map { "\($0).\(base)" } ?? base
        }
    }

    /// The tests a change picks in one test file.
    ///
    /// A changed line in a `@Test` function picks that function. One
    /// anywhere else — a helper, a suite's `init`, a shared value — picks
    /// every test in the file: they may use it, and following who calls
    /// what is more than a line number says. A line with no code on it —
    /// blank, or a comment — picks nothing: it changes no test.
    public static func picked(inFile path: String, changed: Set<Int>) -> [Picked] {
        guard !changed.isEmpty, let source = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return picked(in: source, changed: changed).map {
            Picked(span: Span(file: name, lines: $0.lines), function: $0.function)
        }
    }

    public static func spans(ofFile path: String, changed: Set<Int>) -> [Span] {
        picked(inFile: path, changed: changed).map(\.span)
    }

    static func spans(in source: String, changed: Set<Int>) -> [ClosedRange<Int>] {
        picked(in: source, changed: changed).map(\.lines)
    }

    static func picked(in source: String, changed: Set<Int>) -> [(lines: ClosedRange<Int>, function: FunctionDeclSyntax)] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: "", tree: tree)

        // The lines code is on, a token spanning lines counting on each.
        var code: Set<Int> = []
        for token in tree.tokens(viewMode: .sourceAccurate) where token.tokenKind != .endOfFile {
            let first = converter.location(for: token.positionAfterSkippingLeadingTrivia).line
            let last = converter.location(for: token.endPositionBeforeTrailingTrivia).line
            code.formUnion(first...max(first, last))
        }
        let touched = changed.intersection(code)
        guard !touched.isEmpty else { return [] }

        let finder = TestFinder(viewMode: .sourceAccurate)
        finder.walk(tree)
        let tests = finder.functions.map { function in
            (lines: converter.location(for: function.positionAfterSkippingLeadingTrivia).line
                ... converter.location(for: function.endPositionBeforeTrailingTrivia).line,
             function: function)
        }

        var picked: [(lines: ClosedRange<Int>, function: FunctionDeclSyntax)] = []
        for line in touched.sorted() {
            guard let test = tests.first(where: { $0.lines.contains(line) }) else { return tests }
            if !picked.contains(where: { $0.lines == test.lines }) { picked.append(test) }
        }
        return picked
    }

    private final class TestFinder: SyntaxVisitor {
        var functions: [FunctionDeclSyntax] = []

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            let isTest = node.attributes.contains { element in
                guard let attribute = element.as(AttributeSyntax.self) else { return false }
                let name = attribute.attributeName.trimmedDescription
                return name == "Test" || name == "Testing.Test"
            }
            if isTest { functions.append(node) }
            return .skipChildren
        }
    }
}
