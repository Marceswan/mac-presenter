import Foundation

// CONTRACT: the speech agent implements this file. Do not change the public shape
// without updating every caller.

/// Events the listener sends to its owner on the main actor.
enum ListenerEvent: Sendable {
    /// Text the recognizer can still revise. Replaces the previous volatile text.
    case volatile(String)
    /// Text the recognizer will not change. Append it.
    case final(String)
    /// Microphone input level, 0...1.
    case level(Float)
    /// Progress message while the listener prepares, for example a model download.
    case status(String)
    /// The audio device changed. The owner must call `stop()` and then `start(...)` again.
    case interrupted
    /// Recognition stopped because of an error. The text is a user-facing message.
    case failed(String)
}

enum ListenerError: LocalizedError {
    case microphoneDenied
    case noInputDevice
    case localeUnsupported(String)
    case audioFormatUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is off. Open System Settings > Privacy & Security > Microphone and turn on Presenter."
        case .noInputDevice:
            "No microphone is available. Connect a microphone and try again."
        case .localeUnsupported(let id):
            "Speech recognition does not support the language \(id). Select a different language in Settings."
        case .audioFormatUnavailable:
            "The speech model cannot use the microphone audio format."
        }
    }
}

@MainActor
final class SpeechListener {
    init() {}

    /// Asks for microphone access, prepares the on-device speech model, and starts
    /// to send events. Returns when audio flows. Throws `ListenerError` or a framework error.
    func start(
        locale: Locale,
        contextualWords: [String],
        onEvent: @escaping @MainActor @Sendable (ListenerEvent) -> Void
    ) async throws {
        // STUB
    }

    /// Stops audio capture and recognition. Safe to call when not started.
    func stop() async {
        // STUB
    }

    /// Locales that on-device speech recognition supports on this Mac.
    static func supportedLocales() async -> [Locale] {
        [] // STUB
    }
}
