import AppKit
import Observation
import PresenterCore
import UniformTypeIdentifiers

@MainActor
@Observable
final class PrompterModel {
    enum Mode { case edit, prompt }

    enum ListenState: Equatable {
        case idle
        case preparing(String)
        case listening
        case failed(String)
    }

    static let wordsPerMinute = 140.0

    static let sampleScript = """
    Welcome to Presenter. [Press Command-Return to switch to the prompter. Then press Space to start listening.]

    Read this text out loud at your normal pace. The prompter listens to your voice and scrolls while you speak. If you skip a sentence, continue to read. The prompter finds your place again after a few words.

    Text in square brackets is a cue. [PAUSE] Cues stay on the screen, but the prompter does not wait for you to say them.

    You can scroll with the trackpad or the arrow keys at any time. The prompter continues from the line at the markers.

    Replace this text with your script. Then press Command-Return to start.
    """

    // MARK: State

    var mode: Mode = .edit
    private(set) var presentationTitle: String
    private(set) var hasUnsavedChanges = false
    private(set) var saveFailed = false
    var isLibraryPresented = false
    var fileError: String?

    var currentPresentationID: UUID { workspace.selectedID }
    var saveStatus: String {
        if store == nil { return "Saving unavailable" }
        if saveFailed { return "Changes not saved" }
        return hasUnsavedChanges ? "Saving\u{2026}" : "Saved on this Mac"
    }
    var presentations: [Presentation] {
        workspace.presentations.sorted { $0.updatedAt > $1.updatedAt }
    }
    private(set) var scriptText: String
    private(set) var script: Script
    private(set) var position: Int = 0
    private(set) var state: ListenState = .idle
    private(set) var level: Float = 0
    private(set) var heard: String = ""

    var isActive: Bool {
        switch state {
        case .preparing, .listening: true
        case .idle, .failed: false
        }
    }

    var wordCount: Int { script.words.count }

    var estimatedMinutes: Int {
        guard wordCount > 0 else { return 0 }
        return max(1, Int((Double(wordCount) / Self.wordsPerMinute).rounded(.up)))
    }

    // MARK: Private

    private var workspace: PresentationWorkspace
    @ObservationIgnored private let store: PresentationStore?
    @ObservationIgnored private var follower: ScriptFollower
    @ObservationIgnored private var transcript = TranscriptBuffer()
    @ObservationIgnored private let listener = SpeechListener()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    init(store providedStore: PresentationStore? = nil) {
        let loaded: PresentationWorkspace
        do {
            let store = try providedStore ?? PresentationStore.applicationSupport()
            loaded = try store.load(defaultText: Self.sampleScript)
            self.store = store
        } catch {
            loaded = PresentationWorkspace(title: "Untitled Presentation", text: Self.sampleScript)
            self.store = nil
            fileError = "Could not open your presentation library: \(error.localizedDescription) Your saved files have not been changed. Saving is disabled to preserve them."
        }
        workspace = loaded
        presentationTitle = loaded.current.title
        scriptText = loaded.current.text
        let script = Script(text: loaded.current.text)
        self.script = script
        follower = ScriptFollower(script: script)
        // Persist first-launch content and legacy migration, too.
        if store != nil {
            hasUnsavedChanges = true
            _ = flushSave()
        }
    }

    // MARK: Script text

    /// Call when the text changes. Rebuilds the script and keeps the position.
    func setScriptText(_ text: String) {
        guard text != scriptText else { return }
        scriptText = text
        workspace.setText(text)
        hasUnsavedChanges = true
        let newScript = Script(text: text)
        script = newScript
        follower = ScriptFollower(script: newScript, position: position)
        position = follower.position
        scheduleSave()
    }

    func setPresentationTitle(_ title: String) {
        guard title != presentationTitle else { return }
        presentationTitle = title
        hasUnsavedChanges = true
        scheduleSave()
    }

    func newPresentation() {
        guard flushSave() else { return }
        var next = workspace
        next.add(title: "Untitled Presentation", text: "")
        activate(next)
    }

    func showLibrary() {
        guard flushSave() else { return }
        setMode(.edit)
        isLibraryPresented = true
    }

    func openPresentation(_ id: UUID) {
        guard flushSave() else { return }
        var next = workspace
        next.select(id)
        activate(next)
    }

