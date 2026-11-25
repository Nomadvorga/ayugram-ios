import Dispatch
import Foundation
import XCTest

// Compile the exact production settings and AyuSettingsStore together with this file.
// This replaces only the app group's build-time identifier with an isolated test suite.
let APP_GROUP_IDENTIFIER = "ExteraFeedSettingsTests.\(UUID().uuidString)"

private final class SharedFeedSettings: @unchecked Sendable {
    let value: ExteraFeedSettings

    init(_ value: ExteraFeedSettings) { self.value = value }
}

final class ExteraFeedSettingsTests: XCTestCase {
    override func tearDown() {
        AyuSettingsStore.shared.userDefaults.removePersistentDomain(forName: APP_GROUP_IDENTIFIER)
        super.tearDown()
    }

    private func settings() -> ExteraFeedSettings {
        return ExteraFeedSettings(accountId: Int64.random(in: 1 ... Int64.max))
    }

    func testFreshAccountHasNoSelectedChannelsOrReadMarks() {
        let state = self.settings().state
        XCTAssertTrue(state.channelIds.isEmpty)
        XCTAssertTrue(state.categories.isEmpty)
        XCTAssertNil(state.selectedCategoryId)
        XCTAssertFalse(state.includeArchived)
        XCTAssertFalse(state.unreadOnly)
        XCTAssertTrue(state.isUnread(channelId: 100, messageId: 1))
        XCTAssertFalse(state.isUnread(channelId: 100, messageId: 0))
    }

    func testFullStateSurvivesReopeningAndAccountsAreIsolated() throws {
        let id = Int64.random(in: 1 ... Int64.max)
        let first = ExteraFeedSettings(accountId: id)
        let second = ExteraFeedSettings(accountId: -id)
        first.update { state in
            state.channelIds = [11, 22]
            state.includeArchived = true
            state.unreadOnly = true
            state.categories = [.init(id: "a", title: "Science", channelIds: [33, 44]), .init(id: "b", title: "Music", channelIds: [55], isHidden: true)]
            state.selectedCategoryId = "a"
        }
        first.markRead(channelId: 33, messageId: 123)
        let reopened = ExteraFeedSettings(accountId: id)
        XCTAssertEqual(reopened.state, first.state)
        XCTAssertEqual(reopened.state.effectiveChannelIds, [33, 44])
        XCTAssertTrue(reopened.state.includeArchived)
        XCTAssertTrue(reopened.state.unreadOnly)
        XCTAssertEqual(reopened.state.categories.map(\.title), ["Science", "Music"])
        XCTAssertFalse(reopened.state.isUnread(channelId: 33, messageId: 123))
        let stored = try XCTUnwrap(AyuSettingsStore.shared.userDefaults.string(forKey: "extera.feed.account.\(id).v1"))
        XCTAssertEqual(try JSONDecoder().decode(ExteraFeedSettings.State.self, from: Data(stored.utf8)), first.state)
        XCTAssertEqual(second.state, ExteraFeedSettings.State())
    }

    func testReadCursorIsMonotonicAndChannelSpecific() {
        let settings = self.settings()
        settings.markRead(channelId: 11, messageId: 50)
        settings.markRead(channelId: 11, messageId: 3)
        settings.markRead(channelId: 11, messageId: 0)
        settings.markRead(channelId: 11, messageId: -7)
        XCTAssertFalse(settings.state.isUnread(channelId: 11, messageId: 49))
        XCTAssertFalse(settings.state.isUnread(channelId: 11, messageId: 50))
        XCTAssertTrue(settings.state.isUnread(channelId: 11, messageId: 51))
        XCTAssertTrue(settings.state.isUnread(channelId: 22, messageId: 1))
        XCTAssertEqual(settings.state.readMaxIds, ["11": 50])
    }

    func testHidingOrDeletingSelectedCategoryFallsBackWithoutLosingMainSelection() {
        let settings = self.settings()
        settings.update { state in
            state.channelIds = [1, 2]
            state.categories = [.init(id: "a", title: "Category", channelIds: [3])]
            state.selectedCategoryId = "a"
        }
        XCTAssertEqual(settings.state.effectiveChannelIds, [3])
        settings.update { $0.categories[0].isHidden = true }
        XCTAssertNil(settings.state.selectedCategoryId)
        XCTAssertEqual(settings.state.effectiveChannelIds, [1, 2])
        settings.update {
            $0.categories[0].isHidden = false
            $0.selectedCategoryId = "a"
        }
        settings.markRead(channelId: 3, messageId: 9)
        settings.update { $0.categories.removeAll() }
        XCTAssertNil(settings.state.selectedCategoryId)
        XCTAssertEqual(settings.state.effectiveChannelIds, [1, 2])
        XCTAssertFalse(settings.state.isUnread(channelId: 3, messageId: 9))
    }

