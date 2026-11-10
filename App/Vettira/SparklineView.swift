import SwiftUI
import VettiraCore

/// A dashboard row's small chart of the day: the `PriceChart`'s line in system green when the
/// price is up on the day and red when it's down, over the previous close as a faint dotted line.
/// The points are the chart's; this only strokes them, flipped so up is up.
struct SparklineView: View {
    let chart: PriceChart
    static let size = CGSize(width: 64, height: 20)

    var body: some View {
        let color = Color.direction(chart.direction)
        Canvas { context, size in
            let inset = 1.5
            if let y = chart.previousCloseY(height: size.height, inset: inset) {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: size.height - y))
                line.addLine(to: CGPoint(x: size.width, y: size.height - y))
                context.stroke(line, with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [1.5, 2]))
            }
            for segment in chart.lines(width: size.width, height: size.height, inset: inset) {
                let points = segment.map { CGPoint(x: $0.x, y: size.height - $0.y) }
                guard let first = points.first else { continue }
                if points.count == 1 {
                    // A price on its own between two gaps: a dot.
                    context.fill(Path(ellipseIn: CGRect(x: first.x - 1, y: first.y - 1, width: 2, height: 2)), with: .color(color))
                    continue
                }
                var path = Path()
                path.addLines(points)
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityElement()
        .accessibilityLabel(chart.description)
        .help(chart.description)
    }
}
