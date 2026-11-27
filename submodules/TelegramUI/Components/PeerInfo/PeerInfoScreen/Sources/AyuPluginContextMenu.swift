import AyuPluginBridge
import ContextUI
import Display
import Foundation
import SwiftSignalKit
import TelegramPresentationData
import UIKit

/// The context menu a plugin request belongs to. The controller is assigned
/// once it exists; plugin rows are added only while it is on screen.
public final class AyuPluginContextMenuHandle {
    public weak var controller: ContextController?

    public init() {}

    @MainActor public var isPresented: Bool {
        guard let controller = self.controller, controller.isViewLoaded else { return false }
        return controller.view.window != nil
    }
}

/// Rows that plugins registered with `add_menu_item`, for the app's context menus.
public enum AyuPluginContextMenu {
    /// The native rows are published at once and unchanged. Plugin rows follow
    /// as a second value when the bridge has them: Telegram's cache and Python
    /// conditions are awaited off the menu, which never waits for them.
    public static func appending(to signal: Signal<ContextController.Items, NoError>, request: AyuPluginMenuRequest, isPresented: @escaping @MainActor () -> Bool) -> Signal<ContextController.Items, NoError> {
        return signal |> mapToSignal { items in
            return Signal<ContextController.Items, NoError> { subscriber in
                subscriber.putNext(items)
                let task = Task { @MainActor in
                    let session = await AyuPluginMenuBridge.shared.open(request, isPresented: isPresented)
                    if !Task.isCancelled, !session.entries.isEmpty, case var .list(existing) = items.content {
                        if !existing.isEmpty { existing.append(.separator) }
                        existing.append(contentsOf: session.entries.map { entry in AyuPluginContextMenu.item(entry, session: session) })
                        var updated = items
                        updated.content = .list(existing)
                        subscriber.putNext(updated)
                    }
                    subscriber.putCompletion()
                }
                return ActionDisposable { task.cancel() }
            }
        }
    }

    public static func appending(to signal: Signal<ContextController.Items, NoError>, request: AyuPluginMenuRequest, menu: AyuPluginContextMenuHandle) -> Signal<ContextController.Items, NoError> {
        return self.appending(to: signal, request: request, isPresented: { menu.isPresented })
    }

    private static func item(_ entry: AyuPluginMenuEntry, session: AyuPluginMenuSession) -> ContextMenuItem {
        var longPress: ((ContextControllerProtocol?, @escaping (ContextMenuActionResult) -> Void) -> Void)?
        if entry.hasLongClick {
            longPress = { _, dismiss in
                dismiss(.dismissWithoutContent)
                session.activate(entry, longClick: true)
            }
        }
        return .action(ContextMenuActionItem(id: entry.identifier, text: entry.text, textLayout: entry.subtext.map { .secondLineWithValue($0) } ?? .twoLinesMax, icon: { theme in
            return entry.icon?.image(color: theme.contextMenu.primaryColor)
        }, action: { _, dismiss in
            dismiss(.dismissWithoutContent)
            session.activate(entry)
        }, longPressAction: longPress))
    }
}
