import AccountContext
import AyuPluginBridge
import Display
import SGSwiftUI
import SwiftUI
import UIKit

private struct AyuPluginManagerScreen: UIViewControllerRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    func makeUIViewController(context: Context) -> AyuPluginManagerViewController {
        let controller = AyuPluginManagerViewController(service: .shared)
        controller.overrideUserInterfaceStyle = self.colorScheme == .dark ? .dark : .light
        return controller
    }

    func updateUIViewController(_ controller: AyuPluginManagerViewController, context: Context) {
        controller.overrideUserInterfaceStyle = self.colorScheme == .dark ? .dark : .light
    }
}

@MainActor
func ayuPluginManagerController(context: AccountContext) -> ViewController {
    return SGSwiftUIController(
        title: "Плагины",
        presentationData: context.sharedContext.currentPresentationData.with { $0 },
        presentationDataSignal: context.sharedContext.presentationData
    ) {
        AyuPluginManagerScreen()
    }
}
