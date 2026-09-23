import Foundation
import LitmusCore

/// Works out what the caller would otherwise have to type.
///
/// Every default here is one a person would reach the same way — by looking at
/// the directory, asking xcodebuild, or asking git. Where the answer is
/// genuinely ambiguous, nothing is chosen: a run against the wrong scheme
/// costs hours before it says anything.
enum Discovery {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - harness

    /// A project that reaches for UIKit cannot build for this machine, so its
    /// tests have to go through a simulator whatever else is true of it.
    static func harness(in project: URL) -> HarnessKind {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: project.path)) ?? []

        if contents.contains(where: { $0.hasSuffix(".xcworkspace") || $0.hasSuffix(".xcodeproj") }) {
            return .xcode
        }

        return importsUIKit(under: project.appendingPathComponent("Sources")) ? .xcode : .swiftpm
    }

    private static func importsUIKit(under root: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return false }

        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if source.contains("\nimport UIKit") || source.hasPrefix("import UIKit") {
                return true
            }
        }

        return false
    }

    // MARK: - scheme

    /// Litmus's scheme of every unit test, written into `project` when
    /// `write` allows it, or found there from an earlier write.
    static func allTestsScheme(in project: URL, write: Bool) throws -> String? {
        if write { return try AllTestsScheme.prepare(in: project) }

        guard let location = AllTestsScheme.schemeLocation(in: project) else { return nil }
        let file = location.directory.appendingPathComponent("\(AllTestsScheme.name).xcscheme")
        return FileManager.default.fileExists(atPath: file.path) ? AllTestsScheme.name : nil
    }

    /// The one scheme, when there is one.
    ///
    /// With several, this stops and lists them. Picking the first would be a
    /// guess that takes hours to disprove.
    static func scheme(in project: URL) throws -> String {
        let listed = try run("/usr/bin/xcodebuild", ["-list", "-json"], in: project)

        guard
            let root = try? JSONSerialization.jsonObject(with: Data(listed.utf8)) as? [String: Any],
            let container = (root["project"] ?? root["workspace"]) as? [String: Any],
            let schemes = container["schemes"] as? [String],
            !schemes.isEmpty
        else {
            throw Failure(description: "could not read the schemes here — pass --scheme")
        }

        guard schemes.count == 1 else {
            throw Failure(description: """
            this project has \(schemes.count) schemes, so pass --scheme:
              \(schemes.joined(separator: "\n  "))
            """)
        }

        return schemes[0]
    }

    // MARK: - simulators

    /// Simulators to spread the work over.
    ///
    /// Booted ones come first: the person picked those, and a simulator that is
    /// already up costs nothing to reach. Beyond that, the newest runtime's
    /// iPhones.
    static func simulators(count: Int) throws -> [String] {
        let listed = try run(
            "/usr/bin/xcrun",
            ["simctl", "list", "devices", "available", "-j"],
            in: URL(fileURLWithPath: NSTemporaryDirectory())
        )

        guard
            let root = try? JSONSerialization.jsonObject(with: Data(listed.utf8)) as? [String: Any],
            let byRuntime = root["devices"] as? [String: [[String: Any]]]
        else {
            throw Failure(description: "could not list simulators — pass --simulators")
        }

        // Runtime identifiers sort by version, so the last one is the newest.
        let runtimes = byRuntime.keys.filter { $0.contains("iOS") }.sorted()

        var booted: [String] = []
        var idle: [String] = []

        for runtime in runtimes.reversed() {
            for device in byRuntime[runtime] ?? [] {
                guard
                    let udid = device["udid"] as? String,
                    let name = device["name"] as? String,
                    name.hasPrefix("iPhone")
                else { continue }

                if device["state"] as? String == "Booted" {
                    booted.append(udid)
                } else {
                    idle.append(udid)
                }
            }
        }

        let chosen = Array((booted + idle).prefix(count))

        guard !chosen.isEmpty else {
            throw Failure(description: "no iPhone simulator is available — pass --destination")
        }

        return chosen
    }

    // MARK: - git

    /// The branch this one is measured against.
    ///
    /// `origin/HEAD` is what the remote calls its default branch, which is the
    /// same thing a review diffs against. Absent — no remote, a shallow clone —
    /// there is no sensible base and the whole tree is the honest scope.
    static func defaultBase(in project: URL) -> String? {
        guard
            let head = try? run(
                "/usr/bin/git",
                ["symbolic-ref", "refs/remotes/origin/HEAD"],
                in: project
            ).trimmingCharacters(in: .whitespacesAndNewlines),
            head.hasPrefix("refs/remotes/")
        else { return nil }

        let base = String(head.dropFirst("refs/remotes/".count))

        // On the default branch itself there is nothing to compare against,
        // and an empty diff would report a suite as perfect on zero mutants.
        guard
            let current = try? run("/usr/bin/git", ["rev-parse", "--abbrev-ref", "HEAD"], in: project)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !base.hasSuffix("/\(current)")
        else { return nil }

        return base
    }

    // MARK: -

    private static func run(_ executable: String, _ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw Failure(description: "\(executable) \(arguments.joined(separator: " ")) failed")
        }

        return String(data: data, encoding: .utf8) ?? ""
    }
}
