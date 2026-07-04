import XCTest
@testable import Equaliser

@MainActor
final class EqualiserStoreSnapshotTests: XCTestCase {

    var store: EqualiserStore!

    override func setUp() async throws {
        store = EqualiserStore()
    }

    override func tearDown() async throws {
        store = nil
    }

    // MARK: - saveSnapshot Tests

    func testSaveSnapshot_populatesSnapshotsAndSetsSelectedKey() {
        // Arrange: Ensure starting state is clean
        XCTAssertNil(store.snapshots["A"])
        XCTAssertNil(store.selectedSnapshotKey)

        // Act: Save to slot A
        store.saveSnapshot(key: "A")

        // Assert: Slot A is populated and selected
        XCTAssertNotNil(store.snapshots["A"])
        XCTAssertEqual(store.selectedSnapshotKey, "A")

        // Verify snapshot contains expected data
        let snapshot = store.snapshots["A"]!
        XCTAssertEqual(snapshot.leftBands.count, 64)
        XCTAssertEqual(snapshot.rightBands.count, 64)
        XCTAssertNotNil(snapshot.timestamp)
    }

    func testSaveSnapshot_overwritesExistingSlot() {
        // Arrange: Save initial state to slot A
        store.saveSnapshot(key: "A")
        let firstTimestamp = store.snapshots["A"]!.timestamp

        // Modify EQ configuration
        store.updateBandGain(index: 0, gain: 6.0)

        // Act: Save new state to same slot
        store.saveSnapshot(key: "A")

        // Assert: Slot is overwritten with new data
        XCTAssertEqual(store.selectedSnapshotKey, "A")
        XCTAssertNotEqual(store.snapshots["A"]!.timestamp, firstTimestamp)
    }

    func testSaveSnapshot_movesSelectionWhenSavingToDifferentSlot() {
        // Arrange: Save to slot A first
        store.saveSnapshot(key: "A")
        XCTAssertEqual(store.selectedSnapshotKey, "A")

        // Modify EQ configuration
        store.updateBandGain(index: 0, gain: 3.0)

        // Act: Save to slot B
        store.saveSnapshot(key: "B")

        // Assert: Selection moved to B, A is untouched
        XCTAssertEqual(store.selectedSnapshotKey, "B")
        XCTAssertNotNil(store.snapshots["A"])
        XCTAssertNotNil(store.snapshots["B"])
    }

    // MARK: - restoreSnapshot Tests

    func testRestoreSnapshot_appliesSavedConfiguration() {
        // Arrange: Set up specific EQ state and save it
        store.updateBandGain(index: 0, gain: 6.0)
        store.updateBandGain(index: 1, gain: -3.0)
        store.inputGain = 2.0
        store.outputGain = -1.0
        store.bandCount = 10
        store.channelMode = .stereo
        store.isBypassed = true

        store.saveSnapshot(key: "A")

        // Modify the live EQ to different values
        store.updateBandGain(index: 0, gain: 0.0)
        store.updateBandGain(index: 1, gain: 0.0)
        store.inputGain = 0.0
        store.outputGain = 0.0
        store.bandCount = 31
        store.channelMode = .linked
        store.isBypassed = false

        // Act: Restore from slot A
        store.restoreSnapshot(key: "A")

        // Assert: All saved values are restored
        XCTAssertEqual(store.eqConfiguration.bands[0].gain, 6.0, accuracy: 0.01)
        XCTAssertEqual(store.eqConfiguration.bands[1].gain, -3.0, accuracy: 0.01)
        XCTAssertEqual(store.inputGain, 2.0, accuracy: 0.01)
        XCTAssertEqual(store.outputGain, -1.0, accuracy: 0.01)
        XCTAssertEqual(store.bandCount, 10)
        XCTAssertEqual(store.channelMode, .stereo)
        XCTAssertEqual(store.isBypassed, true)
        XCTAssertEqual(store.selectedSnapshotKey, "A")
    }

    func testRestoreSnapshot_onEmptySlotIsNoOp() {
        // Arrange: Set up specific EQ state
        store.updateBandGain(index: 0, gain: 6.0)
        store.inputGain = 2.0
        store.bandCount = 10
        let originalGain = store.eqConfiguration.bands[0].gain
        let originalInputGain = store.inputGain
        let originalBandCount = store.bandCount
        let originalSelectedKey = store.selectedSnapshotKey

        // Act: Try to restore from empty slot B
        store.restoreSnapshot(key: "B")

        // Assert: Nothing changed
        XCTAssertEqual(store.eqConfiguration.bands[0].gain, originalGain, accuracy: 0.01)
        XCTAssertEqual(store.inputGain, originalInputGain, accuracy: 0.01)
        XCTAssertEqual(store.bandCount, originalBandCount)
        XCTAssertEqual(store.selectedSnapshotKey, originalSelectedKey)
    }

