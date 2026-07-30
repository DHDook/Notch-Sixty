import AppKit
import XCTest
@testable import Equaliser

@MainActor
final class WindowActivationControllerTests: XCTestCase {
    func testDockStyle_requestsRegularActivation() {
        let policyApplier = RecordingActivationPolicyApplier()
        let controller = WindowActivationController(policyApplier: policyApplier)

        controller.setInterfaceStyle(.dock)

        XCTAssertEqual(policyApplier.policies, [.regular])
    }

    func testTrayStyle_requestsAccessoryActivation() {
        let policyApplier = RecordingActivationPolicyApplier()
        let controller = WindowActivationController(policyApplier: policyApplier)

        controller.setInterfaceStyle(.tray)

        XCTAssertEqual(policyApplier.policies, [.accessory])
    }

    func testBothStyle_requestsRegularActivation() {
        let policyApplier = RecordingActivationPolicyApplier()
        let controller = WindowActivationController(policyApplier: policyApplier)

        controller.setInterfaceStyle(.both)

        XCTAssertEqual(policyApplier.policies, [.regular])
    }

    func testPrepareToShowWindow_requestsRegularUnderDockStyle() {
        let policyApplier = RecordingActivationPolicyApplier()
        let controller = WindowActivationController(policyApplier: policyApplier)

        controller.setInterfaceStyle(.dock)
        controller.prepareToShowWindow()

        XCTAssertEqual(policyApplier.policies, [.regular])
    }

    func testPrepareToShowWindow_requestsRegularUnderBothStyle() {
        let policyApplier = RecordingActivationPolicyApplier()
        let controller = WindowActivationController(policyApplier: policyApplier)

        controller.setInterfaceStyle(.both)
        controller.prepareToShowWindow()

        XCTAssertEqual(policyApplier.policies, [.regular])
    }

    func testPrepareToShowWindow_isNoOpUnderTrayStyle() {
        let policyApplier = RecordingActivationPolicyApplier()
        let controller = WindowActivationController(policyApplier: policyApplier)

        controller.setInterfaceStyle(.tray)
        controller.prepareToShowWindow()

        XCTAssertEqual(policyApplier.policies, [.accessory])
    }

    func testStyleSwitching_appliesNewPolicyImmediately() {
        let policyApplier = RecordingActivationPolicyApplier()
        let controller = WindowActivationController(policyApplier: policyApplier)

        controller.setInterfaceStyle(.dock)
        controller.setInterfaceStyle(.tray)
        controller.setInterfaceStyle(.both)

        XCTAssertEqual(policyApplier.policies, [.regular, .accessory, .regular])
    }

    func testStyleSwitching_isIdempotent() {
        let policyApplier = RecordingActivationPolicyApplier()
        let controller = WindowActivationController(policyApplier: policyApplier)

        controller.setInterfaceStyle(.dock)
        controller.setInterfaceStyle(.dock)
        controller.setInterfaceStyle(.dock)

        XCTAssertEqual(policyApplier.policies, [.regular])
    }
}

private final class RecordingActivationPolicyApplier: ActivationPolicyApplying {
    private(set) var policies: [NSApplication.ActivationPolicy] = []

    func apply(_ policy: NSApplication.ActivationPolicy) {
        policies.append(policy)
    }
}
