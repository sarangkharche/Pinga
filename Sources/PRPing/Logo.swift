import AppKit

// One vector mark for the menu bar and app icon: a pull request with a ping dot.
enum PRPingLogo {
    static func image(size: CGFloat = 18, appIcon: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let context = NSGraphicsContext.current!.cgContext
            if appIcon {
                NSColor(calibratedRed: 0.065, green: 0.078, blue: 0.09, alpha: 1).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.05, dy: size * 0.05), xRadius: size * 0.20, yRadius: size * 0.20).fill()
                context.translateBy(x: size * 0.18, y: size * 0.18)
                context.scaleBy(x: size * 0.64 / 18, y: size * 0.64 / 18)
                NSColor.white.setStroke()
                NSColor.white.setFill()
            } else {
                context.scaleBy(x: size / 18, y: size / 18)
                NSColor.labelColor.setStroke()
                NSColor.labelColor.setFill()
            }
            let branch = NSBezierPath()
            branch.lineWidth = 1.45
            branch.lineCapStyle = .round
            branch.lineJoinStyle = .round
            branch.move(to: NSPoint(x: 4, y: 5))
            branch.line(to: NSPoint(x: 4, y: 13))
            branch.move(to: NSPoint(x: 12, y: 5))
            branch.line(to: NSPoint(x: 12, y: 9))
            branch.curve(to: NSPoint(x: 8.5, y: 13), controlPoint1: NSPoint(x: 12, y: 12), controlPoint2: NSPoint(x: 11, y: 13))
            branch.stroke()
            for point in [NSPoint(x: 4, y: 3), NSPoint(x: 4, y: 15), NSPoint(x: 12, y: 3)] {
                let circle = NSBezierPath(ovalIn: NSRect(x: point.x - 1.7, y: point.y - 1.7, width: 3.4, height: 3.4))
                circle.lineWidth = 1.35
                circle.stroke()
            }
            if appIcon { NSColor(calibratedRed: 0.40, green: 0.91, blue: 0.76, alpha: 1).setFill() }
            NSBezierPath(ovalIn: NSRect(x: 13.5, y: 13.5, width: 3, height: 3)).fill()
            return true
        }
        image.isTemplate = !appIcon
        return image
    }
}
