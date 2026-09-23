import Testing

@testable import LitmusCore

@Suite("xcodebuild activity")
struct XcodebuildActivityTests {
    @Test("names the target being built, and counts the targets")
    func building() {
        let activity = XcodebuildActivity()

        activity.read("SwiftCompile normal arm64 /p/A.swift (in target 'CoreFlow' from project 'CoreFlow')")
        activity.read("SwiftCompile normal arm64 /p/B.swift (in target 'CoreFlow' from project 'CoreFlow')")
        let summary = activity.read("Ld /p/Setting (in target 'FeatureSetting' from project 'FeatureSetting')")

        #expect(summary == "building FeatureSetting · 2 target(s) so far")
    }

    @Test("says nothing new for another step of the same target")
    func sameTarget() {
        let activity = XcodebuildActivity()
        activity.read("SwiftCompile x (in target 'CoreFlow' from project 'CoreFlow')")

        #expect(activity.read("SwiftCompile y (in target 'CoreFlow' from project 'CoreFlow')") == nil)
    }

    @Test("names the bundle under test, and counts finished and failed tests")
    func testing() {
        let activity = XcodebuildActivity()

        activity.read("Test Suite 'DomainSettingsTests.xctest' started at 2026-09-23 14:00:00")
        activity.read("Test case 'SettingsSuite/loads()' passed on 'iPhone' (0.001 seconds)")
        let summary = activity.read("Test Case '-[DomainSettingsTests.T testSave]' failed (0.002 seconds).")

        #expect(summary == "testing DomainSettingsTests · 2 test(s) run, 1 failed")
    }

    @Test("ignores lines that say nothing about progress")
    func noise() {
        let activity = XcodebuildActivity()

        #expect(activity.read("note: Using global toolchain override") == nil)
        #expect(activity.summary == nil)
    }
}
