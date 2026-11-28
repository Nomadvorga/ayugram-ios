import Foundation

/// Bounds callback handoff without blocking main. Revocation wins until `enter` begins.
/// The Python runtime also verifies callback generation on its interpreter queue.
final class AyuBridgeCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [String: UUID] = [:]
    private var pending: [String: Int] = [:]
    private var tokens: [String: String] = [:]
    func activate(owner: String, generation: UUID) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.generations[owner] = generation
    }
    func revoke(owner: String) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.generations.removeValue(forKey: owner)
        self.pending.removeValue(forKey: owner)
        self.tokens = self.tokens.filter { $0.value != owner }
    }
    func register(token: String, owner: String) {
        self.lock.lock(); defer { self.lock.unlock() }; self.tokens[token] = owner
    }
    func cancel(token: String, owner: String) {
        self.lock.lock(); defer { self.lock.unlock() }
        if self.tokens[token] == owner { self.tokens.removeValue(forKey: token) }
    }
    func reserve(owner: String, generation: UUID, limit: Int) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.generations[owner] == generation, self.pending[owner, default: 0] < limit else { return false }
        self.pending[owner, default: 0] += 1; return true
    }
    func enter(owner: String, generation: UUID, token: String?) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.generations[owner] == generation else { return false }
        if let token {
            guard self.tokens[token] == owner else { return false }
            self.tokens.removeValue(forKey: token)
        }
        return true
    }
    /// `enter` without consuming the token: asked again while the callback waits in a queue.
    func isLive(owner: String, generation: UUID, token: String?) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.generations[owner] == generation else { return false }
        return token.map { self.tokens[$0] == owner } ?? true
    }
    func finish(owner: String) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.pending[owner] = max(0, self.pending[owner, default: 0] - 1)
        if self.pending[owner] == 0 { self.pending.removeValue(forKey: owner) }
    }
}

/// JSONDecoder validates values; this bounded structural pass additionally rejects duplicate
/// object keys (including equivalent escaped spellings) before JSONDecoder discards evidence.
enum AyuBridgeJSONValidation {
    static func validate(_ data: Data) throws {
        var parser = Parser(bytes: Array(data))
        try parser.value(depth: 0)
        parser.space()
        guard parser.position == parser.bytes.count else { throw Parser.failure }
    }
    private struct Parser {
        static var failure: AyuBridgeFailure { AyuBridgeFailure("invalid_request", "Malformed or duplicate-key JSON") }
        let bytes: [UInt8]
        var position = 0
        mutating func space() {
            while self.position < self.bytes.count, [9, 10, 13, 32].contains(self.bytes[self.position]) { self.position += 1 }
        }
        mutating func take(_ byte: UInt8) throws {
            self.space()
            guard self.position < self.bytes.count, self.bytes[self.position] == byte else { throw Self.failure }
            self.position += 1
        }
        mutating func string() throws -> String {
            self.space()
            let start = self.position
            try self.take(34)
            var escaped = false
            while self.position < self.bytes.count {
                let byte = self.bytes[self.position]; self.position += 1
                if escaped { escaped = false; continue }
                if byte == 92 { escaped = true; continue }
                if byte == 34 {
                    return try JSONDecoder().decode(String.self, from: Data(self.bytes[start..<self.position]))
                }
                guard byte >= 32 else { throw Self.failure }
            }
            throw Self.failure
        }
        mutating func value(depth: Int) throws {
            guard depth < 32 else { throw AyuBridgeFailure("resource_limit", "JSON nesting limit exceeded") }
            self.space()
            guard self.position < self.bytes.count else { throw Self.failure }
            switch self.bytes[self.position] {
            case 123:
                self.position += 1; self.space()
                if self.position < self.bytes.count, self.bytes[self.position] == 125 { self.position += 1; return }
                var keys: Set<String> = []
                while true {
                    let key = try self.string()
                    guard keys.insert(key).inserted else { throw Self.failure }
                    try self.take(58); try self.value(depth: depth + 1); self.space()
                    guard self.position < self.bytes.count else { throw Self.failure }
                    if self.bytes[self.position] == 125 { self.position += 1; return }
                    try self.take(44)
                }
            case 91:
                self.position += 1; self.space()
                if self.position < self.bytes.count, self.bytes[self.position] == 93 { self.position += 1; return }
                while true {
                    try self.value(depth: depth + 1); self.space()
                    guard self.position < self.bytes.count else { throw Self.failure }
                    if self.bytes[self.position] == 93 { self.position += 1; return }
                    try self.take(44)
                }
            case 34: _ = try self.string()
            default:
                let start = self.position
                while self.position < self.bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(self.bytes[self.position]) { self.position += 1 }
                guard self.position > start else { throw Self.failure }
                let token = Data(self.bytes[start..<self.position])
                let first = self.bytes[start]
                if (first == 45 || (48...57).contains(first)), !token.contains(46), !token.contains(69), !token.contains(101) {
                    _ = try JSONDecoder().decode(Int64.self, from: token)
                } else { _ = try JSONDecoder().decode(AyuBridgeValue.self, from: token) }
            }
        }
    }
}
