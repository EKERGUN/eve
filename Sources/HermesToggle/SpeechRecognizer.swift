import Foundation
import AVFoundation
import Speech

/// Simple file logger at ~/Library/Logs/HermesToggle/swift.log — NSLog is
/// unreliable for ad-hoc signed apps, so we append to a file we control.
enum FileLog {
    private static let url: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/HermesToggle", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u.appendingPathComponent("swift.log")
    }()
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    static func log(_ msg: String) {
        let line = "\(fmt.string(from: Date())) \(msg)\n"
        NSLog("%@", msg)
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            try? h.seekToEnd()
            try? h.write(contentsOf: data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

// User-editable config at ~/Library/Application Support/EVE/config.json.
// Missing file or any parse failure falls back to defaults.
struct EVEConfig: Codable {
    var wake_words: [String]?
    var stop_phrases: [String]?
    var locale: String?          // command recognizer (used to transcribe post-wake text)
    var wake_locale: String?     // wake recognizer (runs in parallel, catches the wake word)
    var silence_finalize_seconds: Double?

    static let defaultWakeWords = ["eve", "eva", "evie", "evy", "hey eve", "hey eva"]
    static let defaultStopPhrases = [
        "stop", "stop it", "stop talking", "be quiet", "quiet", "shut up",
        "silence", "shush", "hush", "enough", "that's enough",
        "dur", "sus", "kes", "kes sesini", "sessiz ol", "yeter", "tamam dur",
    ]

    static func load() -> EVEConfig {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/EVE/config.json")
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(EVEConfig.self, from: data) else {
            return EVEConfig()
        }
        FileLog.log("[speech] loaded config: \(url.path)")
        return cfg
    }
}

@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var currentText: String = ""
    @Published var displayText: String = ""   // current utterance only (past processedLength)
    @Published var isRunning: Bool = false
    @Published var level: Double = 0.0
    @Published var lastError: String? = nil
    @Published var conversationActive: Bool = false
    /// Fired when a stop phrase is heard (separate from `onCommand`) so the
    /// bridge can also interrupt any TTS still in flight.
    var onStop: (() -> Void)?
    /// When true, wake detection is skipped. Set while EVE is speaking so her
    /// own voice echoing into the mic can't self-trigger a wake event.
    /// On the falling edge we snap our cursor to the current transcript so
    /// EVE's own echoed words never end up in a user command.
    var suppressWake: Bool = false {
        didSet {
            guard oldValue != suppressWake else { return }
            if oldValue && !suppressWake {
                processedLength = currentText.count
                lastFinalizedText = currentText
                awaitingCommandAfterWake = false
                wakeCutoffIndex = nil
                wakeLastText = currentText
                displayText = ""
                // Apple's recognizer buffers 1-2s of audio internally, so
                // echoed partials keep arriving briefly after EVE stops.
                // Drain window: keep discarding partials for the next
                // ~3s so they don't land as fake user commands.
                drainUntil = Date().addingTimeInterval(3.0)
                FileLog.log("[speech] suppress→listening: snap=\(processedLength), drain until \(drainUntil)")
            }
        }
    }
    private var drainUntil: Date = .distantPast

    private var lastInteractionAt: Date = .distantPast
    private let conversationIdleTimeout: TimeInterval = 120  // 2 minutes

    private let config: EVEConfig
    private let wakeWords: [String]
    private let stopPhraseSet: Set<String>

    // Callbacks
    var onCommand: ((String) -> Void)?   // final command text (post-wake)
    var onWake: (() -> Void)?            // fired the moment "Eve" is heard (for barge-in)

    private let engine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?          // command locale
    private let wakeRecognizer: SFSpeechRecognizer?      // wake locale (may be same as above)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var wakeRequest: SFSpeechAudioBufferRecognitionRequest?
    private var wakeTask: SFSpeechRecognitionTask?
    private var wakeLastText: String = ""

    // Wake-word state
    private var awaitingCommandAfterWake = false
    private var wakeCutoffIndex: String.Index? = nil
    private var lastFinalizedText: String = ""
    /// How many characters of the recognizer's cumulative transcript we've
    /// already analysed for wake words. Bumped to `currentText.count` after
    /// each command is sent so we don't re-trigger on old text when the task
    /// stays alive across turns.
    private var processedLength: Int = 0
    // Debounce re-triggering: ignore wake word if we just handled one.
    private var lastWakeAt: Date = .distantPast
    private var lastPartialUpdate: Date = .distantPast
    private var finalizeTimer: Timer?
    private let silenceFinalizeSeconds: TimeInterval

    init() {
        let cfg = EVEConfig.load()
        self.config = cfg
        self.wakeWords = (cfg.wake_words?.isEmpty == false ? cfg.wake_words! : EVEConfig.defaultWakeWords)
            .map { $0.lowercased() }
        self.stopPhraseSet = Set((cfg.stop_phrases?.isEmpty == false ? cfg.stop_phrases! : EVEConfig.defaultStopPhrases)
            .map { $0.lowercased() })
        self.silenceFinalizeSeconds = cfg.silence_finalize_seconds ?? 1.2
        let locale = cfg.locale ?? "en-US"
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
        // Wake recognizer defaults to the command locale. Set `wake_locale` in
        // config.json to something different (e.g. "tr-TR") when your accent
        // causes the command locale to mis-hear the wake word.
        let wakeLoc = cfg.wake_locale ?? locale
        if wakeLoc == locale {
            self.wakeRecognizer = nil  // reuse single recognizer
        } else {
            self.wakeRecognizer = SFSpeechRecognizer(locale: Locale(identifier: wakeLoc))
        }
        FileLog.log("[speech] wake_words=\(wakeWords) locale=\(locale) wake_locale=\(wakeLoc) finalize=\(silenceFinalizeSeconds)s")
    }

    func start() {
        guard !isRunning else { return }
        lastError = nil
        FileLog.log("[speech] start requested (auth status=\(SFSpeechRecognizer.authorizationStatus().rawValue))")
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                FileLog.log("[speech] auth callback: \(status.rawValue)")
                switch status {
                case .authorized:
                    do {
                        try self.beginSession()
                        FileLog.log("[speech] session started OK, recognizer available=\(self.recognizer?.isAvailable ?? false)")
                    }
                    catch {
                        self.lastError = "speech start: \(error.localizedDescription)"
                        FileLog.log("[speech] beginSession FAILED: \(error.localizedDescription)")
                    }
                case .denied, .restricted, .notDetermined:
                    self.lastError = "Speech recognition not authorized (status=\(status.rawValue))"
                    FileLog.log("[speech] AUTH DENIED")
                @unknown default:
                    self.lastError = "Speech recognition unknown auth state"
                }
            }
        }
    }

    func stop() {
        isRunning = false
        conversationActive = false
        finalizeTimer?.invalidate()
        finalizeTimer = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        wakeTask?.cancel()
        wakeTask = nil
        wakeRequest?.endAudio()
        wakeRequest = nil
        wakeLastText = ""
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        currentText = ""
        displayText = ""
        level = 0.0
    }

    private func beginSession() throws {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw NSError(domain: "SpeechRecognizer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Recognizer unavailable for locale"])
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        // Bias recognition toward the wake words so Apple's LM prefers them
        // over common homophones ("If", "You", "Evan", etc.).
        req.contextualStrings = wakeWords + [
            "Eve", "Eve,", "Hey Eve", "Eve stop", "Eve what",
            "Eve please", "Eve open", "Eve tell me",
        ]
        if #available(macOS 13, *) {
            if recognizer.supportsOnDeviceRecognition {
                req.requiresOnDeviceRecognition = true
            }
        }
        self.request = req

        // If a separate wake recognizer is configured, start its own request.
        if let wakeRec = wakeRecognizer, wakeRec.isAvailable {
            let wReq = SFSpeechAudioBufferRecognitionRequest()
            wReq.shouldReportPartialResults = true
            if #available(macOS 13, *), wakeRec.supportsOnDeviceRecognition {
                wReq.requiresOnDeviceRecognition = true
            }
            self.wakeRequest = wReq
            self.wakeTask = wakeRec.recognitionTask(with: wReq) { [weak self] result, error in
                guard let self else { return }
                if let result = result {
                    Task { @MainActor in self.handleWakeResult(result) }
                }
                if error != nil {
                    Task { @MainActor in self.restartWakeAfterError() }
                }
            }
            FileLog.log("[speech] wake recognizer started (\(wakeRec.locale.identifier))")
        }

        let inputNode = engine.inputNode
        // AEC via setVoiceProcessingEnabled requires a full audio graph
        // including an output node, which this app doesn't set up — enabling
        // it kills the input tap. Rely on `suppressWake` (set while Python
        // reports state=speaking) to prevent self-wake from echo.
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            self?.wakeRequest?.append(buffer)
            // Level meter for the orb
            if let ch = buffer.floatChannelData?[0] {
                let n = Int(buffer.frameLength)
                if n > 0 {
                    var sum: Float = 0
                    for i in 0..<n { let v = ch[i]; sum += v * v }
                    let rms = sqrtf(sum / Float(n))
                    let norm = min(1.0, Double(rms) * 6.0)
                    Task { @MainActor [weak self] in self?.level = norm }
                }
            }
        }

        engine.prepare()
        try engine.start()
        isRunning = true

        self.task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result = result {
                Task { @MainActor in self.handleResult(result) }
            }
            if let error = error {
                Task { @MainActor in
                    // Some errors fire on cancellation — surface only if we're still running.
                    if self.isRunning {
                        self.lastError = "speech: \(error.localizedDescription)"
                    }
                    self.restartAfterError()
                }
            }
        }
    }

    private func restartAfterError() {
        // If the recognizer died while we meant to be running, restart it.
        guard isRunning else { return }
        task = nil
        request = nil
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        // Small delay then restart
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if self.isRunning {
                do { try self.beginSession() }
                catch { self.lastError = "restart: \(error.localizedDescription)" }
            }
        }
    }

    private func handleWakeResult(_ result: SFSpeechRecognitionResult) {
        let full = result.bestTranscription.formattedString
        FileLog.log("[speech] WAKE partial: \(full.prefix(120))")
        if suppressWake {
            wakeLastText = full
            return
        }
        let lower = full.lowercased()
        // Only look at the tail (everything past what we already processed).
        if let _ = findWake(in: lower, after: wakeLastText.lowercased().count) {
            let now = Date()
            if now.timeIntervalSince(lastWakeAt) > 0.6 {
                lastWakeAt = now
                FileLog.log("[speech] WAKE DETECTED from wake recognizer")
                onWake?()
            }
            awaitingCommandAfterWake = true
            // Mark where the command recognizer's cursor should start cutting.
            // We cannot map wake-recognizer offset → command-recognizer offset
            // directly (different tokenizations), so we mark "everything from
            // NOW onwards on the command stream is the command".
            wakeCutoffIndex = currentText.endIndex
        }
        wakeLastText = full
        // Each wake result counts as an audio update — reset the finalize timer.
        lastPartialUpdate = Date()
        scheduleFinalize()
    }

    private func restartWakeAfterError() {
        guard isRunning, let wakeRec = wakeRecognizer else { return }
        wakeTask?.cancel()
        wakeTask = nil
        wakeRequest?.endAudio()
        wakeRequest = nil
        wakeLastText = ""
        let wReq = SFSpeechAudioBufferRecognitionRequest()
        wReq.shouldReportPartialResults = true
        if #available(macOS 13, *), wakeRec.supportsOnDeviceRecognition {
            wReq.requiresOnDeviceRecognition = true
        }
        self.wakeRequest = wReq
        self.wakeTask = wakeRec.recognitionTask(with: wReq) { [weak self] result, error in
            guard let self else { return }
            if let result = result {
                Task { @MainActor in self.handleWakeResult(result) }
            }
            if error != nil {
                Task { @MainActor in self.restartWakeAfterError() }
            }
        }
    }

    private func handleResult(_ result: SFSpeechRecognitionResult) {
        let full = result.bestTranscription.formattedString
        FileLog.log("[speech] partial: \(String(full.suffix(120))) final=\(result.isFinal)")

        // Detect Apple resetting its partial buffer (occurs after long silence
        // or when the recognizer segments a new utterance). If the new `full`
        // is shorter than our cursor OR no longer starts with our last
        // finalized prefix, the cursor is stale — reset it.
        let lowerFull = full.lowercased()
        let lowerLast = lastFinalizedText.lowercased()
        if full.count < processedLength || !lowerFull.hasPrefix(lowerLast) {
            FileLog.log("[speech] transcript reset (len was \(processedLength), now \(full.count)) — clearing cursor")
            processedLength = 0
            lastFinalizedText = ""
            awaitingCommandAfterWake = false
            wakeCutoffIndex = nil
        }

        currentText = full
        displayText = processedLength < full.count
            ? String(full.dropFirst(processedLength))
            : ""
        lastPartialUpdate = Date()

        // If we already detected wake via the wake recognizer, keep the
        // cursor at the start of this stream (everything will be the command).
        if awaitingCommandAfterWake && wakeCutoffIndex == nil {
            wakeCutoffIndex = full.startIndex
        }

        // Wake detection only looks at the NEW portion of the transcript
        // (past processedLength) so old commands never retrigger wake.
        let lower = full.lowercased()
        let inDrain = Date() < drainUntil
        if suppressWake || inDrain {
            // Either EVE is speaking, or we're in the post-speech drain
            // window catching Apple's buffered echo partials. Scan for the
            // emergency barge-in pattern ("<wake> <stop>") — a sequence
            // that essentially never appears in Hermes's own reply text.
            let newTail = String(full.dropFirst(processedLength))
            if let _ = matchWakeThenStop(in: newTail) {
                FileLog.log("[speech] barge-in STOP during \(suppressWake ? "suppression" : "drain"): \(newTail.suffix(80))")
                conversationActive = false
                onStop?()
            }
            processedLength = full.count
            lastFinalizedText = full
            return
        }
        if let wakeRange = findWake(in: lower, after: max(processedLength, lastFinalizedText.lowercased().count)) {
            // Fire wake event immediately (barge-in).
            let now = Date()
            if now.timeIntervalSince(lastWakeAt) > 0.6 {
                lastWakeAt = now
                onWake?()
            }
            awaitingCommandAfterWake = true
            // Remember index right AFTER the wake word, in the mixed-case full string.
            let lowerIdx = lower.index(lower.startIndex, offsetBy: wakeRange.upperBound)
            let mixedOffset = lower.distance(from: lower.startIndex, to: lowerIdx)
            wakeCutoffIndex = full.index(full.startIndex, offsetBy: mixedOffset)
        }

        // Every partial update resets the finalize timer. When it fires after
        // `silenceFinalizeSeconds` of no updates, we treat the current text
        // as final. SFSpeechRecognizer's own `isFinal` only fires on explicit
        // audio end, so we need our own silence-based cutoff.
        scheduleFinalize()

        if result.isFinal {
            finalizeNow()
        }
    }

    private func scheduleFinalize() {
        finalizeTimer?.invalidate()
        finalizeTimer = Timer.scheduledTimer(withTimeInterval: silenceFinalizeSeconds,
                                             repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finalizeNow() }
        }
    }

    private func finalizeNow() {
        finalizeTimer?.invalidate()
        finalizeTimer = nil
        let full = currentText

        // Expire conversation after long idle.
        if conversationActive && Date().timeIntervalSince(lastInteractionAt) > conversationIdleTimeout {
            FileLog.log("[speech] conversation timed out after \(Int(conversationIdleTimeout))s idle — requiring wake word again")
            conversationActive = false
        }

        // Decide which part of the transcript is the command.
        var command: String? = nil
        if awaitingCommandAfterWake {
            // Find the LAST wake match in the *current* full text and take
            // everything after it. Apple's recognizer occasionally re-writes
            // partials without changing length, so a stored index can go
            // stale; rescanning at finalize avoids losing command words.
            let lower = full.lowercased()
            if let endOffset = findLastWakeEnd(in: lower) {
                let idx = full.index(full.startIndex, offsetBy: endOffset)
                command = String(full[idx...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?;:\n\t"))
            } else if let cut = wakeCutoffIndex, cut <= full.endIndex {
                // Rescan didn't find the wake (rare) — fall back to stored index.
                command = String(full[cut...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?;:\n\t"))
            }
        } else if conversationActive {
            // No wake required while conversation is active — take everything
            // past the cursor as the command.
            let tail = String(full.dropFirst(processedLength))
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?;:\n\t"))
            if !tail.isEmpty { command = tail }
        }

        if let c = command, !c.isEmpty {
            if isStopPhrase(c) {
                FileLog.log("[speech] stop phrase: \(c) — exiting conversation")
                conversationActive = false
                onStop?()
            } else {
                FileLog.log("[speech] FIRE command: \(c.prefix(80)) (conversationActive=\(conversationActive))")
                conversationActive = true     // entering / staying in conversation
                lastInteractionAt = Date()
                onCommand?(c)
            }
        }

        processedLength = full.count
        awaitingCommandAfterWake = false
        wakeCutoffIndex = nil
        lastFinalizedText = full
        wakeLastText = full
        displayText = ""
    }

    func isStopPhrase(_ text: String) -> Bool {
        let cleaned = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))
        if stopPhraseSet.contains(cleaned) { return true }

        // Split into words. If every word (after dedup) forms a stop phrase,
        // treat the whole utterance as "stop". Catches "stop stop", "stop now",
        // "be quiet be quiet", etc.
        let words = cleaned
            .split(whereSeparator: { !$0.isLetter })
            .map { String($0) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return false }

        // De-dupe adjacent repeats: "stop stop stop" -> "stop"
        var compact: [String] = []
        for w in words where compact.last != w { compact.append(w) }
        let collapsed = compact.joined(separator: " ")
        if stopPhraseSet.contains(collapsed) { return true }

        // Also accept if EVERY distinct word is a single-word stop token.
        let singleWordStops = Set(stopPhraseSet.filter { !$0.contains(" ") })
        if Set(words).isSubset(of: singleWordStops) { return true }

        return false
    }

    private func startNewRequest() {
        // Replace the recognition request with a fresh one so subsequent utterances recognize.
        guard isRunning, let recognizer = recognizer else { return }
        task?.cancel()
        task = nil
        request?.endAudio()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        // Bias recognition toward the wake words so Apple's LM prefers them
        // over common homophones ("If", "You", "Evan", etc.).
        req.contextualStrings = wakeWords + [
            "Eve", "Eve,", "Hey Eve", "Eve stop", "Eve what",
            "Eve please", "Eve open", "Eve tell me",
        ]
        if #available(macOS 13, *) {
            if recognizer.supportsOnDeviceRecognition {
                req.requiresOnDeviceRecognition = true
            }
        }
        self.request = req
        self.task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result = result {
                Task { @MainActor in self.handleResult(result) }
            }
            if let error = error {
                Task { @MainActor in self.restartAfterError() }
            }
        }
    }

    /// Check if the input contains a wake word followed immediately (within a
    /// few filler tokens) by a stop phrase — e.g. "eve stop", "eve be quiet",
    /// "hey eve shut up". Used for barge-in during TTS playback.
    func matchWakeThenStop(in text: String) -> Range<String.Index>? {
        let lower = text.lowercased()
        for wake in wakeWords.sorted(by: { $0.count > $1.count }) {
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

    /// Scan the ENTIRE string for the LAST occurrence of any wake word and
    /// return the offset just past its end. Used on finalize to locate the
    /// command boundary fresh (avoids stale indices when Apple re-transcribes
    /// partials).
    func findLastWakeEnd(in lower: String) -> Int? {
        let sorted = wakeWords.sorted { $0.count > $1.count }
        var best: Int? = nil
        var bestStart: Int = -1
        for v in sorted {
            let escaped = NSRegularExpression.escapedPattern(for: v)
            let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b",
                                                 options: .caseInsensitive)
            guard let rx = regex else { continue }
            let ns = lower as NSString
            let matches = rx.matches(in: lower, range: NSRange(location: 0, length: ns.length))
            for m in matches {
                if m.range.location > bestStart {
                    bestStart = m.range.location
                    best = m.range.location + m.range.length
                }
            }
        }
        return best
    }

    // Wake-word matcher. Uses the per-instance `wakeWords` list (config-driven).
    // Returns the (start, end) offset range in `lower`, or nil. Longer variants
    // checked first so "hey eve" beats "eve".
    func findWake(in lower: String, after startOffset: Int) -> Range<Int>? {
        let sorted = wakeWords.sorted { $0.count > $1.count }
        let search = String(lower.dropFirst(min(startOffset, lower.count)))
        for v in sorted {
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
}
