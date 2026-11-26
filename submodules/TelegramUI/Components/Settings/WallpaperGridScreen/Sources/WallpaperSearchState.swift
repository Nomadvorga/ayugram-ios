import Foundation

/// Pure query and pagination state for the configured image inline bot.
/// The controller owns the signal; this value rejects stale pages by identity.
struct WallpaperSearchQuery: Equatable {
    static let colors = ["Blue", "Red", "Orange", "Yellow", "Green", "Teal", "Purple", "Pink", "Brown", "Black", "Gray", "White"]

    let text: String
    let color: String?

    init(text: String, color: String?) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.color = color.flatMap { Self.colors.contains($0) ? $0 : nil }
    }

    var botQuery: String? {
        guard !self.text.isEmpty || self.color != nil else {
            return nil
        }
        return "#wallpaper " + (self.color.map { "#color\($0) " } ?? "") + self.text
    }
}

struct WallpaperSearchState<Item> {
    struct Request: Equatable {
        let generation: Int
        let query: String
        let offset: String
    }

    private(set) var items: [Item] = []
    private(set) var query = WallpaperSearchQuery(text: "", color: nil)
    private(set) var failed = false
    private(set) var request: Request?

    private var generation = 0
    private var nextOffset: String?
    private var ids: Set<String> = []

    var canLoadMore: Bool {
        return self.request == nil && self.nextOffset != nil
    }

    mutating func reset(_ query: WallpaperSearchQuery) {
        self.generation += 1
        self.query = query
        self.items.removeAll()
        self.ids.removeAll()
        self.request = nil
        self.failed = false
        self.nextOffset = query.botQuery == nil ? nil : ""
    }

    mutating func begin() -> Request? {
        guard self.request == nil, let offset = self.nextOffset, let query = self.query.botQuery else {
            return nil
        }
        let request = Request(generation: self.generation, query: query, offset: offset)
        self.request = request
        self.failed = false
        return request
    }

    mutating func receive(_ request: Request, items: [Item], nextOffset: String?, id: (Item) -> String) {
        guard self.request == request else {
            return
        }
        self.request = nil
        let previousCount = self.items.count
        for item in items where self.ids.insert(id(item)).inserted {
            self.items.append(item)
        }
        if self.items.count == previousCount || nextOffset?.isEmpty != false || nextOffset == request.offset {
            self.nextOffset = nil
        } else {
            self.nextOffset = nextOffset
        }
    }

    mutating func fail(_ request: Request) {
        guard self.request == request else {
            return
        }
        self.request = nil
        self.failed = true
    }
}
