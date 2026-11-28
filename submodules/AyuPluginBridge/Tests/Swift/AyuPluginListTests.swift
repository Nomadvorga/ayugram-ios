import Foundation
import UIKit
import XCTest
@testable import AyuPluginBridge

/// The plugin list after exteraGram's `PluginsActivity`: order, search, pins, the card and the
/// screen's rows. The screen tests use the real service with imported, never enabled, plugins.
@MainActor
final class AyuPluginListTests: XCTestCase {
    private func plugin(_ id: String, _ name: String, native: Bool = false, enabled: Bool = false, blockers: [String] = [], error: String? = nil,
                        busy: Bool = false, author: String? = nil, description: String? = nil, requirements: [String]? = nil, icon: String? = nil) -> AyuInstalledPlugin {
        AyuInstalledPlugin(id: id, name: name, version: "1.2", blockers: blockers, isEnabled: enabled, isBusy: busy, error: error,
                           nativeAdapter: native ? "adapter" : nil, author: author, description: description, requirements: requirements, icon: icon)
    }

    private func iconView(in view: UIView) -> UIImageView? {
        if let image = view as? UIImageView, image.accessibilityIdentifier == AyuPluginCell.iconIdentifier { return image }
        for subview in view.subviews { if let found = self.iconView(in: subview) { return found } }
        return nil
    }

    private func view(_ identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for subview in view.subviews { if let found = self.view(identifier, in: subview) { return found } }
        return nil
    }

    private func picture(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
    }

