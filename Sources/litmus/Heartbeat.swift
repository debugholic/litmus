import Foundation

/// Says what a step is doing and how long it has been at it, while it runs.
///
/// A build or a suite is minutes of a blocked process with nothing on screen,
/// and silence on a terminal reads as a hang. Naming the step before waiting
/// on it was not enough: the gap between "measuring coverage…" and the first
/// result is where people start wondering whether it died.
///
/// On a terminal the step's line is redrawn in place every second, with the
/// time so far. Anywhere else — a CI log, a file — a redrawn line would arrive
/// as a pile of carriage returns, so the step is printed once and followed by
/// a line every thirty seconds.
final class Heartbeat: @unchecked Sendable {
    /// The one the whole run shares: only one step runs at a time, and what
    /// xcodebuild reports belongs to whichever that is.
    static let shared = Heartbeat()

    /// Whether stdout is a terminal that can redraw a line.
    static let live: Bool = isatty(STDOUT_FILENO) != 0
        && ProcessInfo.processInfo.environment["TERM"] != "dumb"

    private let live: Bool
    private let interval: TimeInterval
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var started = Date()
    private var label: String?
    private var detail: String?

    init(live: Bool = Heartbeat.live) {
        self.live = live
        self.interval = live ? 1 : 30
    }

    /// Shows `label` and starts counting.
    func begin(_ label: String) {
        lock.lock()
        defer { lock.unlock() }

        timer?.cancel()
        started = Date()
        self.label = label
        detail = nil

        if live {
            draw("\(label)  0s")
        } else {
            print(label)
        }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()

        self.timer = timer
    }

    /// Stops counting and returns how long the step took, or nil if it was
    /// never started.
    ///
    /// On a terminal the line is left with its final time, or cleared when
    /// `keep` is false — for a line that the result is about to replace.
    @discardableResult
    func end(keep: Bool = true) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }

        guard let timer else { return nil }
        timer.cancel()
        self.timer = nil

        let took = Date().timeIntervalSince(started)
        if live, let label {
            if keep {
                draw("\(label)  \(Self.format(took))\n")
            } else {
                draw("")
            }
        }
        label = nil

        return took
    }

    /// What the step is doing right now, shown beside its name until the
    /// next change or the next step.
    func report(_ detail: String) {
        lock.lock()
        defer { lock.unlock() }

        guard timer != nil, let label else { return }
        self.detail = detail
        if live { draw(line(label)) }
    }

    private func tick() {
        lock.lock()
        defer { lock.unlock() }

        guard timer != nil, let label else { return }

        if live {
            draw(line(label))
        } else {
            let doing = detail.map { " — \($0)" } ?? ""
            print("    … \(Self.elapsed(since: started))\(doing)")
        }
    }

    private func line(_ label: String) -> String {
        let doing = detail.map { " \($0)" } ?? ""
        return "\(label)\(doing)  \(Self.elapsed(since: started))"
    }

    /// Replaces the current line: back to its start, clear it, write.
    ///
    /// Cut to the terminal's width. A line that wraps leaves its first half
    /// behind, and every redraw after it stacks another copy.
    private func draw(_ text: String) {
        let trailingNewline = text.hasSuffix("\n")
        var body = trailingNewline ? String(text.dropLast()) : text
        let width = Self.columns
        if width > 1, body.count > width - 1 {
            body = String(body.prefix(width - 2)) + "…"
        }
        print("\r\u{1B}[2K" + body + (trailingNewline ? "\n" : ""), terminator: "")
        fflush(stdout)
    }

    private static var columns: Int {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return 0 }
        return Int(size.ws_col)
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
