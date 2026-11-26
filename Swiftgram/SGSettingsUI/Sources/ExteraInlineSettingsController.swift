import AccountContext
import Display
import Foundation
import SGMath
import SGItemListUI
import SGSimpleSettings
import SGStrings
import SwiftSignalKit
import TelegramPresentationData
import UIKit

// Stable localization keys; English/Russian fallbacks keep the standalone screen
// readable until its owning settings session adds these to the string catalog.
private enum ExteraInlineStrings {
    static let keys: [String: String] = [
        "Calculation Results": "Title",
        "Show Result": "ShowResult",
        "Features": "Features",
        "Calculator": "Calculator",
        "NEW": "New",
        "Currencies": "Currencies",
        "Units of Measurement": "Units",
        "Time Zones": "TimeZones",
        "Settings": "Settings",
        "Group Digits": "GroupDigits",
        "Angles in sin, cos, tan": "Angles",
        "Degrees": "Degrees",
        "Radians": "Radians",
        "Default Currency": "DefaultCurrency",
        "Measurement System": "MeasureSystem",
        "Auto": "Auto",
        "Metric": "Metric",
        "Imperial": "Imperial",
        "Capabilities": "Capabilities",
        "Arithmetic and Functions": "Arithmetic",
        "Percentages and Shorthands": "Percentages",
        "Brackets, powers, functions, numeral systems": "ArithmeticInfo",
        "Discounts, markups, thousands and millions": "PercentagesInfo",
        "Money and cryptocurrencies": "CurrenciesInfo",
        "Length, weight, temperature, speed, time": "UnitsInfo",
        "Cities, abbreviations and current time": "TimeZonesInfo",
        "off": "Off",
        "Expanded": "Expanded",
        "Collapsed": "Collapsed",
        "Double tap to expand or collapse help": "ExpandHint",
        "Tap an example to copy it.": "CopyHint",
        "Copy expression": "CopyExpression",
        "Copied": "Copied",
        "loading rates…": "LoadingRates",
        "rates unavailable": "RatesUnavailable",
        "no conversion": "NoConversion",
        "Rates updated: ": "RatesUpdated",
        "Cancel": "Cancel",
        "Currency name or code": "CurrencySearch",
        "A gray result appears after ‘=’. Tap the result to insert it into your message, or use its copy button.": "ResultHint",
        "Auto uses this device’s region for currency and measurements. Phone-number currency detection is not available on iOS.": "AutoInfo",
        "Functions and constants. Separate arguments with ‘;’ or a comma followed by a space.": "FunctionsText",
        "bin, oct and hex show another numeral system. dec(x, n) reads x in base n.": "BasesText",
        "A percentage after + or − is calculated from the number on the left.": "PercentagesText",
        "‘k’ means a thousand and ‘kk’ a million. ‘тыс’ and ‘млн’ also work.": "ShorthandsText",
        "Without ‘to’, the amount converts to your default currency.": "CurrencyText",
        "Telegram Stars prices depend on the account and are not available in this calculator.": "StarsUnavailable",
        "Without ‘to’, foreign units convert to your measurement system, and familiar ones to a more convenient scale.": "UnitsText",
        "Durations are broken down into days, hours and minutes.": "DurationsText",
        "Time in another zone converts to your time zone.": "TimeText",
        "With ‘to’ and a city, time converts there. ‘Now’ shows the current time.": "CurrentTimeText",
        "12% of 1200 =": "Example.PercentOf",
        "300k / 12 =": "Example.Shorthand",
        "100 dollars to euros =": "Example.CurrencyTarget",
        "5k ₽ to $ =": "Example.CurrencyShorthand",
        "50$ to GRAM =": "Example.Crypto",
        "10 miles =": "Example.Distance",
        "5 kg to lb =": "Example.Weight",
        "100 km/h to mph =": "Example.Speed",
        "90 min =": "Example.Duration",
        "2 h + 45 min =": "Example.DurationSum",
        "6pm est =": "Example.TimeZone",
        "12:00 in tokyo =": "Example.Tokyo",
        "now in new york =": "Example.Now"
    ]

