import Foundation
import Testing

@testable import LitmusCore

@Suite("Subprocess")
struct SubprocessTests {
    private let directory = URL(fileURLWithPath: NSTemporaryDirectory())

    @Test("keeps the whole log of a tool that finishes")
    func finishes() async throws {
        let output = try await Subprocess.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo one; echo two >&2; exit 3"],
            directory: directory,
            timeout: 30
        )

        #expect(output.log.contains("one"))
        #expect(output.log.contains("two"))
        #expect(output.status == 3)
        #expect(!output.timedOut)
    }

    /// A mutant that turns a loop infinite never finishes on its own.
    @Test("stops a tool that runs past its time")
    func stopsAHang() async throws {
        let started = Date()

        let output = try await Subprocess.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo started; exec sleep 60"],
            directory: directory,
            // Five seconds, not one: on a busy machine the shell had not
            // printed before a one-second limit stopped it.
            timeout: 5
        )

        #expect(output.timedOut)
        #expect(output.log.contains("started"))
        #expect(Date().timeIntervalSince(started) < 30)
    }

    @Test("stops what the tool started, not just the tool")
    func stopsChildren() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("litmus-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        // The child writes its pid and outlives a parent that only waits.
        _ = try await Subprocess.run(
            executable: "/bin/sh",
            arguments: ["-c", "sh -c 'echo $$ > \(marker.path); exec sleep 60' & wait"],
            directory: directory,
            // Long enough for the child to write its pid on a busy machine.
            timeout: 5
        )

        let pid = try #require(pid_t(
            try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        #expect(kill(pid, 0) != 0)
    }

    @Test("reads a run that was stopped as a timeout")
    func timedOutIsKilled() {
        let output = TestOutput(log: "Test run with 3 tests in 1 suites passed", status: 0, timedOut: true)

        #expect(TestSuiteOutcome(output).verdict == .timedOut)
    }

    /// A run killed outright leaves its tools running in the working copy.
    @Test("stops what an earlier run left behind, by the path it names")
    func leftovers() throws {
        let marker = "litmus-leftover-\(UUID().uuidString)"
        let stray = Process()
        stray.executableURL = URL(fileURLWithPath: "/bin/sh")
        stray.arguments = ["-c", "sleep 60; true", marker]
        try stray.run()
        defer { if stray.isRunning { stray.terminate() } }

        let stopped = Subprocess.stopLeftovers(naming: marker)
        stray.waitUntilExit()

        #expect(stopped == [stray.processIdentifier])
        #expect(!stray.isRunning)
    }

    @Test("stops every tool it is running when asked to")
    func stopsAll() async throws {
        let marker = "litmus-stop-all-\(UUID().uuidString)"
        let started = Date()
        let task = Task.detached {
            try await Subprocess.run(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 60; true", marker],
                directory: URL(fileURLWithPath: "/tmp")
            )
        }
        // Started on another task; wait until it is actually running.
        let mine: (Process) -> Bool = { $0.arguments?.contains(marker) == true }
        while !Subprocess.isRunning(matching: mine), Date().timeIntervalSince(started) < 30 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // Only this test's process: other tests run theirs at the same time.
        Subprocess.stopAll(grace: 2, matching: mine)
        let output = try await task.value

        // Stopped well before its sleep of 60 seconds ran out. A loaded CI
        // runner took 21 seconds to get there, so the bound is loose.
        #expect(output.status != 0)
        #expect(Date().timeIntervalSince(started) < 50)
    }

    /// A lane whose sibling failed is cancelled. The tool it was waiting on
    /// goes with it, rather than running on for the rest of its time.
    @Test("stops the tool when the task waiting on it is cancelled")
    func stopsWhenCancelled() async throws {
        let marker = "litmus-cancel-\(UUID().uuidString)"
        let started = Date()
        let task = Task {
            try await Subprocess.run(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 60; true", marker],
                directory: directory,
                timeout: 120
            )
        }
        let mine: (Process) -> Bool = { $0.arguments?.contains(marker) == true }
        while !Subprocess.isRunning(matching: mine), Date().timeIntervalSince(started) < 30 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!Subprocess.isRunning(matching: mine))
        #expect(Date().timeIntervalSince(started) < 50)
    }

    /// Waiting on a tool holds no thread, so more of them than there are
    /// cores all run at once.
    @Test("runs more tools at once than the machine has cores")
    func holdsNoThread() async throws {
        let count = ProcessInfo.processInfo.activeProcessorCount * 2 + 2
        let started = Date()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask {
                    _ = try await Subprocess.run(
                        executable: "/bin/sleep", arguments: ["2"], directory: directory
                    )
                }
            }
            try await group.waitForAll()
        }

        // One after another, or a core's worth at a time, would take three
        // rounds of two seconds at least.
        #expect(Date().timeIntervalSince(started) < 5.5)
    }
}
