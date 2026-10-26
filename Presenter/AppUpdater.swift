import Foundation
import Observation
import Sparkle

/// Sparkle updates: an hourly check against the GitHub Releases feed, a download in
/// the background, and an install when Presenter quits.
///
/// Sparkle shows a window only when an update waits a long time without a quit. That
/// window never appears in prompt mode or while listening: it waits until the editor
/// is showing and the microphone is off. Not started under tests (the test host is the app).
@MainActor
@Observable
final class AppUpdater: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    nonisolated static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// True only when an update window cannot interrupt a presentation.
    nonisolated static func mayShowUpdateUI(mode: PrompterModel.Mode, isListening: Bool) -> Bool {
        mode == .edit && !isListening
    }

    let started: Bool
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var showDeferredUpdate: () -> Void = {}
    @ObservationIgnored private var mode: PrompterModel.Mode = .edit
    @ObservationIgnored private var isListening = false
    @ObservationIgnored private var hasDeferredUpdate = false

    init(startingUpdater: Bool = !AppUpdater.isRunningTests, showDeferredUpdate: (() -> Void)? = nil) {
        started = startingUpdater
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater, updaterDelegate: nil, userDriverDelegate: self
        )
        self.showDeferredUpdate = showDeferredUpdate ?? { [weak self] in self?.checkForUpdates() }
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Call when the prompter mode or the listening state changes.
    func presentationStateChanged(mode: PrompterModel.Mode, isListening: Bool) {
        self.mode = mode
        self.isListening = isListening
        guard hasDeferredUpdate, Self.mayShowUpdateUI(mode: mode, isListening: isListening) else { return }
        hasDeferredUpdate = false
        showDeferredUpdate()
    }

    /// Records that Sparkle wanted to show an update while a presentation could be running.
    func noteDeferredUpdate() {
        hasDeferredUpdate = true
    }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        let allowed = Self.mayShowUpdateUI(mode: mode, isListening: isListening)
        if !allowed { noteDeferredUpdate() }
        return allowed
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        // A deferred update is shown from presentationStateChanged(mode:isListening:).
    }
}
