/// The sender avatar belongs to the last-message preview in a group chat-list row.
public enum ExteraSenderMiniAvatarPolicy {
    public static func shouldShow(
        enabled: Bool,
        isGroup: Bool,
        hasRealAuthor: Bool,
        hasMessagePreview: Bool,
        hasDraft: Bool,
        hasActivity: Bool,
        isSpecialRow: Bool
    ) -> Bool {
        return enabled
            && isGroup
            && hasRealAuthor
            && hasMessagePreview
            && !hasDraft
            && !hasActivity
            && !isSpecialRow
    }
}
