import Testing

@testable import LitmusCore

@Suite("xcodebuild activity")
struct XcodebuildActivityTests {
    @Test("names the target being built")
    func building() {
        let activity = XcodebuildActivity()

        activity.read("SwiftCompile normal arm64 /p/A.swift (in target 'CoreFlow' from project 'CoreFlow')")
        let summary = activity.read("Ld /p/Setting (in target 'FeatureSetting' from project 'FeatureSetting')")

        #expect(summary == "building FeatureSetting")
    }

    /// Lines as xcodebuild printed them for a Swift Testing bundle.
    @Test("follows Swift Testing's suites and counts its tests")
    func swiftTesting() {
        let activity = XcodebuildActivity()
        activity.read("Ld /p/Setting (in target 'FeatureSetting' from project 'FeatureSetting')")

        activity.read("Test Suite 'All tests' started at 2026-09-23 16:45:09.945.")
        activity.read("◇ Test run started.")
        activity.read("◇ Suite DomainSettingsTests started.")
        activity.read("◇ Test \"QuizCount는 c45까지\" started.")
        activity.read("✔ Test \"QuizCount는 c45까지\" passed after 0.001 seconds.")
        activity.read("✘ Test \"테마 선택이 반영된다\" failed after 0.1 seconds with 1 issue.")
        let summary = activity.read("✔ Test run with 5 tests in 1 suite passed after 0.031 seconds.")

        #expect(summary == nil)
        #expect(activity.summary == "testing DomainSettingsTests · 2 test(s) run, 1 failed")
    }

    @Test("does not go back to building on a build line during tests")
    func staysTesting() {
        let activity = XcodebuildActivity()
        activity.read("◇ Suite SettingTests started.")

        #expect(activity.read("CopySwiftLibs x (in target 'Lottie' from project 'Lottie')") == nil)
        #expect(activity.summary == "testing SettingTests · 0 test(s) run, 0 failed")
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

        activity.read("Test Suite 'DomainSettingsTests' started at 2026-09-23 14:00:00")
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
