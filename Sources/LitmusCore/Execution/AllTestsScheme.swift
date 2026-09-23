import Foundation

/// A scheme that runs every unit test in the project.
///
/// A project's own schemes are for building apps, and the tests they run are
/// whatever someone remembered to tick. On one Tuist project the shared
/// schemes ran 15 of 70 test targets; the Domain, Data and Core tests were in
/// no scheme at all. So Litmus writes a scheme of its own, naming every unit
/// test target, into its working copy — never into the project.
public enum AllTestsScheme {
    public static let name = "litmus-all-tests"

    /// A unit test target, and the project it lives in.
    public struct Target: Sendable, Equatable {
        public let name: String
        /// The target's id in its project, which a scheme refers to it by.
        public let blueprint: String
        /// The `.xcodeproj`, relative to the directory holding the scheme's
        /// workspace or project.
        public let container: String
    }

    /// Writes the scheme into `root` and returns its name, or nil when there
    /// is nothing to put in it.
    ///
    /// Written once: a copy that already has it is left alone.
    public static func prepare(in root: URL) throws -> String? {
        guard let location = schemeLocation(in: root) else { return nil }
        let file = location.directory.appendingPathComponent("\(name).xcscheme")

        if FileManager.default.fileExists(atPath: file.path) { return name }

        let targets = try location.projects.flatMap { try unitTestTargets(inProject: $0, relativeTo: root) }
        guard !targets.isEmpty else { return nil }

        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        try scheme(for: targets).write(to: file, atomically: true, encoding: .utf8)
        return name
    }

    /// Takes out of the scheme the test targets a failed build or run names,
    /// and returns them; none when the log names nothing in the scheme.
    ///
    /// A project whose own test support does not compile, or whose own tests
    /// fail, would otherwise stop every other target from running. A target
    /// is named directly when its tests fail, and through its project when
    /// something it needs — test doubles, usually — does not build.
    public static func leaveOut(
        failedIn log: String,
        failedBundles: [String] = [],
        in root: URL
    ) throws -> [String] {
        guard let location = schemeLocation(in: root) else { return [] }
        let file = location.directory.appendingPathComponent("\(name).xcscheme")
        guard let current = try? String(contentsOf: file, encoding: .utf8) else { return [] }

        let included = Set(
            current.components(separatedBy: "BlueprintName = \"").dropFirst()
                .compactMap { $0.split(separator: "\"").first.map(String.init) }
        )
        let targets = try location.projects
            .flatMap { try unitTestTargets(inProject: $0, relativeTo: root) }
            .filter { included.contains($0.name) }

        let failed = failures(in: log)
        let dropped = targets.filter { target in
            failed.targets.contains(target.name)
                || failedBundles.contains(target.name)
                || failed.projects.contains(URL(fileURLWithPath: target.container).deletingPathExtension().lastPathComponent)
        }
        let kept = targets.filter { !dropped.contains($0) }

        // Nothing left would be a scheme that cannot test, and the log that
        // led here says more about why than an empty run would.
        guard !dropped.isEmpty, !kept.isEmpty else { return [] }

        try scheme(for: kept).write(to: file, atomically: true, encoding: .utf8)
        return dropped.map(\.name)
    }

    /// Targets and projects a log says failed: the build commands listed
    /// under `The following build commands failed:`, and the targets of
    /// `Failing tests:`.
    ///
    /// Only those two lists are read. Every compile step in the log names
    /// its target the same way, failed or not, and reading them all once
    /// took every target in the project out of the scheme.
    static func failures(in log: String) -> (targets: Set<String>, projects: Set<String>) {
        enum Section { case none, failedCommands, failingTests }

        var targets: Set<String> = []
        var projects: Set<String> = []
        var section = Section.none

        for line in log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("The following build commands failed:") {
                section = .failedCommands
                continue
            }
            if line.hasPrefix("Failing tests:") {
                section = .failingTests
                continue
            }
            guard section != .none, line.hasPrefix("\t") || line.hasPrefix("    ") else {
                section = .none
                continue
            }

            switch section {
            case .failedCommands:
                if let range = line.range(
                    of: #"\(in target '[^']+' from project '[^']+'\)"#, options: .regularExpression
                ) {
                    let parts = line[range].split(separator: "'")
                    targets.insert(String(parts[1]))
                    projects.insert(String(parts[3]))
                }
            case .failingTests:
                let test = line.trimmingCharacters(in: .whitespaces)
                if let target = test.split(whereSeparator: { ".:/".contains($0) }).first {
                    targets.insert(String(target))
                }
            case .none:
                break
            }
        }