    func testCategoryRenameReorderAndSelectionRemainIndependent() {
        let settings = self.settings()
        settings.update {
            $0.channelIds = [10]
            $0.categories = [.init(id: "a", title: "A", channelIds: [20]), .init(id: "b", title: "B", channelIds: [30])]
            $0.selectedCategoryId = "a"
        }
        settings.update {
            $0.categories[0].title = "Renamed"
            $0.categories.swapAt(0, 1)
        }
        XCTAssertEqual(settings.state.categories.map(\.id), ["b", "a"])
        XCTAssertEqual(settings.state.selectedCategory?.title, "Renamed")
        XCTAssertEqual(settings.state.effectiveChannelIds, [20])
        settings.update { $0.selectedCategoryId = "b" }
        XCTAssertEqual(settings.state.effectiveChannelIds, [30])
        settings.update { $0.selectedCategoryId = "missing" }
        XCTAssertNil(settings.state.selectedCategoryId)
        XCTAssertEqual(settings.state.effectiveChannelIds, [10])
    }

    func testEmptyCategoryDoesNotSilentlyUseMainFeed() {
        let settings = self.settings()
        settings.update {
            $0.channelIds = [10]
            $0.categories = [.init(id: "empty", title: "Empty")]
            $0.selectedCategoryId = "empty"
        }
        XCTAssertTrue(settings.state.effectiveChannelIds.isEmpty)
        XCTAssertEqual(settings.state.selectedCategoryId, "empty")
    }

    func testReadCursorIsSharedAcrossCategorySwitches() {
        let settings = self.settings()
        settings.update {
            $0.categories = [.init(id: "a", title: "A", channelIds: [20]), .init(id: "b", title: "B", channelIds: [20, 30])]
            $0.selectedCategoryId = "a"
        }
        settings.markRead(channelId: 20, messageId: 99)
        settings.update { $0.selectedCategoryId = "b" }
        XCTAssertFalse(settings.state.isUnread(channelId: 20, messageId: 99))
        XCTAssertTrue(settings.state.isUnread(channelId: 20, messageId: 100))
        XCTAssertTrue(settings.state.isUnread(channelId: 30, messageId: 1))
    }

    func testPresentationPreferencesPersistWithoutChangingAnyAccountState() {
        let first = self.settings()
        let second = self.settings()
        first.update { $0.channelIds = [1, 2] }
        second.update { $0.channelIds = [3] }
        let firstState = first.state
        let secondState = second.state
        let presentation = ExteraFeedSettings.shared
        defer {
            presentation.widePosts = true
            presentation.showUnreadCounter = true
        }
        presentation.widePosts = false
        presentation.showUnreadCounter = false
        XCTAssertFalse(ExteraFeedSettings.shared.widePosts)
        XCTAssertFalse(ExteraFeedSettings.shared.showUnreadCounter)
        XCTAssertEqual(AyuSettingsStore.shared.userDefaults.object(forKey: "extera.feed.widePosts") as? Bool, false)
        XCTAssertEqual(AyuSettingsStore.shared.userDefaults.object(forKey: "extera.feed.showUnreadCounter") as? Bool, false)
        XCTAssertEqual(first.state, firstState)
        XCTAssertEqual(second.state, secondState)
    }

    func testBulkSelectionPreservesFullRegistryAndCategoryIndependence() {
        let settings = self.settings()
        let ids = Set((1 ... 2500).map(Int64.init))
        settings.update {
            $0.categories = [.init(id: "category", title: "Category", channelIds: [999])]
            $0.setChannelSelection(ids, categoryId: nil)
        }
        XCTAssertEqual(settings.state.channelIds, ids)
        XCTAssertEqual(settings.state.categories[0].channelIds, [999])
        settings.update { $0.setChannelSelection([11, 12], categoryId: "category") }
        XCTAssertEqual(settings.state.channelIds, ids)
        XCTAssertEqual(settings.state.categories[0].channelIds, [11, 12])
        settings.update { $0.setChannelSelection([], categoryId: nil) }
        XCTAssertTrue(settings.state.channelIds.isEmpty)
        XCTAssertEqual(settings.state.categories[0].channelIds, [11, 12])
        settings.update { $0.setChannelSelection([], categoryId: "category") }
        XCTAssertTrue(settings.state.categories[0].channelIds.isEmpty)
    }

