/// Shared visibility gate for the persisted sender-mini-avatar preference.
/// Keep chat-specific eligibility supplied by the bubble's native author layout.
public enum ExteraSenderMiniAvatarPolicy {
    public static func shouldShow(
        enabled: Bool,
        isIncoming: Bool,
        isGroupOrChannel: Bool,
        supportsNativeSenderProfiles: Bool,
        hasVisibleAuthorHeader: Bool,
        hasRealAuthor: Bool,
        isPreview: Bool,
        isSidePanelOpen: Bool
    ) -> Bool {
        return enabled
            && isIncoming
            && isGroupOrChannel
            && supportsNativeSenderProfiles
            && hasVisibleAuthorHeader
            && hasRealAuthor
            && !isPreview
            && !isSidePanelOpen
    }
}