        return (targets, projects)
    }

    /// Where the scheme goes, and the projects it may name.
    ///
    /// In a workspace, the projects the workspace lists: a scheme that names a
    /// project outside it does not build. Without one, the single project at
    /// the root.
    public static func schemeLocation(in root: URL) -> (directory: URL, projects: [URL])? {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []

        if let workspace = entries.sorted().first(where: { $0.hasSuffix(".xcworkspace") }) {
            let url = root.appendingPathComponent(workspace)
            let contents = url.appendingPathComponent("contents.xcworkspacedata")
            guard let data = try? Data(contentsOf: contents) else { return nil }

            return (
                url.appendingPathComponent("xcshareddata/xcschemes"),
                projects(inWorkspace: data).map { root.appendingPathComponent($0) }
            )
        }

        let projects = entries.filter { $0.hasSuffix(".xcodeproj") }
        guard projects.count == 1 else { return nil }

        let url = root.appendingPathComponent(projects[0])
        return (url.appendingPathComponent("xcshareddata/xcschemes"), [url])
    }

    /// The `.xcodeproj` paths a workspace lists, relative to its directory.
    static func projects(inWorkspace data: Data) -> [String] {
        let reader = WorkspaceReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.projects
    }

    /// Unit test targets, read from the project file. UI tests are left out:
    /// they drive the app from outside and cannot see a mutant's module.
    static func unitTestTargets(inProject project: URL, relativeTo root: URL) throws -> [Target] {
        let file = project.appendingPathComponent("project.pbxproj")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }

        let json = try Subprocess.run(
            executable: "/usr/bin/plutil",
            arguments: ["-convert", "json", "-o", "-", file.path],
            directory: root
        )

        guard
            json.status == 0,
            let plist = try? JSONSerialization.jsonObject(with: Data(json.log.utf8)) as? [String: Any],
            let objects = plist["objects"] as? [String: [String: Any]]
        else { return [] }

        let container = String(project.path.dropFirst(root.path.count + 1))

        return objects
            .compactMap { id, object -> Target? in
                guard
                    object["isa"] as? String == "PBXNativeTarget",
                    object["productType"] as? String == "com.apple.product-type.bundle.unit-test",
                    let name = object["name"] as? String
                else { return nil }
                return Target(name: name, blueprint: id, container: container)
            }
            .sorted { $0.name < $1.name }
    }

    static func scheme(for targets: [Target]) -> String {
        func reference(_ target: Target) -> String {
            """
                        <BuildableReference
                           BuildableIdentifier = "primary"
                           BlueprintIdentifier = "\(target.blueprint)"
                           BuildableName = "\(escape(target.name)).xctest"
                           BlueprintName = "\(escape(target.name))"
                           ReferencedContainer = "container:\(escape(target.container))">
                        </BuildableReference>
            """
        }

        let builds = targets.map { target in
            """
                     <BuildActionEntry
                        buildForTesting = "YES"
                        buildForRunning = "NO"
                        buildForProfiling = "NO"
                        buildForArchiving = "NO"
                        buildForAnalyzing = "NO">
            \(reference(target))
                     </BuildActionEntry>
            """
        }.joined(separator: "\n")

        let testables = targets.map { target in
            """
                     <TestableReference
                        skipped = "NO">
            \(reference(target))
                     </TestableReference>
            """
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- Written by litmus into its working copy. Never part of your project. -->
        <Scheme
           LastUpgradeVersion = "1600"
           version = "1.7">
           <BuildAction
              parallelizeBuildables = "YES"
              buildImplicitDependencies = "YES">
              <BuildActionEntries>
        \(builds)
              </BuildActionEntries>
           </BuildAction>
           <TestAction
              buildConfiguration = "Debug"
              shouldUseLaunchSchemeArgsEnv = "YES"
              codeCoverageEnabled = "YES">
              <Testables>
        \(testables)
              </Testables>
           </TestAction>
        </Scheme>

        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }
}

/// Collects `.xcodeproj` references, resolving nested `group:` paths.
private final class WorkspaceReader: NSObject, XMLParserDelegate {
    private(set) var projects: [String] = []
    private var groups: [String] = []

    func parser(
        _ parser: XMLParser,
        didStartElement element: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        let location = attributes["location"] ?? ""

        switch element {
        case "Group":
            groups.append(Self.path(location, under: groups.last ?? ""))
        case "FileRef":
            let path = Self.path(location, under: groups.last ?? "")
            if path.hasSuffix(".xcodeproj") { projects.append(path) }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement element: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        if element == "Group" { groups.removeLast() }
    }

    /// `group:` is relative to the enclosing group; `container:` to the
    /// workspace. Anything else — absolute paths — is outside the copy.
    private static func path(_ location: String, under base: String) -> String {
        if location.hasPrefix("group:") {
            let relative = String(location.dropFirst("group:".count))
            return base.isEmpty ? relative : (relative.isEmpty ? base : base + "/" + relative)
        }
        if location.hasPrefix("container:") {
            return String(location.dropFirst("container:".count))
        }
        return base
    }
}
