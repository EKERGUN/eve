import Foundation
import AppKit

@MainActor
final class HermesController: ObservableObject {
    @Published var isOn: Bool = false
    @Published var isBusy: Bool = false
    @Published var statusLabel: String = "IDLE"
    @Published var detailLine: String? = nil
    @Published var lastError: String? = nil

    let dashboardURL = "http://127.0.0.1:9119"
    private let dashboardPort = 9119

    private var dashboardProcess: Process?
    private var startedAt: Date?

    private let hermesBin: String = {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/hermes",
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "\(NSHomeDirectory())/.local/bin/hermes"
    }()

    private var logDir: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/HermesToggle", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func toggle() {
        if isBusy { return }
        if isOn { stop() } else { start() }
    }

    func reconcile() {
        Task { await reconcileAsync() }
    }

    private func reconcileAsync() async {
        let dashUp = await pingDashboard()
        let gwUp = runHermes(["gateway", "status"]).exitCode == 0
        let anyUp = dashUp || gwUp
        self.isOn = anyUp
        self.statusLabel = anyUp ? "ONLINE" : "IDLE"
        if anyUp {
            self.detailLine = "\(dashboardURL)  ·  gateway \(gwUp ? "up" : "down")"
        } else {
            self.detailLine = nil
        }
    }

    private func start() {
        isBusy = true
        statusLabel = "STARTING"
        lastError = nil
        Task {
            do {
                if await isDashboardAlreadyRunning() {
                    self.lastError = "dashboard already running on :9119 — skipping spawn"
                } else {
                    try await startDashboard()
                }
                _ = runHermes(["gateway", "start"])
                let reachable = await waitForDashboard(timeout: 12)
                self.startedAt = Date()
                self.isOn = true
                self.isBusy = false
                self.statusLabel = reachable ? "ONLINE" : "PARTIAL"
                self.detailLine = reachable
                    ? "\(dashboardURL)  ·  gateway started"
                    : "dashboard not reachable yet — check logs"
                if reachable, let url = URL(string: dashboardURL) {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                self.isBusy = false
                self.isOn = false
                self.statusLabel = "ERROR"
                self.lastError = "start failed: \(error.localizedDescription)"
            }
        }
    }

    private func stop() {
        isBusy = true
        statusLabel = "STOPPING"
        lastError = nil
        Task {
            _ = runHermes(["gateway", "stop"])
            stopDashboard()
            self.startedAt = nil
            self.isOn = false
            self.isBusy = false
            self.statusLabel = "IDLE"
            self.detailLine = nil
        }
    }

    private func startDashboard() async throws {
        guard FileManager.default.isExecutableFile(atPath: hermesBin) else {
            throw NSError(domain: "HermesToggle", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "hermes binary not found at \(hermesBin)"])
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "\(shellQuote(hermesBin)) dashboard --no-open --port \(dashboardPort)"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        proc.environment = env

        let logURL = logDir.appendingPathComponent("dashboard.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        proc.standardOutput = handle
        proc.standardError = handle

        try proc.run()
        self.dashboardProcess = proc
    }

    private func stopDashboard() {
        if let p = dashboardProcess, p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(3)
            while p.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if p.isRunning {
                kill(p.processIdentifier, SIGKILL)
            }
        }
        dashboardProcess = nil
        _ = runShell("/usr/bin/pkill", ["-f", "hermes dashboard"])
    }

    private func waitForDashboard(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await pingDashboard() { return true }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return false
    }

    private func isDashboardAlreadyRunning() async -> Bool {
        await pingDashboard()
    }

    private func pingDashboard() async -> Bool {
        guard let url = URL(string: "\(dashboardURL)/") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.0
        req.httpMethod = "HEAD"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse { return http.statusCode < 500 }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func runHermes(_ args: [String]) -> (exitCode: Int32, output: String) {
        return runShell(hermesBin, args)
    }

    @discardableResult
    private func runShell(_ bin: String, _ args: [String]) -> (exitCode: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, "run failed: \(error.localizedDescription)")
        }
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
