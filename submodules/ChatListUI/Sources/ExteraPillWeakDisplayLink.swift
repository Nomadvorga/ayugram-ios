import UIKit

final class ExteraPillWeakDisplayLink: NSObject {
    weak var target: NSObject?
    let selector: Selector
    init(target: NSObject, selector: Selector) { self.target = target; self.selector = selector }
    @objc func tick(_ link: CADisplayLink) {
        guard let target else { link.invalidate(); return }
        _ = target.perform(self.selector)
    }
}
