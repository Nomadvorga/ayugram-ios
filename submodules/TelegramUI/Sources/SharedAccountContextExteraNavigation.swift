import AccountContext
import Display
import SGSettingsUI

extension SharedAccountContextImpl {
    public func makeExteraFeedController(context: AccountContext) -> ViewController? {
        return exteraFeedController(context: context)
    }
}
