import Foundation

/// Tracks one delayed retry without relying on cancellation of a submitted
/// dispatch work item. A reservation stops counting as pending after its
/// monotonic deadline, so a callback lost during a system transition cannot
/// suppress all future retries.
package struct MonotonicRetrySchedule: Sendable {
    package struct Reservation: Equatable, Sendable {
        fileprivate let token: UInt64
        fileprivate let deadlineUptime: TimeInterval
    }

    private var nextToken: UInt64 = 0
    private var reservation: Reservation?

    package init() {}

    package func hasPendingRetry(at uptime: TimeInterval) -> Bool {
        guard let reservation else { return false }
        return uptime < reservation.deadlineUptime
    }

    package mutating func reserve(
        after delay: TimeInterval,
        now uptime: TimeInterval
    ) -> Reservation? {
        guard !hasPendingRetry(at: uptime) else { return nil }
        nextToken &+= 1
        let reservation = Reservation(
            token: nextToken,
            deadlineUptime: uptime + max(0, delay)
        )
        self.reservation = reservation
        return reservation
    }

    /// Consumes only the currently reserved callback. An older callback that
    /// arrives after an overdue retry was replaced is deliberately ignored.
    package mutating func consume(_ candidate: Reservation) -> Bool {
        guard reservation == candidate else { return false }
        reservation = nil
        return true
    }

    package mutating func cancel() {
        reservation = nil
    }
}
