import AppKit
import QuartzCore

/// GPU-accelerated peak meter view using Core Animation layers.
/// Implements MeterObserver for direct updates from MeterStore, bypassing SwiftUI.
final class PeakMeterLayer: NSView, MeterObserver {
    // MARK: - Sublayers

    private let backgroundLayer = CALayer()
    private let fillLayer = CAGradientLayer()
    private let fillMaskLayer = CALayer()
    private let peakHoldLayer = CALayer()
    private let clipLayer = CALayer()
    private let borderLayer = CAShapeLayer()

    // MARK: - Gradient Colors (matching current SwiftUI meters)

    private let gradientColors: [CGColor] = [
        NSColor(red: 0.0, green: 0.45, blue: 0.95, alpha: 1.0).cgColor,  // Blue
        NSColor(red: 0.0, green: 0.8, blue: 0.0, alpha: 1.0).cgColor,   // Green
        NSColor(red: 1.0, green: 1.0, blue: 0.0, alpha: 1.0).cgColor,   // Yellow
        NSColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0).cgColor,   // Red
    ]

    private let gradientLocations: [NSNumber] = [0.0, 0.3, 0.6, 1.0]

    // MARK: - State

    var orientation: MeterOrientation = .vertical
    private var currentPeak: Float = 0
    private var currentPeakHold: Float = 0
    private var isCurrentlyClipping: Bool = false
    private var isSetupComplete = false

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    // MARK: - Setup

    private func setupLayers() {
        wantsLayer = true
        guard let layer = self.layer else { return }

        // Background layer (gray rounded rect)
        backgroundLayer.backgroundColor = NSColor.gray.withAlphaComponent(0.18).cgColor
        backgroundLayer.cornerRadius = 4
        backgroundLayer.masksToBounds = true
        layer.addSublayer(backgroundLayer)

        // Fill gradient layer
        fillLayer.colors = gradientColors
        fillLayer.locations = gradientLocations
        fillLayer.cornerRadius = 3

        // Fill mask - use a solid color layer that we scale via transform
        fillMaskLayer.backgroundColor = NSColor.white.cgColor
        fillLayer.mask = fillMaskLayer
        layer.addSublayer(fillLayer)

        // Peak hold line (white, 2pt height for vertical, 2pt width for horizontal)
        peakHoldLayer.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        peakHoldLayer.cornerRadius = 1
        layer.addSublayer(peakHoldLayer)

        // Clip indicator (circular LED-style dot)
        clipLayer.backgroundColor = NSColor.red.cgColor
        clipLayer.cornerRadius = 4  // 8pt diameter circle
        clipLayer.borderWidth = 1
        clipLayer.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        clipLayer.isHidden = true
        layer.addSublayer(clipLayer)

        // Border layer
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.gray.withAlphaComponent(0.4).cgColor
        borderLayer.lineWidth = 1
        layer.addSublayer(borderLayer)

        isSetupComplete = true
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let bounds = self.bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Reset transform before frame calculations to avoid interaction issues
        fillMaskLayer.transform = CATransform3DIdentity

        // Background fills entire bounds
        backgroundLayer.frame = bounds

        // Fill layer fills entire bounds
        fillLayer.frame = bounds

        // Configure orientation-specific properties
        switch orientation {
        case .vertical:
            // Fill mask - anchor at bottom center
            fillMaskLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
            fillMaskLayer.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
            fillMaskLayer.position = CGPoint(x: bounds.midX, y: 0)
            // Gradient: bottom to top
            fillLayer.startPoint = CGPoint(x: 0.5, y: 0)
            fillLayer.endPoint = CGPoint(x: 0.5, y: 1)

        case .horizontalGrowingLeft:
            // Fill mask - anchor at trailing (right) edge
            fillMaskLayer.anchorPoint = CGPoint(x: 1.0, y: 0.5)
            fillMaskLayer.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
            fillMaskLayer.position = CGPoint(x: bounds.width, y: bounds.midY)
            // Gradient: right to left
            fillLayer.startPoint = CGPoint(x: 1, y: 0.5)
            fillLayer.endPoint = CGPoint(x: 0, y: 0.5)

        case .horizontalGrowingRight:
            // Fill mask - anchor at leading (left) edge
            fillMaskLayer.anchorPoint = CGPoint(x: 0.0, y: 0.5)
            fillMaskLayer.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
            fillMaskLayer.position = CGPoint(x: 0, y: bounds.midY)
            // Gradient: left to right
            fillLayer.startPoint = CGPoint(x: 0, y: 0.5)
            fillLayer.endPoint = CGPoint(x: 1, y: 0.5)
        }

        // Peak hold line
        switch orientation {
        case .vertical:
            // Horizontal line, 2pt height, positioned by Y
            peakHoldLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 2)

        case .horizontalGrowingLeft, .horizontalGrowingRight:
            // Vertical line, 2pt width, positioned by X
            peakHoldLayer.frame = CGRect(x: 0, y: 0, width: 2, height: bounds.height)
        }

        // Clip indicator (8pt diameter circle)
        let clipDiameter: CGFloat = 8
        let clipRadius = clipDiameter / 2
        let clipMargin: CGFloat = 2  // Margin from outer edge

        switch orientation {
        case .vertical:
            // Centered horizontally, near top
            clipLayer.frame = CGRect(
                x: bounds.midX - clipRadius,
                y: bounds.height - clipMargin - clipDiameter,
                width: clipDiameter,
                height: clipDiameter
            )

        case .horizontalGrowingLeft:
            // Near left (outer) edge, vertically centered
            clipLayer.frame = CGRect(
                x: clipMargin,
                y: bounds.midY - clipRadius,
                width: clipDiameter,
                height: clipDiameter
            )

        case .horizontalGrowingRight:
            // Near right (outer) edge, vertically centered
            clipLayer.frame = CGRect(
                x: bounds.width - clipMargin - clipDiameter,
                y: bounds.midY - clipRadius,
                width: clipDiameter,
                height: clipDiameter
            )
        }

        // Border path
        let borderPath = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4, cornerHeight: 4, transform: nil)
        borderLayer.path = borderPath
        borderLayer.frame = bounds

        // Re-apply current state - must be done after all frame/bounds operations
        updateFillTransform()
        updatePeakHoldPosition()

        CATransaction.commit()
    }

    // MARK: - MeterObserver Protocol

    func meterUpdated(value: Float, hold: Float, clipping: Bool) {
        currentPeak = max(0, min(1, value))
        currentPeakHold = max(0, min(1, hold))
        isCurrentlyClipping = clipping

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateFillTransform()
        updatePeakHoldPosition()
        CATransaction.commit()
        updateClipIndicator()
    }

    // MARK: - Private Updates

    private func updateFillTransform() {
        guard isSetupComplete else { return }

        let scale = CGFloat(currentPeak)

        // Scale based on orientation
        switch orientation {
        case .vertical:
            // Scale from bottom: scale Y
            fillMaskLayer.transform = CATransform3DMakeScale(1.0, scale, 1.0)

        case .horizontalGrowingLeft, .horizontalGrowingRight:
            // Scale horizontally: scale X
            fillMaskLayer.transform = CATransform3DMakeScale(scale, 1.0, 1.0)
        }
    }

    private func updatePeakHoldPosition() {
        guard isSetupComplete else { return }

        guard currentPeakHold > 0 else {
            peakHoldLayer.isHidden = true
            return
        }

        peakHoldLayer.isHidden = false

        let bounds = self.bounds

        switch orientation {
        case .vertical:
            // Position by Y (vertical meter)
            let holdY = bounds.height * CGFloat(currentPeakHold)
            var frame = peakHoldLayer.frame
            frame.origin.y = holdY - 1  // Center the 2pt line on the hold position
            peakHoldLayer.frame = frame

        case .horizontalGrowingLeft:
            // Position by X from right edge (grows left)
            let holdX = bounds.width * (1 - CGFloat(currentPeakHold)) - 1
            var frame = peakHoldLayer.frame
            frame.origin.x = holdX
            peakHoldLayer.frame = frame

        case .horizontalGrowingRight:
            // Position by X from left edge (grows right)
            let holdX = bounds.width * CGFloat(currentPeakHold) - 1
            var frame = peakHoldLayer.frame
            frame.origin.x = holdX
            peakHoldLayer.frame = frame
        }
    }

    private func updateClipIndicator() {
        clipLayer.isHidden = !isCurrentlyClipping
    }
}
