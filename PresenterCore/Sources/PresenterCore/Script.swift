import Foundation

/// A script split into the words a speaker reads aloud.
///
/// Text inside square brackets, such as `[PAUSE]`, is a cue. Cues show on the
/// prompter but the follower does not expect the speaker to say them.
public struct Script: Equatable, Sendable {
    public struct Word: Equatable, Sendable {
        /// Normalized form used for matching against recognized speech.
        public let key: String
        /// UTF-16 range of the word in `text`.
        public let range: NSRange
        /// Match weight. Common short words carry less evidence.
        public let weight: Double
    }

    public let text: String
    public let words: [Word]
    public let cueRanges: [NSRange]

    public init(text: String) {
        self.text = text
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        let cues = Self.cuePattern.matches(in: text, range: full).map(\.range)
        var words: [Word] = []
        for match in Self.wordPattern.matches(in: text, range: full) {
            let range = match.range
            if cues.contains(where: { NSIntersectionRange($0, range).length > 0 }) { continue }
            let key = Self.normalize(ns.substring(with: range))
            guard !key.isEmpty else { continue }
            words.append(Word(key: key, range: range, weight: Self.weight(of: key)))
        }
        self.words = words
        self.cueRanges = cues
    }

    /// Index of the first word that starts at or after `location`.
    /// Returns `words.count` when no word follows.
    public func wordIndex(atOrAfterCharacter location: Int) -> Int {
        var low = 0
        var high = words.count
        while low < high {
            let mid = (low + high) / 2
            if words[mid].range.location < location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Uncommon words that help the recognizer: names, numbers and long words.
    public func contextualWords(limit: Int = 100) -> [String] {
        let ns = text as NSString
        var seen = Set<String>()
        var result: [String] = []
        for (index, word) in words.enumerated() {
            let original = ns.substring(with: word.range)
            let isCapitalizedMidSentence: Bool = {
                guard index > 0, original.first?.isUppercase == true else { return false }
                let gap = ns.substring(with: NSRange(
                    location: NSMaxRange(words[index - 1].range),
                    length: word.range.location - NSMaxRange(words[index - 1].range)))
                return !gap.contains(where: { ".!?:".contains($0) })
            }()
            let hasDigit = original.contains(where: \.isNumber)
            guard isCapitalizedMidSentence || hasDigit || original.count >= 9 else { continue }
            if seen.insert(original.lowercased()).inserted {
                result.append(original)
                if result.count == limit { break }
            }
        }
        return result
    }

    // MARK: - Normalization

    /// Converts one word to its matching key: lowercase, no accents, no
    /// apostrophes, small numbers as words, common homophones merged.
    public static func normalize(_ word: String) -> String {
        let folded = word
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        let spelled = numberWords[folded] ?? folded
        return homophones[spelled] ?? spelled
    }

    /// Splits recognized speech into matching keys and drops filler sounds.
    public static func keys(fromSpoken text: String) -> [String] {
        let ns = text as NSString
        return wordPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { normalize(ns.substring(with: $0.range)) }
            .filter { !$0.isEmpty && !fillers.contains($0) }
    }

    static func weight(of key: String) -> Double {
        stopwords.contains(key) ? 0.35 : 1.0
    }

    // MARK: - Tables

    private static let wordPattern = try! NSRegularExpression(
        pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#)
    private static let cuePattern = try! NSRegularExpression(pattern: #"\[[^\]\n]*\]"#)

    private static let fillers: Set<String> = ["um", "uh", "uhm", "umm", "er", "erm", "ah", "hmm", "mm", "mhm"]

    private static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "do", "for", "from", "has", "have",
        "he", "her", "his", "i", "if", "in", "is", "it", "its", "me", "my", "not", "of", "on", "or",
        "our", "she", "so", "that", "the", "their", "them", "there", "they", "this", "to", "us",
        "was", "we", "were", "what", "with", "you", "your",
    ]

    private static let homophones: [String: String] = [
        "four": "for", "two": "to", "too": "to", "their": "there", "theyre": "there",
        "youre": "your", "whos": "whose", "thats": "that",
    ]

    private static let numberWords: [String: String] = [
        "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four", "5": "five", "6": "six",
        "7": "seven", "8": "eight", "9": "nine", "10": "ten", "11": "eleven", "12": "twelve",
        "13": "thirteen", "14": "fourteen", "15": "fifteen", "16": "sixteen", "17": "seventeen",
        "18": "eighteen", "19": "nineteen", "20": "twenty", "30": "thirty", "40": "forty",
        "50": "fifty", "60": "sixty", "70": "seventy", "80": "eighty", "90": "ninety",
        "100": "hundred",
    ]
}
