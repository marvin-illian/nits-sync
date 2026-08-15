import Foundation
import XCTest
@testable import NitsCtrlCore

final class DisplayModelsTests: XCTestCase {
    func testIdentityRoundTripsWithStableKey() throws {
        let identity = ExternalDisplayIdentity(
            vendorID: 0x0610,
            productID: 0x1234,
            serialNumber: 42,
            alphanumericSerialNumber: "SERIAL-TEXT",
            displayUUID: UUID(uuidString: "E9D2407D-1C57-4958-AC4A-747C483C48F9"),
            edidHash: "ABCDEF",
            transportPath: "IOService:/example/path"
        )

        let data = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(ExternalDisplayIdentity.self, from: data)

        XCTAssertEqual(decoded, identity)
        XCTAssertEqual(decoded.stableKey, "v00000610-p00001234-s0000002a")
        XCTAssertFalse(decoded.isAmbiguous)
    }

    func testAlphanumericSerialIsStableAcrossPortsWhenNumericSerialIsMissing() {
        let firstPort = ExternalDisplayIdentity(
            vendorID: 0x1e6d,
            productID: 0x5b96,
            alphanumericSerialNumber: "  008NTTQ03665  ",
            edidHash: "same-panel",
            transportPath: "port-a"
        )
        let secondPort = ExternalDisplayIdentity(
            vendorID: 0x1e6d,
            productID: 0x5b96,
            alphanumericSerialNumber: "008nttq03665",
            edidHash: "same-panel",
            transportPath: "port-b"
        )

        XCTAssertEqual(firstPort.stableKey, secondPort.stableKey)
        XCTAssertTrue(firstPort.stableKey.hasPrefix("v00001e6d-p00005b96-a"))
        XCTAssertTrue(firstPort.matchesForPersistence(secondPort))
        XCTAssertFalse(firstPort.isAmbiguous)
    }

    func testNumericSerialStillTakesPrecedenceOverAlphanumericSerial() {
        let identity = ExternalDisplayIdentity(
            vendorID: 1,
            productID: 2,
            serialNumber: 3,
            alphanumericSerialNumber: "different-text"
        )

        XCTAssertEqual(identity.stableKey, "v00000001-p00000002-s00000003")
    }

    func testDifferentKnownAlphanumericSerialsNeverLegacyMatch() {
        let first = ExternalDisplayIdentity(
            vendorID: 1,
            productID: 2,
            alphanumericSerialNumber: "panel-a",
            edidHash: "same-edid",
            transportPath: "same-port"
        )
        let second = ExternalDisplayIdentity(
            vendorID: 1,
            productID: 2,
            alphanumericSerialNumber: "panel-b",
            edidHash: "same-edid",
            transportPath: "same-port"
        )

        XCTAssertFalse(first.matchesForPersistence(second))
        XCTAssertNotEqual(first.stableKey, second.stableKey)
    }

    func testOldIdentityJSONStillDecodesAndProfileMigratesOnUpsert() throws {
        let oldJSON = Data(#"""
        {
            "vendorID": 1,
            "productID": 2,
            "edidHash": "same-edid",
            "transportPath": "same-port"
        }
        """#.utf8)
        let oldIdentity = try JSONDecoder().decode(
            ExternalDisplayIdentity.self,
            from: oldJSON
        )
        XCTAssertNil(oldIdentity.alphanumericSerialNumber)

        let currentIdentity = ExternalDisplayIdentity(
            vendorID: 1,
            productID: 2,
            alphanumericSerialNumber: "serial-a",
            edidHash: "same-edid",
            transportPath: "same-port"
        )
        let curve = try CalibrationCurve.defaultCurve(
            minimumNits: 10,
            maximumNits: 300
        )
        var store = DisplayProfileStore(profiles: [DisplayProfile(
            identity: oldIdentity,
            name: "Existing Calibration",
            calibration: curve
        )])

        let recovered = try XCTUnwrap(store.profile(for: currentIdentity))
        XCTAssertEqual(recovered.name, "Existing Calibration")
        XCTAssertEqual(recovered.identity, currentIdentity)

        store.upsert(recovered)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].identity, currentIdentity)
    }

    func testProfileStoreMatchesMovedDisplayByRealSerial() throws {
        let originalIdentity = ExternalDisplayIdentity(
            vendorID: 1,
            productID: 2,
            serialNumber: 3,
            transportPath: "port-a"
        )
        let movedIdentity = ExternalDisplayIdentity(
            vendorID: 1,
            productID: 2,
            serialNumber: 3,
            transportPath: "port-b"
        )
        let curve = try CalibrationCurve.defaultCurve(minimumNits: 8, maximumNits: 300)
        let profile = DisplayProfile(
            identity: originalIdentity,
            name: "Desk Display",
            calibration: curve
        )

        var store = DisplayProfileStore(profiles: [profile])
        XCTAssertEqual(store.profile(for: movedIdentity)?.name, "Desk Display")

        store.upsert(DisplayProfile(
            identity: movedIdentity,
            name: "Renamed",
            calibration: curve
        ))
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profile(for: originalIdentity)?.name, "Renamed")
    }

    func testIdentityWithoutUniqueHardwareDataIsMarkedAmbiguous() {
        let identity = ExternalDisplayIdentity(vendorID: 1, productID: 2, edidHash: "model-edid")
        XCTAssertTrue(identity.isAmbiguous)
    }
}
