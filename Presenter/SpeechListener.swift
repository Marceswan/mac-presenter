import Accelerate
import AVFoundation
import Foundation
import Speech

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
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var configObserver: NSObjectProtocol?
    private var tapInstalled = false
    /// Incremented by `stop()`. A `start` call that sees a new value stops early.
    private var generation = 0

    init() {}

    /// Asks for microphone access, prepares the on-device speech model, and starts
    /// to send events. Returns when audio flows. Throws `ListenerError` or a framework error.
    func start(
        locale: Locale,
        contextualWords: [String],
        onEvent: @escaping @MainActor @Sendable (ListenerEvent) -> Void
    ) async throws {
        await stop()
        let token = generation
        do {
            try await run(token: token, locale: locale, contextualWords: contextualWords, onEvent: onEvent)
        } catch {
            if token == generation { await stop() }
            throw error
        }
    }

    /// Stops audio capture and recognition. Safe to call when not started.
    func stop() async {
        generation += 1
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        if let engine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
        engine = nil
        tapInstalled = false
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        let analyzer = self.analyzer
        self.analyzer = nil
        await analyzer?.cancelAndFinishNow()
    }

    /// Locales that on-device speech recognition supports on this Mac.
    static func supportedLocales() async -> [Locale] {
        if SpeechTranscriber.isAvailable {
            return await SpeechTranscriber.supportedLocales
        }
        return await DictationTranscriber.supportedLocales
    }

    // MARK: - Start pipeline

    private func run(
        token: Int,
        locale: Locale,
        contextualWords: [String],
        onEvent: @escaping @MainActor @Sendable (ListenerEvent) -> Void
    ) async throws {
        // 1. Microphone permission.
        var status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            status = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        guard status == .authorized else { throw ListenerError.microphoneDenied }
        try checkCurrent(token)

        // 2. Input device. Check it before any model download.
        let engine = AVAudioEngine()
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw ListenerError.noInputDevice
        }

        // 3. Module and locale.
        let module: any SpeechModule
        let resultsTask: Task<Void, Never>
        if SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = SpeechTranscriber(
                locale: supported,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [])
            module = transcriber
            resultsTask = Self.makeResultsTask(transcriber.results, onEvent: onEvent) {
                ($0.isFinal, String($0.text.characters))
            }
        } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = DictationTranscriber(
                locale: supported,
                contentHints: [],
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .frequentFinalization],
                attributeOptions: [])
            module = transcriber
            resultsTask = Self.makeResultsTask(transcriber.results, onEvent: onEvent) {
                ($0.isFinal, String($0.text.characters))
            }
        } else {
            throw ListenerError.localeUnsupported(locale.identifier)
        }
        // Store the Task now. If a step below throws, `stop()` cancels it.
        self.resultsTask = resultsTask
        try checkCurrent(token)

        // 4. Model assets.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            onEvent(.status("Downloading the speech model"))
            try await request.downloadAndInstall()
        }
        try checkCurrent(token)

        // 5. Analyzer.
        let analyzer = SpeechAnalyzer(modules: [module])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module], considering: inputFormat)
        else { throw ListenerError.audioFormatUnavailable }
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        if !contextualWords.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualWords
            try? await analyzer.setContext(context)
        }
        try checkCurrent(token)
        self.analyzer = analyzer

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        try await analyzer.start(inputSequence: stream)
        try checkCurrent(token)

        // 6. Microphone tap.
        guard let processor = AudioTapProcessor(
            inputFormat: inputFormat,
            outputFormat: analyzerFormat,
            continuation: continuation,
            onLevel: { level in Task { @MainActor in onEvent(.level(level)) } })
        else { throw ListenerError.audioFormatUnavailable }
        engine.inputNode.installTap(
            onBus: 0, bufferSize: 1024, format: inputFormat,
            block: Self.makeTapBlock(processor: processor))
        self.engine = engine
        tapInstalled = true

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { _ in
            Task { @MainActor in onEvent(.interrupted) }
        }

        engine.prepare()
        try engine.start()
        try checkCurrent(token)
    }

    private func checkCurrent(_ token: Int) throws {
        if token != generation { throw CancellationError() }
    }

    /// Forwards recognizer results to `onEvent`. Sends `.failed` only for real errors,
    /// not for cancellation from `stop()`.
    private static func makeResultsTask<S: AsyncSequence & Sendable>(
        _ results: S,
        onEvent: @escaping @MainActor @Sendable (ListenerEvent) -> Void,
        extract: @escaping @Sendable (S.Element) -> (isFinal: Bool, text: String)
    ) -> Task<Void, Never> where S.Element: Sendable {
        Task { @MainActor in
            do {
                for try await result in results {
                    if Task.isCancelled { return }
                    let (isFinal, text) = extract(result)
                    if isFinal {
                        if !text.isEmpty { onEvent(.final(text)) }
                    } else {
                        onEvent(.volatile(text))
                    }
                }
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                onEvent(.failed(
                    "Speech recognition stopped because of an error. Start the prompter again. Reason: \(error.localizedDescription)"))
            }
        }
    }

    /// Builds the tap block outside the main actor. A block made in a main-actor
    /// method inherits main-actor isolation. The audio thread then fails the isolation check.
    nonisolated private static func makeTapBlock(processor: AudioTapProcessor) -> AVAudioNodeTapBlock {
        { buffer, _ in processor.process(buffer) }
    }
}

/// Converts microphone buffers to the analyzer format. Only the audio thread uses it.
private final class AudioTapProcessor: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let sampleRateRatio: Double
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let onLevel: @Sendable (Float) -> Void

    init?(
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        self.converter = converter
        self.outputFormat = outputFormat
        self.sampleRateRatio = outputFormat.sampleRate / inputFormat.sampleRate
        self.continuation = continuation
        self.onLevel = onLevel
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        onLevel(Self.level(of: buffer))

        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * sampleRateRatio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: output))
    }

    /// RMS of the first channel. Maps -50 dB...0 dB to 0...1.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(channels[0], 1, &rms, vDSP_Length(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 1e-7))
        return min(max((decibels + 50) / 50, 0), 1)
    }
}
