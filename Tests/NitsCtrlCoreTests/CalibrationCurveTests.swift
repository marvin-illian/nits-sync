import XCTest
@testable import NitsCtrlCore

final class CalibrationCurveTests: XCTestCase {
    func testDefaultCurveInterpolatesBothDirectionsAndClamps() throws {
        let curve = try CalibrationCurve.defaultCurve(
            minimumNits: 10,
            maximumNits: 310,
            rawMinimum: 0,
            rawMaximum: 100
        )

        XCTAssertEqual(curve.nits(forRawValue: 50), 160, accuracy: 0.000_001)
        XCTAssertEqual(curve.nits(forRawValue: Double(-10)), 10)
        XCTAssertEqual(curve.nits(forRawValue: Double(120)), 310)
        XCTAssertEqual(curve.rawValue(forNits: 160), 50)
        XCTAssertEqual(curve.rawValue(forNits: -100), 0)
        XCTAssertEqual(curve.rawValue(forNits: 1_000), 100)
    }

    func testPiecewiseCurveUsesCorrectSegment() throws {
        let curve = try CalibrationCurve(points: [
            CalibrationPoint(rawValue: 0, nits: 5),
            CalibrationPoint(rawValue: 50, nits: 80),
            CalibrationPoint(rawValue: 100, nits: 300),
        ])

        XCTAssertEqual(curve.nits(forRawValue: 25), 42.5, accuracy: 0.000_001)
        let rawValue = try XCTUnwrap(curve.rawValue(forNits: 190))
        XCTAssertEqual(rawValue, 75, accuracy: 0.000_001)
    }

    func testRejectsNonMonotonicCurves() {
        XCTAssertThrowsError(try CalibrationCurve(points: [
            CalibrationPoint(rawValue: 0, nits: 10),
            CalibrationPoint(rawValue: 0, nits: 20),
        ])) { error in
            XCTAssertEqual(error as? CalibrationCurveError, .rawValuesMustIncrease(index: 1))
        }

        XCTAssertThrowsError(try CalibrationCurve(points: [
            CalibrationPoint(rawValue: 0, nits: 10),
            CalibrationPoint(rawValue: 100, nits: 10),
        ])) { error in
            XCTAssertEqual(error as? CalibrationCurveError, .nitsMustIncrease(index: 1))
        }
    }

    func testNonFiniteQueryReturnsNil() throws {
        let curve = try CalibrationCurve.defaultCurve(minimumNits: 5, maximumNits: 100)
        XCTAssertNil(curve.nits(forRawValue: .nan))
        XCTAssertNil(curve.rawValue(forNits: .infinity))
        XCTAssertNil(curve.quantizedRawValue(forNits: .nan))
    }
}
