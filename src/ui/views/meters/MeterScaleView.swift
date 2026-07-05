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
    private let canvasHeight: CGFloat = 12
    private let edgeInset: CGFloat = 6
    private let minLabelSpacing: CGFloat = 5
    private let tickH: CGFloat = 6        // tick height — matches text cap height at 6pt font
    private let tickW: CGFloat = 1
    private let labelFont = Font.system(size: 6, weight: .medium, design: .monospaced)
    private let unitFont  = Font.system(size: 6, weight: .medium, design: .monospaced)

    var body: some View {
        let totalWidth = barLength * 2 + labelColumnWidth
        Canvas { context, size in
            var lastLeftLabelX:  CGFloat?
            var lastRightLabelX: CGFloat?

            // Vertical center of the canvas — tick and text both sit on this line.
            let midY = size.height / 2

            for db in MeterConstants.standardTickValues {
                let position = MeterConstants.normalizedPosition(for: db)
                let usable   = barLength - edgeInset
                let leftX    = edgeInset + usable * (1 - CGFloat(position))
                let rightX   = (barLength + labelColumnWidth) + usable * CGFloat(position)

                // Tick: a thin vertical stroke, centered vertically on midY.
                // Drawn unconditionally (even if the label is skipped by the collision guard).
                context.fill(
                    Path(CGRect(x: leftX - tickW / 2,
                                y: midY - tickH / 2,
                                width: tickW,
                                height: tickH)),
                    with: .color(.gray.opacity(0.5))
                )
                context.fill(
                    Path(CGRect(x: rightX - tickW / 2,
                                y: midY - tickH / 2,
                                width: tickW,
                                height: tickH)),
                    with: .color(.gray.opacity(0.5))
                )

                // Label: centered vertically on midY, immediately adjacent to tick.
                // Left side: label sits to the RIGHT of the tick (reads outward from center).
                // Right side: label sits to the LEFT of the tick (mirror).
                let label    = String(format: "%.0f", abs(db))
                let resolved = context.resolve(
                    Text(label).font(labelFont).foregroundStyle(.secondary)
                )

                if lastLeftLabelX == nil || abs(leftX - lastLeftLabelX!) >= minLabelSpacing {
                    context.draw(resolved,
                                 at: CGPoint(x: leftX + tickW + 1, y: midY),
                                 anchor: .leading)
                    lastLeftLabelX = leftX
                }

                if lastRightLabelX == nil || abs(rightX - lastRightLabelX!) >= minLabelSpacing {
                    context.draw(resolved,
                                 at: CGPoint(x: rightX - tickW - 1, y: midY),
                                 anchor: .trailing)
                    lastRightLabelX = rightX
                }
            }

            // "-dBFS" unit label, centered in the label column between the two halves.
            let unit = context.resolve(
                Text("-dBFS").font(unitFont).foregroundStyle(.tertiary)
            )
            context.draw(unit,
                         at: CGPoint(x: barLength + labelColumnWidth / 2, y: midY),
                         anchor: .center)
        }
        .frame(width: totalWidth, height: canvasHeight)
    }
}
