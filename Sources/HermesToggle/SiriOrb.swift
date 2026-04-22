import SwiftUI

struct SiriOrb: View {
    let state: VoiceState
    let level: Double  // 0.0..1.0
    @State private var phase: Double = 0

    private var palette: [Color] {
        switch state {
        case .listening:    return [Color(red: 1.00, green: 0.78, blue: 0.28),
                                    Color(red: 0.95, green: 0.50, blue: 0.14)]
        case .transcribing: return [Color(red: 0.40, green: 0.85, blue: 1.00),
                                    Color(red: 0.22, green: 0.55, blue: 0.92)]
        case .thinking:     return [Color(red: 0.72, green: 0.50, blue: 1.00),
                                    Color(red: 0.40, green: 0.20, blue: 0.85)]
        case .speaking:     return [Color(red: 1.00, green: 0.92, blue: 0.55),
                                    Color(red: 1.00, green: 0.52, blue: 0.22)]
        case .error:        return [Color.red.opacity(0.9), Color.red.opacity(0.5)]
        default:            return [Color(red: 1.00, green: 0.70, blue: 0.30),
                                    Color(red: 0.70, green: 0.35, blue: 0.12)]
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
            Canvas { gfx, size in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let rect = CGRect(origin: .zero, size: size)
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let baseR = min(size.width, size.height) * 0.34
                let breathing = 1.0 + 0.04 * sin(t * 1.8)
                let lvl = max(0, min(1, level))
                let audioBoost = 1.0 + lvl * 0.55
                let r = baseR * breathing * audioBoost

                // Core orb (no outer halo — keeps the orb a clean circle with
                // no rectangular edge where the glow would clip against the frame).
                let orbRect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                gfx.fill(
                    Circle().path(in: orbRect),
                    with: .radialGradient(
                        Gradient(colors: [palette[0], palette[1]]),
                        center: CGPoint(x: center.x - r * 0.3, y: center.y - r * 0.3),
                        startRadius: 0, endRadius: r
                    )
                )

                // Morphing noisy ring — three sinusoidal offsets that "ripple"
                let lobes = [3.0, 5.0, 7.0]
                let speeds = [1.6, 1.1, 2.3]
                for (i, l) in lobes.enumerated() {
                    var path = Path()
                    let amp = r * (0.04 + 0.08 * lvl)
                    let steps = 120
                    for s in 0...steps {
                        let theta = Double(s) / Double(steps) * .pi * 2
                        let wobble = sin(theta * l + t * speeds[i]) * amp
                        let rr = r + wobble + CGFloat(i) * 1.5
                        let x = center.x + CGFloat(cos(theta)) * rr
                        let y = center.y + CGFloat(sin(theta)) * rr
                        if s == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    path.closeSubpath()
                    gfx.stroke(path,
                               with: .color(palette[0].opacity(0.22 - Double(i) * 0.05)),
                               lineWidth: 1.2)
                }

                // Specular highlight
                let hlR = r * 0.32
                let hlRect = CGRect(x: center.x - r * 0.35 - hlR / 2,
                                    y: center.y - r * 0.45 - hlR / 2,
                                    width: hlR, height: hlR * 0.7)
                gfx.fill(
                    Ellipse().path(in: hlRect),
                    with: .color(.white.opacity(0.35))
                )
            }
            .blur(radius: 0.4)
        }
    }
}