    func openScript() {
        guard flushSave() else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Presentation"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["txt", "md", "markdown", "rtf", "docx"].compactMap {
            UTType(filenameExtension: $0)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importPresentation(at: url)
    }

    func importPresentation(at url: URL) {
        guard flushSave() else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try ScriptImporter.read(url)
            var next = workspace
            next.add(title: url.deletingPathExtension().lastPathComponent, text: text)
            activate(next)
        } catch {
            fileError = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Save the candidate before switching so a write failure keeps the current work open.
    private func activate(_ next: PresentationWorkspace) {
        guard let store else {
            fileError = "Your saved library could not be opened. Restore it from a backup or use a compatible app version before creating presentations."
            return
        }
        do {
            try store.save(next)
            stopListening()
            workspace = next
            presentationTitle = next.current.title
            scriptText = next.current.text
            script = Script(text: scriptText)
            follower = ScriptFollower(script: script)
            transcript = TranscriptBuffer()
            position = 0
            heard = ""
            hasUnsavedChanges = false
            saveFailed = false
            mode = .edit
            isLibraryPresented = false
        } catch {
            fileError = "Could not save your presentations: \(error.localizedDescription) Your current presentation is still open."
        }
    }

    // MARK: Position

    /// Call when the user scrolls by hand.
    func jump(to index: Int) {
        follower.reset(to: index)
        position = follower.position
        transcript.markBaseline()
    }

    func restart() {
        jump(to: 0)
    }

    func setMode(_ newMode: Mode) {
        mode = newMode
        if newMode == .edit, isActive { stopListening() }
    }

    func toggleMode() {
        setMode(mode == .edit ? .prompt : .edit)
    }

    // MARK: Listening

    func toggleListening() {
        if isActive { stopListening() } else { startListening() }
    }

    func startListening() {
        guard !isActive else { return }
        generation += 1
        let current = generation
        state = .preparing("Starting the microphone")
        transcript.markBaseline()
        let identifier = UserDefaults.standard.string(forKey: Prefs.localeIdentifier) ?? ""
        let locale = identifier.isEmpty ? Locale.current : Locale(identifier: identifier)
        let words = script.contextualWords()
        let pending = stopTask

        Task { [weak self] in
            await pending?.value
            guard let self, self.generation == current else { return }
            do {
                try await self.listener.start(locale: locale, contextualWords: words) { [weak self] event in
                    self?.handle(event, generation: current)
                }
                if self.generation == current, case .preparing = self.state {
                    self.state = .listening
                }
            } catch {
                guard self.generation == current else { return }
                self.finishListening(as: .failed(error.localizedDescription))
            }
        }
    }

    func stopListening() {
        finishListening(as: .idle)
    }

    private func finishListening(as newState: ListenState) {
        generation += 1
        state = newState
        level = 0
        let previous = stopTask
        stopTask = Task { [listener] in
            await previous?.value
            await listener.stop()
        }
    }

    private func handle(_ event: ListenerEvent, generation eventGeneration: Int) {
        guard eventGeneration == generation else { return }
        switch event {
        case .volatile(let text):
            transcript.setVolatile(text)
            follow()
        case .final(let text):
            transcript.appendFinal(text)
            follow()
        case .level(let value):
            level = max(value, level * 0.8)
        case .status(let message):
            state = .preparing(message)
        case .interrupted:
            finishListening(as: .idle)
            startListening()
        case .failed(let message):
            finishListening(as: .failed(message))
        }
    }

    private func follow() {
        let tail = transcript.tail(6)
        heard = tail.joined(separator: " ")
        if follower.ingest(spokenTail: tail) {
            position = follower.position
        }
    }

    // MARK: Persistence

    /// Called by Command-S, navigation and app termination, before the debounce can run.
    @discardableResult
    func flushSave() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard hasUnsavedChanges else { return true }
        guard let store else {
            fileError = "Saving is disabled because your existing presentation library could not be opened. Your saved files have not been changed. Quit Presenter and restore the library from a backup or use a compatible app version."
            return false
        }
        var snapshot = workspace
        snapshot.renameCurrent(to: presentationTitle)
        do {
            try store.save(snapshot)
            workspace = snapshot
            hasUnsavedChanges = false
            saveFailed = false
            return true
        } catch {
            saveFailed = true
            fileError = "Could not save your presentations: \(error.localizedDescription) Your changes are still open. Try saving again with Command-S."
            return false
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveFailed = false
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.flushSave()
        }
    }
}
