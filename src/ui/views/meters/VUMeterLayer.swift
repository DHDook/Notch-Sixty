import AppKit
import QuartzCore

/// GPU-accelerated VU meter view using Core Animation layers.
/// Implements MeterObserver for direct updates from MeterStore, bypassing SwiftUI.
/// Draws a semicircular arc gauge face with needle and overload indicator.
final class VUMeterLayer: NSView, MeterObserver {
    // MARK: - Sublayers

    private let backgroundLayer = CAShapeLayer()
    private let faceLayer = CAShapeLayer()
    private let faceGradientLayer = CAGradientLayer()
    private let tickLayer = CAShapeLayer()
    private let majorTickLayer = CAShapeLayer()
    private let redTickLayer = CAShapeLayer()
    private let needleLayer = CAShapeLayer()
    private let pivotLayer = CAShapeLayer()
    private let clipLayer = CAShapeLayer()
    private let labelLayer = CATextLayer()

    private var tickLabelValues: [Float] = [0, -12, -24, -36, -48, -60]
    private var tickLabelLayers: [CATextLayer] = []

    // MARK: - Colors

    private var faceColor = NSColor(hex: "#161412")
    private var needleColor = NSColor(hex: "#D9541F")
    private var tickColor = NSColor(hex: "#EDEAE2")
    private var redTickColor = NSColor(hex: "#A32D2D")

    // MARK: - Constants

    // 60° sweep, flatter and wider (was 140° sweep at 160°/20°)
    private let arcStartAngle: CGFloat = .pi * (120.0 / 180.0)  // 120° — up-left
    private let arcEndAngle: CGFloat   = .pi * (60.0 / 180.0)   // 60°  — up-right
    private let arcClockwise: Bool = true  // Clockwise for proper arc direction
    private let needleLength: CGFloat = 0.85  // As fraction of radius
    private let pivotRadius: CGFloat = 4

    // MARK: - State

    private var currentNeedleValue: Float = 0
    private var isCurrentlyClipping: Bool = false
    private var isSetupComplete = false
    private var channelLabel: String = ""

    // MARK: - Initialization

    init(channelLabel: String = "") {
        self.channelLabel = channelLabel
        super.init(frame: .zero)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        self.channelLabel = ""
        super.init(coder: coder)
        setupLayers()
    }

    // MARK: - Setup

    private func setupLayers() {
        wantsLayer = true
        guard let layer = self.layer else { return }

        // Background layer (semicircular face)
        backgroundLayer.fillColor = faceColor.cgColor
        layer.addSublayer(backgroundLayer)

        // Face gradient layer (subtle vignette)
        faceGradientLayer.colors = [
            NSColor.black.withAlphaComponent(0.12).cgColor,
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.08).cgColor
        ]
        faceGradientLayer.locations = [0, 0.5, 1]
        faceGradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        faceGradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(faceGradientLayer)

        // Face layer (border)
        faceLayer.fillColor = nil
        faceLayer.strokeColor = tickColor.cgColor
        faceLayer.lineWidth = 2
        layer.addSublayer(faceLayer)

        // Tick marks layer
        tickLayer.fillColor = nil
        tickLayer.strokeColor = tickColor.cgColor
        tickLayer.lineWidth = 1
        layer.addSublayer(tickLayer)

        // Major tick marks layer (for labeled ticks)
        majorTickLayer.fillColor = nil
        majorTickLayer.strokeColor = tickColor.cgColor
        majorTickLayer.lineWidth = 1.5
        layer.addSublayer(majorTickLayer)

        // Red tick marks layer (for top 15-20%)
        redTickLayer.fillColor = nil
        redTickLayer.strokeColor = redTickColor.cgColor
        redTickLayer.lineWidth = 1
        layer.addSublayer(redTickLayer)

        // Needle layer
        needleLayer.fillColor = nil
        needleLayer.strokeColor = needleColor.cgColor
        needleLayer.lineWidth = 2
        needleLayer.lineCap = .round
        needleLayer.shadowColor = NSColor.black.cgColor
        needleLayer.shadowOpacity = 0.35
        needleLayer.shadowRadius = 1.5
        needleLayer.shadowOffset = CGSize(width: 0, height: -1)
        layer.addSublayer(needleLayer)

