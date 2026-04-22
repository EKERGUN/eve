import SwiftUI
import AppKit
import AVFoundation

@main
struct HermesToggleApp: App {
    @StateObject private var controller = HermesController()
    @StateObject private var voice = VoiceBridge()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        Self.ensureConfigExists()
        // Request mic permission up-front so macOS binds the TCC grant to
        // EVE.app's bundle id rather than to the venv python child.
        // Once granted, macOS remembers and the child process inherits.
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    /// On first launch, drop a starter `config.json` into Application Support
    /// so users can see where to edit wake words / stop phrases / locale.
    static func ensureConfigExists() {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/EVE", isDirectory: true)
        let file = dir.appendingPathComponent("config.json")
        if fm.fileExists(atPath: file.path) { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let starter = """
        {
          "wake_words": ["eve", "eva", "evie", "hey eve"],
          "stop_phrases": [
            "stop", "stop it", "be quiet", "shut up", "enough",
            "dur", "sus", "yeter"
          ],
          "locale": "en-US",
          "silence_finalize_seconds": 1.2
        }
        """
        try? starter.data(using: .utf8)?.write(to: file)
        NSLog("[config] wrote starter config at \\(file.path)")
    }

    var body: some Scene {
        WindowGroup("Hermes") {
            ToggleView()
                .environmentObject(controller)
                .environmentObject(voice)
                .frame(width: 440, height: 620)
                .onAppear {
                    IconSwapper.apply(isOn: controller.isOn)
                    controller.reconcile()
                }
                .onChange(of: controller.isOn) { newValue in
                    IconSwapper.apply(isOn: newValue)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
