import Testing
@testable import PresenterCore

struct TranscriptBufferTests {
    @Test func volatileTextIsReplacedNotAppended() {
        var buffer = TranscriptBuffer()
        buffer.setVolatile("good")
        buffer.setVolatile("good morning")
        #expect(buffer.tail(6) == ["good", "morning"])
    }

    @Test func finalTextIsKeptAndVolatileCleared() {
        var buffer = TranscriptBuffer()
        buffer.setVolatile("good morning")
        buffer.appendFinal("good morning")
        buffer.setVolatile("every")
        #expect(buffer.tail(6) == ["good", "morning", "every"])
    }

    @Test func tailIsLimited() {
        var buffer = TranscriptBuffer()
        buffer.appendFinal("one two three four five six seven")
        #expect(buffer.tail(3) == ["five", "six", "seven"])
    }

    @Test func baselineHidesEarlierSpeech() {
        var buffer = TranscriptBuffer()
        buffer.appendFinal("old words here")
        buffer.markBaseline()
        #expect(buffer.tail(6).isEmpty)
        buffer.setVolatile("new")
        #expect(buffer.tail(6) == ["new"])
    }

    @Test func newSessionDropsUnfinishedTextWithoutHidingNewWords() {
        var buffer = TranscriptBuffer()
        buffer.appendFinal("old words here")
        buffer.setVolatile("one two three four five six")  // the stopped session never finalizes this
        buffer.startSession()
        #expect(buffer.tail(6).isEmpty)
        buffer.setVolatile("new words")
        #expect(buffer.tail(6) == ["new", "words"])
    }

    @Test func historyStaysBounded() {
        var buffer = TranscriptBuffer()
        for _ in 0..<500 { buffer.appendFinal("alpha beta") }
        #expect(buffer.storedWordCount <= TranscriptBuffer.maxStoredWords)
        #expect(buffer.tail(2) == ["alpha", "beta"])
    }
}
