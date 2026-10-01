import AppKit

/// The approved version 03 template, drawn at native resolution so state transitions stay smooth on any display.
@MainActor
enum EyeIcon {
    static func image(pose: EyePose) -> NSImage {
        let template = pose.red + pose.green < 0.00001
        let body = bodyPath, crown = crownPath, eye = eyePath
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let color: NSColor
            if template {
                color = .black
            } else {
                let neutral = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .black
                let weight = max(0, 1 - pose.red - pose.green)
                color = NSColor(srgbRed: neutral.redComponent * weight + 0.86 * pose.red + 0.36 * pose.green,
                                green: neutral.greenComponent * weight + 0.36 * pose.red + 0.70 * pose.green,
                                blue: neutral.blueComponent * weight + 0.34 * pose.red + 0.45 * pose.green, alpha: 1)
            }
            context.saveGState()
            context.translateBy(x: 1.6875, y: 3.1875)
            context.scaleBy(x: 0.8125, y: 0.8125)
            context.setFillColor(color.cgColor)
            context.addPath(body)
            context.fillPath()

            // Cut out the opening, then clip the fixed-size pupil to it. Only the lids move during a blink.
            if pose.open > 0 {
                var transform = CGAffineTransform(translationX: 0, y: 10.5)
                    .scaledBy(x: 1, y: pose.open).translatedBy(x: 0, y: -10.5)
                let opening = eye.copy(using: &transform)!
                context.setBlendMode(.clear)
                context.addPath(opening)
                context.fillPath()
                context.setBlendMode(.normal)
                context.saveGState()
                context.addPath(opening)
                context.clip()
                context.fillEllipse(in: CGRect(x: pose.pupilX - 1.6, y: 6.9, width: 3.2, height: 4.6))
                context.restoreGState()
            }
            let slit = (1 - EyeMotion.ease(pose.open / 0.14)) * pose.lidLine
            if slit > 0 {
                context.setBlendMode(.destinationOut)
                context.setStrokeColor(NSColor.black.withAlphaComponent(slit).cgColor)
                context.setLineWidth(0.65)
                context.setLineCap(.round)
                context.move(to: CGPoint(x: 3.6, y: 10.5))
                context.addQuadCurve(to: CGPoint(x: 14.4, y: 10.3), control: CGPoint(x: 9, y: 11))
                context.strokePath()
            }
            context.restoreGState()
            context.setFillColor(color.cgColor)
            context.addPath(crown)
            context.fillPath()
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = "Side Eye"
        return image
    }

    private static let bodyPath: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 9, y: 1))
        p.addCurve(to: CGPoint(x: 17, y: 9), control1: CGPoint(x: 15.8, y: 1), control2: CGPoint(x: 17, y: 2.2))
        p.addCurve(to: CGPoint(x: 9, y: 17), control1: CGPoint(x: 17, y: 15.8), control2: CGPoint(x: 15.8, y: 17))
        p.addCurve(to: CGPoint(x: 1, y: 9), control1: CGPoint(x: 2.2, y: 17), control2: CGPoint(x: 1, y: 15.8))
        p.addCurve(to: CGPoint(x: 9, y: 1), control1: CGPoint(x: 1, y: 2.2), control2: CGPoint(x: 2.2, y: 1))
        p.closeSubpath()
        return p
    }()

    private static let eyePath: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 3.1, y: 8.4))
        p.addLine(to: CGPoint(x: 14.9, y: 7.2))
        p.addCurve(to: CGPoint(x: 9, y: 13.1), control1: CGPoint(x: 14.9, y: 11.4), control2: CGPoint(x: 12.6, y: 13.1))
        p.addCurve(to: CGPoint(x: 3.1, y: 8.4), control1: CGPoint(x: 5.9, y: 13.1), control2: CGPoint(x: 3.7, y: 11.6))
        p.closeSubpath()
        return p
    }()

    private static let crownPath: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 8.3, y: 4.5))
        p.addCurve(to: CGPoint(x: 10, y: 0.7), control1: CGPoint(x: 8.1, y: 2.8), control2: CGPoint(x: 8.7, y: 1.3))
        p.addCurve(to: CGPoint(x: 10.5, y: 1.7), control1: CGPoint(x: 10.7, y: 0.4), control2: CGPoint(x: 11.1, y: 1.2))
        p.addCurve(to: CGPoint(x: 9.6, y: 4.5), control1: CGPoint(x: 9.6, y: 2.5), control2: CGPoint(x: 9.5, y: 3.4))
        p.addCurve(to: CGPoint(x: 14, y: 2.5), control1: CGPoint(x: 11, y: 2.8), control2: CGPoint(x: 12.8, y: 2.5))
        p.addCurve(to: CGPoint(x: 10.1, y: 5.5), control1: CGPoint(x: 13.5, y: 4), control2: CGPoint(x: 12.2, y: 5.1))
        p.addLine(to: CGPoint(x: 9, y: 6.4))
        p.addLine(to: CGPoint(x: 7.9, y: 5.5))
        p.addCurve(to: CGPoint(x: 4, y: 2.5), control1: CGPoint(x: 5.8, y: 5.1), control2: CGPoint(x: 4.5, y: 4))
        p.addCurve(to: CGPoint(x: 8.3, y: 4.5), control1: CGPoint(x: 5.5, y: 2.5), control2: CGPoint(x: 7, y: 3.1))
        p.closeSubpath()
        return p
    }()
}
