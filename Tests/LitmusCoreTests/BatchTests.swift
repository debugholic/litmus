import Foundation
import SwiftParser
import Testing

@testable import LitmusCore

/// Many mutants in one test process, and what happens when one of them takes
/// the process down.
///
/// A shell script stands in for xcodebuild and does what the driver does:
/// reads the batch and writes START and END lines to the results file. What is
/// checked is litmus's side — relaunching past a crash, stopping a hang, and
/// refusing a red baseline.
@Suite("Batch")
struct BatchTests {
    /// Behaves by the name of each id:
    /// `crash…` exits mid-run, `hang…` never finishes, `killed…` fails, and
    /// `uncovered…` is reached by no test, and anything else passes. A batch
    /// that mentions `redbaseline` fails the baseline; one that mentions
    /// `dyingprobe` dies while probing, if it is asked to probe.
    private final class FakeRunner {
        let directory: URL
        var path: String { directory.appendingPathComponent("xcodebuild").path }
        var launches: Int {
            (try? String(contentsOf: directory.appendingPathComponent("launches"), encoding: .utf8))?
                .split(separator: "\n").count ?? 0
        }

        init(neverStarts: Bool = false) throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("litmus-batch-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let body = neverStarts
                ? "sleep 100"
                : """
                red=0; grep -q redbaseline "$batch" && red=1
                echo "${TEST_RUNNER_LITMUS_PROBE_DIR:-none}" >> "\(directory.path)/probes"
                while IFS= read -r id || [ -n "$id" ]; do
                  echo "START $id" >> "$out"
                  case "$id" in
                    -) if [ $red = 1 ]; then echo "END - killed 0.1" >> "$out"; exit 0; fi
                       echo "END - survived 0.1" >> "$out"
                       if [ -n "$TEST_RUNNER_LITMUS_PROBE_DIR" ]; then
                         echo "START ~probe" >> "$out"
                         grep -q dyingprobe "$batch" && exit 1
                         echo "END ~probe survived 0.1" >> "$out"
                       fi ;;
                    uncovered*) echo "END $id nocoverage 0" >> "$out" ;;
                    crash*) exit 1 ;;
                    hang*) sleep 100 ;;
                    killed*) echo "END $id killed 0.1" >> "$out" ;;
                    *) echo "END $id survived 0.1" >> "$out" ;;
                  esac
                done < "$batch"
                """

            let script = """
            #!/bin/sh
            echo launched >> "\(directory.path)/launches"
            batch="$TEST_RUNNER_LITMUS_BATCH_FILE"
            out="$TEST_RUNNER_LITMUS_RESULTS_FILE"
            : > "$out"
            \(body)
            """
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }

        /// The probe folder each launch was given, or "none".
        var probes: [String] {
            (try? String(contentsOf: directory.appendingPathComponent("probes"), encoding: .utf8))?
                .split(separator: "\n").map(String.init) ?? []
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private var quick: Batch.Timeouts {
        var timeouts = Batch.Timeouts()
        timeouts.launch = 3
        timeouts.baseline = 3
        timeouts.mutant = 2
        timeouts.floor = 2
        return timeouts
    }

    private func run(
        _ ids: [String],
        with runner: FakeRunner,
        events: inout [Batch.Event]
    ) throws -> [String: Verdict] {
        let xcodebuild = Xcodebuild(
            executable: runner.path,
            workingDirectory: runner.directory,
            scheme: "App",
            derivedDataPath: runner.directory.appendingPathComponent("dd")
        )
        let plan = Batch.Plan(built: BuiltTests(artifact: URL(fileURLWithPath: "/tmp/App.xctestrun")))

        var collected: [Batch.Event] = []
        let verdicts = try xcodebuild.runBatch(plan, target: "AppTests", lane: "id=X", ids: ids, timeouts: quick) {
            collected.append($0)
        }
        events = collected
        return verdicts
    }

    // MARK: - one process

    @Test("gives every mutant a verdict in one launch")
    func oneLaunch() throws {
        let runner = try FakeRunner()
        var events: [Batch.Event] = []

        let verdicts = try run(["-", "a", "killed-b", "c"], with: runner, events: &events)

        #expect(verdicts == ["-": .survived, "a": .survived, "killed-b": .killed, "c": .survived])
        #expect(runner.launches == 1)
        #expect(events.first == .started("-"))
    }

    // MARK: - recovery

    /// A crash takes the process and the rest of the batch with it. The
    /// crashing mutant is killed — the suite did not pass with it on — and
    /// the rest run in a fresh launch, without the baseline again.
    @Test("relaunches past a mutant that crashes the process")
    func crash() throws {
        let runner = try FakeRunner()
        var events: [Batch.Event] = []

        let verdicts = try run(["-", "a", "crash-b", "c", "killed-d"], with: runner, events: &events)

        #expect(verdicts == [
            "-": .survived, "a": .survived, "crash-b": .killed, "c": .survived, "killed-d": .killed,
        ])
        #expect(runner.launches == 2)
        #expect(events.filter { $0 == .started("-") }.count == 1)
    }

