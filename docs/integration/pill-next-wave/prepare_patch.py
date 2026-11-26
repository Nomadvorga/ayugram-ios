"""Build a review-only unified patch; never writes any production source.

Run from any directory: uv run python docs/integration/pill-next-wave/prepare_patch.py
The patch is based on exact source contents at generation time. A failed anchor is
an explicit rebase requirement, never permission to overwrite root work.
"""
from pathlib import Path
import difflib
import hashlib
import json
import re
import struct

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
APK = Path(r"C:/Users/PC/ayugram-apk-src")
changes = {}
bases = {}


def source(name):
    if name not in changes:
        text = (ROOT / name).read_text(encoding="utf-8")
        bases[name] = text
        changes[name] = text
    return changes[name]


def replace(name, old, new):
    text = source(name)
    if text.count(old) != 1:
        raise ValueError(f"Rebase required: {name}: anchor count {text.count(old)}: {old[:90]}")
    changes[name] = text.replace(old, new)


def add(name, payload):
    if (ROOT / name).exists():
        raise ValueError(f"New destination already exists: {name}")
    bases[name] = ""
    changes[name] = (HERE / payload).read_text(encoding="utf-8")


model = "Swiftgram/SGSimpleSettings/Sources/ExteraPillStackSettings.swift"
provider = "submodules/ChatListUI/Sources/ExteraPillBuiltinProvider.swift"
view = "submodules/ChatListUI/Sources/ExteraPillStackView.swift"
editor = "submodules/ChatListUI/Sources/ExteraPillStackController.swift"
core = "submodules/TelegramCore/Sources/TelegramEngine/AccountData/ExteraAccountEntryStatus.swift"
ghost = "submodules/TelegramCore/Sources/Network/AyuGhostRequestFilter.swift"
presence = "submodules/TelegramCore/Sources/State/ManagedAccountPresence.swift"

add("Swiftgram/SGSimpleSettings/Sources/ExteraPillParity.swift", "ExteraPillParity.swift")
add("submodules/ChatListUI/Sources/ExteraPillWeatherSettingsController.swift", "ExteraPillWeatherSettingsController.swift")
add("submodules/ChatListUI/Sources/ExteraPillStorageRing.swift", "ExteraPillStorageRing.swift")
add("submodules/TelegramCore/Sources/TelegramEngine/AccountData/ExteraPresenceBarrier.swift", "ExteraPresenceBarrier.swift")
replace(model, "    /// APK LastSeenPill: off by default", (HERE / "settings.fragment").read_text(encoding="utf-8") + "    /// APK LastSeenPill: off by default")

# Exact ordered country candidates from the APK PhoneFormat header. No phone data
# is exported: only a public calling-code/country lookup table is embedded.
phone = (APK / "resources/assets/PhoneFormats.dat").read_bytes()
countries = {}
for i in range(struct.unpack_from("<I", phone)[0]):
    offset = 4 + i * 12
    code = phone[offset:offset+4].split(b"\0")[0].decode("ascii")
    country = phone[offset+4:offset+8].split(b"\0")[0].decode("ascii").upper()
    countries.setdefault(code, []).append(country)
rates = (APK / "sources/com/exteragram/messenger/utils/network/ExchangeRates.java").read_text(encoding="utf-8")
fiat = re.findall(r'"([A-Z]{3})"', rates.split("Arrays.asList(", 1)[1].split(");", 1)[0])
exponents = json.loads((APK / "resources/assets/currencies.json").read_text(encoding="utf-8"))
parity = "Swiftgram/SGSimpleSettings/Sources/ExteraPillParity.swift"
def swift_dictionary(value):
    return "[" + json.dumps(value, separators=(",", ":"))[1:-1] + "]"

changes[parity] = changes[parity].replace("/*COUNTRIES*/", swift_dictionary(countries)).replace("/*FIAT*/", json.dumps(fiat)).replace("/*EXPONENTS*/", swift_dictionary({c: exponents.get(c, {}).get("exp", 0) for c in fiat}))