    static func text(_ english: String, _ russian: String, language: String) -> String {
        if let suffix = self.keys[english] {
            let key = "Extera.InlineSettings." + suffix
            let value = i18n(key, language)
            if !value.isEmpty && value != key { return value }
        }
        return language.hasPrefix("ru") ? russian : english
    }
}

/// Standalone calculation preferences and copyable, independently expandable help.
public func exteraInlineSettingsController(context: AccountContext) -> ViewController {
    return ExteraInlineSettingsController(context: context)
}

private final class ExteraInlineButton: UIButton {
    var action: (() -> Void)?

    init() {
        super.init(frame: .zero)
        self.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func pressed() { self.action?() }
}

private final class ExteraInlineSettingsController: ViewController {
    private let context: AccountContext
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let settings = ExteraMathSettings.shared
    private var expanded = Set<Int>()
    private var presentationDisposable: Disposable?
    private var settingsObserver: NSObjectProtocol?
    private var contentSizeObserver: NSObjectProtocol?
    private var ratesRequest: ExteraMathCurrencyRequest?
    private var ratesFailed = false

    private var data: PresentationData { return self.context.sharedContext.currentPresentationData.with { $0 } }
    private var accent: UIColor { return self.data.theme.list.itemAccentColor }

    init(context: AccountContext) {
        self.context = context
        let data = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: NavigationBarTheme(rootControllerTheme: data.theme), strings: NavigationBarStrings(presentationStrings: data.strings)))
        self.title = self.text("Calculation Results", "Результаты вычислений")
        self.presentationDisposable = (context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self else { return }
            self.setNavigationBarPresentationData(NavigationBarPresentationData(theme: NavigationBarTheme(rootControllerTheme: data.theme), strings: NavigationBarStrings(presentationStrings: data.strings)), animated: false)
            self.title = self.text("Calculation Results", "Результаты вычислений")
            self.rebuild()
        })
        self.settingsObserver = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: .main, using: { [weak self] _ in self?.rebuild() })
        self.contentSizeObserver = NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main, using: { [weak self] _ in self?.rebuild() })
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        self.presentationDisposable?.dispose()
        if let observer = self.settingsObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = self.contentSizeObserver { NotificationCenter.default.removeObserver(observer) }
        self.ratesRequest?.cancel()
    }

    private func text(_ english: String, _ russian: String) -> String {
        return ExteraInlineStrings.text(english, russian, language: self.data.strings.baseLanguageCode)
    }

    override func loadDisplayNode() {
        self.displayNode = ViewControllerTracingNode()
        self.displayNodeDidLoad()
        self.scrollView.contentInsetAdjustmentBehavior = .never
        self.displayNode.view.addSubview(self.scrollView)
        self.stack.axis = .vertical
        self.stack.spacing = 10
        self.stack.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView.addSubview(self.stack)
        NSLayoutConstraint.activate([
            self.stack.topAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.topAnchor, constant: 8),
            self.stack.bottomAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            self.stack.leadingAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.leadingAnchor),
            self.stack.trailingAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.trailingAnchor),
            self.stack.widthAnchor.constraint(equalTo: self.scrollView.frameLayoutGuide.widthAnchor)
        ])
        self.rebuild()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.rebuild()
        self.loadRatesIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.ratesRequest?.cancel()
        self.ratesRequest = nil
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        let bottom = layout.insets(options: [.input]).bottom
        let side = layout.sideInsets(forBandFrom: top, to: layout.size.height - bottom)
        let width = min(680, max(0, layout.size.width - side.left - side.right - 24))
        let left = side.left + (layout.size.width - side.left - side.right - width) / 2
        transition.updateFrame(view: self.scrollView, frame: CGRect(x: left, y: top, width: width, height: max(0, layout.size.height - top - bottom)))
    }

    private func label(_ text: String, style: UIFont.TextStyle = .body, secondary: Bool = false) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = UIFont.preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = secondary ? self.data.theme.list.itemSecondaryTextColor : self.data.theme.list.itemPrimaryTextColor
        return label
    }

    private func inset(_ content: UIView, left: CGFloat = 16, vertical: CGFloat = 12) -> UIView {
        let view = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: left),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: vertical),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -vertical)
        ])
        return view
    }

    private func vertical(_ views: [UIView], spacing: CGFloat = 0) -> UIStackView {
        let result = UIStackView(arrangedSubviews: views)
        result.axis = .vertical
        result.spacing = spacing
        return result
    }

    private func card(_ views: [UIView], master: Bool = false) -> UIView {
        var rows: [UIView] = []
        for (index, view) in views.enumerated() {
            if index != 0 {
                let line = UIView()
                line.backgroundColor = self.data.theme.list.itemBlocksSeparatorColor
                line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
                rows.append(self.inset(line, left: 52, vertical: 0))
            }
            rows.append(view)
        }
        let card = self.vertical(rows)
        card.backgroundColor = master && self.settings.inlineResults ? self.accent : self.data.theme.list.itemBlocksBackgroundColor
        card.layer.cornerRadius = master ? 28 : 22
        card.clipsToBounds = true
        return card
    }

    private func header(_ english: String, _ russian: String) {
        let label = self.label(self.text(english, russian), style: .subheadline)
        label.textColor = self.accent
        self.stack.addArrangedSubview(self.inset(label, vertical: 6))
    }

    private func note(_ english: String, _ russian: String) -> UIView {
        return self.inset(self.label(self.text(english, russian), style: .footnote, secondary: true), vertical: 2)
    }

    private func toggle(_ title: String, symbol: String? = nil, value: Bool, master: Bool = false, isNew: Bool = false, update: @escaping (Bool) -> Void) -> UIView {
        let label = self.label(title)
        let control = SGExteraToggleControl(value: value, theme: self.data.theme, style: exteraSettingsAppearance().controlStyle)
        control.valueUpdated = update
        control.onTintColor = master && value ? UIColor.white.withAlphaComponent(0.35) : self.accent
        control.accessibilityLabel = title
        let row = UIStackView()
        row.alignment = .center
        row.spacing = 12
        if let symbol { row.addArrangedSubview(self.icon(symbol)) }
        row.addArrangedSubview(label)
        if isNew {
            let badge = self.label(self.text("NEW", "NEW"), style: .caption2)
            badge.textColor = self.accent
            badge.setContentHuggingPriority(.required, for: .horizontal)
            badge.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(badge)
        }
        row.addArrangedSubview(control)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        if master && value { label.textColor = .white }
        return self.inset(row)
    }

    private func icon(_ symbol: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = self.data.theme.list.itemSecondaryTextColor
        icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
        icon.isAccessibilityElement = false
        return icon
    }

    private func actionRow(_ title: String, value: String, action: @escaping () -> Void) -> UIView {
        let button = ExteraInlineButton()
        button.action = action
        button.accessibilityLabel = title
        button.accessibilityValue = value
        let titleLabel = self.label(title)
        let valueLabel = self.label(value)
        valueLabel.textColor = self.accent
        valueLabel.textAlignment = .right
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let content = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        content.spacing = 12
        content.alignment = .center
        content.isUserInteractionEnabled = false
        self.fill(button, with: self.inset(content))
        return button
    }

    private func fill(_ parent: UIView, with child: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor), child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor), child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            parent.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
    }

    private func rebuild() {
        guard self.isViewLoaded else { return }
        let offset = self.scrollView.contentOffset
        self.displayNode.backgroundColor = self.data.theme.list.blocksBackgroundColor
        for view in self.stack.arrangedSubviews { self.stack.removeArrangedSubview(view); view.removeFromSuperview() }
        self.stack.addArrangedSubview(self.card([
            self.toggle(self.text("Show Result", "Показывать результат"), value: self.settings.inlineResults, master: true, update: { [weak self] value in self?.settings.inlineResults = value })
        ], master: true))
        self.stack.addArrangedSubview(self.note("A gray result appears after ‘=’. Tap the result to insert it into your message, or use its copy button.", "Серый результат появляется после «=». Нажмите на результат для вставки в сообщение или на кнопку копирования рядом с ним."))
        if self.settings.inlineResults {
            self.header("Features", "Функции")
            self.stack.addArrangedSubview(self.card([
                self.toggle(self.text("Calculator", "Калькулятор"), symbol: "function", value: self.settings.inlineMathResult, update: { [weak self] in self?.settings.inlineMathResult = $0 }),
                self.toggle(self.text("Currencies", "Валюты"), symbol: "dollarsign.circle", value: self.settings.inlineCurrencies, isNew: true, update: { [weak self] in self?.settings.inlineCurrencies = $0 }),
                self.toggle(self.text("Units of Measurement", "Единицы измерения"), symbol: "ruler", value: self.settings.inlineUnits, isNew: true, update: { [weak self] in self?.settings.inlineUnits = $0 }),
                self.toggle(self.text("Time Zones", "Часовые пояса"), symbol: "globe", value: self.settings.inlineTimeZones, isNew: true, update: { [weak self] in self?.settings.inlineTimeZones = $0 })
            ]))
            self.header("Settings", "Настройки")
            var options = [self.toggle(self.text("Group Digits", "Разделять разряды"), value: self.settings.inlineDigitGrouping, update: { [weak self] in self?.settings.inlineDigitGrouping = $0 })]
            if self.settings.inlineMathResult {
                options.append(self.actionRow(self.text("Angles in sin, cos, tan", "Углы в sin, cos, tan"), value: self.settings.inlineAngleUnit == .degrees ? self.text("Degrees", "Градусы") : self.text("Radians", "Радианы"), action: { [weak self] in self?.chooseAngles() }))
            }
            if self.settings.inlineCurrencies {
                let currency = self.settings.inlineTargetCurrency
                options.append(self.actionRow(self.text("Default Currency", "Валюта по умолчанию"), value: currency == "auto" ? self.text("Auto", "Авто") : currency, action: { [weak self] in self?.chooseCurrency() }))
            }
            if self.settings.inlineUnits {
                options.append(self.actionRow(self.text("Measurement System", "Система мер"), value: self.measureTitle(self.settings.inlineMeasureSystem), action: { [weak self] in self?.chooseMeasures() }))
            }
            self.stack.addArrangedSubview(self.card(options))
            self.stack.addArrangedSubview(self.note("Auto uses this device’s region for currency and measurements. Phone-number currency detection is not available on iOS.", "«Авто» выбирает валюту и систему мер по региону устройства. Определение валюты по номеру телефона на iOS пока недоступно."))
        }
        self.header("Capabilities", "Возможности")
        self.stack.addArrangedSubview(self.card((0..<5).map { self.feature($0) }))
        self.stack.addArrangedSubview(self.note("Tap an example to copy it.", "Нажмите на пример, чтобы скопировать его."))
        self.scrollView.layoutIfNeeded()
        self.scrollView.contentOffset = CGPoint(x: 0, y: min(max(0, offset.y), max(0, self.scrollView.contentSize.height - self.scrollView.bounds.height)))
    }

    private func feature(_ index: Int) -> UIView {
        let titles = [self.text("Arithmetic and Functions", "Арифметика и функции"), self.text("Percentages and Shorthands", "Проценты и сокращения"), self.text("Currencies", "Валюты"), self.text("Units of Measurement", "Единицы измерения"), self.text("Time Zones", "Часовые пояса")]
        let subtitles = [self.text("Brackets, powers, functions, numeral systems", "Скобки, степени, функции, системы счисления"), self.text("Discounts, markups, thousands and millions", "Скидки, наценки, тысячи и миллионы"), self.text("Money and cryptocurrencies", "Деньги и криптовалюты"), self.text("Length, weight, temperature, speed, time", "Длина, вес, температура, скорость, время"), self.text("Cities, abbreviations and current time", "Города, сокращения и текущее время")]
        let enabled = [self.settings.inlineMathResult, self.settings.inlineMathResult, self.settings.inlineCurrencies, self.settings.inlineUnits, self.settings.inlineTimeZones][index] && self.settings.inlineResults
        let title = self.label(titles[index])
        let subtitle = self.label(subtitles[index], style: .footnote, secondary: true)
        let textColumn = self.vertical([title, subtitle], spacing: 4)
        if !enabled {
            let badge = self.label(self.text("off", "выключено"), style: .caption2, secondary: true)
            textColumn.insertArrangedSubview(badge, at: 1)
        }
        let chevron = UIImageView(image: UIImage(systemName: self.expanded.contains(index) ? "chevron.up" : "chevron.down"))
        chevron.tintColor = self.data.theme.list.itemSecondaryTextColor
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [self.icon(["function", "percent", "dollarsign.circle", "ruler", "globe"][index]), textColumn, chevron])
        row.spacing = 12
        row.alignment = .center
        row.isUserInteractionEnabled = false
        let button = ExteraInlineButton()
        button.accessibilityLabel = titles[index]
        button.accessibilityValue = self.expanded.contains(index) ? self.text("Expanded", "Развёрнуто") : self.text("Collapsed", "Свёрнуто")
        if !enabled { button.accessibilityValue = (button.accessibilityValue ?? "") + ", " + self.text("off", "выключено") }
        button.accessibilityHint = self.text("Double tap to expand or collapse help", "Двойное нажатие раскрывает или сворачивает справку")
        self.fill(button, with: self.inset(row, vertical: 16))
        button.action = { [weak self] in
            guard let self else { return }
            if !self.expanded.insert(index).inserted { self.expanded.remove(index) }
            if !self.expanded.contains(2) { self.ratesRequest?.cancel(); self.ratesRequest = nil }
            self.rebuild()
            self.loadRatesIfNeeded()
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
        guard self.expanded.contains(index) else { return button }
        return self.vertical([button, self.inset(self.documentation(index), left: 52, vertical: 4)])
    }

    private func documentation(_ index: Int) -> UIView {
        let body = self.vertical([], spacing: 10)
        func prose(_ english: String, _ russian: String) { body.addArrangedSubview(self.label(self.text(english, russian), style: .footnote, secondary: true)) }
        func examples(_ expressions: [String]) { for expression in expressions { body.addArrangedSubview(self.example(expression)) } }
        switch index {
        case 0:
            examples(["(120 + 80) / 4 =", "√144 + 2^3 ="])
            prose("Functions and constants. Separate arguments with ‘;’ or a comma followed by a space.", "Функции и константы. Аргументы разделяются «;» или запятой с пробелом.")
            body.addArrangedSubview(self.functionCodes())
            examples(["max(12, 40, 7) =", "sin(30) ="])
            prose("bin, oct and hex show another numeral system. dec(x, n) reads x in base n.", "bin, oct и hex показывают число в другой системе счисления, а dec(x, n) читает x в системе n.")
            examples(["hex(255) =", "dec(ff, 16) =", "0xff + 1 ="])
        case 1:
            prose("A percentage after + or − is calculated from the number on the left.", "Процент после + или − считается от числа слева.")
            examples(["2300 - 15% =", self.text("12% of 1200 =", "12% от 1200 =")])
            prose("‘k’ means a thousand and ‘kk’ a million. ‘тыс’ and ‘млн’ also work.", "«к» — тысяча, «кк» — миллион. «тыс» и «млн» тоже работают.")
            examples([self.text("300k / 12 =", "300к / 12 =")])
        case 2:
            prose("Without ‘to’, the amount converts to your default currency.", "Без «в» сумма переводится в валюту по умолчанию.")
            examples(["100€ =", self.text("100 dollars to euros =", "100 долларов в евро ="), self.text("5k ₽ to $ =", "5к ₽ в $ ="), self.text("50$ to GRAM =", "50$ в GRAM =")])
            prose("Telegram Stars prices depend on the account and are not available in this calculator.", "Цена звёзд Telegram зависит от аккаунта и пока недоступна в этом калькуляторе.")
            if let snapshot = ExteraMathCurrencyRequest.cached() {
                let formatter = DateFormatter()
                formatter.dateStyle = .short; formatter.timeStyle = .short
                body.addArrangedSubview(self.label(self.text("Rates updated: ", "Курсы обновлены: ") + formatter.string(from: snapshot.date), style: .caption1, secondary: true))
            }
        case 3:
            prose("Without ‘to’, foreign units convert to your measurement system, and familiar ones to a more convenient scale.", "Без «в» чужие единицы переводятся в вашу систему мер, а свои — в более удобные.")
            examples(["72°F =", self.text("10 miles =", "10 миль ="), self.text("5 kg to lb =", "5 кг в фунтах ="), self.text("100 km/h to mph =", "100 км/ч в mph =")])
            prose("Durations are broken down into days, hours and minutes.", "Длительность раскладывается на дни, часы и минуты.")
            examples([self.text("90 min =", "90 мин ="), self.text("2 h + 45 min =", "2 ч + 45 мин =")])
        default:
            prose("Time in another zone converts to your time zone.", "Время в другом поясе переводится в ваше.")
            examples([self.text("6pm est =", "18:00 utc ="), self.text("12:00 in tokyo =", "12:00 в токио =")])
            prose("With ‘to’ and a city, time converts there. ‘Now’ shows the current time.", "С «в» и городом время переводится туда, а «сейчас» показывает текущее.")
            examples([self.text("now in new york =", "сейчас в нью-йорке =")])
        }
        return body
    }

    private func functionCodes() -> UIView {
        let codes = ["round", "min", "max", "abs", "sqrt", "log", "ln", "sin", "cos", "tan", "pi", "e"]
        let columns = UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory ? 3 : 6
        let rows = self.vertical([], spacing: 6)
        for start in stride(from: 0, to: codes.count, by: columns) {
            let row = UIStackView()
            row.spacing = 4
            row.distribution = .fillEqually
            for code in codes[start..<min(codes.count, start + columns)] {
                let label = self.label(code, style: .caption2)
                label.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .monospacedSystemFont(ofSize: 10, weight: .regular))
                label.textAlignment = .center
                let chip = UIView()
                chip.backgroundColor = self.data.theme.list.itemPrimaryTextColor.withAlphaComponent(0.055)
                chip.layer.cornerRadius = 7
                label.translatesAutoresizingMaskIntoConstraints = false
                chip.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 3), label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -3),
                    label.topAnchor.constraint(equalTo: chip.topAnchor, constant: 6), label.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -6)
                ])
                row.addArrangedSubview(chip)
            }
            rows.addArrangedSubview(row)
        }
        return rows
    }

    private func example(_ expression: String) -> UIView {
        let options = ExteraMathEngine.Options(settings: self.settings, preview: true)
        let suggestion = ExteraMathEngine.suggestion(in: expression, caret: (expression as NSString).length, options: options)
        let result: String
        if let suggestion, !suggestion.isPendingCurrency { result = suggestion.value }
        else if suggestion?.isPendingCurrency == true { result = self.ratesFailed || self.ratesRequest == nil && !ExteraMathCurrencyRequest.shouldRefresh() ? self.text("rates unavailable", "курсы недоступны") : self.text("loading rates…", "загрузка курсов…") }
        else { result = self.text("no conversion", "нет преобразования") }
        let label = self.label("")
        let font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let content = NSMutableAttributedString(string: expression + " ", attributes: [.font: font, .foregroundColor: self.data.theme.list.itemPrimaryTextColor])
        content.append(NSAttributedString(string: result, attributes: [.font: font, .foregroundColor: self.data.theme.list.itemSecondaryTextColor]))
        label.attributedText = content
        let button = ExteraInlineButton()
        button.backgroundColor = self.data.theme.list.itemPrimaryTextColor.withAlphaComponent(0.055)
        button.layer.cornerRadius = 10
        button.accessibilityLabel = expression + " " + result
        button.accessibilityHint = self.text("Copy expression", "Скопировать выражение")
        button.action = { [weak self] in
            UIPasteboard.general.string = expression
            UIAccessibility.post(notification: .announcement, argument: self?.text("Copied", "Скопировано"))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        label.isUserInteractionEnabled = false
        self.fill(button, with: self.inset(label, left: 10, vertical: 8))
        return button
    }

    private func loadRatesIfNeeded() {
        guard self.expanded.contains(2), self.ratesRequest == nil else { return }
        guard ExteraMathCurrencyRequest.shouldRefresh() else { return }
        self.ratesFailed = false
        self.ratesRequest = ExteraMathCurrencyRequest { [weak self] snapshot in
            guard let self else { return }
            self.ratesRequest = nil
            self.ratesFailed = snapshot == nil
            self.rebuild()
        }
    }

    private func measureTitle(_ system: ExteraMathSettings.MeasureSystem) -> String {
        switch system {
        case .auto: return self.text("Auto", "Авто")
        case .metric: return self.text("Metric", "Метрическая")
        case .imperial: return self.text("Imperial", "Имперская")
        }
    }

    private func choose(_ title: String, options: [(String, Bool, () -> Void)]) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        for (text, selected, action) in options {
            alert.addAction(UIAlertAction(title: (selected ? "✓ " : "") + text, style: .default, handler: { _ in action() }))
        }
        alert.addAction(UIAlertAction(title: self.text("Cancel", "Отмена"), style: .cancel))
        self.present(alert, animated: true)
    }

    private func chooseAngles() {
        self.choose(self.text("Angles in sin, cos, tan", "Углы в sin, cos, tan"), options: [
            (self.text("Degrees", "Градусы"), self.settings.inlineAngleUnit == .degrees, { [weak self] in self?.settings.inlineAngleUnit = .degrees }),
            (self.text("Radians", "Радианы"), self.settings.inlineAngleUnit == .radians, { [weak self] in self?.settings.inlineAngleUnit = .radians })
        ])
    }

    private func chooseMeasures() {
        self.choose(self.text("Measurement System", "Система мер"), options: ExteraMathSettings.MeasureSystem.allCases.map { system in
            return (self.measureTitle(system), system == self.settings.inlineMeasureSystem, { [weak self] in self?.settings.inlineMeasureSystem = system })
        })
    }

    private func chooseCurrency() {
        let controller = ExteraInlineCurrencyController(context: self.context)
        (self.navigationController as? NavigationController)?.pushViewController(controller)
    }
}

