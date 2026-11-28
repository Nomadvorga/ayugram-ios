import Foundation
import UIKit
import SGSimpleSettings
import ChatListHeaderComponent

// exteraGram "Hide Search Bar": the chat lists' headers have no search field; search opens from a header button.
enum AyuChatListSearchBar {
    // Read once: the lists set up their scroll geometry with it, so a change applies on the next launch.
    static let isHidden: Bool = ExteraSettings.shared.hideDialogsSearchBar

    // How far a chat list scrolls before its header stops collapsing: the search field's height, or nothing without one.
    static var scrollHeight: CGFloat {
        return self.isHidden ? 0.0 : ChatListNavigationBar.searchScrollHeight
    }
}
