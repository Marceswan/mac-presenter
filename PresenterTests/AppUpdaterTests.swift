import AppKit
import Testing
@testable import Presenter

@MainActor
struct AppUpdaterTests {
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

    @Test func deferredReminderWaitsThroughSeveralStateChanges() {
        var shown = 0
        let updater = AppUpdater(startingUpdater: false, showDeferredUpdate: { shown += 1 })
        updater.presentationStateChanged(mode: .prompt, isListening: true)
        updater.noteDeferredUpdate()
        updater.presentationStateChanged(mode: .prompt, isListening: false)
        updater.presentationStateChanged(mode: .edit, isListening: true)
        #expect(shown == 0)
        updater.presentationStateChanged(mode: .edit, isListening: false)
        #expect(shown == 1)
        updater.presentationStateChanged(mode: .prompt, isListening: false)
        updater.presentationStateChanged(mode: .edit, isListening: false)
        #expect(shown == 1)
    }

    @Test func checkForUpdatesIsInTheAppMenuAfterAbout() throws {
        let appMenu = try #require(NSApp.mainMenu?.items.first?.submenu)
        let titles = appMenu.items.map(\.title)
        let check = try #require(titles.firstIndex(of: "Check for Updates\u{2026}"))
        let about = try #require(titles.firstIndex { $0.hasPrefix("About") })
        #expect(check > about)
    }
}