        // Pivot layer (center dot)
        pivotLayer.fillColor = needleColor.cgColor
        layer.addSublayer(pivotLayer)

        // Clip indicator (red dot at 0 dB)
        clipLayer.fillColor = NSColor.red.cgColor
        clipLayer.isHidden = true
        layer.addSublayer(clipLayer)

        // Channel label
        labelLayer.string = channelLabel
        labelLayer.fontSize = 10
        labelLayer.alignmentMode = .center
        labelLayer.foregroundColor = tickColor.cgColor
        labelLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.addSublayer(labelLayer)

        // Tick label layers
        tickLabelLayers = tickLabelValues.map { _ in
            let layer = CATextLayer()
            layer.fontSize = 6
            layer.alignmentMode = .center
            layer.foregroundColor = tickColor.cgColor
            layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            self.layer?.addSublayer(layer)
            return layer
        }

        self.layer?.masksToBounds = true
        isSetupComplete = true
        updateColorsForAppearance()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let bounds = self.bounds

        // Card face (replaces the semicircular dome)
        let cardRect = bounds.insetBy(dx: 2, dy: 2)
        let cardPath = CGPath(roundedRect: cardRect, cornerWidth: 2, cornerHeight: 2, transform: nil)

        // Pivot positioned below frame for vintage VU meter appearance
        let center = CGPoint(x: cardRect.midX, y: cardRect.minY - 75)
        let radius = cardRect.width * 0.92

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Card face background
        backgroundLayer.path = cardPath

        // Card face border
        faceLayer.path = cardPath

        // Face gradient layer
        faceGradientLayer.frame = cardRect
        let gradientMask = CAShapeLayer()
        gradientMask.path = cardPath
        faceGradientLayer.mask = gradientMask

        // Tick marks
        let tickPath = CGMutablePath()
        let majorTickPath = CGMutablePath()
        let redTickPath = CGMutablePath()
        for dbValue in MeterConstants.standardTickValues {
            let normalized = MeterConstants.normalizedPosition(for: dbValue)
            let angle = arcStartAngle + (arcEndAngle - arcStartAngle) * CGFloat(normalized)

            // Determine tick color based on position (red for top 15-20%)
            let isRedZone = normalized > 0.8

            let innerRadius = radius * 0.85
            let outerRadius = radius * 0.95

            let startPoint = CGPoint(
                x: center.x + innerRadius * cos(angle),
                y: center.y + innerRadius * sin(angle)
            )
            let endPoint = CGPoint(
                x: center.x + outerRadius * cos(angle),
                y: center.y + outerRadius * sin(angle)
            )

            if isRedZone {
                redTickPath.move(to: startPoint)
                redTickPath.addLine(to: endPoint)
            } else if tickLabelValues.contains(dbValue) {
                majorTickPath.move(to: startPoint)
                majorTickPath.addLine(to: endPoint)
            } else {
                tickPath.move(to: startPoint)
                tickPath.addLine(to: endPoint)
            }
        }
        tickLayer.path = tickPath
        majorTickLayer.path = majorTickPath
        redTickLayer.path = redTickPath

        // Tick labels
        for (i, value) in tickLabelValues.enumerated() {
            let normalized = MeterConstants.normalizedPosition(for: value)
            let angle = arcStartAngle + (arcEndAngle - arcStartAngle) * CGFloat(normalized)
            let labelRadius = radius * 0.97
            let point = CGPoint(x: center.x + labelRadius * cos(angle),
                                 y: center.y + labelRadius * sin(angle))
            let label = tickLabelLayers[i]
            label.string = value == 0 ? "0" : "\(Int(value))"
            label.frame = CGRect(x: point.x - 10, y: point.y - 4, width: 20, height: 8)
        }