replace(core, "    return account.network.request(Api.functions.users.getUsers(id: [.inputUserSelf]), automaticFloodWait: false)", "    return exteraPresenceBarrier(network: account.network)\n    |> mapToSignal { _ in account.network.request(Api.functions.users.getUsers(id: [.inputUserSelf]), automaticFloodWait: false) }")
replace(ghost, "let _ = network.request(Api.functions.account.updateStatus(offline: .boolFalse), ayuBypassGhost: true).start()\n        Queue.mainQueue().after(0.2) {\n            if AyuGhostSettings.shared.suppressOnlineStatus {\n                let _ = network.request(Api.functions.account.updateStatus(offline: .boolTrue), ayuBypassGhost: true).start()\n                AyuGhostLastSeen.shared.recordNow()\n            }\n        }", "let _ = ayuTrackedPresence(network: network, operation:\n            network.request(Api.functions.account.updateStatus(offline: .boolFalse), ayuBypassGhost: true)\n            |> mapToSignal { _ -> Signal<Api.Bool, MTRpcError> in\n                return (.single(true) |> delay(0.2, queue: .mainQueue()))\n                |> mapToSignal { _ -> Signal<Api.Bool, MTRpcError> in\n                    guard AyuGhostSettings.shared.suppressOnlineStatus else { return .complete() }\n                    return network.request(Api.functions.account.updateStatus(offline: .boolTrue), ayuBypassGhost: true)\n                }\n            }).start()")
replace(ghost, "let _ = network.request(Api.functions.account.updateStatus(offline: .boolTrue)).start()\n        AyuGhostLastSeen.shared.recordNow()", "let _ = ayuTrackedPresence(network: network, operation: network.request(Api.functions.account.updateStatus(offline: .boolTrue))).start()")
# Wrap existing presence operations only; no extra packets or filter bypasses.
replace(presence, "self.currentRequestDisposable.set((request\n", "self.currentRequestDisposable.set((ayuTrackedPresence(network: self.network, operation: request)\n")
replace(ghost, '    // The server shows a sender online anyway; with the pulse it is for 0.2 s only.', '    ayuPresenceUpdated(network: network)\n    // The server shows a sender online anyway; with the pulse it is for 0.2 s only.')

replace(provider, "import Foundation\n", "import Foundation\nimport Postbox\nimport TelegramUIPreferences\n")
replace(provider, "    private var selectedKind: ExteraBuiltinPill?", "    private var selectedKind: ExteraBuiltinPill?\n    private var proxyStatuses: ProxyServersStatuses?\n    private var entryEvents: Disposable?\n    private var eventRefresh: DispatchWorkItem?\n    var storageProgress: ((Double?) -> Void)?\n    private var cachedStorageProgress: Double?\n    private var phoneNumber = \"\"\n    func updatePhone(_ value: String) { self.phoneNumber = value }")
replace(provider, "var currency: String { ExteraPillStackSettings.shared.currency(account: self.accountId) }", "var currency: String {\n        let kind = self.selectedKind ?? .gram\n        return ExteraPillCurrency.resolve(ExteraPillStackSettings.shared.target(kind, account: self.accountId), phone: self.phoneNumber)\n    }")
replace(provider, "        self.generation.cancel(); self.disposable.set(nil)", "        self.generation.cancel(); self.disposable.set(nil)\n        self.proxyStatuses = nil; self.entryEvents?.dispose(); self.entryEvents = nil\n        self.eventRefresh?.cancel(); self.eventRefresh = nil\n        self.storageProgress?(nil)")
replace(provider, 'let cacheKey = self.currency + "." + self.language + "." + (kind == .weather ? self.weatherSource : "")', 'let weatherSettings = ExteraPillStackSettings.shared.weather(account: self.accountId)\n        let cacheKey = self.currency + "." + self.language + "." + (kind == .weather ? self.weatherSource + String(describing: weatherSettings) + TimeZone.current.identifier : "")')
replace(provider, 'let weatherAuthorized = kind != .weather || [.authorizedAlways, .authorizedWhenInUse].contains(self.locationAuthorizationStatus)', 'let weatherAuthorized = kind != .weather || !weatherSettings.current || [.authorizedAlways, .authorizedWhenInUse].contains(self.locationAuthorizationStatus)')
replace(provider, '            publish(cached.0); return', '            if kind == .storage { self.storageProgress?(self.cachedStorageProgress) }\n            publish(cached.0); return')
replace(provider, '            publish(""); return', '            publish(""); return')
replace(provider, 'self.disposable.set((Weather.getWeatherData(context: self.context, load: true) |> deliverOnMainQueue)', 'let weather: Signal<WeatherDataState, NoError>\n            if weatherSettings.current { weather = Weather.getWeatherData(context: self.context, load: true) }\n            else {\n                weather = Weather.requestWeatherData(context: self.context, location: CLLocationCoordinate2D(latitude: weatherSettings.latitude, longitude: weatherSettings.longitude))\n                |> map { $0.map { WeatherDataState.loaded($0) } ?? .none }\n            }\n            self.disposable.set((weather |> deliverOnMainQueue)')
replace(provider, 'success("\\(String(data.emoji.prefix(8))) \\(Int(data.temperature.rounded()))°C")', 'success("\\(String(data.emoji.prefix(8))) " + ExteraPillWeather.temperature(data.temperature, timezone: TimeZone.current.identifier))')
replace(provider, 'let value = try ExteraPillExchangeRate.value(data: result.get(), base: base, target: target, locale: Locale(identifier: exteraPillLanguageCode(self.language)))\n                    success(kind.title(self.language) + " " + value)', 'let value = try ExteraPillCurrency.price(data: result.get(), base: base, target: target)\n                    success(value)')
start = source(provider).index('            self.disposable.set((self.context.account.networkState')
end = source(provider).index('        case .entryTime:', start)
changes[provider] = source(provider)[:start] + (HERE / "proxy.fragment").read_text(encoding="utf-8") + source(provider)[end:]
replace(provider, 'let bytes = stats.totalStats.categories.values.reduce(Int64(0)) { $0 + $1.size }\n                success(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))', 'let bytes = stats.totalStats.categories.values.reduce(Int64(0)) { $0 + $1.size }\n                // Media cache label; device occupancy is a separate value.\n                let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())\n                let total = (attributes?[.systemSize] as? NSNumber)?.doubleValue ?? 0\n                let free = (attributes?[.systemFreeSize] as? NSNumber)?.doubleValue ?? 0\n                let progress = total > 0 ? min(1, max(0.05, (total - free) / total)) : 0.05\n                self.cachedStorageProgress = progress; self.storageProgress?(progress)\n                success(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))')
replace(provider, '        case .entryTime:\n            self.entryTimeRequestInFlight = true', '''        case .entryTime:
            if ExteraPillStackSettings.shared.entryTimeAutoRefresh(account: self.accountId) {
                self.entryEvents = exteraPresenceEvents(network: self.context.account.network).start(next: { [weak self] fetch in
                    guard let self, self.generation.accepts(ticket) else { return }
                    self.eventRefresh?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, !self.entryTimeRequestInFlight else { return }
                        self.start(.entryTime, force: true)
                    }
                    self.eventRefresh = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + (fetch ? 0 : 0.25), execute: work)
                })
            }
            self.entryTimeRequestInFlight = true''')

