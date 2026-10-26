/// Tracks where the speaker is in a script from the most recent recognized words.
///
/// Each call to `ingest` aligns the spoken tail against script windows near the
/// current position. Small steps forward need little evidence. Large jumps and
/// moves back need several matching words, so ad-libs and common words do not
/// pull the prompter away from the speaker.
public struct ScriptFollower: Sendable {
    public let script: Script
    /// Index of the next word the speaker will read. `0...script.words.count`.
    public private(set) var position: Int = 0

    public var lookahead = 40
    public var lookbehind = 30

    public init(script: Script, position: Int = 0) {
        self.script = script
        self.position = min(max(0, position), script.words.count)
    }

    public mutating func reset(to index: Int) {
        position = min(max(0, index), script.words.count)
    }

    /// Updates `position` from the latest recognized words, oldest first.
    /// Returns true when the position changed.
    @discardableResult
    public mutating func ingest(spokenTail tail: [String]) -> Bool {
        let words = script.words
        guard !tail.isEmpty, !words.isEmpty else { return false }

        let current = alignment(tail: tail, endingAt: position - 1)
        let stayRank = current?.rank ?? 0

        var best: (end: Int, rank: Double)?
        let first = max(0, position - lookbehind)
        let last = min(words.count - 1, position + lookahead - 1)
        guard first <= last else { return false }

        for end in first...last where end != position - 1 {
            guard let candidate = alignment(tail: tail, endingAt: end) else { continue }
            let delta = end + 1 - position
            guard accepts(candidate, delta: delta, stayRank: stayRank) else { continue }
            let rank = candidate.rank - 0.03 * Double(abs(delta))
            if best == nil || rank > best!.rank { best = (end, rank) }
        }

        guard let best else { return false }
        position = best.end + 1
        return true
    }

    // MARK: - Scoring

    struct Alignment {
        /// Weighted matches across the whole window.
        var total: Double
        /// Weighted matches at or after the current position.
        var fresh: Double
        /// Weighted matches before the current position.
        var support: Double { total - fresh }
        /// Spoken words after the anchor that matched nothing.
        var trailing: Int
        var rank: Double { total - 0.5 * Double(trailing) }
    }

    private func accepts(_ a: Alignment, delta: Int, stayRank: Double) -> Bool {
        // Words that fit here as well as ahead are not new evidence. The
        // recognizer sends the same words again when volatile text becomes final.
        if delta > 0, a.rank <= stayRank { return false }
        switch delta {
        case 1...2:
            return a.fresh >= 0.35 && (a.support >= 0.35 || a.fresh >= 1.0)
        case 3...6:
            return a.fresh >= 1.35
        case 7...:
            return a.fresh >= 2.35
        default:
            // Move back only when the newest word anchors a strong match
            // that clearly beats staying here.
            return a.trailing == 0 && a.total >= 2.8 && a.rank > stayRank + 0.5
        }
    }

    /// Best weighted alignment of `tail` against the script window that ends at
    /// word `end`, with script word `end` matched by one of the last two spoken words.
    func alignment(tail: [String], endingAt end: Int) -> Alignment? {
        let words = script.words
        guard end >= 0, end < words.count else { return nil }
        let m = tail.count
        let low = max(0, end - m - 2)
        let width = end - low  // script words before the anchor

        // dp[i][j]: best (total, fresh) aligning tail[0..<i] with words[low..<low+j].
        var dp = Array(repeating: Array(repeating: (0.0, 0.0), count: width + 1), count: m + 1)
        if width > 0 && m > 0 {
            for i in 1...m {
                for j in 1...width {
                    var cell = better(dp[i - 1][j], dp[i][j - 1])
                    let index = low + j - 1
                    let value = match(tail[i - 1], words[index])
                    if value > 0 {
                        let previous = dp[i - 1][j - 1]
                        let fresh = index >= position ? value : 0
                        cell = better(cell, (previous.0 + value, previous.1 + fresh))
                    }
                    dp[i][j] = cell
                }
            }
        }

        var result: Alignment?
        for anchor in max(0, m - 2)..<m {
            let value = match(tail[anchor], words[end])
            guard value > 0 else { continue }
            let before = dp[anchor][width]
            let fresh = end >= position ? value : 0
            let candidate = Alignment(total: before.0 + value, fresh: before.1 + fresh, trailing: m - 1 - anchor)
            if result == nil || candidate.rank > result!.rank { result = candidate }
        }
        return result
    }

    private func better(_ a: (Double, Double), _ b: (Double, Double)) -> (Double, Double) {
        if a.0 != b.0 { return a.0 > b.0 ? a : b }
        return a.1 >= b.1 ? a : b
    }

    private func match(_ spoken: String, _ word: Script.Word) -> Double {
        similarity(spoken, word.key) * word.weight
    }

    /// 1 for an exact match, less for near misses, 0 for no match.
    func similarity(_ spoken: String, _ key: String) -> Double {
        if spoken == key { return 1 }
        let s = spoken.count, k = key.count
        // A partial word from a hypothesis that is still forming.
        if s >= 3, k > s, key.hasPrefix(spoken), s * 2 >= k { return 0.7 }
        if min(s, k) >= 4 {
            let limit = min(s, k) >= 7 ? 2 : 1
            if abs(s - k) <= limit, editDistance(spoken, key, limit: limit) <= limit { return 0.8 }
        }
        return 0
    }

    private func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            var rowMin = row[0]
            for j in 1...b.count {
                let saved = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : 1 + min(previous, row[j], row[j - 1])
                previous = saved
                rowMin = min(rowMin, row[j])
            }
            if rowMin > limit { return rowMin }
        }
        return row[b.count]
    }
}