private final class ExteraInlineCurrencyController: ViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    private let context: AccountContext
    private let table = UITableView(frame: .zero, style: .plain)
    private let search = UISearchBar()
    private var codes: [String] = []
    private var filtered: [String] = []
    private var presentationDisposable: Disposable?

    init(context: AccountContext) {
        self.context = context
        let data = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: NavigationBarTheme(rootControllerTheme: data.theme), strings: NavigationBarStrings(presentationStrings: data.strings)))
        self.codes = ["auto"] + ExteraMathEngine.supportedCurrencyCodes.sorted { self.name($0).localizedCaseInsensitiveCompare(self.name($1)) == .orderedAscending }
        self.filtered = self.codes
        self.presentationDisposable = (context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self else { return }
            self.setNavigationBarPresentationData(NavigationBarPresentationData(theme: NavigationBarTheme(rootControllerTheme: data.theme), strings: NavigationBarStrings(presentationStrings: data.strings)), animated: false)
            self.title = ExteraInlineStrings.text("Default Currency", "Валюта по умолчанию", language: data.strings.baseLanguageCode)
            if self.isViewLoaded {
                self.displayNode.backgroundColor = data.theme.list.blocksBackgroundColor
                self.table.backgroundColor = data.theme.list.blocksBackgroundColor
                self.table.separatorColor = data.theme.list.itemBlocksSeparatorColor
                self.search.barTintColor = data.theme.list.blocksBackgroundColor
                self.table.reloadData()
            }
        })
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { self.presentationDisposable?.dispose() }

    private func name(_ code: String) -> String {
        let language = self.context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
        if code == "auto" { return ExteraInlineStrings.text("Auto", "Авто", language: language) }
        if let crypto = ["GRAM": "Gram", "BTC": "Bitcoin", "ETH": "Ethereum", "SOL": "Solana", "USDT": "Tether"][code] { return crypto }
        return Locale(identifier: language).localizedString(forCurrencyCode: code) ?? code
    }

    override func loadDisplayNode() {
        self.displayNode = ViewControllerTracingNode()
        self.displayNodeDidLoad()
        let data = self.context.sharedContext.currentPresentationData.with { $0 }
        self.displayNode.backgroundColor = data.theme.list.blocksBackgroundColor
        self.table.backgroundColor = data.theme.list.blocksBackgroundColor
        self.table.separatorColor = data.theme.list.itemBlocksSeparatorColor
        self.table.dataSource = self
        self.table.delegate = self
        self.table.keyboardDismissMode = .onDrag
        self.table.rowHeight = UITableView.automaticDimension
        self.table.estimatedRowHeight = 56
        self.table.contentInsetAdjustmentBehavior = .never
        self.search.delegate = self
        self.search.placeholder = ExteraInlineStrings.text("Currency name or code", "Название или код валюты", language: data.strings.baseLanguageCode)
        self.search.searchBarStyle = .minimal
        self.search.sizeToFit()
        self.table.tableHeaderView = self.search
        self.displayNode.view.addSubview(self.table)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        transition.updateFrame(view: self.table, frame: CGRect(x: layout.safeInsets.left, y: top, width: layout.size.width - layout.safeInsets.left - layout.safeInsets.right, height: max(0, layout.size.height - top - layout.insets(options: [.input]).bottom)))
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { return self.filtered.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "currency") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "currency")
        let code = self.filtered[indexPath.row]
        let data = self.context.sharedContext.currentPresentationData.with { $0 }
        cell.textLabel?.text = self.name(code)
        cell.detailTextLabel?.text = code == "auto" ? ExteraMathSettings.shared.resolvedTargetCurrency : code
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .caption1)
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.textColor = data.theme.list.itemPrimaryTextColor
        cell.detailTextLabel?.textColor = data.theme.list.itemSecondaryTextColor
        cell.backgroundColor = data.theme.list.itemBlocksBackgroundColor
        cell.tintColor = data.theme.list.itemAccentColor
        cell.accessoryType = ExteraMathSettings.shared.inlineTargetCurrency == code ? .checkmark : .none
        cell.accessibilityTraits = cell.accessoryType == .checkmark ? [.button, .selected] : [.button]
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        ExteraMathSettings.shared.inlineTargetCurrency = self.filtered[indexPath.row]
        self.search.resignFirstResponder()
        let _ = (self.navigationController as? NavigationController)?.popViewController(animated: true)
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.filtered = query.isEmpty ? self.codes : self.codes.filter { $0.localizedCaseInsensitiveContains(query) || self.name($0).localizedCaseInsensitiveContains(query) }
        self.table.reloadData()
    }
}
