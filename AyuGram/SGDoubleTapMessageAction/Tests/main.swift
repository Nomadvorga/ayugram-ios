// Host check of the swipe actions carousel. Run from the repository root:
// swiftc -warnings-as-errors -o /tmp/ayu-swipe-tests AyuGram/SGDoubleTapMessageAction/Sources/AyuSwipeActionsCarousel.swift AyuGram/SGDoubleTapMessageAction/Tests/main.swift && /tmp/ayu-swipe-tests

import Foundation
import CoreGraphics

var passed = 0
var failed = 0
func check(_ label: String, _ expected: String, _ actual: String) {
    if expected == actual {
        passed += 1
    } else {
        failed += 1
        print("FAILED \(label): expected \(expected), got \(actual)")
    }
}

// Drags the message past the trigger, enters the list, then moves the finger vertically by each of `distances`.
func scrub(_ carousel: inout AyuSwipeActionsCarousel, from start: CGFloat = 300.0, distances: [CGFloat]) -> [Int] {
    var y = start
    var result: [Int] = []
    _ = carousel.update(offsetX: -60.0, x: 100.0, y: y)
    // Vertical drift has to outweigh the horizontal one before the list is entered.
    for _ in 0 ..< 3 {
        y += distances.first.map { $0 > 0.0 ? 2.0 : -2.0 } ?? 2.0
        _ = carousel.update(offsetX: -60.0, x: 100.0, y: y)
    }
    for distance in distances {
        y += distance
        if carousel.update(offsetX: -60.0, x: 100.0, y: y) {
            result.append(carousel.selected)
        }
    }
    return result
}

var carousel = AyuSwipeActionsCarousel(count: 4, looped: false, reversed: false, trigger: 50.0)
carousel.chooseDirection(centerY: 100.0, height: 800.0)
check("unfolds downwards with room below", "1", "\(carousel.direction)")
check("below the trigger nothing is watched", "false false", "\(carousel.update(offsetX: -30.0, x: 100.0, y: 300.0)) \(carousel.isScrubbing)")
func fresh(_ count: Int) -> AyuSwipeActionsCarousel {
    var carousel = AyuSwipeActionsCarousel(count: count, looped: false, reversed: false, trigger: 50.0)
    carousel.chooseDirection(centerY: 100.0, height: 800.0)
    return carousel
}
// Entering the list takes the first 4 points of travel.
var short = fresh(4)
var exact = fresh(4)
check("first step is 44 points, the next ones 36", "[] [1] [1, 2]", "\(scrub(&short, distances: [39.0])) \(scrub(&carousel, distances: [40.0, 35.0])) \(scrub(&exact, distances: [40.0, 35.0, 1.0]))")

carousel = AyuSwipeActionsCarousel(count: 3, looped: false, reversed: false, trigger: 50.0)
carousel.chooseDirection(centerY: 100.0, height: 800.0)
check("stops at the last action", "[1, 2] 2 2", "\(scrub(&carousel, distances: [44.0, 36.0, 36.0, 36.0])) \(carousel.selected) \(carousel.slot)")
check("and comes back", "[1, 0] 0", "\(scrub(&carousel, from: 500.0, distances: [-36.0, -36.0, -36.0])) \(carousel.slot)")

carousel = AyuSwipeActionsCarousel(count: 3, looped: true, reversed: false, trigger: 50.0)
carousel.chooseDirection(centerY: 100.0, height: 800.0)
check("a looped list wraps", "[1, 2, 0, 1] 4", "\(scrub(&carousel, distances: [44.0, 36.0, 36.0, 36.0])) \(carousel.slot)")
check("a looped list shows slots beyond the ends", "2...6 1 0", "\(carousel.visibleSlots(carriage: 4.0).map { "\($0)" } ?? "nil") \(carousel.actionIndex(slot: 4)) \(carousel.actionIndex(slot: -3))")

