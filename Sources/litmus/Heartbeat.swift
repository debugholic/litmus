import Foundation

/// Says how long a step has been running, while it runs.
///
/// A build or a suite is minutes of a blocked process with nothing on screen,
/// and silence on a terminal reads as a hang. Naming the step before waiting
/// on it was not enough: the gap between "measuring coverage…" and the first
/// result is where people start wondering whether it died.
///
/// Printed as whole lines rather than redrawn in place, so a CI log reads the
/// same as a terminal.
final class Heartbeat: @unchecked Sendable {
    private let interval: TimeInterval
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var started = Date()

    init(every interval: TimeInterval = 30) {
        self.interval = interval
    }

    func begin() {
        lock.lock()
        defer { lock.unlock() }

        timer?.cancel()
        started = Date()

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            print("    … \(Self.elapsed(since: started))")
        }
        timer.resume()

        self.timer = timer
    }

    /// How long the step took, or nil if it was never started.
    @discardableResult
    func end() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }

        guard let timer else { return nil }
        timer.cancel()
        self.timer = nil

        return Date().timeIntervalSince(started)
    }

    static func elapsed(since start: Date) -> String {
        format(Date().timeIntervalSince(start))
    }

    static func format(_ seconds: TimeInterval) -> String {
        seconds < 60
            ? String(format: "%.0fs", seconds)
            : String(format: "%dm %02ds", Int(seconds) / 60, Int(seconds) % 60)
    }
}
