import Foundation

/// Reads lcov, which is what `llvm-cov export -format=lcov` writes.
///
/// The JSON export gives segments rather than lines: each one opens a region
/// at a position, and turning that back into per-line counts means redoing the
/// arithmetic llvm-cov already did. Getting it slightly wrong is not a rounding
/// error here — a line wrongly called uncovered drops a mutant that could have
/// been killed, and the hole it was pointing at goes unreported. lcov states
/// the counts outright, so nothing is inferred.
enum Lcov {
    /// `SF:<path>` opens a file, `DA:<line>,<count>` gives one line,
    /// `end_of_record` closes it.
    static func parse(_ text: String) -> Coverage {
        var covered: [String: Set<Int>] = [:]
        var accounted: [String: Set<Int>] = [:]
        var file: String?
        var seen: Set<String> = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("SF:") {
                file = String(line.dropFirst(3))
                seen.insert(file!)
                continue
            }

            if line == "end_of_record" {
                file = nil
                continue
            }

            guard
                let file,
                line.hasPrefix("DA:"),
                case let parts = line.dropFirst(3).split(separator: ","),
                parts.count >= 2,
                let number = Int(parts[0]),
                let count = Int(parts[1])
            else { continue }

            accounted[file, default: []].insert(number)
            if count > 0 { covered[file, default: []].insert(number) }
        }

        let files = seen.reduce(into: [String: Coverage.File]()) { result, path in
            let covered = covered[path] ?? []
            result[path] = covered.isEmpty
                ? Coverage.File.unreached
                : .lines(covered: covered, accounted: accounted[path] ?? [])
        }

        return Coverage(files: files)
    }

    static func read(contentsOf url: URL) throws -> Coverage {
        parse(try String(contentsOf: url, encoding: .utf8))
    }
}
