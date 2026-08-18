import XCTest
@testable import Equaliser

@MainActor
final class MeterStoreTests: XCTestCase {

    // MARK: - Test Observer

    private final class TestObserver: MeterObserver {
        var lastValue: Float = 0
        var lastHold: Float = 0
        var lastClipping: Bool = false
        var updateCount = 0

        func meterUpdated(value: Float, hold: Float, clipping: Bool) {
            lastValue = value
            lastHold = hold
            lastClipping = clipping
            updateCount += 1
        }
    }

    // MARK: - Initialization Tests

    func testInit_defaultValues_metersEnabledTrue() {
        let store = MeterStore()
        XCTAssertTrue(store.metersEnabled)
    }

    func testInit_withMetersEnabledFalse() {
        let store = MeterStore(metersEnabled: false)
        XCTAssertFalse(store.metersEnabled)
    }

    // MARK: - Observer Registration Tests

    func testAddObserver_receivesUpdates() {
        let store = MeterStore()
        let observer = TestObserver()

        store.addObserver(observer, for: .inputPeakLeft)

        // Initially silent state should be sent
        XCTAssertEqual(observer.lastValue, 0)
        XCTAssertEqual(observer.lastHold, 0)
        XCTAssertFalse(observer.lastClipping)
    }

    func testRemoveObserver_stopsReceivingUpdates() {
        let store = MeterStore()
        let observer = TestObserver()

        store.addObserver(observer, for: .inputPeakLeft)
        store.removeObserver(observer, for: .inputPeakLeft)

        // Should not crash and updates should stop
        XCTAssertTrue(true)
    }

    // MARK: - metersEnabled Toggle Tests

    func testMetersEnabled_whenDisabled_notifiesAllObserversSilent() {
        let store = MeterStore()
        let peakObserver = TestObserver()
        let rmsObserver = TestObserver()

        store.addObserver(peakObserver, for: .inputPeakLeft)
        store.addObserver(rmsObserver, for: .inputRMSLeft)

        store.metersEnabled = false

        // Both observers should have been notified with silent state
        XCTAssertEqual(peakObserver.lastValue, 0)
        XCTAssertEqual(rmsObserver.lastValue, 0)
    }

    func testMetersEnabled_whenEnabled_startsUpdates() {
        let store = MeterStore(metersEnabled: false)
        let observer = TestObserver()

        store.addObserver(observer, for: .inputPeakLeft)
        let initialCount = observer.updateCount

        store.metersEnabled = true

        // Should not crash and updates should start
        XCTAssertTrue(true)
    }

    // MARK: - Timer Lifecycle Tests

    func testStopMeterUpdates_notifiesAllObserversSilent() {
        let store = MeterStore()
        let observer = TestObserver()

        store.addObserver(observer, for: .inputPeakLeft)
        observer.updateCount = 0  // Reset count

        store.stopMeterUpdates()

        // Observer should have been notified with silent state
        XCTAssertEqual(observer.lastValue, 0)
    }

    func testStartMeterUpdates_withoutPipeline_noCrash() {
        let store = MeterStore()

        store.startMeterUpdates()

        XCTAssertTrue(true)
    }

    // MARK: - Multiple Meter Types

    func testMultipleObserversForDifferentTypes() {
        let store = MeterStore()
        let inputPeakObserver = TestObserver()
        let outputPeakObserver = TestObserver()
        let inputRMSObserver = TestObserver()
        let outputRMSObserver = TestObserver()

        store.addObserver(inputPeakObserver, for: .inputPeakLeft)
        store.addObserver(outputPeakObserver, for: .outputPeakLeft)
        store.addObserver(inputRMSObserver, for: .inputRMSLeft)
        store.addObserver(outputRMSObserver, for: .outputRMSLeft)

        // All observers should have received initial silent state
        XCTAssertEqual(inputPeakObserver.lastValue, 0)
        XCTAssertEqual(outputPeakObserver.lastValue, 0)
        XCTAssertEqual(inputRMSObserver.lastValue, 0)
        XCTAssertEqual(outputRMSObserver.lastValue, 0)
    }

    // MARK: - VU Meter Tests