replace(view, '    private let content = UIView()', '    private let content = UIView()\n    private let storageRing = ExteraPillStorageRing()\n    private var phoneDisposable: Disposable?')
replace(view, '        self.content.addSubview(self.entryTimeIcon)', '''        self.content.addSubview(self.entryTimeIcon)
        self.content.addSubview(self.storageRing); self.storageRing.isHidden = true
        self.provider.storageProgress = { [weak self] value in
            self?.storageRing.isHidden = value == nil
            if let value { self?.storageRing.setProgress(value) }
        }
        self.phoneDisposable = (context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId)) |> deliverOnMainQueue).start(next: { [weak self] peer in
            if case let .user(user)? = peer {
                self?.provider.updatePhone(user.phone ?? "")
                self?.runningSignature = nil; self?.updateRunning()
            }
        })''')
replace(view, 'import SGSimpleSettings\n', 'import SGSimpleSettings\nimport SwiftSignalKit\nimport TelegramCore\n')
replace(view, '        self.provider.stop()\n', '        self.provider.stop(); self.phoneDisposable?.dispose()\n')
replace(view, '        if entryTime {', '        if entryTime || self.selected == ExteraBuiltinPill.storage.id {')
replace(view, '            self.entryTimeIcon.frame = CGRect(x: left, y: floor((self.bounds.height - 20) / 2), width: 20, height: 20)', '            self.entryTimeIcon.frame = CGRect(x: left, y: floor((self.bounds.height - 20) / 2), width: 20, height: 20)\n            self.storageRing.frame = CGRect(x: left + 2, y: floor((self.bounds.height - 16) / 2), width: 16, height: 16)')
replace(view, '        self.entryTimeIcon.tintColor = theme.list.itemPrimaryTextColor', '        self.entryTimeIcon.tintColor = theme.list.itemPrimaryTextColor\n        self.storageRing.tintColor = theme.list.itemPrimaryTextColor')
replace(view, '\\(store.currency(account: account))', '\\(ExteraBuiltinPill.from(id: selected).map { store.target($0, account: account) } ?? "").\\(self.provider.currency).\\(store.weather(account: account)).\\(TimeZone.current.identifier)')
replace(view, ' + store.currency(account: account)', ' + (kind.map { store.target($0, account: account) } ?? "AUTO")')
oldstart = source(view).index('                    let alert = UIAlertController(title: self.text("ISO Currency Code"')
oldend = source(view).index('\n                }))', oldstart)
changes[view] = source(view)[:oldstart] + '''                    let sheet = UIAlertController(title: self.text("Target Currency", "Валюта курса"), message: nil, preferredStyle: .actionSheet)
                    for code in ExteraPillCurrency.targets(for: kind) {
                        sheet.addAction(UIAlertAction(title: code + (store.target(kind, account: account) == code ? " ✓" : ""), style: .default) { _ in store.setTarget(code, kind: kind, account: account) })
                    }
                    sheet.addAction(UIAlertAction(title: self.text("Cancel", "Отмена"), style: .cancel))
                    sheet.popoverPresentationController?.sourceView = self; sheet.popoverPresentationController?.sourceRect = self.bounds
                    controller.present(sheet, animated: true)''' + source(view)[oldend:]
