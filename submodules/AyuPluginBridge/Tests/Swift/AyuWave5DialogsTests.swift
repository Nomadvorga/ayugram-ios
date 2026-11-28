import XCTest
import UIKit
@testable import AyuPluginBridge

/// The runner has no window, so these drive the progress dialog up to its presentation.
@MainActor final class AyuWave5DialogsTests: XCTestCase {
    func testSpinnerDialogDrawsOnlyTheSpinnerAndReportsEveryTouch() {
        var touches = 0
        let dialog = AyuPluginProgressDialogController(spinner: true, title: nil, message: nil, progress: 0, cancelable: false, buttons: [])
        dialog.onTouch = { touches += 1 }
        dialog.loadViewIfNeeded()
        XCTAssertEqual(dialog.modalPresentationStyle, .overFullScreen)
        XCTAssertTrue(dialog.indicator.isAnimating)
        XCTAssertTrue(dialog.indicator.isDescendant(of: dialog.box))
        XCTAssertFalse(dialog.bar.isDescendant(of: dialog.view))
        XCTAssertEqual(dialog.view.backgroundColor, .clear)
        dialog.touched(inside: true); dialog.touched(inside: false)
        XCTAssertEqual(touches, 2)
    }

    func testLoadingDialogShowsProgressButtonsAndCancelsOutsideOnlyWhileCancelable() {
        var touches = 0, pressed: [String] = []
        let dialog = AyuPluginProgressDialogController(spinner: false, title: "Download", message: "file.bin", progress: 25, cancelable: true,
                                                       buttons: [.init(title: "Stop") { pressed.append("stop") }, .init(title: "Hide") { pressed.append("hide") }])
        dialog.onTouch = { touches += 1 }
        dialog.loadViewIfNeeded()
        XCTAssertFalse(dialog.indicator.isDescendant(of: dialog.view))
        XCTAssertTrue(dialog.bar.isDescendant(of: dialog.box))
        XCTAssertEqual(dialog.percent.text, "25%")
        XCTAssertEqual(dialog.bar.progress, 0.25, accuracy: 0.001)
        dialog.setProgress(140)
        XCTAssertEqual(dialog.percent.text, "140%")
        XCTAssertEqual(dialog.bar.progress, 1, accuracy: 0.001)
        XCTAssertEqual(dialog.progress, 140)
        let labels = Self.views(in: dialog.box).compactMap { ($0 as? UILabel)?.text }
        XCTAssertTrue(labels.contains("Download") && labels.contains("file.bin"))
        let buttons = Self.views(in: dialog.box).compactMap { $0 as? UIButton }
        XCTAssertEqual(buttons.map { $0.title(for: .normal) }, ["Stop", "Hide"])
        dialog.pressed(buttons[1])
        XCTAssertEqual(pressed, ["hide"])
        dialog.touched(inside: true)
        XCTAssertEqual(touches, 0)
        dialog.touched(inside: false)
        XCTAssertEqual(touches, 1)
        dialog.cancelable = false
        dialog.touched(inside: false)
        XCTAssertEqual(touches, 1)
    }

    private static func views(in view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + self.views(in: $0) }
    }
}
