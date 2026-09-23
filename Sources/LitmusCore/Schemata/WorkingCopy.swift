import Foundation

/// Where Litmus keeps its copy of a project.
public enum WorkingCopy {
    /// `~/Library/Caches/litmus/<name>-<id>`, for every project.
    ///
    /// One place on every machine, so an antivirus exclusion or a clean-up
    /// names a single folder rather than one beside each project. A project
    /// on another volume is copied rather than cloned; the copy leaves out
    /// build output and links dependency stores, so it is the sources alone,
    /// and a cache folder is somewhere macOS may clear, which costs nothing
    /// since every run makes the copy again.
    ///
    /// The id keeps two projects of the same name apart.
    public static func location(for project: URL, caches: URL? = nil) -> URL {
        let root = caches
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let path = project.standardizedFileURL.path

        return root
            .appendingPathComponent("litmus")
            .appendingPathComponent("\(project.lastPathComponent)-\(identifier(for: path))")
    }

    /// Six hex digits of an FNV-1a hash: the same for a path on every run,
    /// which Swift's own `Hasher` is not.
    static func identifier(for path: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in path.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(String(hash, radix: 16).leftPadded(to: 8).prefix(6))
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
