// Host stand-in for the SGLogging module.
public final class SGLogger {
    public static let shared = SGLogger()

    public func log(_ tag: String, _ what: @autoclosure () -> String) {
    }
}