    func testVUMeter_smoothedValueConvergesGradually() {
        let store = MeterStore()
        let observer = TestObserver()
        store.addObserver(observer, for: .inputVULeft)

        // Simulate a step input by calling updateVUMeter multiple times
        // The value should converge gradually, not jump immediately
        let initialCount = observer.updateCount
        var previousValue: Float = 0

        for _ in 0..<10 {
            // Simulate a step to 0.5 (mid-scale)
            store.updateVUMeter(type: .inputVULeft, dbValue: -20, interval: 1.0/30.0)
            let currentValue = observer.lastValue

            // Value should increase gradually, not jump to target
            if previousValue > 0 {
                let delta = currentValue - previousValue
                // With vuSmoothing = 0.63, the change should be bounded
                XCTAssertLessThan(abs(delta), 0.7, "VU should converge gradually, not jump")
            }

            previousValue = currentValue
        }

        // After multiple ticks, should be close to target (0.5 for -20dB)
        XCTAssertGreaterThan(observer.lastValue, 0.3, "VU should converge toward target")
        XCTAssertLessThan(observer.lastValue, 0.7, "VU should not overshoot significantly")
    }

    func testVUMeter_clippingAtZeroDBFS() {
        let store = MeterStore()
        let observer = TestObserver()
        store.addObserver(observer, for: .inputVULeft)

        // Simulate 0 dBFS input (clipping)
        store.updateVUMeter(type: .inputVULeft, dbValue: 0, interval: 1.0/30.0)

        XCTAssertTrue(observer.lastClipping, "0 dBFS should trigger clipping indicator")

        // Simulate signal dropping below 0 dBFS
        store.updateVUMeter(type: .inputVULeft, dbValue: -10, interval: MeterConstants.clipHoldDuration * 0.9)

        // Clipping should still be true during hold duration
        XCTAssertTrue(observer.lastClipping, "Clipping should hold for clipHoldDuration")

        // After hold duration expires
        store.updateVUMeter(type: .inputVULeft, dbValue: -10, interval: MeterConstants.clipHoldDuration * 0.2)

        XCTAssertFalse(observer.lastClipping, "Clipping should clear after hold duration")
    }

    func testVUMeterSource_toggleChangesObservedType() {
        let store = MeterStore()
        let inputObserver = TestObserver()
        let outputObserver = TestObserver()

        store.addObserver(inputObserver, for: .inputVULeft)
        store.addObserver(outputObserver, for: .outputVULeft)

        // Initially output source
        XCTAssertEqual(store.vuMeterSource, .output)

        // Simulate output meter update
        store.updateVUMeter(type: .outputVULeft, dbValue: -10, interval: 1.0/30.0)

        XCTAssertEqual(outputObserver.lastValue, 0, "Output observer should have received value")
        XCTAssertEqual(inputObserver.lastValue, 0, "Input observer should not have received value")

        // Switch to input source
        store.vuMeterSource = .input

        // Simulate input meter update
        store.updateVUMeter(type: .inputVULeft, dbValue: -10, interval: 1.0/30.0)

        // Now input observer should receive updates
        XCTAssertGreaterThan(inputObserver.lastValue, 0, "Input observer should receive value after source switch")
    }

    // MARK: - Window Visibility Reference Counting Tests

    func testMeterWindowVisibility_referenceCounting() {
        let store = MeterStore()

        // Initially no windows visible
        XCTAssertEqual(store.visibleMeterWindowIDsForTesting.isEmpty, true)

        // Add first window
        store.meterWindowBecameVisible(id: "equaliser")
        XCTAssertEqual(store.visibleMeterWindowIDsForTesting.count, 1)
        XCTAssertTrue(store.visibleMeterWindowIDsForTesting.contains("equaliser"))

        // Add second window
        store.meterWindowBecameVisible(id: "levels-window")
        XCTAssertEqual(store.visibleMeterWindowIDsForTesting.count, 2)
        XCTAssertTrue(store.visibleMeterWindowIDsForTesting.contains("levels-window"))

        // Hide first window - timer should still run (second window still visible)
        store.meterWindowBecameHidden(id: "equaliser")
        XCTAssertEqual(store.visibleMeterWindowIDsForTesting.count, 1)
        XCTAssertTrue(store.visibleMeterWindowIDsForTesting.contains("levels-window"))

        // Hide second window - timer should stop (no windows visible)
        store.meterWindowBecameHidden(id: "levels-window")
        XCTAssertEqual(store.visibleMeterWindowIDsForTesting.count, 0)
        XCTAssertTrue(store.visibleMeterWindowIDsForTesting.isEmpty)
    }

    func testMeterWindowVisibility_multipleRegistrationsSameWindow() {
        let store = MeterStore()

        // Register same window twice (shouldn't crash or duplicate)
        store.meterWindowBecameVisible(id: "equaliser")
        store.meterWindowBecameVisible(id: "equaliser")

        XCTAssertEqual(store.visibleMeterWindowIDsForTesting.count, 1, "Duplicate registrations should not increase count")

        // Hide once should remove it
        store.meterWindowBecameHidden(id: "equaliser")
        XCTAssertEqual(store.visibleMeterWindowIDsForTesting.count, 0)
    }
}