    func testRestoreSnapshot_setsSelectedSnapshotKey() {
        // Arrange: Save to slot A
        store.saveSnapshot(key: "A")
        store.selectedSnapshotKey = nil

        // Act: Restore from slot A
        store.restoreSnapshot(key: "A")

        // Assert: Selection is set
        XCTAssertEqual(store.selectedSnapshotKey, "A")
    }

    // MARK: - clearSnapshot Tests

    func testClearSnapshot_removesSlotAndResetsSelectionIfSelected() {
        // Arrange: Save to slot A and select it
        store.saveSnapshot(key: "A")
        XCTAssertEqual(store.selectedSnapshotKey, "A")
        XCTAssertNotNil(store.snapshots["A"])

        // Act: Clear slot A
        store.clearSnapshot(key: "A")

        // Assert: Slot is removed and selection is reset
        XCTAssertNil(store.snapshots["A"])
        XCTAssertNil(store.selectedSnapshotKey)
    }

    func testClearSnapshot_removesSlotButPreservesSelectionIfNotSelected() {
        // Arrange: Save to slots A and B, select A
        store.saveSnapshot(key: "A")
        store.saveSnapshot(key: "B")
        store.selectedSnapshotKey = "A"

        // Act: Clear slot B (not selected)
        store.clearSnapshot(key: "B")

        // Assert: B is removed but A remains selected
        XCTAssertNil(store.snapshots["B"])
        XCTAssertNotNil(store.snapshots["A"])
        XCTAssertEqual(store.selectedSnapshotKey, "A")
    }

    func testClearSnapshot_onEmptySlotIsNoOp() {
        // Arrange: Ensure slot C is empty
        XCTAssertNil(store.snapshots["C"])

        // Act: Clear empty slot C
        store.clearSnapshot(key: "C")

        // Assert: Still empty, no crash
        XCTAssertNil(store.snapshots["C"])
    }

    // MARK: - Integration Tests

    func testFullWorkflow_saveRestoreClear() {
        // Arrange: Start with clean state
        XCTAssertNil(store.snapshots["A"])
        XCTAssertNil(store.selectedSnapshotKey)

        // Act 1: Save to slot A
        store.updateBandGain(index: 0, gain: 5.0)
        store.saveSnapshot(key: "A")

        // Assert 1: Slot A saved and selected
        XCTAssertNotNil(store.snapshots["A"])
        XCTAssertEqual(store.selectedSnapshotKey, "A")

        // Act 2: Modify EQ and restore
        store.updateBandGain(index: 0, gain: 0.0)
        store.restoreSnapshot(key: "A")

        // Assert 2: Original values restored
        XCTAssertEqual(store.eqConfiguration.bands[0].gain, 5.0, accuracy: 0.01)
        XCTAssertEqual(store.selectedSnapshotKey, "A")

        // Act 3: Clear slot
        store.clearSnapshot(key: "A")

        // Assert 3: Slot cleared and selection reset
        XCTAssertNil(store.snapshots["A"])
        XCTAssertNil(store.selectedSnapshotKey)
    }

    func testMultipleSlotsIndependent() {
        // Arrange: Save different states to A and B
        store.updateBandGain(index: 0, gain: 6.0)
        store.saveSnapshot(key: "A")

        store.updateBandGain(index: 0, gain: -3.0)
        store.saveSnapshot(key: "B")

        // Act: Restore A, then B
        store.restoreSnapshot(key: "A")
        XCTAssertEqual(store.eqConfiguration.bands[0].gain, 6.0, accuracy: 0.01)
        XCTAssertEqual(store.selectedSnapshotKey, "A")

        store.restoreSnapshot(key: "B")
        XCTAssertEqual(store.eqConfiguration.bands[0].gain, -3.0, accuracy: 0.01)
        XCTAssertEqual(store.selectedSnapshotKey, "B")

        // Assert: Both slots still exist independently
        XCTAssertNotNil(store.snapshots["A"])
        XCTAssertNotNil(store.snapshots["B"])
    }
}
