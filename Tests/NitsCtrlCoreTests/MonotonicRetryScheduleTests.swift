import XCTest
@testable import NitsCtrlCore

final class MonotonicRetryScheduleTests: XCTestCase {
    func testLiveReservationSuppressesDuplicateRetry() {
        var schedule = MonotonicRetrySchedule()
        let first = schedule.reserve(after: 2, now: 10)

        XCTAssertNotNil(first)
        XCTAssertTrue(schedule.hasPendingRetry(at: 11.999))
        XCTAssertNil(schedule.reserve(after: 4, now: 11.999))
    }

    func testOverdueReservationCanBeReplaced() {
        var schedule = MonotonicRetrySchedule()
        let overdue = schedule.reserve(after: 2, now: 10)!
        let replacement = schedule.reserve(after: 4, now: 12)!

        XCTAssertNotEqual(overdue, replacement)
        XCTAssertFalse(schedule.consume(overdue))
        XCTAssertTrue(schedule.hasPendingRetry(at: 15.999))
        XCTAssertTrue(schedule.consume(replacement))
        XCTAssertFalse(schedule.hasPendingRetry(at: 16))
    }

    func testCancelInvalidatesSubmittedCallback() {
        var schedule = MonotonicRetrySchedule()
        let cancelled = schedule.reserve(after: 2, now: 10)!

        schedule.cancel()

        XCTAssertFalse(schedule.consume(cancelled))
        XCTAssertFalse(schedule.hasPendingRetry(at: 10))
        XCTAssertNotNil(schedule.reserve(after: 2, now: 10))
    }
}
