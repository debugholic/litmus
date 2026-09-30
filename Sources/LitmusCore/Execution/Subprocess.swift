import Foundation

/// Runs a tool to the end, or until it has run too long.
public enum Subprocess {
    struct Output {
        let log: String
        let status: Int32
        /// Stopped for running past its time, not finished.
        let timedOut: Bool
    }

    /// Awaited rather than waited on. A lane that held a thread while its
    /// tests ran took one of the few the tasks share, and on a runner with
    /// three cores the third lane waited for a thread rather than a
    /// simulator.
    static func run(
        executable: String,
        arguments: [String],
        directory: URL,
        environment: [String: String] = [:],
        timeout: TimeInterval? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment
            .merging(environment) { _, new in new }

        // Drained as it comes: a full pipe buffer would otherwise stall the
        // child, and a test log easily exceeds it.
        let log = Collected(onLine: onLine)
        let drained = Latch()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                drained.open()
            } else {
                log.append(chunk)
            }
        }

        let exited = Latch()
        process.terminationHandler = { _ in exited.open() }

        try process.run()
        track(process)
        defer { untrack(process) }

        var timedOut = false
        if await !exited.wait(timeout: timeout) {
            // A lane given up on: what it started goes with it.
            if Task.isCancelled {
                await stop(process, grace: 0)
                throw CancellationError()
            }
            timedOut = true
            await stop(process)
            await exited.wait()
            // Cancelled while it was being stopped: there is no status yet.
            guard exited.isOpen else { throw CancellationError() }
        }

        // Something the tool started can outlive it and keep the pipe open,
        // so the end of the log is waited for, but not forever.
        if await !drained.wait(timeout: 10) {
            pipe.fileHandleForReading.readabilityHandler = nil
        }

        return Output(log: log.text, status: process.terminationStatus, timedOut: timedOut)
    }

    // MARK: - what is running

    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: [ObjectIdentifier: Process] = [:]

    /// Remembers a tool Litmus started, so an interrupted run can stop it.
    static func track(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        running[ObjectIdentifier(process)] = process
    }

    static func untrack(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        running[ObjectIdentifier(process)] = nil
    }

    /// Whether a tool Litmus started is still running.
    static func isRunning(matching: (Process) -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running.values.contains { $0.isRunning && matching($0) }
    }

    /// Stops every tool Litmus started and everything they started.
    ///
    /// For an interrupted run. Killed on its own, Litmus left xcodebuild
    /// running, still writing into the working copy, and the next run failed
    /// on the result bundle it had left there.
    ///
    /// `matching` narrows it, so a test can stop what it started without
    /// stopping what other tests are running at the same time.
    public static func stopAll(grace: TimeInterval = 5, matching: (Process) -> Bool = { _ in true }) {
        lock.lock()
        let processes = running.values.filter(matching)
        lock.unlock()

        for process in processes where process.isRunning {
            stopNow(process, grace: grace)
        }
    }

    /// Stops tools an earlier run left behind: anything whose command line
    /// names this working copy. A run killed outright cannot clean up after
    /// itself, so the next one does.
    public static func stopLeftovers(naming path: String) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", NSRegularExpression.escapedPattern(for: path)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice

        guard (try? pgrep.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()

        let me = getpid()
        let pids = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != me && $0 != pgrep.processIdentifier }

        for pid in pids {
            for child in descendants(of: pid) { kill(child, SIGKILL) }
            kill(pid, SIGKILL)
        }
        return pids
    }

    /// Asks, then insists — the tool and everything it started.
    ///
    /// `swift test` runs the tests in a helper of its own. Stopping only the
    /// tool left that helper spinning in the mutant's infinite loop long
    /// after the run had moved on.
    static func stop(_ process: Process, grace: TimeInterval = 30) async {
        let tree = ask(process)

        let deadline = Date().addingTimeInterval(grace)
        while alive(process, tree), Date() < deadline {
            // Cancelled, it insists at once.
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { break }
        }

        insist(process, tree)
    }

    /// The same, for an interrupted run, which has no task to wait in.
    private static func stopNow(_ process: Process, grace: TimeInterval) {
        let tree = ask(process)

        let deadline = Date().addingTimeInterval(grace)
        while alive(process, tree), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }

        insist(process, tree)
    }

    private static func ask(_ process: Process) -> [pid_t] {
        let tree = descendants(of: process.processIdentifier)
        process.terminate()
        for pid in tree { kill(pid, SIGTERM) }
        return tree
    }

    private static func alive(_ process: Process, _ tree: [pid_t]) -> Bool {
        process.isRunning || tree.contains(where: isAlive)
    }

    private static func insist(_ process: Process, _ tree: [pid_t]) {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        for pid in tree where isAlive(pid) {
            kill(pid, SIGKILL)
        }
    }

    /// Children first found, then theirs, by asking `pgrep -P`.
    static func descendants(of pid: pid_t) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice

        guard (try? pgrep.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()

        let children = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }

        return children + children.flatMap(descendants(of:))
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var partial = Data()
        private let onLine: (@Sendable (String) -> Void)?

        init(onLine: (@Sendable (String) -> Void)?) {
            self.onLine = onLine
        }

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)

            // Whole lines only; the rest waits for the next chunk.
            var lines: [String] = []
            if onLine != nil {
                partial.append(chunk)
                while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
                    lines.append(String(decoding: partial[partial.startIndex..<newline], as: UTF8.self))
                    partial = Data(partial[partial.index(after: newline)...])
                }
            }
            lock.unlock()

            lines.forEach { onLine?($0) }
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Opens once, and is awaited without holding a thread.
    final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]

        var isOpen: Bool {
            lock.lock()
            defer { lock.unlock() }
            return opened
        }

        func open() {
            lock.lock()
            opened = true
            let resumed = waiting.values
            waiting = [:]
            lock.unlock()

            resumed.forEach { $0.resume() }
        }

        /// Returns once it opens, or once the task is cancelled.
        func wait() async {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    if opened || Task.isCancelled {
                        lock.unlock()
                        continuation.resume()
                    } else {
                        waiting[id] = continuation
                        lock.unlock()
                    }
                }
            } onCancel: {
                lock.lock()
                let continuation = waiting.removeValue(forKey: id)
                lock.unlock()
                continuation?.resume()
            }
        }

        /// Whether it opened within `seconds`. Nil waits as long as it takes.
        func wait(timeout seconds: TimeInterval?) async -> Bool {
            guard let seconds else {
                await wait()
                return isOpen
            }

            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.wait() }
                group.addTask { try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
                await group.next()
                group.cancelAll()
            }
            return isOpen
        }
    }
}