    func testBulkSelectionForDeletedCategoryDoesNotFallBackToMainFeed() {
        var state = ExteraFeedSettings.State()
        state.channelIds = [1]
        state.setChannelSelection([2, 3], categoryId: "deleted")
        XCTAssertEqual(state.channelIds, [1])
    }

    func testMarkAllScopeIncludesUnloadedChannelsButExcludesUnavailableAndArchive() {
        var state = ExteraFeedSettings.State()
        state.channelIds = [1, 2, 3, 99]
        XCTAssertEqual(state.markAllReadChannelIds(available: [1, 2, 3, 4], archived: [2]), [1, 3])
        state.includeArchived = true
        XCTAssertEqual(state.markAllReadChannelIds(available: [1, 2, 3, 4], archived: [2]), [1, 2, 3])
        // Scope does not depend on the currently loaded post page.
        state.channelIds = Set((1 ... 80).map(Int64.init))
        XCTAssertEqual(state.markAllReadChannelIds(available: state.channelIds, archived: []).count, 80)
    }

    func testMarkAllScopeUsesCurrentCategoryAndRespectsEmptyCategory() {
        var state = ExteraFeedSettings.State()
        state.channelIds = [1, 2]
        state.categories = [.init(id: "a", title: "A", channelIds: [3, 4]), .init(id: "empty", title: "Empty")]
        state.selectedCategoryId = "a"
        XCTAssertEqual(state.markAllReadChannelIds(available: [1, 2, 3, 4, 5], archived: [4]), [3])
        state.selectedCategoryId = "empty"
        XCTAssertTrue(state.markAllReadChannelIds(available: [1, 2, 3, 4, 5], archived: []).isEmpty)
    }

    func testBatchReadMarksAreMonotonicAndDoNotHideFuturePosts() {
        let settings = self.settings()
        settings.markRead(channelId: 1, messageId: 100)
        settings.update { $0.markRead(maxIds: [1: 50, 2: 10, 3: 0, 4: -1]) }
        XCTAssertEqual(settings.state.readMaxIds, ["1": 100, "2": 10])
        XCTAssertTrue(settings.state.isUnread(channelId: 1, messageId: 101))
        XCTAssertTrue(settings.state.isUnread(channelId: 2, messageId: 11))
        XCTAssertTrue(settings.state.isUnread(channelId: 3, messageId: 1))
    }

