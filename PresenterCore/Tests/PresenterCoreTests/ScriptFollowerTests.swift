import Testing
@testable import PresenterCore

private let speech = """
Good morning everyone, and thank you for coming tonight. We built this product \
because presenting should feel natural. Every speaker deserves a prompter that \
listens. Thank you for your patience while we finished the demo. Now let me show \
you how the follower keeps pace with your voice.
"""

/// Feeds spoken text to the follower the way a recognizer does:
/// the hypothesis grows one word at a time.
private func speak(_ text: String, into follower: inout ScriptFollower, transcript: inout [String]) {
    for word in Script.keys(fromSpoken: text) {
        transcript.append(word)
        follower.ingest(spokenTail: Array(transcript.suffix(6)))
    }
}

struct ScriptFollowerTests {
    let script = Script(text: speech)

    @Test func followsWordByWord() {
        var follower = ScriptFollower(script: script)
        var heard: [String] = []
        speak("Good morning everyone and thank you", into: &follower, transcript: &heard)
        #expect(follower.position == 6)
    }

    @Test func readingTheWholeScriptReachesTheEnd() {
        var follower = ScriptFollower(script: script)
        var heard: [String] = []
        speak(speech, into: &follower, transcript: &heard)
        #expect(follower.position == script.words.count)
    }

    @Test func partialLastWordStillMatches() {
        var follower = ScriptFollower(script: script)
        follower.ingest(spokenTail: ["good", "morning", "every"])
        #expect(follower.position == 3)
    }

    @Test func fillerAndAdLibsDoNotBlock() {
        var follower = ScriptFollower(script: script)
        var heard: [String] = []
        speak("Good morning you know everyone and uh thank you so much for coming", into: &follower, transcript: &heard)
        #expect(follower.position == 8)
    }

    @Test func misrecognizedWordDoesNotBlock() {
        var follower = ScriptFollower(script: script)
        var heard: [String] = []
        speak("Good morning everyone and thank you fur coming tonight", into: &follower, transcript: &heard)
        #expect(follower.position == 9)
    }

    @Test func repeatingTheSameTailIsIdempotent() {
        var follower = ScriptFollower(script: script)
        let tail = ["good", "morning", "everyone"]
        follower.ingest(spokenTail: tail)
        let first = follower.position
        follower.ingest(spokenTail: tail)
        follower.ingest(spokenTail: tail)
        #expect(follower.position == first)
    }

    @Test func repeatedPhraseDoesNotJumpToLaterCopy() {
        var follower = ScriptFollower(script: script)
        var heard: [String] = []
        speak("Good morning everyone and thank you", into: &follower, transcript: &heard)
        // "thank you for" appears again much later in the script.
        speak("for", into: &follower, transcript: &heard)
        #expect(follower.position == 7)
    }

    @Test func loneStopwordDoesNotJumpAhead() {
        var follower = ScriptFollower(script: script)
        follower.ingest(spokenTail: ["the"])
        #expect(follower.position == 0)
    }

    @Test func skippingAheadNeedsSeveralMatchingWords() {
        var follower = ScriptFollower(script: script)
        var heard: [String] = []
        speak("Good morning everyone", into: &follower, transcript: &heard)
        speak("every speaker", into: &follower, transcript: &heard)
        #expect(follower.position == 3)
        speak("deserves a prompter that listens", into: &follower, transcript: &heard)
        let target = script.words.firstIndex { $0.key == "listens" }! + 1
        #expect(follower.position == target)
    }

    @Test func reReadingASentenceMovesBack() {
        var follower = ScriptFollower(script: script)
        var heard: [String] = []
        speak("Good morning everyone and thank you for coming tonight we built this product", into: &follower, transcript: &heard)
        #expect(follower.position == 13)
        speak("thank you for coming tonight", into: &follower, transcript: &heard)
        #expect(follower.position == 9)
    }

    @Test func resetMovesPosition() {
        var follower = ScriptFollower(script: script)
        follower.reset(to: 20)
        #expect(follower.position == 20)
        follower.reset(to: 999)
        #expect(follower.position == script.words.count)
    }

    @Test func survivesNoisyRecognition() {
        var rng = SeededGenerator(seed: 7)
        var follower = ScriptFollower(script: script)
        var heard: [String] = []
        for word in Script.keys(fromSpoken: speech) {
            let roll = Double.random(in: 0..<1, using: &rng)
            if roll < 0.08 { continue }                       // dropped word
            heard.append(roll < 0.16 ? "blah" : word)         // substituted word
            if roll > 0.95 { heard.append("um") }             // inserted word
            follower.ingest(spokenTail: Array(heard.suffix(6)))
        }
        #expect(follower.position >= script.words.count - 2)
    }

    @Test func emptyScriptIsSafe() {
        var follower = ScriptFollower(script: Script(text: ""))
        follower.ingest(spokenTail: ["hello"])
        #expect(follower.position == 0)
    }
}

/// Deterministic generator so the noisy test is repeatable.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
