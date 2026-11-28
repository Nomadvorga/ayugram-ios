import AccountContext
import Foundation
import SGSimpleSettings
import SwiftSignalKit
import TelegramCore

/// Read-only remote support catalog. No channel join, read receipt, bot start or payment is sent.
/// The APK's RemoteTelegram reads the same two channel ids; mutable usernames must still match ids.
final class ExteraOtherSupportContext {
    typealias Model = ExteraOtherSettingsModel
    struct Snapshot: Equatable {
        var loading = false
        var configurations: [Model.Project: Model.SupportConfiguration] = [:]
        var unavailable = Set<Model.Project>()
    }
    private let context: AccountContext
    private let operation = MetaDisposable()
    private(set) var snapshot = Snapshot()
    let state = ValuePromise(Snapshot(), ignoreRepeated: true)

    init(context: AccountContext) { self.context = context }
    deinit { self.operation.dispose() }

    func reload() {
        guard !self.snapshot.loading else { return }
        self.snapshot.loading = true
        self.state.set(self.snapshot)
        self.operation.set((combineLatest(
            self.load(project: .extera, name: "XS6GEcz5ZXMu82UvXQc", id: 2227431611),
            self.load(project: .ayu, name: "UFhsu4hOFEufes73fkEeuw", id: 2180718299)
        ) |> deliverOnMainQueue).start(next: { [weak self] extera, ayu in
            guard let self else { return }
            self.snapshot.loading = false
            for (project, config) in [(Model.Project.extera, extera), (.ayu, ayu)] {
                if let config {
                    self.snapshot.configurations[project] = config
                    self.snapshot.unavailable.remove(project)
                } else {
                    // Do not retain stale payment addresses after a failed refresh.
                    self.snapshot.configurations.removeValue(forKey: project)
                    self.snapshot.unavailable.insert(project)
                }
            }
            self.state.set(self.snapshot)
        }))
    }

    private func load(project: Model.Project, name: String, id: Int64) -> Signal<Model.SupportConfiguration?, NoError> {
        return self.context.engine.peers.resolvePeerByName(name: name, referrer: nil, ageLimit: 0)
        |> mapToSignal { [context = self.context] result -> Signal<Model.SupportConfiguration?, NoError> in
            switch result {
            case .progress: return .complete()
            case let .result(peer):
                guard let peer, case .channel = peer, peer.id.namespace == Namespaces.Peer.CloudChannel,
                    peer.id.id._internalGetInt64Value() == id else { return .single(nil) }
                return context.engine.messages.searchMessages(location: .peer(peerId: peer.id, fromId: nil, tags: nil, reactions: nil, threadId: nil, minDate: nil, maxDate: nil), query: "", state: nil, limit: 50)
                |> map { result, _ in
                    let messages = result.messages.sorted { $0.id.id < $1.id.id }.map { $0.text }
                    return Model.parseSupport(messages: messages, project: project)
                }
            }
        }
        |> take(1)
        |> timeout(12.0, queue: .mainQueue(), alternate: .single(nil))
    }
}
