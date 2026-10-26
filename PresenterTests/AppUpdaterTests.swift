import AppKit
import Sparkle
import Testing
@testable import Presenter

@MainActor
struct AppUpdaterTests {
    /// Lets blocks that the updater queued on the main queue run.
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func updater(
        state: @escaping () -> (mode: PrompterModel.Mode, isListening: Bool),
        active: @escaping () -> Bool = { true },
        shown: @escaping () -> Void
    ) -> AppUpdater {
        let updater = AppUpdater(startingUpdater: false, isAppActive: active, showDeferredUpdate: shown)
        updater.presentationState = state
        return updater
    }

    @Test func updateUIOnlyInEditModeWhenNotListening() {
        #expect(AppUpdater.mayShowUpdateUI(mode: .edit, isListening: false))
        #expect(!AppUpdater.mayShowUpdateUI(mode: .edit, isListening: true))
        #expect(!AppUpdater.mayShowUpdateUI(mode: .prompt, isListening: false))
        #expect(!AppUpdater.mayShowUpdateUI(mode: .prompt, isListening: true))
    }

    @Test func updaterDoesNotStartUnderTests() {
        #expect(AppUpdater.isRunningTests)
        #expect(!AppUpdater().started)
    }

    @Test func updaterStartsOnlyInReleaseBuildsOutsideTests() {
        #expect(AppUpdater.shouldStart(isRunningTests: false, isDebugBuild: false))
        #expect(!AppUpdater.shouldStart(isRunningTests: false, isDebugBuild: true))
        #expect(!AppUpdater.shouldStart(isRunningTests: true, isDebugBuild: false))
    }

    @Test func checkForUpdatesIsEnabledOnlyWhenItCannotInterruptAPresentation() {
        #expect(AppUpdater.checkForUpdatesEnabled(canCheck: true, mode: .edit, isListening: false))
        #expect(!AppUpdater.checkForUpdatesEnabled(canCheck: false, mode: .edit, isListening: false))
        #expect(!AppUpdater.checkForUpdatesEnabled(canCheck: true, mode: .prompt, isListening: false))
        #expect(!AppUpdater.checkForUpdatesEnabled(canCheck: true, mode: .edit, isListening: true))
    }

    @Test func scheduledReminderIsAlwaysShownByPresenterNotSparkle() async {
        var shown = 0
        let updater = updater(state: { (.edit, false) }, shown: { shown += 1 })
        let sparkleShows = updater.standardUserDriverShouldHandleShowingScheduledUpdate(.empty(), andInImmediateFocus: false)
        #expect(!sparkleShows)
        await drainMainQueue()
        #expect(shown == 1)
    }

    @Test func reminderWaitsForEditModeWithListeningOff() async {
        var shown = 0
        var state: (mode: PrompterModel.Mode, isListening: Bool) = (.prompt, true)
        let updater = updater(state: { state }, shown: { shown += 1 })
        _ = updater.standardUserDriverShouldHandleShowingScheduledUpdate(.empty(), andInImmediateFocus: true)
        await drainMainQueue()
        state = (.prompt, false)
        updater.presentationStateChanged()
        state = (.edit, true)
        updater.presentationStateChanged()
        #expect(shown == 0)
        state = (.edit, false)
        updater.presentationStateChanged()
        #expect(shown == 1)
        state = (.prompt, false)
        updater.presentationStateChanged()
        state = (.edit, false)
        updater.presentationStateChanged()
        #expect(shown == 1)
    }

    @Test func reminderWaitsUntilPresenterIsActive() async {
        var shown = 0
        var active = false
        let updater = updater(state: { (.edit, false) }, active: { active }, shown: { shown += 1 })
        _ = updater.standardUserDriverShouldHandleShowingScheduledUpdate(.empty(), andInImmediateFocus: false)
        await drainMainQueue()
        #expect(shown == 0)
        active = true
        updater.appDidBecomeActive()
        #expect(shown == 1)
    }

    @Test func userAttentionClearsTheDeferredReminder() async {
        var shown = 0
        var state: (mode: PrompterModel.Mode, isListening: Bool) = (.prompt, false)
        let updater = updater(state: { state }, shown: { shown += 1 })
        _ = updater.standardUserDriverShouldHandleShowingScheduledUpdate(.empty(), andInImmediateFocus: true)
        await drainMainQueue()
        updater.standardUserDriverDidReceiveUserAttention(forUpdate: .empty())
        state = (.edit, false)
        updater.presentationStateChanged()
        #expect(shown == 0)
    }

    @Test func finishedUpdateSessionClearsTheDeferredReminder() async {
        var shown = 0
        var state: (mode: PrompterModel.Mode, isListening: Bool) = (.prompt, false)
        let updater = updater(state: { state }, shown: { shown += 1 })
        _ = updater.standardUserDriverShouldHandleShowingScheduledUpdate(.empty(), andInImmediateFocus: true)
        await drainMainQueue()
        updater.standardUserDriverWillFinishUpdateSession()
        state = (.edit, false)
        updater.presentationStateChanged()
        #expect(shown == 0)
    }

    @Test func checkForUpdatesIsInTheAppMenuAfterAbout() throws {
        let appMenu = try #require(NSApp.mainMenu?.items.first?.submenu)
        let titles = appMenu.items.map(\.title)
        let check = try #require(titles.firstIndex(of: "Check for Updates\u{2026}"))
        let about = try #require(titles.firstIndex { $0.hasPrefix("About") })
        #expect(check > about)
    }
}
