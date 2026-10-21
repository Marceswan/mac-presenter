import AVFoundation
import Foundation
import PresenterCore
import Speech

// Usage: SpeechCheck <script.txt> <audio-file>
// Runs SpeechTranscriber over the audio file and feeds the results to ScriptFollower
// the same way the app model does. Exit code 0 when the follower ends within 2 words
// of the script end. Exit code 1 when it does not. Exit code 2 on a setup error.

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("Usage: SpeechCheck <script.txt> <audio-file>") }

guard let scriptText = try? String(contentsOfFile: arguments[1], encoding: .utf8) else {
    fail("Cannot read the script file: \(arguments[1])")
}
let script = Script(text: scriptText)
let total = script.words.count
guard total > 0 else { fail("The script has no words.") }
let scriptNS = scriptText as NSString

func scriptWords(upTo position: Int, count: Int = 6) -> String {
    let end = min(position, total)
    let start = max(0, end - count)
    return script.words[start..<end].map { scriptNS.substring(with: $0.range) }.joined(separator: " ")
}

let audioFile: AVAudioFile
do {
    audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[2]))
} catch {
    fail("Cannot open the audio file: \(error)")
}

guard SpeechTranscriber.isAvailable else { fail("SpeechTranscriber is not available on this Mac.") }
guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) else {
    fail("No supported locale for en_US.")
}

let transcriber = SpeechTranscriber(
    locale: locale,
    transcriptionOptions: [],
    reportingOptions: [.volatileResults],
    attributeOptions: [])

do {
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        print("Downloading the speech model")
        try await request.downloadAndInstall()
    }
} catch {
    fail("Asset install failed: \(error)")
}

let analyzer = SpeechAnalyzer(modules: [transcriber])
let context = AnalysisContext()
context.contextualStrings[.general] = script.contextualWords()
try? await analyzer.setContext(context)

var buffer = TranscriptBuffer()
var follower = ScriptFollower(script: script)
var finals: [String] = []
var resultCount = 0

let resultsTask = Task { () -> Error? in
    do {
        for try await result in transcriber.results {
            let text = String(result.text.characters)
            resultCount += 1
            if result.isFinal {
                buffer.appendFinal(text)
                finals.append(text)
            } else {
                buffer.setVolatile(text)
            }
            if follower.ingest(spokenTail: buffer.tail(6)) {
                print("position \(follower.position)/\(total): \(scriptWords(upTo: follower.position))")
            }
        }
        return nil
    } catch {
        return error
    }
}

do {
    try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
} catch {
    resultsTask.cancel()
    fail("Analyzer failed: \(error)")
}

if let error = await resultsTask.value {
    fail("Results failed: \(error)")
}

print("")
print("Results received: \(resultCount)")
print("Final transcript: \(finals.joined(separator: " "))")
let finalPosition = follower.position
print("FINAL position \(finalPosition) of \(total) words")
if finalPosition < total {
    let next = script.words[finalPosition..<min(total, finalPosition + 6)]
        .map { scriptNS.substring(with: $0.range) }.joined(separator: " ")
    print("Stalled before: \(next)")
}
exit(finalPosition >= total - 2 ? 0 : 1)
