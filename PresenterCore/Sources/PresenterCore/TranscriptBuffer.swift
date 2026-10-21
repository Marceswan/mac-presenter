/// Holds recent recognized words as matching keys.
///
/// The recognizer sends two kinds of text: volatile text, which it can still
/// revise, and final text, which it will not change. Volatile text replaces the
/// previous volatile text. Final text is appended and clears the volatile text.
public struct TranscriptBuffer: Sendable {
    public static let maxStoredWords = 200

    private var finalized: [String] = []
    private var volatile: [String] = []
    private var baseline = 0

    public init() {}

    public var storedWordCount: Int { finalized.count + volatile.count }

    public mutating func setVolatile(_ text: String) {
        volatile = Script.keys(fromSpoken: text)
    }

    public mutating func appendFinal(_ text: String) {
        finalized.append(contentsOf: Script.keys(fromSpoken: text))
        volatile = []
        if finalized.count > Self.maxStoredWords {
            let drop = finalized.count - Self.maxStoredWords / 2
            finalized.removeFirst(drop)
            baseline = max(0, baseline - drop)
        }
    }

    /// Ignores all words heard so far. Use after the speaker jumps to a new place.
    public mutating func markBaseline() {
        baseline = storedWordCount
    }

    /// The last `count` words heard after the baseline, oldest first.
    public func tail(_ count: Int) -> [String] {
        Array((finalized + volatile).dropFirst(baseline).suffix(count))
    }
}
