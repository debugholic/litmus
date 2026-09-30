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

    /// The spans a change picks in one test file.
    ///
    /// A changed line in a `@Test` function picks that function. One
    /// anywhere else — a helper, a suite's `init`, a shared value — picks
    /// the whole file: the tests there may use it, and following who calls
    /// what is more than a line number says. A line with no code on it —
    /// blank, or a comment — picks nothing: it changes no test.
    public static func spans(ofFile path: String, changed: Set<Int>) -> [Span] {
        guard !changed.isEmpty, let source = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return spans(in: source, changed: changed).map { Span(file: name, lines: $0) }
    }

    static func spans(in source: String, changed: Set<Int>) -> [ClosedRange<Int>] {
        let text = source.components(separatedBy: "\n")
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
            converter.location(for: function.positionAfterSkippingLeadingTrivia).line
                ... converter.location(for: function.endPositionBeforeTrailingTrivia).line
        }

        var picked: [ClosedRange<Int>] = []
        for line in touched.sorted() {
            guard let test = tests.first(where: { $0.contains(line) }) else {
                return [1...max(1, text.count)]
            }
            if !picked.contains(test) { picked.append(test) }
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
