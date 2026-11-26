import XCTest

final class ExteraSenderMiniAvatarPolicyTests: XCTestCase {
    private func shouldShow(
        enabled: Bool = true,
        group: Bool = true,
        realAuthor: Bool = true,
        messagePreview: Bool = true,
        draft: Bool = false,
        activity: Bool = false,
        specialRow: Bool = false
    ) -> Bool {
        return ExteraSenderMiniAvatarPolicy.shouldShow(
            enabled: enabled,
            isGroup: group,
            hasRealAuthor: realAuthor,
            hasMessagePreview: messagePreview,
            hasDraft: draft,
            hasActivity: activity,
            isSpecialRow: specialRow
        )
    }

    func testGroupChatPreviewShowsLastMessageAuthorAvatar() {
        XCTAssertTrue(shouldShow())
    }

    func testPrivateChatDoesNotShowSenderMiniAvatar() {
        XCTAssertFalse(shouldShow(group: false))
    }

    func testAnonymousAuthorDoesNotShowSenderMiniAvatar() {
        XCTAssertFalse(shouldShow(realAuthor: false))
    }

    func testMissingPreviewDoesNotShowSenderMiniAvatar() {
        XCTAssertFalse(shouldShow(messagePreview: false))
    }

    func testDraftSuppressesSenderMiniAvatar() {
        XCTAssertFalse(shouldShow(draft: true))
    }

    func testTypingActivitySuppressesSenderMiniAvatar() {
        XCTAssertFalse(shouldShow(activity: true))
    }

    func testSpecialRowsDoNotShowSenderMiniAvatar() {
        XCTAssertFalse(shouldShow(specialRow: true))
    }

    func testDisabledSettingLeavesNativeLayoutUnchanged() {
        XCTAssertFalse(shouldShow(enabled: false))
    }

}