replace(view, 'if kind == .weather, self.provider.locationAuthorizationStatus == .notDetermined', 'if kind == .weather, store.weather(account: account).current, self.provider.locationAuthorizationStatus == .notDetermined')
replace(view, 'sheet.addAction(UIAlertAction(title: self.text("Location Settings", "Настройки геопозиции"), style: .default, handler: { _ in\n                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }\n                }))', 'sheet.addAction(UIAlertAction(title: self.text("Weather Settings", "Настройки погоды"), style: .default, handler: { [weak self, weak controller] _ in\n                    guard let self, let controller else { return }\n                    controller.present(ExteraPillWeatherSettingsController(account: account, language: self.language), animated: true)\n                }))')

# Editor retains fixed UITableView section identities during reorder.
replace(editor, '        self.custom = custom; self.layout = layout', '''        self.custom = custom; self.layout = layout
        self.navigationItem.rightBarButtonItem = layout.visible.isEmpty ? nil : UIBarButtonItem(title: self.text("Reset", "Сбросить"), style: .plain, target: self, action: #selector(self.resetStack))''')
replace(editor, '    @objc private func infiniteChanged', '''    @objc private func resetStack() {
        self.saveLayout { layout in
            let infinite = layout.infiniteScrolling
            layout = ExteraPillStackLayout().normalized(custom: self.custom)
            layout.infiniteScrolling = infinite
        }
    }
    @objc private func infiniteChanged''')
replace(editor, 'case 2: return self.text("Visible Widgets", "Видимые виджеты")', 'case 2: return self.layout.visible.isEmpty ? nil : self.text("Visible Widgets", "Видимые виджеты")')
replace(editor, 'if kind == .entryTime { cell.detailTextLabel?.text = self.text("Unavailable: no supported data provider", "Недоступно: нет поддерживаемого источника данных") }', 'if kind == .entryTime { cell.detailTextLabel?.text = self.text("This account’s server status", "Статус этого аккаунта с сервера") }')

replace(view, 'final class ExteraPillStackView: UIView {', 'final class ExteraPillStackView: UIView, UIGestureRecognizerDelegate {')
replace(view, '    private func step(_ direction: Int) {', (HERE / 'gesture.fragment').read_text(encoding='utf-8') + '\n    private func step(_ direction: Int) {')
replace(view, '        let up = UISwipeGestureRecognizer(target: self, action: #selector(self.swiped(_:))); up.direction = .up; self.addGestureRecognizer(up)\n        let down = UISwipeGestureRecognizer(target: self, action: #selector(self.swiped(_:))); down.direction = .down; self.addGestureRecognizer(down)', '        let pan = UIPanGestureRecognizer(target: self, action: #selector(self.panned(_:)))\n        pan.delegate = self; self.addGestureRecognizer(pan)')
replace(view, '    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) { self.step(gesture.direction == .up ? 1 : -1) }', '''    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        return self.ids.count > 1 && abs(velocity.y) > abs(velocity.x)
    }''')
