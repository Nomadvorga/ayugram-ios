import AccountContext
import AyuPluginBridge
import Display
import SGSwiftUI
import SwiftUI
import UIKit

private struct AyuPluginManagerScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AyuPluginManagerViewController {
        return AyuPluginManagerViewController(service: .shared)
    }

    func updateUIViewController(_ controller: AyuPluginManagerViewController, context: Context) {
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
