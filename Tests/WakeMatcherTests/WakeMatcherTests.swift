import XCTest
@testable import WakeMatcher

final class WakeMatcherTests: XCTestCase {

    private let matcher = WakeMatcher(
        wakeWords: ["eve", "eva", "hey eve", "hey eva"],
        stopPhrases: [
            "stop", "be quiet", "shut up", "quiet", "silence", "enough",
            "that's enough", "shush",
        ]
    )

    // MARK: findWake

    func testFindWake_matchesWordBoundary() {
        let r = matcher.findWake(in: "hello eve what time is it", after: 0)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.lowerBound, 6)
        XCTAssertEqual(r?.upperBound, 9)
    }

    func testFindWake_longerVariantWins() {
        // Both "eve" and "hey eve" appear; longer should win because
        // wakeWords is sorted longest-first internally.
        let r = matcher.findWake(in: "hey eve please open the door", after: 0)
        XCTAssertEqual(r?.lowerBound, 0)
        XCTAssertEqual(r?.upperBound, 7) // "hey eve"
    }

    func testFindWake_returnsNilWhenAbsent() {
        XCTAssertNil(matcher.findWake(in: "the quick brown fox", after: 0))
    }

    func testFindWake_respectsStartOffset() {
        // "eve" at position 0 should be skipped if startOffset is past it.
        let text = "eve hello eve"
        let first = matcher.findWake(in: text, after: 0)
        XCTAssertEqual(first?.lowerBound, 0)
        let second = matcher.findWake(in: text, after: 5)
        XCTAssertEqual(second?.lowerBound, 10)
    }

    func testFindWake_doesNotMatchInsideWord() {
        // "evening" should NOT match "eve" because of \b boundaries.
        XCTAssertNil(matcher.findWake(in: "good evening everyone", after: 0))
    }

    func testFindWake_clampsLargeStartOffset() {
        // startOffset past end of string should not crash, just return nil.
        XCTAssertNil(matcher.findWake(in: "eve", after: 999))
    }

    // MARK: findLastWakeEnd

    func testFindLastWakeEnd_picksLatestOccurrence() {
        // Two "eve"s — should return offset just past the second.
        let end = matcher.findLastWakeEnd(in: "eve open the file eve close it")
        XCTAssertEqual(end, 21) // "eve close" — past second "eve"
    }

    func testFindLastWakeEnd_noMatch() {
        XCTAssertNil(matcher.findLastWakeEnd(in: "no wake word here"))
    }

    func testFindLastWakeEnd_singleMatchAtStart() {
        XCTAssertEqual(matcher.findLastWakeEnd(in: "eve"), 3)
    }

    // MARK: matchWakeThenStop

    func testMatchWakeThenStop_simple() {
        XCTAssertNotNil(matcher.matchWakeThenStop(in: "eve stop"))
    }

    func testMatchWakeThenStop_withPunctuation() {
        XCTAssertNotNil(matcher.matchWakeThenStop(in: "eve, stop!"))
        XCTAssertNotNil(matcher.matchWakeThenStop(in: "hey eve... be quiet"))
    }

    func testMatchWakeThenStop_rejectsWordsBetween() {
        // The pattern only allows whitespace/punctuation between wake and
        // stop, so "eve please stop" should NOT match — that's a normal
        // utterance, not the emergency barge-in pattern.
        XCTAssertNil(matcher.matchWakeThenStop(in: "eve please stop talking"))
    }

    func testMatchWakeThenStop_rejectsLoneWake() {
        XCTAssertNil(matcher.matchWakeThenStop(in: "eve what time is it"))
    }

    func testMatchWakeThenStop_rejectsLoneStop() {
        XCTAssertNil(matcher.matchWakeThenStop(in: "okay stop"))
    }

    // MARK: isStopPhrase

    func testIsStopPhrase_exactSingleWord() {
        XCTAssertTrue(matcher.isStopPhrase("stop"))
        XCTAssertTrue(matcher.isStopPhrase("Stop"))
        XCTAssertTrue(matcher.isStopPhrase("STOP."))
        XCTAssertTrue(matcher.isStopPhrase("  stop!  "))
    }

    func testIsStopPhrase_exactMultiWord() {
        XCTAssertTrue(matcher.isStopPhrase("be quiet"))
        XCTAssertTrue(matcher.isStopPhrase("Be Quiet."))
    }

    func testIsStopPhrase_repeatedSingleWord() {
        // "stop stop stop" collapses to "stop".
        XCTAssertTrue(matcher.isStopPhrase("stop stop stop"))
    }

    func testIsStopPhrase_multiSingleStops() {
        // Multiple distinct single-word stops in a row are still a stop.
        XCTAssertTrue(matcher.isStopPhrase("stop quiet"))
        XCTAssertTrue(matcher.isStopPhrase("quiet enough"))
    }

    func testIsStopPhrase_rejectsNormalSpeech() {
        XCTAssertFalse(matcher.isStopPhrase("what's the weather"))
        XCTAssertFalse(matcher.isStopPhrase("can you stop the timer"))
        XCTAssertFalse(matcher.isStopPhrase("be quiet about it"))
    }

    func testIsStopPhrase_rejectsEmpty() {
        XCTAssertFalse(matcher.isStopPhrase(""))
        XCTAssertFalse(matcher.isStopPhrase("   "))
        XCTAssertFalse(matcher.isStopPhrase("..."))
    }

    // MARK: Turkish locale (configured via wake_locale + stop_phrases in EVEConfig)

    func testStopPhrase_turkishStops() {
        let tr = WakeMatcher(
            wakeWords: ["eve"],
            stopPhrases: ["dur", "kes", "sus", "kes sesini", "sessiz ol"]
        )
        XCTAssertTrue(tr.isStopPhrase("dur"))
        XCTAssertTrue(tr.isStopPhrase("Kes."))
        XCTAssertTrue(tr.isStopPhrase("kes sesini"))
        XCTAssertFalse(tr.isStopPhrase("nasilsin"))
    }
}
