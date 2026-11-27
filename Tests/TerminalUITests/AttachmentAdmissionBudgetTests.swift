import Foundation
import XCTest
@testable import TranoApp

final class AttachmentAdmissionBudgetTests: XCTestCase {
    func testExactLimitsAndThirdOrOversizedAdmissionNeverConsumeBudget() throws {
        let budget = AttachmentAdmissionBudget()
        XCTAssertEqual(AttachmentAdmissionBudget.maximumCount, 2)
        XCTAssertEqual(AttachmentAdmissionBudget.maximumAttachmentBytes, 20 * 1_048_576)
        XCTAssertEqual(AttachmentAdmissionBudget.maximumTotalBytes, 40 * 1_048_576)
        let first = try budget.reserve(byteCount: 20 * 1_048_576), second = try budget.reserve(byteCount: 20 * 1_048_576)
        XCTAssertEqual(budget.usage, .init(count: 2, bytes: 40 * 1_048_576))
        XCTAssertThrowsError(try budget.reserve(byteCount: 1))
        XCTAssertThrowsError(try budget.reserve(byteCount: 20 * 1_048_576 + 1))
        XCTAssertEqual(budget.usage, .init(count: 2, bytes: 40 * 1_048_576))
        first.release(); second.release()
        XCTAssertEqual(budget.usage, .init(count: 0, bytes: 0))
    }
    func testReservationReleaseIsExactlyOnceEvenWhenExplicitReleaseAndDeinitBothRun() throws {
        let budget = AttachmentAdmissionBudget()
        var first: AttachmentAdmissionBudget.Reservation? = try budget.reserve(byteCount: 123)
        let second = try budget.reserve(byteCount: 456)
        first?.release(); first?.release(); first = nil
        XCTAssertEqual(budget.usage, .init(count: 1, bytes: 456))
        let third = try budget.reserve(byteCount: 789)
        XCTAssertThrowsError(try budget.reserve(byteCount: 1))
        second.release(); third.release()
        XCTAssertEqual(budget.usage, .init(count: 0, bytes: 0))
    }
    func testAbandonedReservationRestoresBoundedCapacity() throws {
        let budget = AttachmentAdmissionBudget()
        var reservation: AttachmentAdmissionBudget.Reservation? = try budget.reserve(byteCount: 20 * 1_048_576)
        XCTAssertNotNil(reservation); XCTAssertEqual(budget.usage.count, 1)
        reservation = nil
        XCTAssertEqual(budget.usage, .init(count: 0, bytes: 0))
    }
    func testInvalidCountsRejectBeforeAdmissionAndDoNotCorruptByteArithmetic() {
        let budget = AttachmentAdmissionBudget()
        for count in [-1, Int.min, Int.max, 20 * 1_048_576 + 1] {XCTAssertThrowsError(try budget.reserve(byteCount: count))}
        XCTAssertEqual(budget.usage, .init(count: 0, bytes: 0))
    }
    func testConcurrentAdmissionCannotOverbookAndConcurrentDuplicateReleaseCannotUnderflow() {
        let budget = AttachmentAdmissionBudget(), lock = NSLock()
        var reservations: [AttachmentAdmissionBudget.Reservation] = []
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if let reservation = try? budget.reserve(byteCount: 20 * 1_048_576) {
                lock.lock(); reservations.append(reservation); lock.unlock()
            }
        }
        XCTAssertEqual(reservations.count, 2)
        XCTAssertEqual(budget.usage, .init(count: 2, bytes: 40 * 1_048_576))
        let accepted = reservations
        DispatchQueue.concurrentPerform(iterations: 32) { _ in accepted.forEach {$0.release()} }
        XCTAssertEqual(budget.usage, .init(count: 0, bytes: 0))
    }
}