carousel = AyuSwipeActionsCarousel(count: 3, looped: true, reversed: false, trigger: 50.0)
carousel.chooseDirection(centerY: 100.0, height: 800.0)
check("upwards from the first wraps to the last", "[2] -1", "\(scrub(&carousel, distances: [-44.0])) \(carousel.slot)")

carousel = AyuSwipeActionsCarousel(count: 3, looped: false, reversed: true, trigger: 50.0)
carousel.chooseDirection(centerY: 100.0, height: 800.0)
check("reversed moves the other way", "[] [1]", "\(scrub(&carousel, distances: [44.0, 36.0])) \(scrub(&carousel, from: 500.0, distances: [-36.0]))")

carousel = AyuSwipeActionsCarousel(count: 4, looped: false, reversed: false, trigger: 50.0)
carousel.chooseDirection(centerY: 760.0, height: 800.0)
check("unfolds upwards near the bottom", "-1 [1]", "\(carousel.direction) \(scrub(&carousel, distances: [-44.0]))")
carousel = AyuSwipeActionsCarousel(count: 4, looped: false, reversed: false, trigger: 50.0)
carousel.chooseDirection(centerY: 60.0, height: 150.0)
check("more room below wins when neither side fits", "1", "\(carousel.direction)")
carousel.chooseDirection(centerY: 140.0, height: 150.0)
check("the direction is chosen once", "1", "\(carousel.direction)")

carousel = AyuSwipeActionsCarousel(count: 4, looped: false, reversed: false, trigger: 50.0)
carousel.chooseDirection(centerY: 100.0, height: 800.0)
_ = carousel.update(offsetX: -60.0, x: 100.0, y: 300.0)
var moved = false
for i in 1 ... 20 {
    moved = carousel.update(offsetX: -60.0 - CGFloat(i) * 6.0, x: 100.0 - CGFloat(i) * 6.0, y: 300.0 + CGFloat(i) * 3.0) || moved
}
check("a mostly horizontal drag never enters the list", "false false 0", "\(moved) \(carousel.isScrubbing) \(carousel.selected)")

carousel = AyuSwipeActionsCarousel(count: 1, looped: true, reversed: false, trigger: 50.0)
check("one action has nothing to pick", "[] 0...0", "\(scrub(&carousel, distances: [44.0, 36.0])) \(carousel.visibleSlots(carriage: 0.0).map { "\($0)" } ?? "nil")")

carousel = AyuSwipeActionsCarousel(count: 5, looped: true, reversed: false, trigger: 50.0)
carousel.select(4)
check("select turns a looped list the shorter way", "4 -1 true", "\(carousel.selected) \(carousel.slot) \(carousel.isScrubbing)")
carousel = AyuSwipeActionsCarousel(count: 5, looped: false, reversed: false, trigger: 50.0)
carousel.select(4)
carousel.select(9)
check("select in a plain list", "4 4", "\(carousel.selected) \(carousel.slot)")
check("plain list is clamped to its ends", "0...2 2...4", "\(carousel.visibleSlots(carriage: 0.4).map { "\($0)" } ?? "nil") \(carousel.visibleSlots(carriage: 3.5).map { "\($0)" } ?? "nil")")

func bubble(_ distance: CGFloat, _ live: CGFloat) -> String {
    guard let value = AyuSwipeActionsCarousel.bubble(distance: distance, live: live, easedLive: live) else {
        return "nil"
    }
    return String(format: "%.3f/%.3f", Double(value.scale), Double(value.alpha))
}
check("bubbles shrink and fade with distance", "1.000/1.000 0.850/0.675 0.700/0.450 0.700/0.225 nil nil", "\(bubble(0.0, 1.0)) \(bubble(0.5, 1.0)) \(bubble(1.0, 1.0)) \(bubble(1.5, 1.0)) \(bubble(2.0, 1.0)) \(bubble(1.0, 0.0))")

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
