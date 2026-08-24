import XCTest
@testable import NitsCtrlHardware

final class BuiltInNitsReaderTests: XCTestCase {
    func testFirstSampleIsDelivered() {
        XCTAssertTrue(BuiltInNitsReader.shouldDeliverSample(
            120,
            lastDeliveredNits: nil,
            deadbandNits: 0.5,
            forceDelivery: false
        ))
    }

    func testOrdinaryPollingStillUsesDeadband() {
        XCTAssertFalse(BuiltInNitsReader.shouldDeliverSample(
            120.2,
            lastDeliveredNits: 120,
            deadbandNits: 0.5,
            forceDelivery: false
        ))
        XCTAssertTrue(BuiltInNitsReader.shouldDeliverSample(
            120.5,
            lastDeliveredNits: 120,
            deadbandNits: 0.5,
            forceDelivery: false
        ))
    }

    func testNotificationWatchdogRedeliversUnchangedSample() {
        XCTAssertTrue(BuiltInNitsReader.shouldDeliverSample(
            120,
            lastDeliveredNits: 120,
            deadbandNits: 0.5,
            forceDelivery: true
        ))
    }
}
