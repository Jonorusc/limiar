import AppKit
import SwiftUI

/// Battery glyph for the menu bar, filled to the current level in the MagSafe LED colour,
/// with the percentage drawn inside the battery (like iOS).
/// Drawn by hand (not an SF Symbol) because template images can't carry a fill colour.
enum MenuBarIcon {
    private static let height: CGFloat = 18

    static func image(soc: Int, tint: StatusTint, showPercentage: Bool, dark: Bool) -> NSImage {
        let base: NSColor = dark ? .white : .black
        // A wider body when it has to fit the number.
        let bodySize = showPercentage ? CGSize(width: 31, height: 14) : CGSize(width: 24, height: 12)
        let size = CGSize(width: bodySize.width + 3.5, height: height)
        let level = CGFloat(max(0, min(100, soc))) / 100
        let fillColor = fillColor(tint: tint, soc: soc, base: base)

        let image = NSImage(size: size, flipped: false) { _ in
            let body = CGRect(x: 0.5, y: (height - bodySize.height) / 2, width: bodySize.width, height: bodySize.height)
            let radius: CGFloat = showPercentage ? 4.5 : 3.5

            // Translucent body + outline, like the system battery.
            base.withAlphaComponent(showPercentage ? 0.22 : 0).setFill()
            NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius).fill()
            let outline = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
            outline.lineWidth = 1
            base.withAlphaComponent(0.4).setStroke()
            outline.stroke()

            let nub = CGRect(x: body.maxX + 1, y: body.midY - 2.25, width: 1.75, height: 4.5)
            base.withAlphaComponent(0.4).setFill()
            NSBezierPath(roundedRect: nub, xRadius: 0.9, yRadius: 0.9).fill()

            // Level fill.
            let inner = showPercentage ? body.insetBy(dx: 1.5, dy: 1.5) : body.insetBy(dx: 2, dy: 2)
            let fill = CGRect(x: inner.minX, y: inner.minY, width: max(2, inner.width * level), height: inner.height)
            fillColor.setFill()
            NSBezierPath(roundedRect: fill, xRadius: radius - 1.5, yRadius: radius - 1.5).fill()

            if showPercentage {
                drawNumber(soc, in: body, fill: fill, tint: tint, base: base, dark: dark)
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "\(soc)%"
        return image
    }

    /// One colour for the whole number: contrast with the fill once it covers the middle of the
    /// battery (where the digits sit), otherwise the menu bar text colour.
    private static func drawNumber(_ soc: Int, in body: CGRect, fill: CGRect, tint: StatusTint, base: NSColor, dark: Bool) {
        let text = "\(soc)" as NSString
        let fontSize: CGFloat = soc >= 100 ? 9 : 10.5
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        let measure = text.size(withAttributes: [.font: font])
        let origin = CGPoint(x: body.midX - measure.width / 2, y: body.midY - measure.height / 2 + 0.5)

        let overFill = fill.maxX >= body.midX
        let color: NSColor
        if !overFill {
            color = base
        } else if tint == .neutral {
            color = dark ? .black : .white
        } else {
            color = NSColor.black.withAlphaComponent(0.85)
        }
        text.draw(at: origin, withAttributes: [.font: font, .foregroundColor: color])
    }

    private static func fillColor(tint: StatusTint, soc: Int, base: NSColor) -> NSColor {
        switch tint {
        case .charging: .systemOrange
        case .holding: .systemGreen
        case .neutral: soc <= 10 ? .systemRed : base.withAlphaComponent(0.72)
        }
    }
}

/// SwiftUI label for `MenuBarExtra`; re-renders when the menu bar switches light/dark.
struct MenuBarLabel: View {
    let display: DisplayState
    @AppStorage("showPercentage") private var showPercentage = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: MenuBarIcon.image(soc: display.soc, tint: display.tint,
                                         showPercentage: showPercentage, dark: colorScheme == .dark))
            .accessibilityLabel(Text("Battery \(display.soc)%, \(display.title)"))
    }
}
