import UIKit

/// Preserve an independent Search action when the placeholder also contains an adjustable widget.
final class ExteraPillSearchAccessibilityElement: UIAccessibilityElement {
    var activate: (() -> Void)?
    override func accessibilityActivate() -> Bool { self.activate?(); return true }
}
