import AppKit
import Observation
import Sparkle

/// Sparkle updates: an hourly check against the GitHub Releases feed, a download in
/// the background, and an install when Presenter quits.
///
/// Sparkle shows a window only when an update waits a long time without a quit.
/// Presenter always takes that window over from Sparkle and shows it only while
/// Presenter is active, the editor is showing, and the microphone is off. The check
/// runs at the moment of display, so a window never opens over the prompter.
/// Not started under tests (the test host is the app) or in Debug builds.
@MainActor
@Observable
final class AppUpdater: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    nonisolated static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    nonisolated static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// A Debug build must not replace itself with the published release.
    nonisolated static func shouldStart(isRunningTests: Bool, isDebugBuild: Bool) -> Bool {
        !isRunningTests && !isDebugBuild
    }

    nonisolated static var startsByDefault: Bool {
        shouldStart(isRunningTests: isRunningTests, isDebugBuild: isDebugBuild)
    }

    /// True only when an update window cannot interrupt a presentation.
    nonisolated static func mayShowUpdateUI(mode: PrompterModel.Mode, isListening: Bool) -> Bool {
        mode == .edit && !isListening
    }

    nonisolated static func checkForUpdatesEnabled(canCheck: Bool, mode: PrompterModel.Mode, isListening: Bool) -> Bool {
        canCheck && mayShowUpdateUI(mode: mode, isListening: isListening)
    }

    let started: Bool
    private(set) var canCheckForUpdates = false

    /// Reads the current prompter mode and listening state. The app sets this to read the model.
    @ObservationIgnored var presentationState: () -> (mode: PrompterModel.Mode, isListening: Bool) = { (.edit, false) }

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var activation: NSObjectProtocol?
    @ObservationIgnored private let isAppActive: @MainActor () -> Bool
    @ObservationIgnored private var showDeferredUpdate: () -> Void = {}
    @ObservationIgnored private var hasDeferredUpdate = false

    init(
        startingUpdater: Bool = AppUpdater.startsByDefault,
        isAppActive: (@MainActor () -> Bool)? = nil,
        showDeferredUpdate: (() -> Void)? = nil
    ) {
        started = startingUpdater
        self.isAppActive = isAppActive ?? { NSApp?.isActive ?? false }
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater, updaterDelegate: nil, userDriverDelegate: self
        )
        self.showDeferredUpdate = showDeferredUpdate ?? { [weak self] in self?.checkForUpdates() }
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidBecomeActive() }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Call when the prompter mode or the listening state changes.
    func presentationStateChanged() {
        showDeferredUpdateIfAllowed()
    }

    func appDidBecomeActive() {
        showDeferredUpdateIfAllowed()
    }

    private func showDeferredUpdateIfAllowed() {
        let state = presentationState()
        guard hasDeferredUpdate, isAppActive(),
              Self.mayShowUpdateUI(mode: state.mode, isListening: state.isListening) else { return }
        hasDeferredUpdate = false
        showDeferredUpdate()
    }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle can delay its own window until the app becomes active, without asking
    /// again. So Presenter always shows scheduled updates itself, after its own check.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        hasDeferredUpdate = true
        // Sparkle starts showing the update after this call returns. checkForUpdates() then brings it into focus.
        DispatchQueue.main.async { [weak self] in self?.showDeferredUpdateIfAllowed() }
        return false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        // Presenter shows a scheduled update from showDeferredUpdateIfAllowed().
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        hasDeferredUpdate = false
    }

    func standardUserDriverWillFinishUpdateSession() {
        hasDeferredUpdate = false
    }
}
