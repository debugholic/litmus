import Foundation

/// Pairs paths that name the same file from different roots.
///
/// Litmus mutates a copy, but the facts it filters by come from elsewhere: a
/// coverage report names the original tree, and `git diff` names paths
/// relative to the repository. None of them match the copy end to end, and a
/// lookup that misses simply filters nothing — silently, and looking exactly
/// like a filter that found nothing to drop.
enum PathMatch {
    /// The key whose path shares the longest run of trailing components.
    ///
    /// A shared file name alone is not enough: two modules can each hold a
    /// `Configuration.swift`, and pairing those would filter by the wrong file.
    static func best(for path: String, among candidates: some Sequence<String>) -> String? {
        let wanted = components(of: path)
        var best: (candidate: String, score: Int)?

        for candidate in candidates {
            let other = components(of: candidate)

            var score = 0
            while score < wanted.count, score < other.count, wanted[score] == other[score] {
                score += 1
            }

            guard score > 1, score > (best?.score ?? 1) else { continue }
            best = (candidate, score)
        }

        return best?.candidate
    }

    private static func components(of path: String) -> [String] {
        path.split(separator: "/").reversed().map(String.init)
    }
}