    /// An infinite loop never ends by itself. It is stopped, counted as a
    /// timeout, and the batch goes on.
    @Test("stops a mutant that hangs, and carries on")
    func hang() throws {
        let runner = try FakeRunner()
        var events: [Batch.Event] = []

        let verdicts = try run(["-", "hang-a", "b"], with: runner, events: &events)

        #expect(verdicts == ["-": .survived, "hang-a": .timedOut, "b": .survived])
        #expect(runner.launches == 2)
    }

    @Test("survives two crashes in a row")
    func crashes() throws {
        let runner = try FakeRunner()
        var events: [Batch.Event] = []

        let verdicts = try run(["-", "crash-a", "crash-b", "c"], with: runner, events: &events)

        #expect(verdicts == ["-": .survived, "crash-a": .killed, "crash-b": .killed, "c": .survived])
        #expect(runner.launches == 3)
    }

    /// Measured against a failing suite every mutant looks killed, so a red
    /// baseline ends the batch rather than scoring anything.
    @Test("stops at a red baseline")
    func redBaseline() throws {
        let runner = try FakeRunner()
        var events: [Batch.Event] = []

        let verdicts = try run(["-", "redbaseline", "b"], with: runner, events: &events)

        #expect(verdicts == ["-": .killed])
        #expect(runner.launches == 1)
    }

    @Test("gives up when the runner never starts")
    func neverStarts() throws {
        let runner = try FakeRunner(neverStarts: true)
        var events: [Batch.Event] = []

        #expect(throws: Xcodebuild.Failure.self) {
            _ = try run(["-", "a"], with: runner, events: &events)
        }
    }

    // MARK: - the report

    @Test("reads START and END lines")
    func parse() {
        #expect(Batch.Report.parse("START Foo_Bar_1_2_3") == .started("Foo_Bar_1_2_3"))
        #expect(Batch.Report.parse("END Foo_Bar_1_2_3 killed 0.25") == .finished("Foo_Bar_1_2_3", .killed, 0.25))
        #expect(Batch.Report.parse("END - survived 3.5") == .finished("-", .survived, 3.5))
        #expect(Batch.Report.parse("noise from the runner") == nil)
    }

    // MARK: - the driver

    @Test("writes a driver that parses as Swift")
    func driverParses() {
        #expect(!Parser.parse(source: "import Testing\n" + Batch.driver).hasError)
    }

    /// The copy used to be hardlinks, and a driver appended to a test file
    /// in it landed in the user's project. Appending has to replace the file,
    /// never write into it.
    @Test("appends the driver without touching a hardlinked original")
    func appendDriverReplaces() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("litmus-driver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let original = root.appendingPathComponent("Original.swift")
        let copy = root.appendingPathComponent("Copy.swift")
        try "import Testing\n".write(to: original, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: original, to: copy)

        try Batch.appendDriver(to: .init(name: "AppTests", files: [copy.path]))

        #expect(try String(contentsOf: original, encoding: .utf8) == "import Testing\n")
        #expect(try String(contentsOf: copy, encoding: .utf8).contains(Batch.driverClass))
    }

    @Test("appends the driver once")
    func appendDriverOnce() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("litmus-once-\(UUID().uuidString).swift")
        defer { try? FileManager.default.removeItem(at: file) }
        try "import Testing\n".write(to: file, atomically: true, encoding: .utf8)

        let target = TestedScope.TestTarget(name: "AppTests", files: [file.path])
        try Batch.appendDriver(to: target)
        try Batch.appendDriver(to: target)

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.components(separatedBy: "final class \(Batch.driverClass)").count == 2)
    }

    // MARK: - probing

    @Test("asks the driver to probe, and reads a mutant no test reaches")
    func probes() throws {
        let runner = try FakeRunner()
        var events: [Batch.Event] = []

        let verdicts = try run(["-", "a", "uncovered-b"], with: runner, events: &events)

        #expect(verdicts == ["-": .survived, "a": .survived, "uncovered-b": .noCoverage])
        #expect(runner.probes.count == 1)
        #expect(runner.probes.first != "none")
        #expect(events.contains(.finished(Batch.probe, .survived, 0.1)))
    }

    /// A probe that dies is not a mutant's doing; nothing should be scored
    /// for it, and the batch carries on the old way.
    @Test("carries on without probing when the probe crashes")
    func probeCrash() throws {
        let runner = try FakeRunner()
        var events: [Batch.Event] = []

        let verdicts = try run(["-", "dyingprobe-a", "killed-b"], with: runner, events: &events)

        #expect(verdicts == ["-": .survived, "dyingprobe-a": .survived, "killed-b": .killed])
        #expect(verdicts[Batch.probe] == nil)
        #expect(runner.probes.count == 2)
        #expect(runner.probes.last == "none")
    }

    @Test("reads a mutant no test reaches from the driver's report")
    func parseNoCoverage() {
        #expect(Batch.Report.parse("END A_B_1_2_3 nocoverage 0") == .finished("A_B_1_2_3", .noCoverage, 0))
    }

    /// A filter that matched no test makes Swift Testing exit 69. That says
    /// nothing about the mutant, and must not score a kill.
    @Test("reads a run whose filter matched no test as an error")
    func parseNoTests() {
        #expect(Batch.Report.parse("END A_B_1_2_3 error 0.01") == .finished("A_B_1_2_3", .error, 0.01))
        #expect(Batch.driver.contains("case \(Batch.noTestsFound): return \"error\""))
    }
}