    /// With the plugin engine on; Android's default, and a bare suite's, is off.
    private func defaults(engine: Bool = true) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "AyuPluginListTests." + UUID().uuidString)!
        if engine { defaults.set(true, forKey: AyuPluginManagerViewController.engineKey) }
        return defaults
    }

    private func control(_ label: String, in view: UIView) -> UIControl? {
        if let control = view as? UIControl, control.accessibilityLabel == label { return control }
        for subview in view.subviews { if let found = self.control(label, in: subview) { return found } }
        return nil
    }

    /// `sendActions(for:)` goes through `UIApplication`, which a test bundle does not have.
    private func press(_ control: UIControl, for event: UIControl.Event = .touchUpInside) {
        for target in control.allTargets {
            for action in control.actions(forTarget: target, forControlEvent: event) ?? [] {
                _ = (target as AnyObject).perform(Selector(action), with: control)
            }
        }
    }

    private func height(_ cell: UITableViewCell, width: CGFloat = 360) -> CGFloat {
        cell.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
    }

    func testPinnedPluginsComeFirstAndEachGroupIsOrderedByName() {
        let plugins = [self.plugin("c", "Charlie"), self.plugin("a", "alpha"), self.plugin("b2", "Bravo"), self.plugin("b1", "Bravo"), self.plugin("z", "Zulu")]
        XCTAssertEqual(AyuPluginListOrder.arrange(plugins, pinned: []).map(\.id), ["b1", "b2", "c", "z", "a"])
        XCTAssertEqual(AyuPluginListOrder.arrange(plugins, pinned: ["z", "a", "absent"]).map(\.id), ["z", "a", "b1", "b2", "c"])
    }

    func testSearchKeepsNamesContainingTheQueryIgnoringCase() {
        let plugins = [self.plugin("a", "Night Mode"), self.plugin("b", "Translator"), self.plugin("c", "Ночной режим")]
        XCTAssertEqual(AyuPluginListOrder.arrange(plugins, pinned: [], query: "MODE").map(\.id), ["a"])
        XCTAssertEqual(AyuPluginListOrder.arrange(plugins, pinned: [], query: "ноч").map(\.id), ["c"])
        XCTAssertEqual(AyuPluginListOrder.arrange(plugins, pinned: ["b"], query: "").map(\.id), ["b", "a", "c"])
        XCTAssertEqual(AyuPluginListOrder.arrange(plugins, pinned: [], query: "a").map(\.id), ["b"], "the id is not searched")
        XCTAssertEqual(AyuPluginListOrder.arrange(plugins, pinned: [], query: "absent").count, 0)
    }

    func testPinsPersistAndAreBounded() {
        let defaults = self.defaults()
        let pins = AyuPluginPins(defaults: defaults)
        XCTAssertTrue(pins.toggle("alpha"))
        XCTAssertTrue(pins.toggle("beta"))
        XCTAssertFalse(pins.toggle("alpha"))
        XCTAssertEqual(AyuPluginPins(defaults: defaults).ids, ["beta"])
        XCTAssertFalse(pins.toggle("beta"))
        XCTAssertNil(defaults.object(forKey: AyuPluginPins.key))

        for index in 0..<AyuPluginCapacity.maximumInstalledPlugins { pins.toggle("p\(index)") }
        XCTAssertFalse(pins.toggle("one_more"), "a full table refuses a pin")
        XCTAssertEqual(pins.ids.count, AyuPluginCapacity.maximumInstalledPlugins)
        XCTAssertFalse(pins.toggle("p0"), "and still releases one")
    }

    func testCardTextFollowsThePluginState() {
        XCTAssertEqual(AyuPluginCell.subtitle(for: self.plugin("a", "A", author: " @author ")), "Версия 1.2 • @author")
        XCTAssertEqual(AyuPluginCell.subtitle(for: self.plugin("a", "A")), "Версия 1.2")
        XCTAssertEqual(AyuPluginCell.subtitle(for: self.plugin("a", "A", author: "@author"), compact: true), "v1.2 • @author")
        XCTAssertNil(AyuPluginCell.statusNote(for: self.plugin("a", "A")))
        XCTAssertNil(AyuPluginCell.statusNote(for: self.plugin("a", "A", enabled: true, blockers: ["x"])))
        XCTAssertEqual(AyuPluginCell.statusNote(for: self.plugin("a", "A", blockers: ["x", "y"])), "Не поддерживается этой сборкой · ограничений: 2")
        XCTAssertEqual(AyuPluginCell.statusNote(for: self.plugin("a", "A", busy: true)), "Выполняется операция…")
        XCTAssertTrue(AyuPluginCell.showsSwitch(for: self.plugin("a", "A")))
        XCTAssertTrue(AyuPluginCell.showsSwitch(for: self.plugin("a", "A", enabled: true, blockers: ["x"])), "an enabled plugin can always be switched off")
        XCTAssertFalse(AyuPluginCell.showsSwitch(for: self.plugin("a", "A", blockers: ["x"])))
    }

    func testCardReportsThePressedControlAndNothingElse() throws {
        let cell = AyuPluginCell(style: .default, reuseIdentifier: nil)
        var actions: [AyuPluginCell.Action] = []
        cell.onAction = { actions.append($0) }
        cell.configure(self.plugin("a", "Alpha", enabled: true), pinned: false)
        for label in ["Alpha", "Поделиться", "Открыть в…", "Закрепить", "Настройки плагина", "Удалить плагин"] {
            let control = try XCTUnwrap(self.control(label, in: cell.contentView), label)
            XCTAssertTrue(control.isEnabled && control.isUserInteractionEnabled && !control.isHidden, label)
            self.press(control)
        }
        XCTAssertEqual(actions, [.toggle, .share, .openIn, .pin, .settings, .delete])
        XCTAssertEqual(self.control("Alpha", in: cell.contentView)?.accessibilityValue, "включён")
        // Android's order: share, open in, pin, settings.
        cell.contentView.frame = CGRect(x: 0, y: 0, width: 360, height: self.height(cell))
        cell.contentView.layoutIfNeeded()
        let left = try ["Поделиться", "Открыть в…", "Закрепить", "Настройки плагина"].map { try XCTUnwrap(self.control($0, in: cell.contentView)).frame.minX }
        XCTAssertEqual(left, [0, 48, 96, 144])

        // A disabled plugin has no settings; a pinned one offers to unpin.
        cell.configure(self.plugin("a", "Alpha"), pinned: true)
        XCTAssertEqual(self.control("Настройки плагина", in: cell.contentView)?.isHidden, true)
        XCTAssertNotNil(self.control("Открепить", in: cell.contentView))
        XCTAssertNil(self.control("Закрепить", in: cell.contentView))
        XCTAssertEqual(self.control("Alpha", in: cell.contentView)?.accessibilityValue, "выключен")

        // Unsupported: no switch to press. Busy, a running batch and the batch selection: nothing to press.
        cell.configure(self.plugin("a", "Alpha", blockers: ["x"]), pinned: false)
        XCTAssertEqual(self.control("Alpha", in: cell.contentView)?.isHidden, true)
        let states: [(AyuInstalledPlugin, Bool?, Bool)] = [(self.plugin("a", "Alpha", busy: true), nil, false), (self.plugin("a", "Alpha"), nil, true), (self.plugin("a", "Alpha"), false, false)]
        for (plugin, selected, locked) in states {
            cell.configure(plugin, pinned: false, selected: selected, locked: locked)
            XCTAssertEqual(self.control("Alpha", in: cell.contentView)?.isUserInteractionEnabled, false)
            for label in ["Поделиться", "Открыть в…", "Закрепить", "Удалить плагин"] { XCTAssertEqual(self.control(label, in: cell.contentView)?.isEnabled, false, label) }
        }
        XCTAssertEqual(self.control("Alpha", in: cell.contentView)?.accessibilityValue, "не выбран")
    }

    func testCardGrowsWithItsDescriptionErrorAndWrappedChips() {
        let cell = AyuPluginCell(style: .default, reuseIdentifier: nil)
        cell.configure(self.plugin("a", "Alpha"), pinned: false)
        let bare = self.height(cell)
        XCTAssertGreaterThan(bare, 100)
        cell.configure(self.plugin("a", "Alpha", description: "One line"), pinned: false)
        let described = self.height(cell)
        XCTAssertGreaterThan(described, bare)
        cell.configure(self.plugin("a", "Alpha", description: "One line", requirements: ["requests"]), pinned: false)
        let oneChip = self.height(cell)
        XCTAssertGreaterThan(oneChip, described)
        cell.configure(self.plugin("a", "Alpha", description: "One line", requirements: (0..<12).map { "requirement-number-\($0)" }), pinned: false)
        XCTAssertGreaterThan(self.height(cell), oneChip + 40, "twelve chips wrap over several rows")
        XCTAssertGreaterThan(self.height(cell, width: 280), self.height(cell, width: 600), "a narrower card wraps more")
        cell.configure(self.plugin("a", "Alpha", error: String(repeating: "Traceback line. ", count: 20), description: "One line"), pinned: false)
        XCTAssertGreaterThan(self.height(cell), described, "the error replaces the description")

        let chips = AyuPluginChipsView()
        chips.set((0..<40).map { "chip\($0)" } + [""])
        XCTAssertEqual(chips.subviews.count, 16)
        chips.set([])
        XCTAssertTrue(chips.isEmpty)
        XCTAssertEqual(chips.height(forWidth: 300), 0)
    }

    func testIconReferenceFollowsTheAndroidPattern() {
        let valid = AyuPluginIconReference("exteraPlugins/12")
        XCTAssertEqual(valid?.pack, "exteraPlugins")
        XCTAssertEqual(valid?.index, 12)
        XCTAssertEqual(AyuPluginIconReference("a_1/0")?.index, 0)
        XCTAssertEqual(AyuPluginIconReference("Pack/007")?.index, 7)
        for invalid in [nil, "", "Pack", "Pack/", "/3", "1pack/3", "_pack/3", "Pack/x", "Pack/-1", "Pack/3/4", "Pa ck/3", "Pack/3 ", "Пак/3", "Pack/٣", "Pack/1234567890"] {
            XCTAssertNil(AyuPluginIconReference(invalid), invalid ?? "nil")
        }
    }

    func testCardShowsTheIconAboveTheNameOrBesideItWhenCompact() throws {
        let cell = AyuPluginCell(style: .default, reuseIdentifier: nil)
        let plugin = self.plugin("a", "Alpha", author: "@author", icon: "Pack/1")
        let icon = try XCTUnwrap(self.iconView(in: cell.contentView))
        func layout() -> CGFloat {
            let height = self.height(cell)
            cell.frame = CGRect(x: 0, y: 0, width: 360, height: height)
            cell.layoutIfNeeded()
            return height
        }
        func frame(_ view: UIView) -> CGRect { view.convert(view.bounds, to: cell.contentView) }
        func labels(_ view: UIView) -> [UILabel] { ((view as? UILabel).map { [$0] } ?? []) + view.subviews.flatMap(labels) }

        cell.configure(plugin, pinned: false)
        let name = try XCTUnwrap(labels(cell.contentView).first)
        let subtitle = try XCTUnwrap(labels(cell.contentView).dropFirst().first)
        let toggle = try XCTUnwrap(self.control("Alpha", in: cell.contentView))
        let bare = layout()
        XCTAssertTrue(icon.isHidden, "no icon is handed in")
        XCTAssertLessThanOrEqual(frame(name).maxX, frame(toggle).minX, "the name keeps clear of the switch")

        // The slot is there before the picture, so the picture never moves the card.
        cell.configure(plugin, pinned: false, icon: .pending)
        XCTAssertEqual(layout(), bare + 56 + 12, accuracy: 0.5)
        XCTAssertFalse(icon.isHidden)
        XCTAssertNil(icon.image)
        XCTAssertEqual(frame(icon).size, CGSize(width: 56, height: 56))
        XCTAssertEqual(frame(icon).minX, 16)
        XCTAssertGreaterThanOrEqual(frame(name).minY, frame(icon).maxY + 12)
        XCTAssertEqual(frame(toggle).minY, frame(icon).minY, "the switch is beside the icon")
        let image = self.picture(.systemTeal)
        cell.configure(plugin, pinned: false, icon: .image(image))
        XCTAssertEqual(layout(), bare + 56 + 12, accuracy: 0.5)
        XCTAssertTrue(icon.image === image)

        // A player lies in the slot, one per card; once it draws, the still picture leaves.
        var started: [@MainActor () -> Void] = []
        let moving = UIView()
        let player: AyuPluginCell.IconPlayer = { started.append($0); return moving }
        cell.configure(plugin, pinned: false, icon: .image(image, player: player))
        _ = layout()
        XCTAssertTrue(moving.superview === icon)
        XCTAssertEqual(moving.frame, icon.bounds)
        XCTAssertTrue(icon.image === image, "the still picture stays until the player draws")
        started.first?()
        XCTAssertNil(icon.image)
        cell.configure(plugin, pinned: true, icon: .image(image, player: player))
        XCTAssertNil(icon.image, "configuring again does not bring the still picture back")
        XCTAssertEqual(started.count, 1, "and keeps the player")
        cell.configure(plugin, pinned: false, compact: true, icon: .image(image, player: player))
        _ = layout()
        XCTAssertEqual(moving.frame.size, CGSize(width: 49, height: 49))
        cell.configure(plugin, pinned: false, icon: .image(image))
        XCTAssertNil(moving.superview, "a picture without a player is still")
        XCTAssertTrue(icon.image === image)
        cell.configure(plugin, pinned: false, icon: .image(image, player: player))
        cell.prepareForReuse()
        XCTAssertNil(moving.superview, "a reused card stops playing")
        started.last?()
        cell.configure(plugin, pinned: false, icon: .image(image))
        XCTAssertTrue(icon.image === image, "a late start of a removed player changes nothing")

        // A long name has the whole width under the icon, and three lines of it.
        let long = self.plugin("a", String(repeating: "Long plugin name ", count: 8), icon: "Pack/1")
        cell.configure(long, pinned: false, icon: .image(image))
        _ = layout()
        XCTAssertGreaterThan(frame(name).maxX, frame(toggle).minX)
        XCTAssertGreaterThan(frame(name).height, 2.5 * name.font.lineHeight)
        XCTAssertLessThanOrEqual(frame(name).maxX, 360 - 16)

        // Compact: 49 pt on the left, the text beside it and clear of the switch, the card no taller.
        cell.configure(plugin, pinned: false, compact: true)
        let compactBare = layout()
        cell.configure(long, pinned: false, compact: true, icon: .image(image))
        let compact = layout()
        XCTAssertEqual(frame(icon).size, CGSize(width: 49, height: 49))
        XCTAssertEqual(frame(name).minX, frame(icon).maxX + 16, accuracy: 0.5)
        XCTAssertEqual((frame(name).minY + frame(subtitle).maxY) / 2, frame(icon).midY, accuracy: 1, "the text is centred on the icon")
        XCTAssertLessThanOrEqual(frame(name).maxX, frame(toggle).minX)
        XCTAssertLessThan(frame(name).height, 1.5 * name.font.lineHeight)
        XCTAssertTrue((0...12).contains(compact - compactBare), "\(compact) against \(compactBare)")

        // A reused card drops the picture of the plugin it showed before.
        cell.prepareForReuse()
        cell.configure(self.plugin("b", "Bravo", icon: "Pack/2"), pinned: false, icon: .pending)
        XCTAssertNil(icon.image)
        cell.configure(self.plugin("b", "Bravo"), pinned: false)
        XCTAssertTrue(icon.isHidden)
    }

    func testFailedSwitchIsABulletinWithTheReasonAndACopyButton() throws {
        func texts(_ view: UIView) -> [String] { ((view as? UILabel)?.text.map { [$0] } ?? []) + view.subviews.flatMap(texts) }
        func button(_ view: UIView) -> UIButton? { (view as? UIButton) ?? view.subviews.lazy.compactMap(button).first }

        let notice = AyuPluginAlerts.toggleFailure(self.plugin("a", "Alpha"), enabling: true, AyuPluginService.Failure.busy)
        XCTAssertEqual(notice.title, "Не удалось включить «Alpha».")
        XCTAssertEqual(notice.detail, AyuPluginAlerts.message(AyuPluginService.Failure.busy))
        XCTAssertEqual(AyuPluginAlerts.toggleFailure(self.plugin("a", "Alpha"), enabling: false, AyuPluginService.Failure.busy).title, "Не удалось выключить «Alpha».")

        var copies = 0
        let bulletin = AyuPluginBulletinView(text: notice.title, detail: notice.detail, actionTitle: "Копировать") { copies += 1 }
        XCTAssertEqual(Array(texts(bulletin).prefix(2)), [notice.title, notice.detail])
        let copy = try XCTUnwrap(button(bulletin))
        XCTAssertEqual(copy.title(for: .normal), "Копировать")
        self.press(copy)
        XCTAssertEqual(copies, 1)
        XCTAssertTrue(bulletin.isUserInteractionEnabled)
        XCTAssertGreaterThan(bulletin.duration, 3)

        // A plain notice has nothing to press and leaves sooner.
        let plain = AyuPluginBulletinView(text: "Текст скопирован")
        XCTAssertNil(button(plain))
        XCTAssertFalse(plain.isUserInteractionEnabled)
        XCTAssertLessThan(plain.duration, bulletin.duration)
        XCTAssertGreaterThan(bulletin.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height, plain.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height)
    }

    func testCodeIsReadInTheAppOnlyWhenItIsTextOfAtMost512KiB() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AyuPluginListTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var count = 0
        func text(_ data: Data) throws -> String? {
            count += 1
            let url = directory.appendingPathComponent("\(count).plugin")
            try data.write(to: url)
            return AyuPluginSourceViewer.text(at: url)
        }
        XCTAssertEqual(try text(Data("print('привет')\n".utf8)), "print('привет')\n")
        XCTAssertNil(try text(Data()), "an empty file is not text for Android")
        XCTAssertNil(try text(Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00])), "a package")
        XCTAssertEqual(try text(Data(repeating: 0x61, count: 512 * 1024))?.count, 512 * 1024)
        XCTAssertNil(try text(Data(repeating: 0x61, count: 512 * 1024 + 1)))
        XCTAssertNotNil(try text(Data(repeating: 0x61, count: 8192) + Data([0])), "only the first 8192 bytes are looked at")
        XCTAssertNil(try text(Data(repeating: 0x61, count: 8191) + Data([0])))
        XCTAssertNil(AyuPluginSourceViewer.text(at: directory))
        XCTAssertNil(AyuPluginSourceViewer.text(at: directory.appendingPathComponent("missing.plugin")))

        let viewer = AyuPluginSourceViewController(fileName: "a.plugin", text: "x = 1\n")
        viewer.loadViewIfNeeded()
        XCTAssertEqual(viewer.title, "a.plugin")
        let page = try XCTUnwrap(viewer.view as? UITextView)
        XCTAssertEqual(page.text, "x = 1\n")
        XCTAssertFalse(page.isEditable)
    }

    func testCodePageIsPlainUntilItsColoursArrive() throws {
        let code = "def f():\n    return 'ж'  # 🙂\n"
        var asked: [(code: String, language: String)] = []
        var answer: (@MainActor ([(range: Range<Int>, argb: UInt32)]) -> Void)?
        var palettes: [[String: UInt32]] = []
        let viewer = AyuPluginSourceViewController(fileName: "a.plugin", text: code) { code, language, palette, completion in
            asked.append((code, language))
            palettes.append(palette)
            answer = completion
        }
        viewer.loadViewIfNeeded()
        let page = try XCTUnwrap(viewer.view as? UITextView)
        XCTAssertEqual(asked.map(\.code), [code])
        XCTAssertEqual(asked.map(\.language), ["python"], "Android reads every plugin file as Python")
        XCTAssertEqual(palettes, [AyuPluginSourceViewer.androidCodeColors(.classic)], "without a theme a light page has Android's default colours")
        func color(at index: Int) -> UIColor? { page.textStorage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor }
        let plain = page.textColor
        XCTAssertEqual(color(at: 0), plain)

        let length = (code as NSString).length
        // Runs outside the text are dropped; the rest are coloured where they are.
        try XCTUnwrap(answer)([(0..<3, 0xFF0077AA), (13..<19, 0xFF669900), (length - 1..<length + 1, 0xFFFF0000), (5..<5, 0xFFFF0000), (-1..<2, 0xFFFF0000)])
        XCTAssertEqual(page.text, code)
        XCTAssertEqual(color(at: 0), UIColor(red: 0, green: 0x77 / 255.0, blue: 0xAA / 255.0, alpha: 1))
        XCTAssertEqual(color(at: 2), color(at: 0))
        XCTAssertEqual(color(at: 3), plain)
        XCTAssertEqual(color(at: 13), UIColor(red: 0x66 / 255.0, green: 0x99 / 255.0, blue: 0, alpha: 1))
        XCTAssertEqual(color(at: length - 1), plain)
        XCTAssertEqual((page.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize, 14, "colours leave the font alone")
    }

    func testBannerColourSpreadsFromTheTouchAsOnAndroid() throws {
        // Centre: the touch at mid-height. Radius: the far side and 40 more.
        let near = AyuPluginRippleView.circle(in: CGSize(width: 390, height: 56), from: 348)
        XCTAssertEqual(near.center, CGPoint(x: 348, y: 28))
        XCTAssertEqual(near.radius, 388)
        XCTAssertEqual(AyuPluginRippleView.circle(in: CGSize(width: 390, height: 56), from: 100).radius, 330)
        XCTAssertEqual(AyuPluginRippleView.duration, 0.24)

        let view = AyuPluginRippleView(color: .red)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 56)
        XCTAssertEqual(view.backgroundColor, .red)
        view.set(.blue, from: nil)
        XCTAssertEqual(view.color, .blue)
        XCTAssertEqual(view.backgroundColor, .blue, "no touch, no ripple")
        XCTAssertEqual(view.layer.sublayers?.count ?? 0, 0)

        view.set(.green, from: 348)
        XCTAssertEqual(view.color, .green)
        XCTAssertEqual(view.backgroundColor, .blue, "the old colour stays under the growing circle")
        let circle = try XCTUnwrap(view.layer.sublayers?.first as? CAShapeLayer)
        XCTAssertEqual(circle.position, CGPoint(x: 348, y: 28))
        XCTAssertEqual(circle.path?.boundingBox, CGRect(x: -388, y: -388, width: 776, height: 776))
        XCTAssertEqual(circle.fillColor, UIColor.green.cgColor)
        let grow = try XCTUnwrap(circle.animation(forKey: "grow") as? CABasicAnimation)
        XCTAssertEqual(grow.duration, 0.24)
        XCTAssertEqual(grow.fromValue as? Int, 0)

        // A second change while the first still grows: the first ends at its colour.
        view.set(.red, from: 348)
        XCTAssertEqual(view.backgroundColor, .green)
        XCTAssertEqual(view.layer.sublayers?.count, 1)
        XCTAssertEqual(view.color, .red)
    }

    // MARK: - The screen

    private func screen(_ stack: AyuEndToEnd, defaults: UserDefaults) async -> AyuPluginManagerViewController {
        let manager = AyuPluginManagerViewController(service: stack.service, defaults: defaults)
        manager.loadViewIfNeeded()
        manager.view.frame = CGRect(x: 0, y: 0, width: 390, height: 1400)
        // Let the screen's own `prepare()` finish, so its reload does not land between two checks.
        try? await Task.sleep(nanoseconds: 100_000_000)
        manager.tableView.layoutIfNeeded()
        return manager
    }

    private func names(_ manager: AyuPluginManagerViewController) -> [String] {
        manager.tableView.reloadData()
        manager.tableView.layoutIfNeeded()
        return [1, 2].flatMap { section in
            (0..<manager.tableView.numberOfRows(inSection: section)).map { row in
                let cell = manager.tableView.dataSource?.tableView(manager.tableView, cellForRowAt: IndexPath(row: row, section: section))
                return (cell as? AyuPluginCell).flatMap { self.title(of: $0) } ?? "<" + (cell.map { String(describing: type(of: $0)) } ?? "nil") + ">"
            }
        }
    }

    private func title(of cell: AyuPluginCell) -> String? {
        func labels(_ view: UIView) -> [UILabel] { ((view as? UILabel).map { [$0] } ?? []) + view.subviews.flatMap(labels) }
        return labels(cell.contentView).first?.text
    }

    private func card(_ name: String, in manager: AyuPluginManagerViewController) -> AyuPluginCell? {
        for section in [1, 2] {
            for row in 0..<manager.tableView.numberOfRows(inSection: section) {
                let cell = manager.tableView.dataSource?.tableView(manager.tableView, cellForRowAt: IndexPath(row: row, section: section)) as? AyuPluginCell
                if let cell, self.title(of: cell) == name { return cell }
            }
        }
        return nil
    }

    /// Writes the screen as a PNG when a directory is given, for a look without a device.
    private func snapshot(_ manager: AyuPluginManagerViewController, _ name: String) async {
        guard let directory = ProcessInfo.processInfo.environment["AYU_PLUGIN_TEST_SNAPSHOT_DIR"] else { return }
        // A table that is still animating an update renders without its background.
        try? await Task.sleep(nanoseconds: 600_000_000)
        manager.tableView.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: manager.view.bounds).image { manager.view.layer.render(in: $0.cgContext) }
        try? image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }

    func testScreenListsCardsSearchesPinsAndNeverEnablesByItself() async throws {
        let stack = try AyuEndToEnd.shared()
        let body = "from base_plugin import BasePlugin\n\n\nclass Listed(BasePlugin):\n    pass\n"
        let fixtures = [("e2e_list_zulu", "__icon__ = \"AyuListPack/2\""), ("e2e_list_alpha", "__requirements__ = [\"requests\", \"pillow>=10\"]"),
                        ("e2e_list_mike", "__icon__ = \"AyuListPack/2\""), ("e2e_list_kilo", "__icon__ = \"AyuListPack/5\""), ("e2e_list_lima", "__icon__ = \"not an icon\"")]
        self.addTeardownBlock { for (id, _) in fixtures { await stack.remove(id) } }
        for (id, extra) in fixtures { try await stack.install(AyuEndToEnd.source(id: id, metadata: extra, body)) }
        let defaults = self.defaults()
        let manager = await self.screen(stack, defaults: defaults)
        let table = try XCTUnwrap(manager.tableView)
        let listed = { self.names(manager).filter { $0.hasPrefix("Synthetic e2e_list_") } }

        XCTAssertEqual(listed(), ["alpha", "kilo", "lima", "mike", "zulu"].map { "Synthetic e2e_list_" + $0 })
        XCTAssertEqual(table.numberOfRows(inSection: 0), 5, "engine switch, import, batch selection, last report, compact view")
        let bar = try XCTUnwrap(table.tableHeaderView as? UISearchBar, "a list with plugins can be searched")
        await self.snapshot(manager, "plugin-list")

        // Icons: none without a provider. With one, a valid `__icon__` gets its slot at once and
        // its picture when the provider answers; the same icon is asked for once.
        func icon(_ name: String) -> UIImageView? { self.card("Synthetic e2e_list_" + name, in: manager).flatMap { self.iconView(in: $0.contentView) } }
        XCTAssertEqual(icon("mike")?.isHidden, true)
        var requests: [(icon: String, answer: @MainActor (UIImage?) -> Void)] = []
        var players: [String] = []
        manager.iconPlayerProvider = { pack, index, _ in players.append(pack + "/\(index)"); return nil }
        manager.iconProvider = { pack, index, answer in requests.append((pack + "/\(index)", answer)) }
        _ = listed()
        table.layoutIfNeeded()
        let onScreen = table.visibleCells.compactMap { $0 as? AyuPluginCell }.first { self.title(of: $0) == "Synthetic e2e_list_mike" }
        let shown = try XCTUnwrap(onScreen.flatMap { self.iconView(in: $0.contentView) }, "the card is on screen")
        XCTAssertFalse(shown.isHidden)
        XCTAssertNil(shown.image)
        XCTAssertEqual(icon("alpha")?.isHidden, true, "no __icon__")
        XCTAssertEqual(icon("lima")?.isHidden, true, "not Pack/N")
        XCTAssertEqual(requests.map(\.icon).sorted(), ["AyuListPack/2", "AyuListPack/5"])
        XCTAssertEqual(players, [], "no player before the still picture")
        let teal = self.picture(.systemTeal)
        requests.first { $0.icon == "AyuListPack/2" }?.answer(teal)
        requests.first { $0.icon == "AyuListPack/5" }?.answer(nil)
        XCTAssertTrue(shown.image === teal, "the card on screen gets the picture in place")
        XCTAssertTrue(icon("zulu")?.image === teal)
        XCTAssertEqual(icon("kilo")?.isHidden, false, "a sticker that never arrives leaves its slot empty, as on Android")
        XCTAssertNil(icon("kilo")?.image)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(Set(players), ["AyuListPack/2"], "only an icon that has its picture is asked for a player")
        await self.snapshot(manager, "plugin-list-icons")

        // The batch state has a row only during a batch: selecting adds it, cancelling removes it.
        manager.tableView(table, didSelectRowAt: IndexPath(row: 2, section: 0))
        XCTAssertEqual(table.numberOfRows(inSection: 0), 6)
        XCTAssertEqual(table.dataSource?.tableView(table, cellForRowAt: IndexPath(row: 3, section: 0)).textLabel?.text, "Отменить выбор")
        XCTAssertEqual(table.dataSource?.tableView(table, cellForRowAt: IndexPath(row: 4, section: 0)).textLabel?.text, "Последний отчёт серии")
        await self.snapshot(manager, "plugin-list-selecting")
        manager.tableView(table, didSelectRowAt: IndexPath(row: 3, section: 0))
        XCTAssertEqual(table.numberOfRows(inSection: 0), 5)
        XCTAssertEqual(table.dataSource?.tableView(table, cellForRowAt: IndexPath(row: 3, section: 0)).textLabel?.text, "Последний отчёт серии")

        // Compact view: the last action row switches every card and is remembered.
        func subtitle(_ name: String) -> String? {
            func labels(_ view: UIView) -> [UILabel] { ((view as? UILabel).map { [$0] } ?? []) + view.subviews.flatMap(labels) }
            return self.card(name, in: manager).map { labels($0.contentView) }?.dropFirst().first?.text
        }
        XCTAssertEqual(subtitle("Synthetic e2e_list_mike"), "Версия 1.0.0 • AyuPluginBridge tests")
        let compactRow = try XCTUnwrap(table.dataSource?.tableView(table, cellForRowAt: IndexPath(row: 4, section: 0)))
        XCTAssertEqual(compactRow.textLabel?.text, "Компактный вид плагинов")
        let compact = try XCTUnwrap(compactRow.accessoryView as? UISwitch)
        XCTAssertFalse(compact.isOn)
        compact.isOn = true
        self.press(compact, for: .valueChanged)
        XCTAssertEqual(subtitle("Synthetic e2e_list_mike"), "v1.0.0 • AyuPluginBridge tests")
        XCTAssertTrue(defaults.bool(forKey: AyuPluginCell.compactKey))
        await self.snapshot(manager, "plugin-list-compact")
        compact.isOn = false
        self.press(compact, for: .valueChanged)
        XCTAssertEqual(subtitle("Synthetic e2e_list_mike"), "Версия 1.0.0 • AyuPluginBridge tests")

        // Pin: the card moves to the top and the pin survives a new screen.
        try XCTUnwrap(self.card("Synthetic e2e_list_zulu", in: manager)).onAction?(.pin)
        XCTAssertEqual(listed().first, "Synthetic e2e_list_zulu")
        XCTAssertEqual(AyuPluginPins(defaults: defaults).ids, ["e2e_list_zulu"])

        // The switch, settings and delete of a card ask first; without an answer nothing changes.
        let alpha = try XCTUnwrap(self.card("Synthetic e2e_list_alpha", in: manager))
        for action in [AyuPluginCell.Action.toggle, .settings, .delete] { alpha.onAction?(action) }
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(stack.record("e2e_list_alpha")?.isEnabled, false)
        XCTAssertEqual(stack.record("e2e_list_alpha")?.isBusy, false)

        // Search: the action rows leave, names are matched, an empty result shows the placeholder.
        bar.delegate?.searchBarTextDidBeginEditing?(bar)
        bar.delegate?.searchBar?(bar, textDidChange: "LIST_MI")
        XCTAssertEqual(self.names(manager), ["Synthetic e2e_list_mike"])
        XCTAssertEqual(table.numberOfRows(inSection: 0), 0)
        XCTAssertEqual(table.numberOfRows(inSection: 3), 0)
        bar.delegate?.searchBar?(bar, textDidChange: "no such plugin")
        XCTAssertEqual(self.names(manager), ["<AyuPluginEmptyCell>"])
        await self.snapshot(manager, "plugin-list-empty-search")

        // The placeholder's picture: the glyph until the provider answers, asked once per emoji.
        func emptyPicture() -> UIImageView? {
            table.layoutIfNeeded()
            return table.visibleCells.compactMap { $0 as? AyuPluginEmptyCell }.first.flatMap { self.view(AyuPluginEmptyCell.pictureIdentifier, in: $0.contentView) as? UIImageView }
        }
        XCTAssertEqual(emptyPicture()?.isHidden, true, "no provider, the emoji itself")
        let emptyHeight = table.contentSize.height
        var placeholderRequests: [(sticker: String, answer: @MainActor (UIImage?) -> Void)] = []
        manager.placeholderProvider = { pack, emoji, answer in placeholderRequests.append((pack + "/" + emoji, answer)) }
        XCTAssertEqual(self.names(manager), ["<AyuPluginEmptyCell>"])
        XCTAssertEqual(emptyPicture()?.isHidden, true)
        let orange = self.picture(.systemOrange)
        placeholderRequests.first?.answer(orange)
        XCTAssertTrue(emptyPicture()?.image === orange, "the placeholder on screen gets the picture in place")
        XCTAssertEqual(emptyPicture()?.isHidden, false)
        XCTAssertEqual(self.names(manager), ["<AyuPluginEmptyCell>"])
        XCTAssertTrue(emptyPicture()?.image === orange, "a reload keeps the picture")
        XCTAssertEqual(placeholderRequests.map(\.sticker), ["AnimatedEmojies/🔎"])
        XCTAssertEqual(table.contentSize.height, emptyHeight, "the picture takes the glyph's box")
        await self.snapshot(manager, "plugin-list-empty-search-picture")

        // A player lies over the picture, which leaves once the player draws.
        var placeholderPlayers: [(sticker: String, started: @MainActor () -> Void)] = []
        manager.placeholderPlayerProvider = { pack, emoji, started in placeholderPlayers.append((pack + "/" + emoji, started)); return UIView() }
        XCTAssertEqual(emptyPicture()?.subviews.count, 1)
        XCTAssertEqual(emptyPicture()?.subviews.first?.frame.size, CGSize(width: 100, height: 100))
        XCTAssertTrue(emptyPicture()?.image === orange, "the still picture stays until the player draws")
        placeholderPlayers.forEach { $0.started() }
        XCTAssertNil(emptyPicture()?.image)
        XCTAssertEqual(emptyPicture()?.isHidden, false)
        XCTAssertEqual(Set(placeholderPlayers.map(\.sticker)), ["AnimatedEmojies/🔎"])
        manager.placeholderPlayerProvider = nil
        XCTAssertEqual(emptyPicture()?.subviews.count, 0)
        XCTAssertTrue(emptyPicture()?.image === orange, "without a player the picture is still")
        bar.delegate?.searchBarCancelButtonClicked?(bar)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 5)
        XCTAssertEqual(listed().count, 5)

        // Share hands out a copy of the stored bytes under the plugin's own file name.
        let copy = try await stack.service.exportCopy("e2e_list_alpha")
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        XCTAssertEqual(copy.lastPathComponent, "e2e_list_alpha.plugin")
        XCTAssertTrue(String(decoding: try Data(contentsOf: copy), as: UTF8.self).contains("__id__ = \"e2e_list_alpha\""))
        do { _ = try await stack.service.exportCopy("e2e_list_absent"); XCTFail("an unknown plugin has no file") } catch {}
    }

    func testOpenInButtonShowsTheCodeOfThePlugin() async throws {
        let stack = try AyuEndToEnd.shared()
        let id = "e2e_list_openin"
        let source = AyuEndToEnd.source(id: id, "from base_plugin import BasePlugin\n\n\nclass Listed(BasePlugin):\n    pass\n")
        self.addTeardownBlock { await stack.remove(id) }
        try await stack.install(source)
        let manager = await self.screen(stack, defaults: self.defaults())
        let navigation = UINavigationController(rootViewController: manager)
        var highlighted: [String] = []
        var palettes: [[String: UInt32]] = []
        manager.engineTheme = .night
        manager.codeHighlighter = { code, language, palette, completion in
            highlighted.append(language + ":" + code)
            palettes.append(palette)
            completion([(0..<2, 0xFFFF0000), (2..<4, palette["comment"] ?? 0)])
        }
        let copies = { try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("AyuPluginShare-") }.sorted() }
        let before = try copies()
        let card = try XCTUnwrap(self.card("Synthetic " + id, in: manager))
        self.press(try XCTUnwrap(self.control("Открыть в…", in: card.contentView)))
        for _ in 0..<100 where !(navigation.topViewController is AyuPluginSourceViewController) { try await Task.sleep(nanoseconds: 20_000_000) }
        let viewer = try XCTUnwrap(navigation.topViewController as? AyuPluginSourceViewController)
        XCTAssertEqual(viewer.title, id + ".plugin")
        XCTAssertEqual((viewer.view as? UITextView)?.text, source)
        XCTAssertEqual(highlighted, ["python:" + source], "the screen's highlighter colours the page")
        XCTAssertEqual((viewer.view as? UITextView)?.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, UIColor(red: 1, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(palettes, [AyuPluginSourceViewer.androidCodeColors(.night)], "the page asks for the colours of the screen's Android theme")
        let comment = try XCTUnwrap((viewer.view as? UITextView)?.textStorage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? UIColor)
        var white: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(comment.getWhite(&white, alpha: &alpha))
        XCTAssertEqual(white, 1, accuracy: 0.001)
        XCTAssertEqual(alpha, 127.0 / 255, accuracy: 0.001, "Android's comment colour is half transparent")
        XCTAssertEqual(stack.record(id)?.isEnabled, false, "reading the code runs nothing")
        XCTAssertEqual(try copies(), before, "the copy read for the page is removed")
    }

    func testCodePageLooksLikeAndroidsCodeBlock() throws {
        func components(_ color: UIColor?) -> [Int] {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return [red, green, blue, alpha].map { Int(($0 * 255).rounded()) }
        }
        let expected: [(AyuPluginManagerViewController.EngineTheme?, [[Int]])] = [
            (.classic, [[255, 255, 255, 255], [0x1A, 0x1D, 0x21, 255], [0x62, 0xA9, 0xE3, 20]]),
            (.day, [[255, 255, 255, 255], [0x33, 0x33, 0x33, 255], [0x62, 0xA9, 0xE3, 20]]),
            (.darkBlue, [[0x1D, 0x27, 0x33, 255], [255, 255, 255, 255], [0x64, 0xB5, 0xFD, 20]]),
            (.night, [[0x18, 0x18, 0x19, 255], [255, 255, 255, 255], [0x64, 0xB5, 0xFD, 20]]),
            (nil, [[255, 255, 255, 255], [0x1A, 0x1D, 0x21, 255], [0x62, 0xA9, 0xE3, 20]])
        ]
        for (theme, colors) in expected {
            let viewer = AyuPluginSourceViewController(fileName: "a.plugin", text: "def f():\n    return 'x'  # note\n", theme: theme) { _, _, palette, completion in
                completion([(0..<3, palette["keyword"] ?? 0), (4..<5, palette["function"] ?? 0), (20..<23, palette["string"] ?? 0), (25..<31, palette["comment"] ?? 0)])
            }
            viewer.loadViewIfNeeded()
            let page = try XCTUnwrap(viewer.view as? UITextView)
            page.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
            page.layoutIfNeeded()
            let block = try XCTUnwrap(page.subviews.first { $0.accessibilityIdentifier == AyuPluginSourceViewController.blockIdentifier })
            XCTAssertEqual([components(page.backgroundColor), components(page.textColor), components(block.backgroundColor)], colors, "\(String(describing: theme))")
            XCTAssertEqual(page.textContainerInset, UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16), "8 of the page, then 12 inside the block")
            XCTAssertEqual(page.textContainer.lineFragmentPadding, 0)
            XCTAssertGreaterThan(page.contentSize.height, 40)
            XCTAssertEqual(block.frame, CGRect(x: 0, y: 8, width: 320, height: page.contentSize.height - 16), "the page shows above and below the block")
            XCTAssertEqual(page.subviews.first, block, "the block is behind the code")
            if let directory = ProcessInfo.processInfo.environment["AYU_PLUGIN_TEST_SNAPSHOT_DIR"], let theme {
                page.frame.size.height = 120
                let image = UIGraphicsImageRenderer(bounds: page.bounds).image { page.layer.render(in: $0.cgContext) }
                try? image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("plugin-code-\(theme).png"))
            }
        }
    }

    func testCodeFontFollowsAndroidsBlocks() throws {
        XCTAssertEqual([0, 80, 81, 220, 221, 500, 501, 8192].map { AyuPluginSourceViewer.fontSize(codeLength: $0) }, [14, 14, 13, 13, 12, 12, 11, 11])
        XCTAssertEqual(AyuPluginSourceViewer.blocks(of: ""), [])
        XCTAssertEqual(AyuPluginSourceViewer.blocks(of: "x = 1\n"), [0..<6])
        XCTAssertEqual(AyuPluginSourceViewer.blocks(of: String(repeating: "a", count: 8192)), [0..<8192])
        XCTAssertEqual(AyuPluginSourceViewer.blocks(of: String(repeating: "a", count: 8193)), [0..<8192, 8192..<8193], "a line longer than a block is cut")
        XCTAssertEqual(AyuPluginSourceViewer.blocks(of: "\n" + String(repeating: "a", count: 8200)), [0..<8192, 8192..<8201], "a break at the very start does not end a block")
        // 100 lines of 100 units: the first block ends after the last break inside 8192, the
        // short rest is a block of its own with a larger font, as on Android.
        let line = String(repeating: "🙂", count: 49) + "x\n"
        let code = String(repeating: line, count: 83) + "y = 1\n"
        XCTAssertEqual(AyuPluginSourceViewer.blocks(of: code), [0..<8100, 8100..<8306])
        let viewer = AyuPluginSourceViewController(fileName: "a.plugin", text: code)
        viewer.loadViewIfNeeded()
        let page = try XCTUnwrap(viewer.view as? UITextView)
        XCTAssertEqual(page.text, code)
        func size(at index: Int) -> CGFloat? { (page.textStorage.attribute(.font, at: index, effectiveRange: nil) as? UIFont)?.pointSize }
        XCTAssertEqual([0, 8099, 8100, 8305].map { size(at: $0) }, [11, 11, 13, 13])
        XCTAssertTrue((page.textStorage.attribute(.font, at: 8099, effectiveRange: nil) as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) ?? false)
    }

    func testCodeColoursAreThoseOfAndroidThemes() {
        let light = AyuPluginSourceViewer.androidCodeColors(.classic), dark = AyuPluginSourceViewer.androidCodeColors(.darkBlue)
        XCTAssertEqual(light, AyuPluginSourceViewer.androidCodeColors(.day), "Day has no code colours of its own")
        XCTAssertEqual(dark, AyuPluginSourceViewer.androidCodeColors(.night))
        XCTAssertEqual(light.count, 37)
        let names = ["keyword", "builtin", "punctuation", "annotation", "boolean", "class-name", "string", "number", "comment", "function", "decorator"]
        XCTAssertEqual(names.map { light[$0] }, [0xFFE05356, 0xFFE05356, 0xFF4DBBFF, 0xFF4DBBFF, 0xFF7F79F3, 0xFF7F79F3, 0xFF37C123, 0xFF327FE5, 0x80000000, 0xFFF28C39, nil])
        XCTAssertEqual(names.map { dark[$0] }, [0xFFFF9380, 0xFFFF9380, 0x7FFFFFFF, 0x7FFFFFFF, 0xFFFF9380, 0xFFFF9380, 0xFF88E378, 0xFF59DED7, 0x7FFFFFFF, 0xFFFF9380, nil])
    }

    func testEngineSwitchHidesTheListAndStopsRunningPlugins() async throws {
        let stack = try AyuEndToEnd.shared()
        let id = "e2e_list_engine"
        self.addTeardownBlock { await stack.remove(id) }
        try await stack.install(AyuEndToEnd.source(id: id, "from base_plugin import BasePlugin\n\n\nclass Listed(BasePlugin):\n    pass\n"))
        let defaults = self.defaults(engine: false)
        let manager = await self.screen(stack, defaults: defaults)
        let table = try XCTUnwrap(manager.tableView)
        func flip(to value: Bool) throws {
            let row = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 0, section: 0)))
            XCTAssertEqual(row.textLabel?.text, "Включить систему плагинов")
            let toggle = try XCTUnwrap(row.accessoryView as? AyuPluginRippleSwitch)
            XCTAssertNil(toggle.overlay, "flipped by hand, the switch animates itself")
            XCTAssertEqual(toggle.isOn, !value)
            let colors = AyuPluginManagerViewController.engineColors
            XCTAssertEqual(row.backgroundColor, value ? colors.off : colors.on, "the banner has the colour of its state")
            XCTAssertEqual(row.textLabel?.textColor, .white)
            XCTAssertEqual(toggle.thumbTintColor, value ? colors.thumbOff : colors.thumbOn)
            toggle.isOn = value
            self.press(toggle, for: .valueChanged)
        }

        // Off, as on Android before the user turns it on: the switch alone.
        XCTAssertEqual((0...3).map { table.numberOfRows(inSection: $0) }, [1, 0, 0, 0])
        XCTAssertNil(table.tableHeaderView)

        await self.snapshot(manager, "plugin-engine-off")
        try flip(to: true)
        XCTAssertTrue(defaults.bool(forKey: AyuPluginManagerViewController.engineKey))
        XCTAssertEqual(table.cellForRow(at: IndexPath(row: 0, section: 0))?.backgroundColor, AyuPluginManagerViewController.engineColors.on, "the banner on screen changes colour in place")
        let ripple = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 0, section: 0))?.backgroundView as? AyuPluginRippleView)
        XCTAssertEqual(ripple.color, AyuPluginManagerViewController.engineColors.on)
        let circle = try XCTUnwrap(ripple.layer.sublayers?.first as? CAShapeLayer, "the colour spreads as a circle")
        XCTAssertGreaterThan(circle.position.x, ripple.bounds.midX, "from the switch")
        XCTAssertEqual(circle.position.y, ripple.bounds.midY)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 5)
        XCTAssertNotNil(table.tableHeaderView)
        XCTAssertTrue(self.names(manager).contains("Synthetic " + id))
        XCTAssertEqual(stack.record(id)?.isEnabled, false, "turning the engine on starts no plugin")
        await self.snapshot(manager, "plugin-engine-on")

        // As on Android, a tap anywhere on the banner flips the engine, and the colour spreads from the tap.
        func tap(at x: CGFloat) throws -> (toggle: AyuPluginRippleSwitch, circle: CAShapeLayer?) {
            let path = IndexPath(row: 0, section: 0)
            let banner = try XCTUnwrap(table.cellForRow(at: path) as? AyuPluginBannerCell)
            banner.lastTouchX = x
            table.delegate?.tableView?(table, didSelectRowAt: path)
            let shown = try XCTUnwrap(table.cellForRow(at: path))
            XCTAssertTrue(shown === banner, "the row stays while the list changes around it")
            return (try XCTUnwrap(banner.accessoryView as? AyuPluginRippleSwitch), banner.backgroundView?.layer.sublayers?.last as? CAShapeLayer)
        }
        var tapped = try tap(at: 30)
        XCTAssertFalse(defaults.bool(forKey: AyuPluginManagerViewController.engineKey))
        XCTAssertFalse(tapped.toggle.isOn, "the switch follows the tap")
        XCTAssertEqual(tapped.circle?.position.x, 30)
        XCTAssertEqual(tapped.circle?.fillColor, AyuPluginManagerViewController.engineColors.off.cgColor)
        XCTAssertEqual((0...3).map { table.numberOfRows(inSection: $0) }, [1, 0, 0, 0])
        // As on Android, the same circle recolours the switch: the new colours inside it, the old outside.
        let colors = AyuPluginManagerViewController.engineColors
        var overlay = try XCTUnwrap(tapped.toggle.overlay)
        XCTAssertFalse(overlay.isOn, "both thumbs slide")
        XCTAssertFalse(overlay.isUserInteractionEnabled)
        XCTAssertEqual([overlay.onTintColor, overlay.backgroundColor, overlay.thumbTintColor], [colors.trackOff, colors.trackOff, colors.thumbOff])
        XCTAssertEqual([tapped.toggle.onTintColor, tapped.toggle.backgroundColor, tapped.toggle.thumbTintColor], [colors.trackOn, colors.trackOn, colors.thumbOn])
        let cut = try XCTUnwrap(overlay.layer.mask as? CAShapeLayer)
        let background = try XCTUnwrap((tapped.toggle.superview as? UITableViewCell)?.backgroundView)
        let centre = tapped.toggle.convert(cut.position, to: background), spreading = try XCTUnwrap(tapped.circle?.position)
        XCTAssertEqual(centre.x, spreading.x, accuracy: 0.01, "the banner's own circle")
        XCTAssertEqual(centre.y, spreading.y, accuracy: 0.01)
        XCTAssertEqual(cut.path?.boundingBox, tapped.circle?.path?.boundingBox)
        XCTAssertEqual((cut.animation(forKey: "grow") as? CABasicAnimation)?.duration, 0.24)
        tapped.toggle.settle()
        XCTAssertNil(tapped.toggle.overlay)
        XCTAssertEqual([tapped.toggle.onTintColor, tapped.toggle.backgroundColor, tapped.toggle.thumbTintColor], [colors.trackOn, colors.trackOff, colors.thumbOff])
        // Turning off runs its shutdown first; until that ends a tap is ignored, as on Android.
        _ = try tap(at: 200)
        XCTAssertNil(tapped.toggle.overlay)
        XCTAssertFalse(defaults.bool(forKey: AyuPluginManagerViewController.engineKey))
        try await Task.sleep(nanoseconds: 50_000_000)
        tapped = try tap(at: 200)
        XCTAssertTrue(defaults.bool(forKey: AyuPluginManagerViewController.engineKey))
        XCTAssertTrue(tapped.toggle.isOn)
        XCTAssertEqual(tapped.circle?.position.x, 200)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 5)
        overlay = try XCTUnwrap(tapped.toggle.overlay)
        XCTAssertEqual([overlay.onTintColor, overlay.backgroundColor, overlay.thumbTintColor], [colors.trackOn, colors.trackOn, colors.thumbOn])
        XCTAssertEqual(tapped.toggle.thumbTintColor, colors.thumbOff, "the old colour stays outside the circle")
        // A change while the circle still grows ends it first.
        tapped.toggle.setOn(true, following: nil)
        XCTAssertNil(tapped.toggle.overlay)
        XCTAssertEqual(tapped.toggle.thumbTintColor, colors.thumbOn, "the thumb has the colour of its state")

        // Light is Android's default theme, dark its "Dark Blue".
        let palette = AyuPluginManagerViewController.engineColors
        func hex(_ color: UIColor, _ style: UIUserInterfaceStyle) -> String {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
            color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&red, green: &green, blue: &blue, alpha: nil)
            return String(format: "%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
        }
        let all = [palette.on, palette.off, palette.trackOn, palette.trackOff, palette.thumbOn, palette.thumbOff]
        XCTAssertEqual(all.map { hex($0, .light) }, ["229AF0", "96A2AD", "1079C4", "78828A", "FFFFFF", "FFFFFF"])
        XCTAssertEqual(all.map { hex($0, .dark) }, ["4E81AB", "1D2733", "80D5FF", "58626E", "4E81AB", "1D2733"])

        // The app can name the Android theme its own stands for; the banner on screen follows at once.
        func values(_ theme: AyuPluginManagerViewController.EngineTheme) -> [String] {
            let colors = AyuPluginManagerViewController.androidColors(theme)
            return [colors.on, colors.off, colors.trackOn, colors.trackOff, colors.thumbOn, colors.thumbOff].map { hex($0, .light) }
        }
        XCTAssertEqual(values(.classic), ["229AF0", "96A2AD", "1079C4", "78828A", "FFFFFF", "FFFFFF"])
        XCTAssertEqual(values(.day), ["229AF0", "96A2AD", "0084CB", "78828A", "FFFFFF", "FFFFFF"])
        XCTAssertEqual(values(.darkBlue), ["4E81AB", "1D2733", "80D5FF", "58626E", "4E81AB", "1D2733"])
        XCTAssertEqual(values(.night), ["2F76AB", "1E1E20", "77D1FF", "68686A", "2D82C3", "1E1E20"])
        func shown() throws -> [String] {
            let banner = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 0, section: 0)))
            let toggle = try XCTUnwrap(banner.accessoryView as? AyuPluginRippleSwitch)
            XCTAssertNil(toggle.overlay)
            XCTAssertNil((banner.backgroundView as? AyuPluginRippleView)?.spreading, "a theme does not spread")
            return [banner.backgroundColor, (banner.backgroundView as? AyuPluginRippleView)?.color, toggle.onTintColor, toggle.backgroundColor, toggle.thumbTintColor].map { $0.map { hex($0, .light) } ?? "none" }
        }
        manager.engineTheme = .night
        XCTAssertEqual(try shown(), ["2F76AB", "2F76AB", "77D1FF", "68686A", "2D82C3"])
        _ = self.names(manager)
        XCTAssertEqual(try shown(), ["2F76AB", "2F76AB", "77D1FF", "68686A", "2D82C3"], "a row made later has them too")
        manager.engineTheme = .day
        XCTAssertEqual(try shown(), ["229AF0", "229AF0", "0084CB", "78828A", "FFFFFF"])
        manager.engineTheme = nil
        XCTAssertEqual(try shown(), ["229AF0", "229AF0", "1079C4", "78828A", "FFFFFF"])

        try await stack.service.enable(id)
        XCTAssertEqual(stack.record(id)?.isEnabled, true)
        try flip(to: false)
        XCTAssertFalse(defaults.bool(forKey: AyuPluginManagerViewController.engineKey))
        XCTAssertEqual((0...3).map { table.numberOfRows(inSection: $0) }, [1, 0, 0, 0])
        XCTAssertNil(table.tableHeaderView)
        for _ in 0..<300 where stack.record(id)?.isEnabled == true { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(stack.record(id)?.isEnabled, false, "turning the engine off disables what runs")
        XCTAssertEqual(self.names(manager), [])
    }
}
