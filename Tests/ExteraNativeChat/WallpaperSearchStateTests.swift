import XCTest

final class WallpaperSearchStateTests: XCTestCase {
    func testBotQueryUsesCanonicalColorAndWallpaperScope() {
        XCTAssertEqual(WallpaperSearchQuery(text: "  cats\n", color: "Blue").botQuery, "#wallpaper #colorBlue cats")
        XCTAssertEqual(WallpaperSearchQuery(text: "", color: "Red").botQuery, "#wallpaper #colorRed ")
        XCTAssertEqual(WallpaperSearchQuery(text: "cats", color: "unknown").botQuery, "#wallpaper cats")
        XCTAssertNil(WallpaperSearchQuery(text: " \n", color: nil).botQuery)
    }

    func testClearingSearchRejectsLateReplyAfterReentry() {
        var state = WallpaperSearchState<String>()
        state.reset(WallpaperSearchQuery(text: "cats", color: nil))
        let old = state.begin()!
        state.reset(WallpaperSearchQuery(text: "", color: nil))
        state.reset(WallpaperSearchQuery(text: "cats", color: nil))
        let current = state.begin()!
        state.receive(old, items: ["old"], nextOffset: "old-page", id: { $0 })
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertEqual(state.request, current)
        state.receive(current, items: ["new"], nextOffset: nil, id: { $0 })
        XCTAssertEqual(state.items, ["new"])
    }

    func testOnlyOnePageIsInFlightAndIdsAreDeduplicated() {
        var state = WallpaperSearchState<String>()
        state.reset(WallpaperSearchQuery(text: "cats", color: nil))
        let first = state.begin()!
        XCTAssertNil(state.begin())
        state.receive(first, items: ["a", "a", "b"], nextOffset: "2", id: { $0 })
        let second = state.begin()!
        XCTAssertEqual(second.offset, "2")
        state.receive(second, items: ["b", "c"], nextOffset: "3", id: { $0 })
        XCTAssertEqual(state.items, ["a", "b", "c"])
    }

    func testDuplicatePageAndRepeatedOffsetStopPagination() {
        var state = WallpaperSearchState<String>()
        state.reset(WallpaperSearchQuery(text: "cats", color: nil))
        let first = state.begin()!
        state.receive(first, items: ["a"], nextOffset: "2", id: { $0 })
        let duplicate = state.begin()!
        state.receive(duplicate, items: ["a"], nextOffset: "3", id: { $0 })
        XCTAssertNil(state.begin())
        state.reset(WallpaperSearchQuery(text: "cats", color: nil))
        let restarted = state.begin()!
        state.receive(restarted, items: ["a"], nextOffset: "2", id: { $0 })
        let repeatedOffset = state.begin()!
        state.receive(repeatedOffset, items: ["b"], nextOffset: "2", id: { $0 })
        XCTAssertNil(state.begin())
    }

    func testPageFailureKeepsItemsAndOffsetForRetry() {
        var state = WallpaperSearchState<String>()
        state.reset(WallpaperSearchQuery(text: "cats", color: nil))
        let first = state.begin()!
        state.receive(first, items: ["a"], nextOffset: "2", id: { $0 })
        let second = state.begin()!
        state.fail(second)
        XCTAssertTrue(state.failed)
        XCTAssertEqual(state.items, ["a"])
        XCTAssertEqual(state.begin()?.offset, "2")
        XCTAssertFalse(state.failed)
    }

    func testColorChangeRejectsStaleFailureAndResetsPagination() {
        var state = WallpaperSearchState<String>()
        state.reset(WallpaperSearchQuery(text: "cats", color: "Blue"))
        let old = state.begin()!
        state.reset(WallpaperSearchQuery(text: "cats", color: "Red"))
        let current = state.begin()!
        state.fail(old)
        XCTAssertFalse(state.failed)
        XCTAssertEqual(state.request, current)
        XCTAssertEqual(current.query, "#wallpaper #colorRed cats")
        XCTAssertEqual(current.offset, "")
    }
}
