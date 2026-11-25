import Display

public extension SharedAccountContext {
    /// Lightweight hosts such as the composer harness do not install the optional feed UI.
    func makeExteraFeedController(context: AccountContext) -> ViewController? { return nil }
}
