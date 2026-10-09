import Foundation
import SwiftParser
import SwiftSyntax

/// Whether anything a test runs can come out differently from one run to the
/// next, found before anything is built by following what it calls through
/// the project's sources.
///
/// By name, without types: a call to `load()` follows every `load()` the
/// project declares, a protocol requirement every type that has it. That
/// errs towards finding too much, which only costs a run. What it cannot
/// see is code without source — the SDK, a binary framework — and a call
/// made by name at run time, as a notification is.
public struct FlakyRisk {
    /// What can vary, and how the test reaches it.
    public struct Finding: Sendable, Equatable {
        /// `Task`, `Date`, `.shared`.
        public let factor: String
        /// From the test to where the factor is: `first()`, `Player.play()`.
        public let path: [String]
    }

    /// A declaration whose body a call can run.
    private struct Unit {
        let label: String
        let node: Syntax
        let id: String
        /// The type it belongs to, nil for a free function.
        let owner: String?
    }

    private var units: [String: [Unit]] = [:]
    /// What an instance of each type runs when it is made: its initialisers
    /// and the defaults of its stored values.
    private var making: [String: [Unit]] = [:]
    /// Every type the project declares, and what each inherits from.
    private var types: [String: [String]] = [:]
    /// Protocols and enums, whose members any value may have without a
    /// visible `Type(...)`.
    private var alwaysLive: Set<String> = []

    /// Reads every Swift file under `root`, build output and hidden folders
    /// left out.
    public init(root: URL) {
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in walker {
            if ["build", "DerivedData", "Pods", "Carthage"].contains(url.lastPathComponent) {
                walker.skipDescendants(of: url)
                continue
            }
            guard url.pathExtension == "swift", let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            add(source, file: url.path)
        }
    }

    /// For tests: the sources given, keyed by a made-up path.
    init(sources: [String: String]) {
        for (file, source) in sources { add(source, file: file) }
    }

    private mutating func add(_ source: String, file: String) {
        let indexer = Indexer(file: file)
        indexer.walk(Parser.parse(source: source))
        for (name, found) in indexer.units { units[name, default: []] += found }
        for (type, found) in indexer.making { making[type, default: []] += found }
        for (type, parents) in indexer.types { types[type, default: []] += parents }
        alwaysLive.formUnion(indexer.alwaysLive)
    }

    // MARK: - following a test

    /// The first thing that can vary on the way from `test`, nearest first,
    /// or nil when nothing it reaches can.
    ///
    /// A method is followed only into types an instance of which the test
    /// has made on the way: a test that hands a mock in never runs the real
    /// type's code, whatever its methods are called. A type made later
    /// brings in the methods already called by name.
    public func finding(for test: FunctionDeclSyntax, limit: Int = 20_000) -> Finding? {
        let root = Unit(label: "\(test.name.text)()", node: Syntax(test), id: "test", owner: nil)

        var queue: [(unit: Unit, path: [String])] = [(root, [root.label])]
        var seen: Set<String> = [root.id]
        var live = alwaysLive
        var called: Set<String> = []

        func enqueue(_ unit: Unit, from path: [String]) {
            guard !seen.contains(unit.id) else { return }
            seen.insert(unit.id)
            queue.append((unit, path + [unit.label]))
        }

        func makeLive(_ type: String, from path: [String]) {
            guard live.insert(type).inserted else {
                return
            }
            for unit in making[type] ?? [] { enqueue(unit, from: path) }
            for name in called {
                for unit in units[name] ?? [] where unit.owner == type { enqueue(unit, from: path) }
            }
            // What it inherits runs as its own.
            for parent in types[type] ?? [] where types[parent] != nil { makeLive(parent, from: path) }
        }

        // The suite's own set-up runs before the test does.
        if let suite = Self.enclosingType(of: Syntax(test)) { makeLive(suite, from: [root.label]) }

        var index = 0
        while index < queue.count, index < limit {
            let (unit, path) = queue[index]
            index += 1

            let scan = Scan(viewMode: .sourceAccurate)
            scan.walk(unit.node)
            if let factor = scan.factor {
                return Finding(factor: factor, path: path)
            }
            for name in scan.references {
                if types[name] != nil {
                    makeLive(name, from: path)
                    continue
                }
                guard called.insert(name).inserted else { continue }
                for next in units[name] ?? [] where next.owner.map(live.contains) ?? true {
                    enqueue(next, from: path)
                }
            }
        }
        return nil
    }

    /// The type a declaration sits in: `Player` for a method of `Player` or
    /// of an extension of it.
    static func enclosingType(of node: Syntax) -> String? {
        var current = node.parent
        while let parent = current {
            if let decl = parent.as(ClassDeclSyntax.self) { return decl.name.text }
            if let decl = parent.as(StructDeclSyntax.self) { return decl.name.text }
            if let decl = parent.as(EnumDeclSyntax.self) { return decl.name.text }
            if let decl = parent.as(ActorDeclSyntax.self) { return decl.name.text }
            if let decl = parent.as(ExtensionDeclSyntax.self) { return decl.extendedType.trimmedDescription }
            current = parent.parent
        }
        return nil
    }

    // MARK: - what can vary

