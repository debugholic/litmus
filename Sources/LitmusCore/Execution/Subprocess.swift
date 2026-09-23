import Foundation

/// Runs a tool to the end, or until it has run too long.
enum Subprocess {
    struct Output {
        let log: String
        let status: Int32
        /// Stopped for running past its time, not finished.
        let timedOut: Bool
    }

    static func run(
        executable: String,
        arguments: [String],
        directory: URL,
        environment: [String: String] = [:],
        timeout: TimeInterval? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment
            .merging(environment) { _, new in new }

        // Drained on its own thread: a full pipe buffer would otherwise stall
        // the child, and a test log easily exceeds it.
        let log = Collected(onLine: onLine)
        let drained = DispatchSemaphore(value: 0)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                drained.signal()
            } else {
                log.append(chunk)
            }
        }

        try process.run()

        let deadline = timeout.map { Date().addingTimeInterval($0) }
        var timedOut = false

        if deadline == nil {
            process.waitUntilExit()
        } else {
            while process.isRunning {
                if let deadline, Date() > deadline {
                    timedOut = true
                    stop(process)
                    break
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            process.waitUntilExit()
        }

        // Something the tool started can outlive it and keep the pipe open,
        // so the end of the log is waited for, but not forever.
        if drained.wait(timeout: .now() + 10) == .timedOut {
            pipe.fileHandleForReading.readabilityHandler = nil
        }

        return Output(log: log.text, status: process.terminationStatus, timedOut: timedOut)
    }

    /// Asks, then insists — the tool and everything it started.
    ///
    /// `swift test` runs the tests in a helper of its own. Stopping only the
    /// tool left that helper spinning in the mutant's infinite loop long
    /// after the run had moved on.
    static func stop(_ process: Process) {
        let tree = descendants(of: process.processIdentifier)
        process.terminate()
        for pid in tree { kill(pid, SIGTERM) }

        let deadline = Date().addingTimeInterval(30)
        while process.isRunning || tree.contains(where: isAlive), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }

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
}
