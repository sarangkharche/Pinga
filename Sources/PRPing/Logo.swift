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
            let mark = NSBezierPath()
            mark.lineWidth = 1.25
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            mark.move(to: NSPoint(x: 5, y: 2.5))
            mark.line(to: NSPoint(x: 5, y: 15.5))
            mark.line(to: NSPoint(x: 10, y: 15.5))
            mark.curve(to: NSPoint(x: 13.5, y: 12.5), controlPoint1: NSPoint(x: 12.5, y: 15.5), controlPoint2: NSPoint(x: 13.5, y: 14.5))
            mark.line(to: NSPoint(x: 13.5, y: 10.5))
            mark.curve(to: NSPoint(x: 10, y: 7.5), controlPoint1: NSPoint(x: 13.5, y: 8.5), controlPoint2: NSPoint(x: 12.5, y: 7.5))
            mark.line(to: NSPoint(x: 5, y: 7.5))
            mark.stroke()
            return true
        }
        image.isTemplate = !appIcon
        return image
    }
}