replace(view, '        self.label.text = text', '        self.label.text = text\n        if let selected = self.selected { self.rememberedText[selected] = text }')
replace(view, '        self.runningSignature = nil; self.provider.stop()', '        self.cancelPan()\n        self.runningSignature = nil; self.provider.stop()')
replace(view, '        self.provider.stop(); self.phoneDisposable?.dispose()', '        self.panDisplayLink?.invalidate()\n        self.provider.stop(); self.phoneDisposable?.dispose()')
replace(view, '    private func openOptions() {', '''    private func openOptions(longPress: Bool = false) {''')
replace(view, 'self.openOptions() } }', 'self.openOptions(longPress: true) } }')
replace(view, '        if kind == .proxy {', '''        if longPress, kind == .proxy || kind == .storage {
            let sheet = UIAlertController(title: kind?.title(self.language), message: nil, preferredStyle: .actionSheet)
            if kind == .storage {
                sheet.addAction(UIAlertAction(title: self.text("Storage Usage", "Использование памяти"), style: .default) { [weak self] _ in
                    guard let self else { return }; self.context.sharedContext.openStorageUsage(context: self.context)
                })
                sheet.addAction(UIAlertAction(title: self.text("Refresh", "Обновить"), style: .default) { [weak self] _ in self?.updateRunning(force: true) })
            }
            sheet.addAction(UIAlertAction(title: self.text("Settings", "Настройки"), style: .default) { [weak self, weak controller] _ in
                guard let self, let controller else { return }
                (controller.navigationController as? NavigationController)?.pushViewController(exteraPillDashboardController(context: self.context))
            })
            sheet.addAction(UIAlertAction(title: self.text("Cancel", "Отмена"), style: .cancel))
            sheet.popoverPresentationController?.sourceView = self; sheet.popoverPresentationController?.sourceRect = self.bounds
            controller.present(sheet, animated: true); return
        }
        if kind == .proxy {''')

add("submodules/ChatListUI/Sources/ExteraPillStorageUsage.swift", "ExteraPillStorageUsage.swift")
add("submodules/ChatListUI/Sources/ExteraPillWeakDisplayLink.swift", "ExteraPillWeakDisplayLink.swift")
replace(core, '    return exteraPresenceBarrier(network: account.network)\n    |> mapToSignal', '    return exteraPresenceBarrier(network: account.network)\n    |> castError(MTRpcError.self)\n    |> mapToSignal')
replace(core, 'import Foundation\n', 'import Foundation\nimport MtProtoKit\n')
replace(core, '            return exteraAccountEntryStatus(data.status)', '            let status = exteraAccountEntryStatus(data.status)\n            exteraRecordEntryStatus(status, network: account.network)\n            return status')
replace(provider, 'exteraPresenceEvents(network: self.context.account.network)', 'exteraPresenceEvents(account: self.context.account)')
replace(provider, '            self.entryTimeRequestInFlight = true', '''            if !force, let cached = exteraCachedEntryStatusOnAttach(account: self.context.account) {
                self.entryTimeStatus = cached; publish(self.entryTimeText(cached)); return
            }
            self.entryTimeRequestInFlight = true''')
replace(view, 'var hostVisible = false { didSet { self.updateRunning() } }', '''var hostVisible = false { didSet {
        if self.hostVisible && !oldValue { exteraEntryStatusDialogsAppeared(account: self.context.account) }
        self.updateRunning()
    } }''')
replace('submodules/TelegramCore/Sources/UpdatePeers.swift', 'func updatePeerPresencesClean(transaction: Transaction, accountPeerId: PeerId, peerPresences: [PeerId: UpdatedApiPresence]) {', '''func updatePeerPresencesClean(transaction: Transaction, accountPeerId: PeerId, peerPresences: [PeerId: UpdatedApiPresence]) {
    // Observe an actual self status before the existing cache exclusion removes it.
    // UI-only notification: no new request, read-state write or presence mutation.
    if peerPresences[accountPeerId] != nil { ayuSelfPresenceObserved(peerId: accountPeerId) }''')
