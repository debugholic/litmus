import Foundation
import LitmusCore

/// Stops everything a run started when the run itself is stopped.
///
/// Ctrl-C reached Litmus and not the xcodebuild it had started, which went
/// on writing into the working copy. The next run found its result bundle
/// already there and failed.
enum Interruption {
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    static func install() {
        guard sources.isEmpty else { return }

        for number in [SIGINT, SIGTERM, SIGHUP] {
            // Ignored here so the dispatch source receives it instead of the
            // default handler ending the process on the spot.
            signal(number, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                print("\n  stopping — ending xcodebuild and the tests it started…")
                Subprocess.stopAll(grace: 5)
                RunLock.release()
                exit(128 + number)
            }
            source.resume()
            sources.append(source)
        }
    }
}

/// One run per working copy.
///
/// Two runs in one copy delete and rewrite each other's files; what the
/// second one reports is an xcodebuild error about a file the first one
/// wrote. Said plainly instead, before anything is touched.
enum RunLock {
    struct Busy: Error, CustomStringConvertible {
        let pid: pid_t
        let workingCopy: URL

        var description: String {
            """
            another litmus run (PID \(pid)) is using \(workingCopy.path).
            Wait for it to finish, or stop it with: kill \(pid)
            """
        }
    }

    nonisolated(unsafe) private static var held: URL?

    static func acquire(for workingCopy: URL) throws {
        try FileManager.default.createDirectory(
            at: workingCopy.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let file = workingCopy.deletingLastPathComponent()
            .appendingPathComponent(workingCopy.lastPathComponent + ".lock")

        if let text = try? String(contentsOf: file, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid != getpid(),
           kill(pid, 0) == 0 {
            throw Busy(pid: pid, workingCopy: workingCopy)
        }

        try "\(getpid())\n".write(to: file, atomically: true, encoding: .utf8)
        held = file
        atexit { RunLock.release() }

        // A run killed outright could not stop what it started. Anything
        // still naming this copy is from such a run, since this one holds
        // the lock and has started nothing yet.
        let leftovers = Subprocess.stopLeftovers(naming: workingCopy.path)
        if !leftovers.isEmpty {
            print("  stopped \(leftovers.count) process(es) an earlier run left behind")
        }
    }

    static func release() {
        guard let held else { return }
        try? FileManager.default.removeItem(at: held)
        self.held = nil
    }
}
