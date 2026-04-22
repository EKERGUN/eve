import Foundation
import AVFoundation
import Speech

// User-editable config at ~/Library/Application Support/EVE/config.json.
// Missing file or any parse failure falls back to defaults.
struct EVEConfig: Codable {
    var wake_words: [String]?
    var stop_phrases: [String]?
    var locale: String?
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
        NSLog("[speech] loaded config: \(url.path)")
        return cfg
    }
}

@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var currentText: String = ""
    @Published var isRunning: Bool = false
    @Published var level: Double = 0.0
    @Published var lastError: String? = nil

    private let config: EVEConfig
    private let wakeWords: [String]
    private let stopPhraseSet: Set<String>

    // Callbacks
    var onCommand: ((String) -> Void)?   // final command text (post-wake)
    var onWake: (() -> Void)?            // fired the moment "Eve" is heard (for barge-in)

    private let engine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    // Wake-word state
    private var awaitingCommandAfterWake = false
    private var wakeCutoffIndex: String.Index? = nil
    private var lastFinalizedText: String = ""
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
        NSLog("[speech] wake_words=\(wakeWords) locale=\(locale) finalize=\(silenceFinalizeSeconds)s")
    }

    func start() {
        guard !isRunning else { return }
        lastError = nil
        NSLog("[speech] start requested (auth status=\(SFSpeechRecognizer.authorizationStatus().rawValue))")
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                NSLog("[speech] auth callback: \(status.rawValue)")
                switch status {
                case .authorized:
                    do {
                        try self.beginSession()
                        NSLog("[speech] session started OK, recognizer available=\(self.recognizer?.isAvailable ?? false)")
                    }
                    catch {
                        self.lastError = "speech start: \(error.localizedDescription)"
                        NSLog("[speech] beginSession FAILED: \(error.localizedDescription)")
                    }
                case .denied, .restricted, .notDetermined:
                    self.lastError = "Speech recognition not authorized (status=\(status.rawValue))"
                    NSLog("[speech] AUTH DENIED")
                @unknown default:
                    self.lastError = "Speech recognition unknown auth state"
                }
            }
        }
    }

    func stop() {
        isRunning = false
        finalizeTimer?.invalidate()
        finalizeTimer = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        currentText = ""
        level = 0.0
    }

    private func beginSession() throws {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw NSError(domain: "SpeechRecognizer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Recognizer unavailable for locale"])
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if #available(macOS 13, *) {
            if recognizer.supportsOnDeviceRecognition {
                req.requiresOnDeviceRecognition = true
            }
        }
        self.request = req

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
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

    private func handleResult(_ result: SFSpeechRecognitionResult) {
        let full = result.bestTranscription.formattedString
        NSLog("[speech] partial: \(full.prefix(120)) final=\(result.isFinal)")
        currentText = full
        lastPartialUpdate = Date()

        // Detect wake word in the *newly* spoken portion.
        let lower = full.lowercased()
        if let wakeRange = findWake(in: lower, after: lastFinalizedText.lowercased().count) {
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
        if awaitingCommandAfterWake, let cut = wakeCutoffIndex,
           cut <= full.endIndex {
            let command = String(full[cut...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?;:\n\t"))
            if !command.isEmpty {
                if isStopPhrase(command) {
                    // "Eve stop" / "Eve be quiet" / "Eve sus" → go idle,
                    // don't bother Hermes. Any in-flight TTS was already
                    // killed by the onWake interrupt.
                    NSLog("[voice] stop phrase: \(command) — going idle")
                } else {
                    onCommand?(command)
                }
            }
        }
        // Reset for the next utterance.
        awaitingCommandAfterWake = false
        wakeCutoffIndex = nil
        lastFinalizedText = ""
        currentText = ""
        // Tear down + rebuild the request so SFSpeechRecognizer starts a new
        // segment (old one accumulates too much context and eventually
        // hits duration limits or rejects input).
        startNewRequest()
    }

    func isStopPhrase(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
        return stopPhraseSet.contains(t)
    }

    private func startNewRequest() {
        // Replace the recognition request with a fresh one so subsequent utterances recognize.
        guard isRunning, let recognizer = recognizer else { return }
        task?.cancel()
        task = nil
        request?.endAudio()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
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