    /// Names that, used in code, make its outcome depend on timing, the
    /// clock, chance or state shared beyond the test.
    static let factors: [String: String] = [
        "Task": "Task", "sleep": "sleep", "usleep": "sleep", "asyncAfter": "asyncAfter",
        "DispatchQueue": "DispatchQueue", "DispatchGroup": "DispatchGroup", "OperationQueue": "OperationQueue",
        "Thread": "Thread", "Timer": "Timer", "RunLoop": "RunLoop",
        "withTaskGroup": "a task group", "withThrowingTaskGroup": "a task group",
        "withCheckedContinuation": "a continuation", "withCheckedThrowingContinuation": "a continuation",
        "AsyncStream": "AsyncStream", "AsyncThrowingStream": "AsyncStream",
        "debounce": "debounce", "throttle": "throttle",
        "CFAbsoluteTimeGetCurrent": "the clock", "ContinuousClock": "the clock", "now": "the clock",
        "SuspendingClock": "the clock", "DispatchTime": "the clock",
        "random": "random", "randomElement": "random", "shuffled": "random", "shuffle": "random",
        "UserDefaults": "UserDefaults", "FileManager": "FileManager", "NotificationCenter": "NotificationCenter",
        "URLSession": "URLSession", "ProcessInfo": "ProcessInfo",
        "shared": ".shared",
    ]

    /// What one body uses: the first factor in it, and the names it calls.
    private final class Scan: SyntaxVisitor {
        var factor: String?
        var references: [String] = []

        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            note(node.baseName.text)
            return .visitChildren
        }

        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            note(node.declName.baseName.text)
            return .visitChildren
        }

        /// `Date()` is now, which moves; `Date(timeIntervalSince1970: 0)`
        /// does not.
        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if factor == nil, node.calledExpression.trimmedDescription == "Date", node.arguments.isEmpty,
               node.trailingClosure == nil {
                factor = "Date()"
            }
            return .visitChildren
        }

        /// A `static var` is state every test in the process shares, and
        /// `async let` runs its work beside the rest.
        override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
            guard factor == nil else { return .visitChildren }
            let modifiers = node.modifiers.map(\.name.tokenKind)
            if node.bindingSpecifier.tokenKind == .keyword(.var),
               modifiers.contains(.keyword(.static)) || modifiers.contains(.keyword(.class)) {
                factor = "static var"
            } else if modifiers.contains(.keyword(.async)) {
                factor = "async let"
            }
            return .visitChildren
        }

        private func note(_ name: String) {
            if factor == nil, let found = FlakyRisk.factors[name] { factor = found }
            references.append(name)
        }
    }

    /// Every declaration a call can reach, by the name a call uses for it:
    /// a function by its name, a computed value by its own; a type's
    /// initialisers and stored defaults by the type, since they run when
    /// one is made, not when a value is read.
    private final class Indexer: SyntaxVisitor {
        let file: String
        var units: [String: [Unit]] = [:]
        var making: [String: [Unit]] = [:]
        var types: [String: [String]] = [:]
        var alwaysLive: Set<String> = []

        init(file: String) {
            self.file = file
            super.init(viewMode: .sourceAccurate)
        }

        private func unit(_ label: String, _ node: some SyntaxProtocol, owner: String?) -> Unit {
            Unit(label: label, node: Syntax(node), id: "\(file):\(node.position.utf8Offset)", owner: owner)
        }

        private func qualified(_ name: String, _ owner: String?) -> String {
            owner.map { "\($0).\(name)" } ?? name
        }

        private func declare(_ name: String, inherits: InheritanceClauseSyntax?) {
            let parents = inherits?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
            types[name, default: []] += parents
        }

        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
            declare(node.name.text, inherits: node.inheritanceClause)
            return .visitChildren
        }

        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
            declare(node.name.text, inherits: node.inheritanceClause)
            return .visitChildren
        }

        override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
            declare(node.name.text, inherits: node.inheritanceClause)
            return .visitChildren
        }

        override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
            declare(node.name.text, inherits: node.inheritanceClause)
            alwaysLive.insert(node.name.text)
            return .visitChildren
        }

        override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
            declare(node.name.text, inherits: node.inheritanceClause)
            alwaysLive.insert(node.name.text)
            return .visitChildren
        }

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            let owner = FlakyRisk.enclosingType(of: Syntax(node))
            units[node.name.text, default: []].append(unit(qualified("\(node.name.text)()", owner), node, owner: owner))
            return .visitChildren
        }

        override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
            if let type = FlakyRisk.enclosingType(of: Syntax(node)) {
                making[type, default: []].append(unit("\(type).init", node, owner: type))
            }
            return .visitChildren
        }

        override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
            let owner = FlakyRisk.enclosingType(of: Syntax(node))
            let modifiers = node.modifiers.map(\.name.tokenKind)
            let byName = modifiers.contains(.keyword(.static)) || modifiers.contains(.keyword(.class))
                || modifiers.contains(.keyword(.lazy)) || owner == nil
            for binding in node.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                // The whole declaration, so a `static var` is seen as one.
                let found = unit(qualified(name, owner), node, owner: owner)
                if binding.accessorBlock != nil || byName {
                    // Worked out each time it is read, or the first time.
                    units[name, default: []].append(found)
                } else if binding.initializer != nil, let owner {
                    making[owner, default: []].append(found)
                }
            }
            return .visitChildren
        }
    }
}
