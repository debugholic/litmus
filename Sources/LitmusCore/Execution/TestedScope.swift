import Foundation

/// The source files a scheme's tests are aimed at.
///
/// Coverage says which lines ran, not which lines a test checked. With a host
/// app that difference is most of the project: launching it runs every module
/// it links, so a scheme with seven tests for one feature marked 153 files as
/// reached, and every mutant outside that feature survived — 1,200 runs to
/// learn that the Setting tests do not look at the Game module.
///
/// The build knows better. Each test target is compiled from a list of files,
/// and so is each module; the modules a test target is aimed at are the one
/// it is named after and the ones it imports with `@testable`.
public struct TestedScope: Sendable, Equatable {
    /// A test target and the files it was compiled from.
    public struct TestTarget: Sendable, Equatable {
        public let name: String
        public let files: [String]
    }

    public let modules: [String]
    let files: Set<String>
    public let testTargets: [TestTarget]

    public init(modules: [String], files: Set<String>, testTargets: [TestTarget] = []) {
        self.modules = modules
        self.files = Set(files.map(Self.normalise))
        self.testTargets = testTargets
    }

    public func contains(_ path: String) -> Bool {
        files.contains(Self.normalise(path))
    }

    static func normalise(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

extension TestedScope {
    /// Works the scope out from a finished build.
    ///
    /// Nil when it cannot: an unfamiliar layout, or a test target whose module
    /// is not among the ones built. A run with no scope mutates everything it
    /// was given, which is the old behaviour rather than a wrong one.
    static func from(xctestrun: URL, derivedData: URL) -> TestedScope? {
        guard
            let data = try? Data(contentsOf: xctestrun),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let root = plist as? [String: Any]
        else { return nil }

        let testTargets = testTargetNames(in: root)
        guard !testTargets.isEmpty else { return nil }

        let fileLists = swiftFileLists(
            under: derivedData.appendingPathComponent("Build/Intermediates.noindex")
        )

        var modules: [String] = []
        var targets: [TestTarget] = []
        for target in testTargets {
            modules.append(moduleName(forTestTarget: target))

            let sources = (fileLists[target] ?? []).flatMap { files(inSwiftFileList: $0) }
            targets.append(TestTarget(name: target, files: sources.sorted()))

            for source in sources {
                guard let text = try? String(contentsOfFile: source, encoding: .utf8) else { continue }
                modules.append(contentsOf: testableImports(in: text))
            }
        }

        var seen: Set<String> = []
        modules = modules.filter { fileLists[$0] != nil && seen.insert($0).inserted }

        let files = modules
            .flatMap { fileLists[$0] ?? [] }
            .flatMap { self.files(inSwiftFileList: $0) }

        guard !files.isEmpty else { return nil }
        return TestedScope(modules: modules, files: Set(files), testTargets: targets)
    }

    /// The test target a single process can run every test of, if there is one.
    public var batchTarget: TestTarget? {
        batchIneligibility == nil ? testTargets.first : nil
    }

    /// Why these tests cannot all run in one process, or nil when they can.
    ///
    /// The driver reruns Swift Testing inside the process; it cannot rerun
    /// XCTest cases, and it cannot reach a second bundle, which xcodebuild
    /// runs in a process of its own. Either way some tests would never run
    /// with the mutant on, and a mutant only they would kill would be
    /// reported as a survivor.
    public var batchIneligibility: String? {
        guard testTargets.count == 1, let target = testTargets.first, !target.files.isEmpty else {
            return testTargets.count > 1
                ? "the scheme runs \(testTargets.count) test bundles"
                : "could not find the test sources"
        }

        var swiftTesting = false
        for file in target.files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
                return "could not read \(URL(fileURLWithPath: file).lastPathComponent)"
            }
            if Self.declaresXCTestCase(in: text) {
                return "\(target.name) has XCTest cases, which only a fresh process reruns"
            }
            if text.contains("import Testing") { swiftTesting = true }
        }

        return swiftTesting ? nil : "\(target.name) has no Swift Testing tests"
    }

    static func declaresXCTestCase(in source: String) -> Bool {
        source.range(of: #":\s*XCTestCase\b"#, options: .regularExpression) != nil
    }

    /// Test target names from either `.xctestrun` layout.
    ///
    /// Format 1 keys each test target at the top level; format 2 nests them
    /// under `TestConfigurations`. Xcode writes whichever the scheme asks for.
    static func testTargetNames(in root: [String: Any]) -> [String] {
        if let configurations = root["TestConfigurations"] as? [[String: Any]] {
            return configurations
                .flatMap { $0["TestTargets"] as? [[String: Any]] ?? [] }
                .compactMap { $0["BlueprintName"] as? String }
        }

        return root.keys
            .filter { !$0.hasPrefix("__") }
            .filter { root[$0] is [String: Any] }
            .sorted()
    }

    /// `FeatureSettingTests` tests `FeatureSetting`; `AppUITests` tests `App`.
    static func moduleName(forTestTarget target: String) -> String {
        for suffix in ["UITests", "Tests"] where target.hasSuffix(suffix) && target.count > suffix.count {
            return String(target.dropLast(suffix.count))
        }
        return target
    }

    static func testableImports(in source: String) -> [String] {
        source.split(separator: "\n").compactMap { line in
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.count >= 3, words[0] == "@testable", words[1] == "import" else { return nil }
            return String(words[2])
        }
    }

    /// Every `<Name>.SwiftFileList` the build wrote, by name.
    static func swiftFileLists(under root: URL) -> [String: [URL]] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [:] }

        var lists: [String: [URL]] = [:]
        for case let url as URL in walker where url.pathExtension == "SwiftFileList" {
            lists[url.deletingPathExtension().lastPathComponent, default: []].append(url)
        }
        return lists
    }

    static func files(inSwiftFileList url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parseSwiftFileList(text)
    }

    /// One path per line, with the shell escaping xcodebuild applies:
    /// `/Volumes/Secret\ Friend/...` is a path with a space in it.
    static func parseSwiftFileList(_ text: String) -> [String] {
        text.split(separator: "\n").map { line in
            var path = ""
            var escaped = false
            for character in line {
                if escaped {
                    path.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else {
                    path.append(character)
                }
            }
            return path
        }
        .filter { !$0.isEmpty }
    }
}