        // Needle
        let needlePath = CGMutablePath()
        let needleEndAngle = arcStartAngle + (arcEndAngle - arcStartAngle) * CGFloat(currentNeedleValue)
        let needleEnd = CGPoint(
            x: center.x + radius * needleLength * cos(needleEndAngle),
            y: center.y + radius * needleLength * sin(needleEndAngle)
        )
        needlePath.move(to: center)
        needlePath.addLine(to: needleEnd)
        needleLayer.path = needlePath

        // Pivot dot
        let pivotPath = CGMutablePath()
        pivotPath.addEllipse(in: CGRect(
            x: center.x - pivotRadius,
            y: center.y - pivotRadius,
            width: pivotRadius * 2,
            height: pivotRadius * 2
        ))
        pivotLayer.path = pivotPath

        // Clip indicator at 0 dB position
        let zeroDbAngle = arcEndAngle
        let clipRadius = radius * 0.92
        let clipCenter = CGPoint(
            x: center.x + clipRadius * cos(zeroDbAngle),
            y: center.y + clipRadius * sin(zeroDbAngle)
        )
        let clipPath = CGMutablePath()
        clipPath.addEllipse(in: CGRect(
            x: clipCenter.x - 3,
            y: clipCenter.y - 3,
            width: 6,
            height: 6
        ))
        clipLayer.path = clipPath

        // Channel label position - inside the card, near the bottom
        labelLayer.position = CGPoint(x: cardRect.midX, y: cardRect.minY + cardRect.height * 0.92)

        CATransaction.commit()
    }

    // MARK: - MeterObserver Protocol

    func meterUpdated(value: Float, hold: Float, clipping: Bool) {
        let newValue = max(0, min(1, value))
        currentNeedleValue = newValue
        isCurrentlyClipping = clipping

        CATransaction.begin()
        CATransaction.setAnimationDuration(1.0 / 30.0) // Smooth animation

        updateNeedlePosition()
        updateClipIndicator()

        CATransaction.commit()
    }

    // MARK: - Private Updates

    private func updateNeedlePosition() {
        guard isSetupComplete else { return }

        let bounds = self.bounds
        let cardRect = bounds.insetBy(dx: 2, dy: 2)
        let center = CGPoint(x: cardRect.midX, y: cardRect.minY - 75)
        let radius = cardRect.width * 0.92

        let angle = arcStartAngle + (arcEndAngle - arcStartAngle) * CGFloat(currentNeedleValue)
        let needleEnd = CGPoint(
            x: center.x + radius * needleLength * cos(angle),
            y: center.y + radius * needleLength * sin(angle)
        )

        let needlePath = CGMutablePath()
        needlePath.move(to: center)
        needlePath.addLine(to: needleEnd)
        needleLayer.path = needlePath
    }

    private func updateClipIndicator() {
        clipLayer.isHidden = !isCurrentlyClipping
    }

    // MARK: - Appearance

    private func updateColorsForAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        if isDark {
            faceColor = NSColor(hex: "#161412")
            tickColor = NSColor(hex: "#EDEAE2")
        } else {
            faceColor = NSColor(hex: "#FAF6EE")
            tickColor = NSColor(hex: "#3A2E1F")
        }
        // needleColor and redTickColor stay the same in both modes

        guard isSetupComplete else { return }
        backgroundLayer.fillColor = faceColor.cgColor
        faceLayer.strokeColor = tickColor.cgColor
        tickLayer.strokeColor = tickColor.cgColor
        majorTickLayer.strokeColor = tickColor.cgColor
        needleLayer.strokeColor = needleColor.cgColor
        pivotLayer.fillColor = needleColor.cgColor
        labelLayer.foregroundColor = tickColor.cgColor
        tickLabelLayers.forEach { $0.foregroundColor = tickColor.cgColor }

        // Update face gradient colors for appearance
        faceGradientLayer.colors = [
            NSColor.black.withAlphaComponent(0.12).cgColor,
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.08).cgColor
        ]
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColorsForAppearance()
    }
}

// MARK: - Color Extension

private extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}