    func testConcurrentScreenInstancesDoNotLoseReadAdvancesOrChannelSelections() {
        let id = Int64.random(in: 1 ... Int64.max)
        let first = SharedFeedSettings(ExteraFeedSettings(accountId: id))
        let second = SharedFeedSettings(ExteraFeedSettings(accountId: id))
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let settings = index.isMultiple(of: 2) ? first.value : second.value
            settings.markRead(channelId: 11, messageId: Int32(index + 1))
            settings.update { $0.channelIds.insert(Int64(index + 1)) }
        }
        XCTAssertEqual(first.value.state.readMaxIds["11"], 100)
        XCTAssertEqual(second.value.state.channelIds, Set((1 ... 100).map(Int64.init)))
    }

    func testCorruptStorageFallsBackAndNextChangeRepairsIt() {
        let id = Int64.random(in: 1 ... Int64.max)
        let key = "extera.feed.account.\(id).v1"
        AyuSettingsStore.shared.setString("{broken json", key)
        let settings = ExteraFeedSettings(accountId: id)
        XCTAssertEqual(settings.state, ExteraFeedSettings.State())
        settings.markRead(channelId: 1, messageId: 10)
        XCTAssertFalse(settings.state.isUnread(channelId: 1, messageId: 10))
        XCTAssertNotNil(try? JSONDecoder().decode(ExteraFeedSettings.State.self, from: Data(AyuSettingsStore.shared.string(key).utf8)))
    }

    func testSynchronousObserverCanWaitForStateReadOnAnotherQueue() {
        let settings = SharedFeedSettings(self.settings())
        let acknowledged = DispatchSemaphore(value: 0)
        let observer = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: nil, using: { _ in
            DispatchQueue.global().async {
                XCTAssertEqual(settings.value.state.readMaxIds["11"], 42)
                acknowledged.signal()
            }
            // Reproduces queue-bound notification delivery without hanging the main
            // XCTest queue forever if the setter still owns the feed lock.
            XCTAssertEqual(acknowledged.wait(timeout: .now() + 2.0), .success,
                           "A synchronous notification waited on a reader blocked by the feed settings lock")
        })
        defer { NotificationCenter.default.removeObserver(observer) }
        settings.value.markRead(channelId: 11, messageId: 42)
        XCTAssertEqual(settings.value.state.readMaxIds["11"], 42)
    }

    func testCategoryDragMovesUpDownAndToEndPreservingIdentityAndMembership() {
        let settings = self.settings()
        settings.update {
            $0.categories = [.init(id: "a", title: "A", channelIds: [1]), .init(id: "b", title: "B", channelIds: [2], isHidden: true), .init(id: "c", title: "C", channelIds: [3])]
            $0.selectedCategoryId = "c"
        }
        settings.update { $0.moveCategory(id: "c", before: "a") }
        XCTAssertEqual(settings.state.categories.map(\.id), ["c", "a", "b"])
        settings.update { $0.moveCategory(id: "c", before: "b") }
        XCTAssertEqual(settings.state.categories.map(\.id), ["a", "c", "b"])
        settings.update { $0.moveCategory(id: "c", before: nil) }
        XCTAssertEqual(settings.state.categories.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(settings.state.visibleCategories.map(\.id), ["a", "c"])
        XCTAssertEqual(settings.state.effectiveChannelIds, [3])
        XCTAssertEqual(settings.state.categories[1].channelIds, [2])
        XCTAssertTrue(settings.state.categories[1].isHidden)
    }

    func testStaleCategoryDragDoesNotDropOrDuplicateCategories() {
        var state = ExteraFeedSettings.State()
        state.categories = [.init(id: "a", title: "A"), .init(id: "b", title: "B")]
        let original = state
        state.moveCategory(id: "gone", before: "a")
        state.moveCategory(id: "a", before: "gone")
        state.moveCategory(id: "a", before: "a")
        XCTAssertEqual(state, original)
    }

    func testHiddenCategoryStaysInEditorAtItsPositionAndReappearsInTabs() {
        let settings = self.settings()
        settings.update {
            $0.categories = [.init(id: "a", title: "A"), .init(id: "b", title: "B"), .init(id: "c", title: "C")]
            $0.selectedCategoryId = "b"
        }
        settings.update { $0.categories[1].isHidden = true }
        XCTAssertNil(settings.state.selectedCategoryId)
        XCTAssertEqual(settings.state.visibleCategories.map(\.id), ["a", "c"])
        XCTAssertEqual(settings.state.categories.map(\.id), ["a", "b", "c"])
        settings.update { $0.categories[1].isHidden = false }
        XCTAssertEqual(settings.state.visibleCategories.map(\.id), ["a", "b", "c"])
        XCTAssertNil(settings.state.selectedCategoryId)
    }

    func testFullRegistryQueueLoadsEverySelectedChannelWithBoundedConcurrency() {
        var queue = ExteraFeedHistoryPolicy.RequestQueue()
        let selected = Set((1 ... 2500).map(Int64.init))
        queue.replace(with: selected)
        var active = Set<Int64>()
        var finished = Set<Int64>()
        while finished != selected {
            while let id = queue.next(active: active) {
                XCTAssertTrue(active.insert(id).inserted)
                XCTAssertFalse(finished.contains(id))
                XCTAssertLessThanOrEqual(active.count, 4)
            }
            XCTAssertFalse(active.isEmpty)
            guard let completed = active.min() else { return }
            active.remove(completed)
            finished.insert(completed)
        }
        XCTAssertTrue(queue.isEmpty)
        XCTAssertTrue(active.isEmpty)
    }

    func testCancelledQueueResumesOnceAndSelectionReplacementDropsOldPendingWork() {
        var queue = ExteraFeedHistoryPolicy.RequestQueue()
        queue.replace(with: [1, 2, 3, 4, 5])
        XCTAssertEqual(queue.next(active: []), 1)
        XCTAssertEqual(queue.next(active: [1]), 2)
        queue.resume(cancelled: [1, 2])
        XCTAssertEqual(queue.next(active: []), 1)
        XCTAssertEqual(queue.next(active: [1]), 2)
        queue.replace(with: [99, 100])
        XCTAssertEqual(queue.next(active: []), 99)
        XCTAssertEqual(queue.next(active: [99]), 100)
        XCTAssertNil(queue.next(active: [99, 100]))
        XCTAssertTrue(queue.isEmpty)
    }

    func testTimelineFrontierPreventsOlderPageFromAppearingBeforeOtherChannelsLoad() {
        let oldest: [Int64: Int] = [1: 500, 2: 100, 3: 300]
        XCTAssertEqual(ExteraFeedHistoryPolicy.frontier(oldest: oldest, exhausted: []), 500)
        // Channel 1 has no earlier posts; its last post must not constrain the rest.
        XCTAssertEqual(ExteraFeedHistoryPolicy.frontier(oldest: oldest, exhausted: [1]), 300)
        XCTAssertNil(ExteraFeedHistoryPolicy.frontier(oldest: oldest, exhausted: [1, 2, 3]))
        // Loading another page lowers the frontier without inserting above published rows.
        XCTAssertEqual(ExteraFeedHistoryPolicy.frontier(oldest: [1: 200, 2: 100, 3: 300], exhausted: []), 300)
    }

    static let allTests = [
        ("testFreshAccountHasNoSelectedChannelsOrReadMarks", testFreshAccountHasNoSelectedChannelsOrReadMarks),
        ("testFullStateSurvivesReopeningAndAccountsAreIsolated", testFullStateSurvivesReopeningAndAccountsAreIsolated),
        ("testReadCursorIsMonotonicAndChannelSpecific", testReadCursorIsMonotonicAndChannelSpecific),
        ("testHidingOrDeletingSelectedCategoryFallsBackWithoutLosingMainSelection", testHidingOrDeletingSelectedCategoryFallsBackWithoutLosingMainSelection),
        ("testCategoryRenameReorderAndSelectionRemainIndependent", testCategoryRenameReorderAndSelectionRemainIndependent),
        ("testEmptyCategoryDoesNotSilentlyUseMainFeed", testEmptyCategoryDoesNotSilentlyUseMainFeed),
        ("testReadCursorIsSharedAcrossCategorySwitches", testReadCursorIsSharedAcrossCategorySwitches),
        ("testPresentationPreferencesPersistWithoutChangingAnyAccountState", testPresentationPreferencesPersistWithoutChangingAnyAccountState),
        ("testBulkSelectionPreservesFullRegistryAndCategoryIndependence", testBulkSelectionPreservesFullRegistryAndCategoryIndependence),
        ("testBulkSelectionForDeletedCategoryDoesNotFallBackToMainFeed", testBulkSelectionForDeletedCategoryDoesNotFallBackToMainFeed),
        ("testMarkAllScopeIncludesUnloadedChannelsButExcludesUnavailableAndArchive", testMarkAllScopeIncludesUnloadedChannelsButExcludesUnavailableAndArchive),
        ("testMarkAllScopeUsesCurrentCategoryAndRespectsEmptyCategory", testMarkAllScopeUsesCurrentCategoryAndRespectsEmptyCategory),
        ("testBatchReadMarksAreMonotonicAndDoNotHideFuturePosts", testBatchReadMarksAreMonotonicAndDoNotHideFuturePosts),
        ("testConcurrentScreenInstancesDoNotLoseReadAdvancesOrChannelSelections", testConcurrentScreenInstancesDoNotLoseReadAdvancesOrChannelSelections),
        ("testCorruptStorageFallsBackAndNextChangeRepairsIt", testCorruptStorageFallsBackAndNextChangeRepairsIt),
        ("testSynchronousObserverCanWaitForStateReadOnAnotherQueue", testSynchronousObserverCanWaitForStateReadOnAnotherQueue),
        ("testCategoryDragMovesUpDownAndToEndPreservingIdentityAndMembership", testCategoryDragMovesUpDownAndToEndPreservingIdentityAndMembership),
        ("testStaleCategoryDragDoesNotDropOrDuplicateCategories", testStaleCategoryDragDoesNotDropOrDuplicateCategories),
        ("testHiddenCategoryStaysInEditorAtItsPositionAndReappearsInTabs", testHiddenCategoryStaysInEditorAtItsPositionAndReappearsInTabs),
        ("testFullRegistryQueueLoadsEverySelectedChannelWithBoundedConcurrency", testFullRegistryQueueLoadsEverySelectedChannelWithBoundedConcurrency),
        ("testCancelledQueueResumesOnceAndSelectionReplacementDropsOldPendingWork", testCancelledQueueResumesOnceAndSelectionReplacementDropsOldPendingWork),
        ("testTimelineFrontierPreventsOlderPageFromAppearingBeforeOtherChannelsLoad", testTimelineFrontierPreventsOlderPageFromAppearingBeforeOtherChannelsLoad),
    ]
}

#if !SWIFT_PACKAGE
@main
private enum ExteraFeedSettingsTestRunner {
    static func main() {
        XCTMain([testCase(ExteraFeedSettingsTests.allTests)])
    }
}
#endif
