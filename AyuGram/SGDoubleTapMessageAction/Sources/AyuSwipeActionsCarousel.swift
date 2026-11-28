// Ported from exteraGram for Android (com.exteragram.messenger.utils.chats.SwipeActionsHelper: picking one of
// several actions during a swipe), GPL v3 or later, © exteraGram.

import Foundation
import CoreGraphics

// Which of the swipe actions is picked: the message is swiped to the left and, without lifting the finger,
// the finger moves up or down through the list. Distances are in points.
struct AyuSwipeActionsCarousel {
    static let step: CGFloat = 36.0
    static let firstStep: CGFloat = 44.0

    let count: Int
    let looped: Bool
    let reversed: Bool
    // How far the message has to be dragged before vertical movement counts.
    let trigger: CGFloat

    private(set) var selected: Int = 0
    // The carriage's position in steps. It leaves 0 ..< count when a looped list wraps around.
    private(set) var slot: Int = 0
    // True once the finger moves through the list rather than along the swipe.
    private(set) var isScrubbing: Bool = false
    // 1 when the list unfolds below the first action, -1 when above, 0 until chosen.
    private(set) var direction: Int = 0

    private var armed = false
    private var stepped = false
    private var anchorY: CGFloat = 0.0
    private var lastX: CGFloat = 0.0
    private var lastY: CGFloat = 0.0
    private var driftX: CGFloat = 0.0
    private var driftY: CGFloat = 0.0

    init(count: Int, looped: Bool, reversed: Bool, trigger: CGFloat) {
        self.count = count
        self.looped = looped
        self.reversed = reversed
        self.trigger = trigger
    }

    // The list unfolds downwards when it fits below the message's centre or there is more room below than above.
    mutating func chooseDirection(centerY: CGFloat, height: CGFloat) {
        guard self.direction == 0 else {
            return
        }
        let needed = AyuSwipeActionsCarousel.firstStep + CGFloat(self.count - 2) * AyuSwipeActionsCarousel.step
        let below = height - centerY
        self.direction = below >= needed || below >= centerY ? 1 : -1
    }

    // `offsetX` is how far the message is dragged, `x` and `y` where the finger is. Returns true when another
    // action became the picked one.
    mutating func update(offsetX: CGFloat, x: CGFloat, y: CGFloat) -> Bool {
        if self.count < 2 {
            return false
        }
        if abs(offsetX) < self.trigger {
            self.armed = false
            self.isScrubbing = false
            return false
        }
        if !self.armed {
            self.armed = true
            self.lastX = x
            self.lastY = y
            self.driftX = 0.0
            self.driftY = 0.0
            return false
        }
        let movedX = abs(x - self.lastX)
        let movedY = y - self.lastY
        self.lastX = x
        self.lastY = y
        if !self.isScrubbing {
            self.driftX = self.driftX * 0.7 + movedX * 0.3
            self.driftY = self.driftY * 0.7 + abs(movedY) * 0.3
            if self.driftY < 0.5 || self.driftY <= self.driftX * 1.5 {
                return false
            }
            self.isScrubbing = true
            self.anchorY = y
            return false
        }
        let travel = (y - self.anchorY) * (self.direction < 0 ? -1.0 : 1.0) * (self.reversed ? -1.0 : 1.0)
        let threshold = self.stepped ? AyuSwipeActionsCarousel.step : AyuSwipeActionsCarousel.firstStep
        if travel >= threshold {
            self.anchorY = y
            self.stepped = true
            if self.looped || self.selected < self.count - 1 {
                self.move(1)
                return true
            }
        } else if travel <= -threshold {
            self.anchorY = y
            self.stepped = true
            if self.looped || self.selected > 0 {
                self.move(-1)
                return true
            }
        }
        return false
    }

    // Picks an action directly; a looped list turns the shorter way.
    mutating func select(_ index: Int) {
        self.isScrubbing = true
        guard index != self.selected, index >= 0, index < self.count else {
            return
        }
        var delta = index - self.selected
        if self.looped {
            delta = AyuSwipeActionsCarousel.floorMod(delta, self.count)
            if delta > self.count / 2 {
                delta -= self.count
            }
        }
        self.selected = index
        self.slot += delta
    }

    private mutating func move(_ delta: Int) {
        self.slot += delta
        self.selected = AyuSwipeActionsCarousel.floorMod(self.slot, self.count)
    }

    // The action a slot shows.
    func actionIndex(slot: Int) -> Int {
        return AyuSwipeActionsCarousel.floorMod(slot, self.count)
    }

    // The slots drawn while the carriage (the animated `slot`) stands at `carriage`: two on each side.
    func visibleSlots(carriage: CGFloat) -> ClosedRange<Int>? {
        guard self.count > 0 else {
            return nil
        }
        var first = Int((carriage - 2.0).rounded(.up))
        var last = Int((carriage + 2.0).rounded(.down))
        if !self.looped || self.count < 2 {
            first = max(first, 0)
            last = min(last, self.count - 1)
        }
        return first <= last ? first ... last : nil
    }

    // How a bubble `distance` steps away from the carriage is drawn: its scale and the alpha of its content,
    // both to be multiplied by the swipe's own. `live` is 0 ... 1 as the other actions appear (1 for the
    // picked one); `easedLive` is `live` through the ease-out-back curve.
    static func bubble(distance: CGFloat, live: CGFloat, easedLive: CGFloat) -> (scale: CGFloat, alpha: CGFloat)? {
        if distance >= 2.0 {
            return nil
        }
        let positionFactor = max(0.0, 1.0 - distance)
        let alphaFactor = max(positionFactor, (2.0 - distance) * 0.45)
        let alpha = alphaFactor * live
        if alpha <= 0.0 {
            return nil
        }
        return ((0.7 + 0.3 * positionFactor) * (0.85 + 0.15 * easedLive), alpha)
    }

    private static func floorMod(_ value: Int, _ modulus: Int) -> Int {
        let remainder = value % modulus
        return remainder < 0 ? remainder + modulus : remainder
    }
}
