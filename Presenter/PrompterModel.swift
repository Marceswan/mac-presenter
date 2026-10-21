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

    @ObservationIgnored private var follower: ScriptFollower
    @ObservationIgnored private var transcript = TranscriptBuffer()
    @ObservationIgnored private let listener = SpeechListener()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    init() {
        let loaded = Self.loadScript() ?? Self.sampleScript
        scriptText = loaded
        let script = Script(text: loaded)
        self.script = script
        follower = ScriptFollower(script: script)
    }

    // MARK: Script text

    /// Call when the text changes. Rebuilds the script and keeps the position.
    func setScriptText(_ text: String) {
        guard text != scriptText else { return }
        scriptText = text
        let newScript = Script(text: text)
        script = newScript
        follower = ScriptFollower(script: newScript, position: position)
        position = follower.position
        scheduleSave()
    }

    func openScript() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var types: [UTType] = [.plainText, .rtf]
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text: String?
        if url.pathExtension.lowercased() == "rtf" {
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        } else {
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        guard let text else { return }
        setScriptText(text)
        restart()
        mode = .edit
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

    private static var scriptURL: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Presenter", isDirectory: true)
            .appendingPathComponent("script.txt")
    }

    private static func loadScript() -> String? {
        guard let url = scriptURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let text = scriptText
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let url = Self.scriptURL else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