replace(ghost, 'return (.single(true) |> delay(0.2, queue: .mainQueue()))', 'return (Signal<Bool, MTRpcError>.single(true) |> delay(0.2, queue: .mainQueue()))')
start = source(ghost).index('        let _ = ayuTrackedPresence(network: network, operation:\n')
end = source(ghost).index('    } else if settings.sendAutomaticOffline {', start)
changes[ghost] = source(ghost)[:start] + '        let _ = ayuTrackedPresence(network: network, operation: ayuPresencePulse(network: network)).start()\n' + source(ghost)[end:]
replace(ghost, 'let _ = ayuTrackedPresence(network: network, operation: network.request(Api.functions.account.updateStatus(offline: .boolTrue))).start()', 'let _ = ayuTrackedPresence(network: network, operation: network.request(Api.functions.account.updateStatus(offline: .boolTrue))).start()\n        AyuGhostLastSeen.shared.recordNow()')
replace(provider, '            if weatherSettings.current { weather = Weather.getWeatherData(context: self.context, load: true) }', '''            if weatherSettings.current {
                guard CLLocationManager.locationServicesEnabled() else { publish(self.text("Enable Location Services", "Включите службы геопозиции")); return }
                weather = Weather.getWeatherData(context: self.context, load: true)
            }''')
replace(provider, 'deinit { self.disposable.dispose(); self.request?.cancel(); self.entryTimeHideTimer?.invalidate() }', 'deinit { self.disposable.dispose(); self.entryEvents?.dispose(); self.eventRefresh?.cancel(); self.request?.cancel(); self.entryTimeHideTimer?.invalidate() }')
replace(view, '            let source = self.provider.weatherSource\n            message =', '''            let source = self.provider.weatherSource
            let mode = store.weather(account: account)
            let location = mode.current ? self.text("current location", "текущая геопозиция") : self.text("selected map coordinates", "выбранные координаты на карте")
            message = self.text("Uses Telegram weather bot @\\(source). Sends \\(location) for this account while selected. You can revoke access below.", "Использует погодного бота Telegram @\\(source). Передаёт \\(location) от этого аккаунта, пока выбран виджет. Разрешение можно отозвать ниже.")
            /* previous explanation retained only in generator source */
            let unusedExplanation =''')
# Remove old explanation rather than leave a warnings-as-errors unused local.
start = source(view).index('            /* previous explanation retained only in generator source */')
end = source(view).index('\n        } else if kind != nil {', start)
changes[view] = source(view)[:start] + source(view)[end:]
start = source(provider).index('            self.disposable.set((self.context.engine.resources.collectStorageUsageStats()')
end = source(provider).index('        case .proxy:', start)
changes[provider] = source(provider)[:start] + '''            self.disposable.set((exteraPillStorageUsage(context: self.context) |> deliverOnMainQueue).start(next: { [weak self] stats in
                guard let self, self.generation.accepts(ticket) else { return }
                self.cachedStorageProgress = stats.occupiedFraction
                self.storageProgress?(stats.occupiedFraction)
                success(ByteCountFormatter.string(fromByteCount: stats.cacheBytes, countStyle: .file))
            }))
''' + source(provider)[end:]
replace(provider, '    var currency: String {\n        let kind = self.selectedKind ?? .gram\n        return ExteraPillCurrency.resolve(ExteraPillStackSettings.shared.target(kind, account: self.accountId), phone: self.phoneNumber)\n    }', '''    var currency: String { self.currency(for: self.selectedKind ?? .gram) }
    func currency(for kind: ExteraBuiltinPill) -> String {
        ExteraPillCurrency.resolve(ExteraPillStackSettings.shared.target(kind, account: self.accountId), phone: self.phoneNumber)
    }''')
replace(view, '\\(self.provider.currency)', '\\(ExteraBuiltinPill.from(id: selected).map { self.provider.currency(for: $0) } ?? "")')
add("submodules/TelegramCore/Tests/ExteraPresenceBarrierTests.swift", "ExteraPresenceBarrierTests.swift")
add("Tests/ExteraPills/ParityHostTests.swift", "ParityHostTests.swift")
patch = []
manifest = {}
for name, updated in changes.items():
    before = bases[name]
    if before == updated:
        continue
    manifest[name] = hashlib.sha256(before.encode()).hexdigest() if before else None
    patch.extend(difflib.unified_diff(before.splitlines(True), updated.splitlines(True), fromfile="a/" + name if before else "/dev/null", tofile="b/" + name))
(HERE / "pill-next-wave.patch").write_text("".join(patch), encoding="utf-8", newline="\n")
(HERE / "base-sha256.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
# Stage reconstructed source under this documentation directory for syntax review.
for name, updated in changes.items():
    target = HERE / "review" / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(updated, encoding="utf-8", newline="\n")
print(f"Prepared review-only patch for {len(manifest)} files. Production sources untouched.")
