import AppKit
import QuartzCore

/// GPU-accelerated VU meter view using Core Animation layers.
/// Implements MeterObserver for direct updates from MeterStore, bypassing SwiftUI.
/// Draws a semicircular arc gauge face with needle and overload indicator.
final class VUMeterLayer: NSView, MeterObserver {
    // MARK: - Sublayers

    private let backgroundLayer = CAShapeLayer()
    private let faceLayer = CAShapeLayer()
    private let tickLayer = CAShapeLayer()
    private let redTickLayer = CAShapeLayer()
    private let needleLayer = CAShapeLayer()
    private let pivotLayer = CAShapeLayer()
    private let clipLayer = CAShapeLayer()
    private let labelLayer = CATextLayer()

    // MARK: - Colors

    private let lightFaceColor = NSColor(hex: "#FAF6EE")
    private let darkFaceColor = NSColor(hex: "#2B2014")
    private let lightNeedleColor = NSColor(hex: "#412402")
    private let darkNeedleColor = NSColor(hex: "#E8A84A")
    private let lightTickColor = NSColor(hex: "#412402")
    private let darkTickColor = NSColor(hex: "#E8A84A")
    private let redTickColor = NSColor(hex: "#A32D2D")
    private let darkRedTickColor = NSColor(hex: "#E24B4A")

    // MARK: - Constants

    private let arcStartAngle: CGFloat = .pi  // Left (180 degrees)
    private let arcEndAngle: CGFloat = 0      // Right (0 degrees)
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
        backgroundLayer.fillColor = lightFaceColor.cgColor
        layer.addSublayer(backgroundLayer)

        // Face layer (border)
        faceLayer.fillColor = nil
        faceLayer.strokeColor = lightTickColor.cgColor
        faceLayer.lineWidth = 2
        layer.addSublayer(faceLayer)

        // Tick marks layer
        tickLayer.fillColor = nil
        tickLayer.strokeColor = lightTickColor.cgColor
        tickLayer.lineWidth = 1
        layer.addSublayer(tickLayer)

        // Red tick marks layer (for top 15-20%)
        redTickLayer.fillColor = nil
        redTickLayer.strokeColor = redTickColor.cgColor
        redTickLayer.lineWidth = 1
        layer.addSublayer(redTickLayer)

        // Needle layer
        needleLayer.fillColor = nil
        needleLayer.strokeColor = lightNeedleColor.cgColor
        needleLayer.lineWidth = 2
        needleLayer.lineCap = .round
        layer.addSublayer(needleLayer)

        // Pivot layer (center dot)
        pivotLayer.fillColor = lightNeedleColor.cgColor
        layer.addSublayer(pivotLayer)

        // Clip indicator (red dot at 0 dB)
        clipLayer.fillColor = NSColor.red.cgColor
        clipLayer.isHidden = true
        layer.addSublayer(clipLayer)

        // Channel label
        labelLayer.string = channelLabel
        labelLayer.fontSize = 10
        labelLayer.alignmentMode = .center
        labelLayer.foregroundColor = lightTickColor.cgColor
        labelLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.addSublayer(labelLayer)

        isSetupComplete = true
        updateColors()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let bounds = self.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.height * 0.85)
        let radius = min(bounds.width, bounds.height) * 0.4

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Background semicircle
        let backgroundPath = CGMutablePath()
        backgroundPath.addArc(center: center, radius: radius, startAngle: arcStartAngle, endAngle: arcEndAngle, clockwise: false)
        backgroundLayer.path = backgroundPath

        // Face border
        faceLayer.path = backgroundPath

        // Tick marks
        let tickPath = CGMutablePath()
        let redTickPath = CGMutablePath()
        let isDark = isDarkMode
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
            } else {
                tickPath.move(to: startPoint)
                tickPath.addLine(to: endPoint)
            }
        }
        tickLayer.strokeColor = isDark ? darkTickColor.cgColor : lightTickColor.cgColor
        tickLayer.path = tickPath
        redTickLayer.strokeColor = isDark ? darkRedTickColor.cgColor : redTickColor.cgColor
        redTickLayer.path = redTickPath

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

        // Channel label position
        labelLayer.position = CGPoint(x: bounds.midX, y: bounds.height - 5)

        CATransaction.commit()
    }

    // MARK: - MeterObserver Protocol

    func meterUpdated(value: Float, hold: Float, clipping: Bool) {
        let newValue = max(0, min(1, value))
        let oldValue = currentNeedleValue
        currentNeedleValue = newValue
        isCurrentlyClipping = clipping

        CATransaction.begin()
        CATransaction.setAnimationDuration(1.0 / 30.0) // Smooth animation

        // Animate needle rotation
        let rotationAnimation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotationAnimation.fromValue = oldValue
        rotationAnimation.toValue = newValue
        rotationAnimation.duration = 1.0 / 30.0
        needleLayer.add(rotationAnimation, forKey: "needleRotation")

        updateNeedlePosition()
        updateClipIndicator()

        CATransaction.commit()
    }

    // MARK: - Private Updates

    private func updateNeedlePosition() {
        guard isSetupComplete else { return }

        let bounds = self.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.height * 0.85)
        let radius = min(bounds.width, bounds.height) * 0.4

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

    // MARK: - Color Scheme

    private var isDarkMode: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func updateColors() {
        let isDark = isDarkMode

        backgroundLayer.fillColor = isDark ? darkFaceColor.cgColor : lightFaceColor.cgColor
        faceLayer.strokeColor = isDark ? darkTickColor.cgColor : lightTickColor.cgColor
        needleLayer.strokeColor = isDark ? darkNeedleColor.cgColor : lightNeedleColor.cgColor
        pivotLayer.fillColor = isDark ? darkNeedleColor.cgColor : lightNeedleColor.cgColor
        labelLayer.foregroundColor = isDark ? darkTickColor.cgColor : lightTickColor.cgColor
        tickLayer.strokeColor = isDark ? darkTickColor.cgColor : lightTickColor.cgColor
        redTickLayer.strokeColor = isDark ? darkRedTickColor.cgColor : redTickColor.cgColor

        // Redraw tick marks with updated colors
        needsLayout = true
    }

    override func updateLayer() {
        super.updateLayer()
        updateColors()
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
