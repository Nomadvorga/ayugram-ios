import XCTest

final class ExteraSenderMiniAvatarPolicyTests: XCTestCase {
    private func shouldShow(
        enabled: Bool = true,
        incoming: Bool = true,
        groupOrChannel: Bool = true,
        nativeSenderProfiles: Bool = true,
        visibleAuthorHeader: Bool = true,
        realAuthor: Bool = true,
        preview: Bool = false,
        sidePanelOpen: Bool = false
    ) -> Bool {
        return ExteraSenderMiniAvatarPolicy.shouldShow(
            enabled: enabled,
            isIncoming: incoming,
            isGroupOrChannel: groupOrChannel,
            supportsNativeSenderProfiles: nativeSenderProfiles,
            hasVisibleAuthorHeader: visibleAuthorHeader,
            hasRealAuthor: realAuthor,
            isPreview: preview,
            isSidePanelOpen: sidePanelOpen
        )
    }

    func testIncomingGroupWithVisibleSenderHeaderShowsMiniAvatar() {
        XCTAssertTrue(shouldShow())
    }

    func testIncomingChannelProfileHeaderShowsMiniAvatar() {
        XCTAssertTrue(shouldShow(groupOrChannel: true))
    }

    func testPrivateChatKeepsNativeAvatarRules() {
        XCTAssertFalse(shouldShow(groupOrChannel: false))
    }

    func testChannelWithoutNativeSenderHeaderDoesNotInventAnAvatar() {
        XCTAssertFalse(shouldShow(visibleAuthorHeader: false))
    }

    func testBroadcastChannelWithoutProfilesKeepsNativeChannelPostLayout() {
        XCTAssertFalse(shouldShow(nativeSenderProfiles: false))
    }

    func testMergedOrHiddenHeaderDoesNotGetAnOrphanAvatar() {
        XCTAssertFalse(shouldShow(visibleAuthorHeader: false))
    }

    func testAnonymousOrSignatureOnlyAuthorDoesNotGetAnAvatar() {
        XCTAssertFalse(shouldShow(realAuthor: false))
    }

    func testAnonymousAdminUsingTheChatPeerDoesNotGetAnAvatar() {
        XCTAssertFalse(shouldShow(realAuthor: false))
    }

    func testOutgoingMessageKeepsNativeAvatarRules() {
        XCTAssertFalse(shouldShow(incoming: false))
    }

    func testDisabledSettingLeavesNativeLayoutUnchanged() {
        XCTAssertFalse(shouldShow(enabled: false))
    }

    func testPreviewAndSidePanelKeepTheirExistingLayout() {
        XCTAssertFalse(shouldShow(preview: true))
        XCTAssertFalse(shouldShow(sidePanelOpen: true))
    }
}
