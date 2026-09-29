import Foundation

/// What a project's sources say about where they can build.
public enum PlatformHints {
    /// `import UIKit`, however it is written: `@preconcurrency import UIKit`
    /// and `import class UIKit.UIView` were read as a package this Mac could
    /// build, and the run failed in `swift build`.
    public static func importsUIKit(_ source: String) -> Bool {
        source.range(
            of: #"(?m)^\s*(?:@\w+\s+)*import\s+(?:(?:class|struct|enum|protocol|func|var|typealias)\s+)?UIKit\b"#,
            options: .regularExpression
        ) != nil
    }

    /// A package manifest whose platforms name iOS and not macOS: it builds
    /// with iOS's SDK, which `swift test` on a Mac does not have.
    public static func iOSOnly(_ manifest: String) -> Bool {
        manifest.contains(".iOS(") && !manifest.contains(".macOS(")
    }
}
