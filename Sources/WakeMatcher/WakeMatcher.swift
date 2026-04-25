import Foundation

/// Pure, dependency-free wake-word and stop-phrase matcher. Lives in its
/// own module so it can be unit-tested without dragging in `@MainActor`,
/// AVFoundation, or Speech.framework.
public struct WakeMatcher: Sendable {
    /// Lowercased, sorted longest-first so "hey eve" beats "eve" when both
    /// would otherwise match the same prefix.
    public let wakeWords: [String]
    public let stopPhraseSet: Set<String>

    public init(wakeWords: [String], stopPhrases: [String]) {
        self.wakeWords = wakeWords
            .map { $0.lowercased() }
            .sorted { $0.count > $1.count }
        self.stopPhraseSet = Set(stopPhrases.map { $0.lowercased() })
    }

    /// First wake-word occurrence in `lower` whose start is at or past
    /// `startOffset`. Offsets are Character counts into `lower`.
    public func findWake(in lower: String, after startOffset: Int) -> Range<Int>? {
        let search = String(lower.dropFirst(min(startOffset, lower.count)))
        for v in wakeWords {
            let escaped = NSRegularExpression.escapedPattern(for: v)
            if let r = search.range(of: "\\b\(escaped)\\b",
                                    options: [.regularExpression, .caseInsensitive]) {
                let offset = search.distance(from: search.startIndex, to: r.lowerBound) + startOffset
                let end = search.distance(from: search.startIndex, to: r.upperBound) + startOffset
                return offset..<end
            }
        }
        return nil
    }

    /// Offset just past the LAST wake-word match in `lower`, or nil if no
    /// wake word appears. Used at finalize time to locate the boundary
    /// between wake word and command without relying on a stale stored
    /// offset.
    public func findLastWakeEnd(in lower: String) -> Int? {
        var bestEnd: Int? = nil
        var bestStart: Int = -1
        for v in wakeWords {
            let escaped = NSRegularExpression.escapedPattern(for: v)
            guard let rx = try? NSRegularExpression(pattern: "\\b\(escaped)\\b",
                                                    options: .caseInsensitive) else { continue }
            let ns = lower as NSString
            for m in rx.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
                if m.range.location > bestStart {
                    bestStart = m.range.location
                    bestEnd = m.range.location + m.range.length
                }
            }
        }
        return bestEnd
    }

    /// Wake-word followed (with only whitespace/punctuation between) by a
    /// stop phrase — e.g. "eve stop", "hey eve, be quiet". Used as a
    /// barge-in heuristic during TTS playback. The pattern intentionally
    /// disallows other words between wake and stop so it doesn't match
    /// regular speech that happens to contain both tokens.
    public func matchWakeThenStop(in text: String) -> Range<String.Index>? {
        let lower = text.lowercased()
        for wake in wakeWords {
            let wakeEsc = NSRegularExpression.escapedPattern(for: wake)
            for stop in stopPhraseSet {
                let stopEsc = NSRegularExpression.escapedPattern(for: stop)
                let pattern = "\\b\(wakeEsc)\\b[,\\.!\\?\\s]*\\b\(stopEsc)\\b"
                if let r = lower.range(of: pattern, options: [.regularExpression]) {
                    return r
                }
            }
        }
        return nil
    }

    /// Whether the utterance is a stop phrase. Matches:
    ///   - Exact membership of a configured stop phrase (after trimming).
    ///   - Adjacent-deduped utterances ("stop stop" → "stop").
    ///   - Utterances composed entirely of single-word stop tokens
    ///     ("be quiet" + "stop" → still a stop, in any order).
    public func isStopPhrase(_ text: String) -> Bool {
        let cleaned = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))
        if stopPhraseSet.contains(cleaned) { return true }

        let words = cleaned
            .split(whereSeparator: { !$0.isLetter })
            .map { String($0) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return false }

        var compact: [String] = []
        for w in words where compact.last != w { compact.append(w) }
        let collapsed = compact.joined(separator: " ")
        if stopPhraseSet.contains(collapsed) { return true }

        let singleWordStops = Set(stopPhraseSet.filter { !$0.contains(" ") })
        if Set(words).isSubset(of: singleWordStops) { return true }

        return false
    }
}
