import Foundation
import Testing
@testable import PresenterCore

struct ScriptTests {
    @Test func splitsWordsAndDropsPunctuation() {
        let script = Script(text: "Hello, world! It's a well-known fact.")
        #expect(script.words.map(\.key) == ["hello", "world", "its", "a", "well", "known", "fact"])
    }

    @Test func wordRangesPointIntoOriginalText() {
        let text = "Good morning, everyone."
        let script = Script(text: text)
        let ns = text as NSString
        #expect(script.words.map { ns.substring(with: $0.range) } == ["Good", "morning", "everyone"])
    }

    @Test func bracketedCuesAreNotSpoken() {
        let script = Script(text: "Welcome [PAUSE] [smile] back.")
        #expect(script.words.map(\.key) == ["welcome", "back"])
        #expect(script.cueRanges.count == 2)
    }

    @Test func smallNumbersNormalizeToWords() {
        #expect(Script.normalize("10") == "ten")
        #expect(Script.normalize("Ten") == "ten")
        #expect(Script.normalize("2026") == "2026")
        #expect(Script.normalize("Café") == "cafe")
        #expect(Script.normalize("don’t") == "dont")
    }

    @Test func spokenTextUsesSameNormalization() {
        #expect(Script.keys(fromSpoken: "We have 3 goals, OK?") == ["we", "have", "three", "goals", "ok"])
    }

    @Test func fillerWordsAreDroppedFromSpokenText() {
        #expect(Script.keys(fromSpoken: "um so uh yeah") == ["so", "yeah"])
    }

    @Test func wordIndexAtCharacterFindsNextWord() {
        let script = Script(text: "one two three")
        #expect(script.wordIndex(atOrAfterCharacter: 0) == 0)
        #expect(script.wordIndex(atOrAfterCharacter: 4) == 1)
        #expect(script.wordIndex(atOrAfterCharacter: 5) == 2)
        #expect(script.wordIndex(atOrAfterCharacter: 99) == 3)
    }
}
