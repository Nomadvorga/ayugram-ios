import XCTest
@testable import AyuPluginBridge

@MainActor final class AyuWave6DialogTests: XCTestCase {
    func testIndeterminateDialogShowsSpinnerBesideAMessageThatChanges() {
        var pressed = 0
        let dialog = AyuPluginProgressDialogController(spinner: false, indeterminate: true, title: nil, message: "Scanning...", progress: 0,
                                                       cancelable: false, buttons: [.init(title: "Stop") { pressed += 1 }])
        dialog.loadViewIfNeeded()
        XCTAssertTrue(dialog.isIndeterminate)
        XCTAssertFalse(dialog.isSpinner)
        XCTAssertTrue(dialog.indicator.isDescendant(of: dialog.box))
        XCTAssertTrue(dialog.indicator.isAnimating)
        XCTAssertTrue(dialog.messageLabel.isDescendant(of: dialog.box))
        XCTAssertTrue(dialog.messageLabel.superview === dialog.indicator.superview)
        XCTAssertFalse(dialog.bar.isDescendant(of: dialog.view))
        XCTAssertFalse(dialog.percent.isDescendant(of: dialog.view))
        XCTAssertEqual(dialog.messageLabel.text, "Scanning...")
        dialog.setMessage("Scanned: 5\nFound: 1")
        XCTAssertEqual(dialog.messageLabel.text, "Scanned: 5\nFound: 1")
        XCTAssertEqual(dialog.messageLabel.numberOfLines, 0)
        dialog.setMessage(nil)
        XCTAssertNil(dialog.messageLabel.text)
    }

    func testMessageSetBeforeTheViewLoadsIsShown() {
        let dialog = AyuPluginProgressDialogController(spinner: false, indeterminate: true, title: "Title", message: nil, progress: 0,
                                                       cancelable: true, buttons: [])
        dialog.setMessage("late")
        dialog.loadViewIfNeeded()
        XCTAssertEqual(dialog.messageLabel.text, "late")
    }
}
