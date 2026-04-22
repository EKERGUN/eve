import AppKit
import SwiftUI

enum IconSwapper {
    static func apply(isOn: Bool) {
        let size = NSSize(width: 512, height: 512)
        let img = NSImage(size: size)
        img.lockFocus()
        draw(isOn: isOn, rect: NSRect(origin: .zero, size: size))
        img.unlockFocus()
        NSApplication.shared.applicationIconImage = img
    }

    private static func draw(isOn: Bool, rect: NSRect) {
        let cx = rect.midX
        let cy = rect.midY
        let r: CGFloat = min(rect.width, rect.height) * 0.36

        // Orb — amber when ON, muted gray when OFF.
        let orbPath = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r,
                                                  width: r * 2, height: r * 2))
        let grad: NSGradient
        if isOn {
            grad = NSGradient(colors: [
                NSColor(calibratedRed: 1.00, green: 0.82, blue: 0.38, alpha: 1.0),
                NSColor(calibratedRed: 1.00, green: 0.58, blue: 0.18, alpha: 1.0),
                NSColor(calibratedRed: 0.78, green: 0.30, blue: 0.08, alpha: 1.0)
            ])!
        } else {
            grad = NSGradient(colors: [
                NSColor(calibratedWhite: 0.55, alpha: 1.0),
                NSColor(calibratedWhite: 0.30, alpha: 1.0),
                NSColor(calibratedWhite: 0.18, alpha: 1.0)
            ])!
        }
        grad.draw(in: orbPath, relativeCenterPosition: NSPoint(x: -0.3, y: 0.3))

        // Morph ring.
        let ringPath = NSBezierPath()
        let lobes: CGFloat = 5
        let amp: CGFloat = 7
        let steps = 180
        for i in 0...steps {
            let theta = CGFloat(i) / CGFloat(steps) * .pi * 2
            let wobble = sin(theta * lobes) * amp
            let rr = r + wobble + 3
            let x = cx + cos(theta) * rr
            let y = cy + sin(theta) * rr
            if i == 0 { ringPath.move(to: NSPoint(x: x, y: y)) }
            else { ringPath.line(to: NSPoint(x: x, y: y)) }
        }
        ringPath.close()
        (isOn
            ? NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.45, alpha: 0.32)
            : NSColor(calibratedWhite: 0.8, alpha: 0.20)
        ).setStroke()
        ringPath.lineWidth = 1.5
        ringPath.stroke()

        // Specular highlight.
        NSColor(calibratedWhite: 1.0, alpha: 0.32).setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - r * 0.35, y: cy + r * 0.15,
                                    width: r * 0.55, height: r * 0.35)).fill()
    }
}
