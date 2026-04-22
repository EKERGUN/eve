import Foundation
import AppKit
import Combine

enum VoiceState: String {
    case idle, listening, transcribing, thinking, speaking, error
}

@MainActor
final class VoiceBridge: ObservableObject {
    @Published var isOn: Bool = false
    @Published var isBusy: Bool = false
    @Published var state: VoiceState = .idle
    @Published var level: Double = 0.0
    @Published var liveText: String = ""
    @Published var lastTranscript: String? = nil
    @Published var lastReply: String? = nil
    @Published var errorMessage: String? = nil
    @Published var conversationActive: Bool = false

    private var bridgeProcess: Process?
    private var ws: URLSessionWebSocketTask?
    private let host = "127.0.0.1"
    private let port = 9121
    let speech = SpeechRecognizer()
    private var cancellables = Set<AnyCancellable>()

    init() {
        speech.$level
            .receive(on: RunLoop.main)
            .sink { [weak self] newLevel in self?.level = newLevel }
            .store(in: &cancellables)
        speech.$displayText
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.liveText = t }
            .store(in: &cancellables)
        speech.$conversationActive
            .receive(on: RunLoop.main)
            .sink { [weak self] b in self?.conversationActive = b }
            .store(in: &cancellables)
    }

    private let pythonPath = "\(NSHomeDirectory())/.hermes/hermes-agent/venv/bin/python"
    private var bridgeScriptPath: String {
        let bundled = Bundle.main.resourcePath.map { "\($0)/voice-bridge/bridge.py" }
        if let p = bundled, FileManager.default.fileExists(atPath: p) { return p }
        return "\(NSHomeDirectory())/.hermes/dock-app/voice-bridge/bridge.py"
    }

    private var logDir: URL {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/HermesToggle", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func toggle() {
        if isBusy { return }
        if isOn { turnOff() } else { turnOn() }
    }

    func interrupt() {
        send(["cmd": "interrupt"])
    }

    private func turnOn() {
        isBusy = true
        errorMessage = nil
        // Wire speech callbacks before starting
        speech.onWake = { [weak self] in
            guard let self else { return }
            NSLog("[voice] WAKE detected — barging in")
            self.send(["cmd": "interrupt"])
            self.state = .listening
        }
        speech.onCommand = { [weak self] command in
            guard let self else { return }
            NSLog("[voice] command: \(command)")
            self.lastTranscript = command
            self.send(["cmd": "process", "text": command])
        }
        Task {
            do {
                NSLog("[voice] turnOn: freeing port")
                freePort()
                try? await Task.sleep(nanoseconds: 300_000_000)
                NSLog("[voice] turnOn: spawning bridge")
                try spawnBridge()
                NSLog("[voice] turnOn: connecting ws")
                try await connectWS()
                NSLog("[voice] turnOn: starting speech recognizer")
                self.speech.start()
                self.isOn = true
                self.state = .listening
                self.isBusy = false
                NSLog("[voice] turnOn: done")
            } catch {
                self.errorMessage = "voice start failed: \(error.localizedDescription)"
                killBridge()
                self.state = .idle
                self.level = 0.0
                self.isOn = false
                self.isBusy = false
            }
        }
    }

    private func turnOff() {
        isBusy = true
        isOn = false
        speech.stop()
        send(["cmd": "stop"])
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            killBridge()
            freePort()
            self.state = .idle
            self.level = 0.0
            self.isBusy = false
        }
    }

    private func freePort() {
        // Kill anything holding the bridge port (zombie from a prior session).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "lsof -nP -tiTCP:\(port) | xargs -r kill -9 2>/dev/null; pkill -9 -f 'voice-bridge/bridge.py' 2>/dev/null; true"]
        try? p.run()
        p.waitUntilExit()
    }

    private func spawnBridge() throws {
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            throw NSError(domain: "VoiceBridge", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "python not found at \(pythonPath)"])
        }
        guard FileManager.default.fileExists(atPath: bridgeScriptPath) else {
            throw NSError(domain: "VoiceBridge", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "bridge.py not found at \(bridgeScriptPath)"])
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [bridgeScriptPath, "--port", "\(port)", "--silence-duration", "1.5"]

        var env = ProcessInfo.processInfo.environment
        env["HERMES_HOME"] = "\(NSHomeDirectory())/.hermes"
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        let logURL = logDir.appendingPathComponent("voice.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let fh = try FileHandle(forWritingTo: logURL)
        try fh.seekToEnd()
        proc.standardOutput = fh
        proc.standardError = fh

        try proc.run()
        self.bridgeProcess = proc
    }

    private func connectWS() async throws {
        let url = URL(string: "ws://\(host):\(port)")!
        var lastError: Error = NSError(domain: "VoiceBridge", code: -1,
                                       userInfo: [NSLocalizedDescriptionKey: "no attempts"])
        // Retry for ~5s while Python boots. Handshake = successfully receive
        // the first event (server sends {"event":"state","value":"idle"} on
        // connect). Reading proves the WS is fully open — sendPing has
        // returned false-positives here.
        for _ in 0..<16 {
            let task = URLSession.shared.webSocketTask(with: url)
            task.resume()
            do {
                let msg = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URLSessionWebSocketTask.Message, Error>) in
                    task.receive { result in
                        switch result {
                        case .success(let m): cont.resume(returning: m)
                        case .failure(let e): cont.resume(throwing: e)
                        }
                    }
                }
                NSLog("[voice] ws handshake ok, first msg received")
                // Feed that first message through handleEvent.
                switch msg {
                case .string(let s): self.handleEvent(s)
                case .data(let d): self.handleEvent(String(data: d, encoding: .utf8) ?? "")
                @unknown default: break
                }
                self.ws = task
                self.listen()
                return
            } catch {
                lastError = error
                task.cancel(with: .goingAway, reason: nil)
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
        throw lastError
    }

    private func listen() {
        guard let ws = ws else { return }
        ws.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                Task { @MainActor in
                    // Ignore close errors after we intentionally turned off.
                    if self.isOn {
                        self.errorMessage = "ws closed: \(err.localizedDescription)"
                    }
                }
            case .success(let msg):
                switch msg {
                case .string(let s): self.handleEvent(s)
                case .data(let d): self.handleEvent(String(data: d, encoding: .utf8) ?? "")
                @unknown default: break
                }
                self.listen()
            }
        }
    }

    private func handleEvent(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let ev = obj["event"] as? String ?? ""
        Task { @MainActor in
            switch ev {
            case "state":
                if let v = obj["value"] as? String, let st = VoiceState(rawValue: v) {
                    self.state = st
                    // Suppress wake detection while EVE is speaking so her
                    // own voice bleeding into the mic can't self-trigger.
                    self.speech.suppressWake = (st == .speaking || st == .thinking)
                }
            case "transcript":
                if let t = obj["text"] as? String { self.lastTranscript = t }
            case "reply":
                if let t = obj["text"] as? String { self.lastReply = t }
            case "error":
                if let m = obj["message"] as? String { self.errorMessage = m }
            default: break
            }
        }
    }

    private func send(_ dict: [String: Any]) {
        guard let ws = ws,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else {
            NSLog("[voice] send skipped, no ws or bad json: \(dict)")
            return
        }
        NSLog("[voice] sending: \(s)")
        ws.send(.string(s)) { err in
            if let err = err {
                NSLog("[voice] send error: \(err.localizedDescription)")
            } else {
                NSLog("[voice] send ok")
            }
        }
    }

    private func killBridge() {
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        if let p = bridgeProcess, p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(2)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        bridgeProcess = nil
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pkill"),
                             arguments: ["-f", "voice-bridge/bridge.py"])
    }
}
