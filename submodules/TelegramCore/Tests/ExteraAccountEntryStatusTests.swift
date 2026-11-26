import XCTest
import TelegramApi
@testable import TelegramCore

final class ExteraAccountEntryStatusTests: XCTestCase {
    func testWireVariantsStayDistinct() {
        XCTAssertEqual(exteraAccountEntryStatus(.userStatusOnline(.init(expires: 123))), .online(until: 123))
        XCTAssertEqual(exteraAccountEntryStatus(.userStatusOffline(.init(wasOnline: 123))), .offline(at: 123))
    }

    func testMissingAndCoarseStatusesMatchExactAPKFallback() {
        XCTAssertEqual(exteraAccountEntryStatus(nil), .longAgo)
        XCTAssertEqual(exteraAccountEntryStatus(.userStatusEmpty), .longAgo)
        XCTAssertEqual(exteraAccountEntryStatus(.userStatusRecently(.init(flags: 0))), .longAgo)
        XCTAssertEqual(exteraAccountEntryStatus(.userStatusLastWeek(.init(flags: 1))), .longAgo)
        XCTAssertEqual(exteraAccountEntryStatus(.userStatusLastMonth(.init(flags: 0))), .longAgo)
    }
}
