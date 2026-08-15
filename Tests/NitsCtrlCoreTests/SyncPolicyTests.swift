import XCTest
@testable import NitsCtrlCore

final class SyncPolicyTests: XCTestCase {
    func testDisplayFollowsSourceWithinRange() throws {
        let profile = try makeProfile(maximumNits: 300)
        let target = try XCTUnwrap(SyncPolicy().target(for: 150, profile: profile))

        XCTAssertEqual(target.rawValue, 49)
        XCTAssertEqual(target.estimatedNits, 149.55, accuracy: 0.000_001)
        XCTAssertEqual(target.clamp, .none)
    }

    func testDisplayClampsAtMaximumWhileSourceCanContinueHigher() throws {
        let profile = try makeProfile(maximumNits: 300)
        let highTarget = try XCTUnwrap(SyncPolicy().target(for: 500, profile: profile))
        XCTAssertEqual(highTarget.rawValue, 100)
        XCTAssertEqual(highTarget.estimatedNits, 300)
        XCTAssertEqual(highTarget.clamp, .maximum)

        let returningTarget = try XCTUnwrap(SyncPolicy().target(for: 350, profile: profile))
        XCTAssertEqual(returningTarget.rawValue, 100)
        XCTAssertEqual(returningTarget.clamp, .maximum)

        let syncedAgain = try XCTUnwrap(SyncPolicy().target(for: 250, profile: profile))
        XCTAssertLessThan(syncedAgain.rawValue, 100)
        XCTAssertEqual(syncedAgain.clamp, .none)
    }

    func testZeroNitsMapsToExternalMinimum() throws {
        let profile = try makeProfile(maximumNits: 300)
        let target = try XCTUnwrap(SyncPolicy().target(for: 0, profile: profile))

        XCTAssertEqual(target.rawValue, 0)
        XCTAssertEqual(target.estimatedNits, 5)
        XCTAssertEqual(target.clamp, .minimum)
    }

    func testDisabledProfileAndInvalidSourceProduceNoTarget() throws {
        var profile = try makeProfile(maximumNits: 300)
        profile.isEnabled = false
        XCTAssertNil(SyncPolicy().target(for: 100, profile: profile))

        profile.isEnabled = true
        XCTAssertNil(SyncPolicy().target(for: .nan, profile: profile))
    }

    private func makeProfile(maximumNits: Double) throws -> DisplayProfile {
        DisplayProfile(
            identity: ExternalDisplayIdentity(vendorID: 1, productID: 2, serialNumber: 3),
            calibration: try CalibrationCurve.defaultCurve(
                minimumNits: 5,
                maximumNits: maximumNits
            )
        )
    }
}
