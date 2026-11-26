import AccountContext
import Display

/// Keeps server capability checks, enable confirmation and age verification in
/// the native flow. The focus tag highlights the row when this account can adjust it.
public func exteraSensitiveContentSettingsController(context: AccountContext) -> ViewController {
    return dataAndStorageController(context: context, focusOnItemTag: .sensitiveContent)
}
