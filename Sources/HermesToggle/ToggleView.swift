import SwiftUI
import AppKit

struct ToggleView: View {
    @EnvironmentObject var controller: HermesController
    @EnvironmentObject var voice: VoiceBridge

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.08)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                header
                caduceus
                voiceStatus
                bigToggle
                statusBlock
                footer
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("EVE")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .tracking(6)
                .foregroundStyle(controller.isOn ? Color.orange.opacity(0.9) : Color.white.opacity(0.45))
            Spacer()
            Circle()
                .fill(controller.isOn ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 8, height: 8)
                .shadow(color: controller.isOn ? .green : .clear, radius: 6)
            Text(controller.statusLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var caduceus: some View {
        Button {
            guard controller.isOn else { return }
            voice.toggle()
        } label: {
            SiriOrb(state: voice.isOn ? voice.state : .idle,
                    level: voice.isOn ? voice.level : 0)
                .frame(width: 240, height: 240)
                .opacity(controller.isOn ? 1.0 : 0.55)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!controller.isOn || voice.isBusy)
        .help(controller.isOn
              ? (voice.isOn ? "Click to stop listening" : "Click to talk to Hermes")
              : "Turn Hermes on first")
    }

    private var bigToggle: some View {
        Button {
            controller.toggle()
        } label: {
            ZStack(alignment: controller.isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(controller.isOn
                          ? LinearGradient(colors: [Color(red: 0.95, green: 0.58, blue: 0.15),
                                                     Color(red: 0.85, green: 0.32, blue: 0.12)],
                                           startPoint: .leading, endPoint: .trailing)
                          : LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.06)],
                                           startPoint: .leading, endPoint: .trailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: 36, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: controller.isOn ? .orange.opacity(0.45) : .clear, radius: 18, y: 6)

                Circle()
                    .fill(Color.white)
                    .frame(width: 58, height: 58)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                    .overlay(
                        Image(systemName: controller.isBusy ? "hourglass"
                                : (controller.isOn ? "power" : "power"))
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(controller.isOn
                                             ? Color(red: 0.85, green: 0.32, blue: 0.12)
                                             : Color.black.opacity(0.55))
                    )
                    .padding(7)
            }
            .frame(height: 72)
            .animation(.spring(response: 0.4, dampingFraction: 0.72), value: controller.isOn)
        }
        .buttonStyle(.plain)
        .disabled(controller.isBusy)
        .opacity(controller.isBusy ? 0.75 : 1.0)
    }

    private var statusBlock: some View {
        VStack(spacing: 10) {
            Text(controller.isOn ? "Hermes is running" : "Hermes is off")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            if let detail = controller.detailLine {
                Text(detail)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }

            if controller.isOn {
                HStack(spacing: 10) {
                    Button {
                        if let url = URL(string: controller.dashboardURL) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Open Dashboard", systemImage: "safari")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(controller.dashboardURL, forType: .string)
                    } label: {
                        Label("Copy URL", systemImage: "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var voiceStatus: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(voice.isOn ? Color.green : Color.white.opacity(0.25))
                    .frame(width: 7, height: 7)
                    .shadow(color: voice.isOn ? .green : .clear, radius: 4)
                Text(voice.isOn ? voice.state.rawValue.uppercased() : "TAP ORB TO TALK")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(.white.opacity(0.7))
            }

            // Live recognizer text — updates as you speak (shows EVE is hearing you).
            if voice.isOn {
                Text(voice.liveText.isEmpty ? " " : voice.liveText)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 16)
            }

            if let t = voice.lastTranscript, voice.isOn {
                Text("▶ \(t)")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            if let r = voice.lastReply, voice.isOn {
                Text(r)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
            }
            if let err = voice.errorMessage {
                Text(err)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.85))
                    .lineLimit(2)
            }
        }
        .frame(minHeight: 28)
    }

    private var footer: some View {
        VStack(spacing: 2) {
            if let err = controller.lastError {
                Text(err)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            Text("☤ dashboard + gateway")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.25))
        }
    }
}
