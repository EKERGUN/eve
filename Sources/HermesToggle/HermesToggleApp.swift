import SwiftUI
import AppKit
import AVFoundation

@main
struct HermesToggleApp: App {
    @StateObject private var controller = HermesController()
    @StateObject private var voice = VoiceBridge()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        // Request mic permission up-front so macOS binds the TCC grant to
        // Hermes.app's bundle id rather than to the venv python child.
        // Once granted, macOS remembers and the child process inherits.
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
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
