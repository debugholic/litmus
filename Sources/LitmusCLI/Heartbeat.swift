import Foundation
import os
import LitmusCore

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
    private struct State {
        var timer: DispatchSourceTimer?
        var started = Date()
        var label: String?
        var detail: String?
    }
    /// Unchecked: the timer is not Sendable, and the line is drawn while
    /// the lock is held so two redraws never interleave.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(live: Bool = Heartbeat.live) {
        self.live = live
        self.interval = live ? 1 : 30
    }

    /// Shows `label` and starts counting.
    func begin(_ label: String) {
        state.withLockUnchecked { state in
            state.timer?.cancel()
            state.started = Date()
            state.label = label
            state.detail = nil

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

            state.timer = timer
        }
    }

    /// Stops counting and returns how long the step took, or nil if it was
    /// never started.
    ///
    /// On a terminal the line is left with its final time, or cleared when
    /// `keep` is false — for a line that the result is about to replace.
    @discardableResult
    func end(keep: Bool = true) -> TimeInterval? {
        state.withLockUnchecked { state in
            guard let timer = state.timer else { return nil }
            timer.cancel()
            state.timer = nil

            let took = Date().timeIntervalSince(state.started)
            if live, let label = state.label {
                if keep {
                    draw("\(label)  \(Self.format(took))\n")
                } else {
                    draw("")
                }
            }
            state.label = nil

            return took
        }
    }

    /// What the step is doing right now, shown beside its name until the
    /// next change or the next step.
    func report(_ detail: String) {
        state.withLockUnchecked { state in
            guard state.timer != nil, let label = state.label else { return }
            state.detail = detail
            if live { draw(line(label, state)) }
        }
    }

    private func tick() {
        state.withLockUnchecked { state in
            guard state.timer != nil, let label = state.label else { return }

            if live {
                draw(line(label, state))
            } else {
                let doing = state.detail.map { " — \($0)" } ?? ""
                print("    … \(Self.elapsed(since: state.started))\(doing)")
            }
        }
    }

    private func line(_ label: String, _ state: State) -> String {
        let doing = state.detail.map { " \($0)" } ?? ""
        return "\(label)\(doing)  \(Self.elapsed(since: state.started))"
    }

    /// Replaces the current line: back to its start, clear it, write.
    ///
    /// Cut to the terminal's width, in columns rather than characters. A
    /// line that wraps leaves its first half behind, and every redraw after
    /// it stacks another copy.
    private func draw(_ text: String) {
        let trailingNewline = text.hasSuffix("\n")
        var body = trailingNewline ? String(text.dropLast()) : text
        let width = Self.columns
        if width > 1 {
            body = TerminalWidth.cut(body, to: width - 1)
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
