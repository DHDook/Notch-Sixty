import SwiftUI

struct MeterScaleView: View {
    let height: CGFloat

    var body: some View {
        // Match PeakMeter structure: VStack(spacing: 4) with content + label
        VStack(spacing: 4) {
            Canvas { context, size in
                for db in MeterConstants.standardTickValues {
                    let position = MeterConstants.normalizedPosition(for: db)
                    let y = size.height * (1 - CGFloat(position))

                    // Draw tick mark
                    let tickWidth: CGFloat = db == 0 ? 6 : 4
                    let tickRect = CGRect(
                        x: size.width - tickWidth,
                        y: y - 0.5,
                        width: tickWidth,
                        height: 1
                    )
                    context.fill(Path(tickRect), with: .color(.gray.opacity(0.6)))

                    // Draw label with appropriate anchor to avoid clipping
                    let label = db == 0 ? "0" : String(format: "%.0f", db)
                    let text = Text(label)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)

                    // Use different anchors for top/bottom to keep text in bounds
                    let anchor: UnitPoint
                    if db == 0 {
                        anchor = .topTrailing  // Top label: text below tick
                    } else if db == -36 {
                        anchor = .bottomTrailing  // Bottom label: text above tick
                    } else {
                        anchor = .trailing  // Middle labels: centered on tick
                    }

                    context.draw(
                        context.resolve(text),
                        at: CGPoint(x: size.width - tickWidth - 3, y: y),
                        anchor: anchor
                    )
                }
            }
            .frame(width: 32, height: height)

            // Match channel label height from PeakMeter
            Text(" ")
                .font(.caption2)
                .foregroundStyle(.clear)
        }
    }
}

/// Horizontal, mirrored dB scale for the new meter layout.
/// Draws a single scale spanning the full row width (barLength × 2 + labelColumnWidth).
/// The scale is mirrored: 0 dB at the outer edges, -60 dB at the center (next to label column).
struct MirroredMeterScaleView: View {
    let barLength: CGFloat
    let labelColumnWidth: CGFloat
    private let canvasHeight: CGFloat = 14
    private let edgeInset: CGFloat = 6
    private let minLabelSpacing: CGFloat = 5   // just under the tightest validated gap (6px)

    var body: some View {
        let totalWidth = barLength * 2 + labelColumnWidth
        Canvas { context, size in
            var lastLeftLabelX: CGFloat?
            var lastRightLabelX: CGFloat?

            for db in MeterConstants.standardTickValues {
                let position = MeterConstants.normalizedPosition(for: db)
                let usable = barLength - edgeInset
                let leftX = edgeInset + usable * (1 - CGFloat(position))
                let rightX = (barLength + labelColumnWidth) + usable * CGFloat(position)

                // Tick marks always draw.
                let tickWidth: CGFloat = 4
                context.fill(Path(CGRect(x: leftX - tickWidth / 2, y: 0, width: tickWidth, height: 3)),
                             with: .color(.gray.opacity(0.6)))
                context.fill(Path(CGRect(x: rightX - tickWidth / 2, y: 0, width: tickWidth, height: 3)),
                             with: .color(.gray.opacity(0.6)))

                // Labels drop the sign — the shared "-dBFS" label covers that.
                let label = String(format: "%.0f", abs(db))
                let text = context.resolve(
                    Text(label)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                )

                if lastLeftLabelX == nil || abs(leftX - lastLeftLabelX!) >= minLabelSpacing {
                    context.draw(text, at: CGPoint(x: leftX, y: 4), anchor: .top)
                    lastLeftLabelX = leftX
                }
                if lastRightLabelX == nil || abs(rightX - lastRightLabelX!) >= minLabelSpacing {
                    context.draw(text, at: CGPoint(x: rightX, y: 4), anchor: .top)
                    lastRightLabelX = rightX
                }
            }

            // Shared unit label, centered between the two halves.
            let unitText = context.resolve(
                Text("-dBFS")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            )
            context.draw(unitText, at: CGPoint(x: barLength + labelColumnWidth / 2, y: 4), anchor: .top)
        }
        .frame(width: totalWidth, height: canvasHeight)
    }
}
