import Foundation

public struct CalibrationPoint: Codable, Hashable, Sendable {
    public let rawValue: UInt16
    public let nits: Double

    public init(rawValue: UInt16, nits: Double) {
        self.rawValue = rawValue
        self.nits = nits
    }
}

public enum CalibrationCurveError: Error, Equatable, Sendable {
    case requiresAtLeastTwoPoints
    case nonFiniteNits(index: Int)
    case negativeNits(index: Int)
    case rawValuesMustIncrease(index: Int)
    case nitsMustIncrease(index: Int)
}

/// A strictly monotonic, piecewise-linear mapping between DDC raw brightness
/// values and estimated physical luminance.
public struct CalibrationCurve: Codable, Hashable, Sendable {
    public let points: [CalibrationPoint]

    public init(points: [CalibrationPoint]) throws {
        guard points.count >= 2 else {
            throw CalibrationCurveError.requiresAtLeastTwoPoints
        }

        for (index, point) in points.enumerated() {
            guard point.nits.isFinite else {
                throw CalibrationCurveError.nonFiniteNits(index: index)
            }
            guard point.nits >= 0 else {
                throw CalibrationCurveError.negativeNits(index: index)
            }
            guard index > 0 else { continue }
            guard points[index - 1].rawValue < point.rawValue else {
                throw CalibrationCurveError.rawValuesMustIncrease(index: index)
            }
            guard points[index - 1].nits < point.nits else {
                throw CalibrationCurveError.nitsMustIncrease(index: index)
            }
        }

        self.points = points
    }

    /// Creates the linear fallback used until measured calibration points exist.
    public static func defaultCurve(
        minimumNits: Double,
        maximumNits: Double,
        rawMinimum: UInt16 = 0,
        rawMaximum: UInt16 = 100
    ) throws -> CalibrationCurve {
        try CalibrationCurve(points: [
            CalibrationPoint(rawValue: rawMinimum, nits: minimumNits),
            CalibrationPoint(rawValue: rawMaximum, nits: maximumNits),
        ])
    }

    public var minimumRawValue: UInt16 { points[0].rawValue }
    public var maximumRawValue: UInt16 { points[points.count - 1].rawValue }
    public var minimumNits: Double { points[0].nits }
    public var maximumNits: Double { points[points.count - 1].nits }

    public func clampedNits(_ nits: Double) -> Double? {
        guard nits.isFinite else { return nil }
        return min(max(nits, minimumNits), maximumNits)
    }

    public func nits(forRawValue rawValue: UInt16) -> Double {
        interpolateNits(forRawValue: Double(rawValue))
    }

    /// Returns nil for a non-finite input and clamps finite input to the curve.
    public func nits(forRawValue rawValue: Double) -> Double? {
        guard rawValue.isFinite else { return nil }
        return interpolateNits(forRawValue: rawValue)
    }

    /// Returns a continuous raw value, clamped to the calibrated domain.
    public func rawValue(forNits nits: Double) -> Double? {
        guard let nits = clampedNits(nits) else { return nil }
        guard nits > minimumNits else { return Double(minimumRawValue) }
        guard nits < maximumNits else { return Double(maximumRawValue) }

        let upperIndex = points.firstIndex { $0.nits >= nits } ?? (points.count - 1)
        let lower = points[upperIndex - 1]
        let upper = points[upperIndex]
        let fraction = (nits - lower.nits) / (upper.nits - lower.nits)
        return Double(lower.rawValue) + fraction * Double(upper.rawValue - lower.rawValue)
    }

    public func quantizedRawValue(
        forNits nits: Double,
        rounding rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero
    ) -> UInt16? {
        guard let rawValue = rawValue(forNits: nits) else { return nil }
        let rounded = rawValue.rounded(rule)
        return UInt16(min(max(rounded, Double(minimumRawValue)), Double(maximumRawValue)))
    }

    private func interpolateNits(forRawValue rawValue: Double) -> Double {
        guard rawValue > Double(minimumRawValue) else { return minimumNits }
        guard rawValue < Double(maximumRawValue) else { return maximumNits }

        let upperIndex = points.firstIndex { Double($0.rawValue) >= rawValue } ?? (points.count - 1)
        let lower = points[upperIndex - 1]
        let upper = points[upperIndex]
        let rawSpan = Double(upper.rawValue - lower.rawValue)
        let fraction = (rawValue - Double(lower.rawValue)) / rawSpan
        return lower.nits + fraction * (upper.nits - lower.nits)
    }

    private enum CodingKeys: String, CodingKey {
        case points
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(points: container.decode([CalibrationPoint].self, forKey: .points))
    }
}
