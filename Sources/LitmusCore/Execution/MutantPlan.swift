import Foundation

/// Loads the list of mutants to run.
///
/// Until the schemata layer is ported, the list is produced by Muter's
/// `mutate-without-running`, which injects the switches and writes its mapping
/// as JSON. Litmus only needs to know where each mutant sits so it can rebuild
/// the same switch name.
public enum MutantPlan {
    public struct DecodingFailure: Error, CustomStringConvertible {
        public let description: String
    }

    public static func load(contentsOf url: URL) throws -> [Mutant] {
        let data = try Data(contentsOf: url)

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = root["mappings"] as? [[String: Any]]
        else {
            throw DecodingFailure(description: "expected a 'mappings' array in \(url.lastPathComponent)")
        }

        return files.flatMap { file -> [Mutant] in
            guard
                let path = file["filePath"] as? String,
                let entries = file["mappings"] as? [[String: Any]]
            else { return [] }

            return entries.compactMap { entry in
                guard
                    let position = entry["position"] as? [String: Any],
                    let line = position["line"] as? Int,
                    let column = position["column"] as? Int,
                    let utf8Offset = position["utf8Offset"] as? Int,
                    let `operator` = entry["mutationOperatorId"] as? String
                else { return nil }

                let snapshot = entry["snapshot"] as? [String: Any]

                return Mutant(
                    filePath: path,
                    line: line,
                    column: column,
                    utf8Offset: utf8Offset,
                    operator: `operator`,
                    description: snapshot?["description"] as? String ?? `operator`
                )
            }
        }
    }
}
