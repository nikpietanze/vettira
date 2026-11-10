import AppKit
import VettiraCore

/// Draws a `PriceChart`: its lines in system green when the price is up on the day and red when
/// it's down, the previous close as a faint dashed line. Where the points go is the chart's to
/// say; this only strokes them. The images draw when shown, not once, so their colours follow the
/// light or dark menu bar and popover they're in.
enum PriceChartImage {
    /// The chart's size in the menu bar and the popover, in points.
    static let size = NSSize(width: 40, height: 16)
    private static let inset: CGFloat = 1.5

    /// The chart on its own, for a popover row.
    static func image(_ chart: PriceChart) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(chart, in: rect)
            return true
        }
        image.cacheMode = .never
        image.accessibilityDescription = chart.description
        return image
    }

    /// The status icon, then the chart, for the menu-bar button. The icon is drawn in the label
    /// colour, as a template image would be.
    static func menuBar(icon: NSImage, chart: PriceChart) -> NSImage {
        let gap: CGFloat = 4
        let total = NSSize(width: icon.size.width + gap + size.width, height: max(icon.size.height, size.height))
        let image = NSImage(size: total, flipped: false) { rect in
            let iconRect = NSRect(
                x: 0, y: (rect.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height)
            icon.draw(in: iconRect)
            NSColor.labelColor.set()
            iconRect.fill(using: .sourceAtop)
            draw(chart, in: NSRect(
                x: iconRect.maxX + gap, y: (rect.height - size.height) / 2, width: size.width, height: size.height))
            return true
        }
        image.cacheMode = .never
        image.accessibilityDescription = chart.description
        return image
    }

    private static func draw(_ chart: PriceChart, in rect: NSRect) {
        if let y = chart.previousCloseY(height: rect.height, inset: inset) {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: rect.minX, y: rect.minY + y))
            line.line(to: NSPoint(x: rect.maxX, y: rect.minY + y))
            line.lineWidth = 1
            line.setLineDash([1.5, 1.5], count: 2, phase: 0)
            NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke()
            line.stroke()
        }
        let color: NSColor = switch chart.direction {
        case .up: .systemGreen
        case .down: .systemRed
        case .flat, .unknown: .labelColor
        }
        color.setStroke()
        color.setFill()
        for segment in chart.lines(width: rect.width, height: rect.height, inset: inset) {
            let points = segment.map { NSPoint(x: rect.minX + $0.x, y: rect.minY + $0.y) }
            guard let first = points.first else { continue }
            if points.count == 1 {
                // A price on its own between two gaps: a dot.
                NSBezierPath(ovalIn: NSRect(x: first.x - 0.75, y: first.y - 0.75, width: 1.5, height: 1.5)).fill()
                continue
            }
            let path = NSBezierPath()
            path.move(to: first)
            points.dropFirst().forEach(path.line(to:))
            path.lineWidth = 1.25
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.stroke()
        }
    }
}
