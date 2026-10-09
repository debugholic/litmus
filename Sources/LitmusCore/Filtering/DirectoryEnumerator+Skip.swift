import Foundation

extension FileManager.DirectoryEnumerator {
    /// Skips what is under `url`, the entry the walk just read.
    ///
    /// Only for a directory. The walk never goes into a link or a file, and
    /// `skipDescendants()` called on one holds over to the next directory it
    /// reads: a linked `.build` left the `Core` read after it unwalked.
    func skipDescendants(of url: URL) {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return }
        skipDescendants()
    }
}
