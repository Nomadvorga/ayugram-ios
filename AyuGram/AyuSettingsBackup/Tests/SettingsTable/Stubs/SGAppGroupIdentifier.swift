// Host stand-in for the SGAppGroupIdentifier module: a throwaway UserDefaults suite, which run.sh deletes.
public func sgAppGroupIdentifier() -> String {
    return "ayu.backup.host.test"
}
