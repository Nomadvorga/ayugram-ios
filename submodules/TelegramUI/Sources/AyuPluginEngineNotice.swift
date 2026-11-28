import AccountContext
import AyuPluginBridge
import Display
import SGSettingsUI
import SwiftSignalKit
import UndoUI

/// Android's `PluginsController.showInstallDialog` with the engine off: the file is not opened;
/// a notice asks to turn the engine on and its button opens the plugins screen.
func presentAyuPluginEngineNotice(context: AccountContext, navigationController: NavigationController?, fileName: String) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    // The name comes from a message; keep it from being read as markup.
    let name = fileName.filter { !"*[]".contains($0) }
    // 2.75 s is Android's `Bulletin.DURATION_LONG`.
    let notice = UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: "Включите **Систему плагинов**, чтобы установить **\(name)**.", timeout: 2.75, customUndoText: "Включить"), elevatedLayout: false, action: { [weak navigationController] action in
        if case .undo = action {
            let _ = Task { @MainActor in
                navigationController?.pushViewController(ayuPluginManagerController(context: context))
            }
        }
        return true
    })
    (navigationController?.topViewController as? ViewController)?.present(notice, in: .current)
}
