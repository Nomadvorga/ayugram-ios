import Display
import ItemListUI

/// Carries appearance in entry equality so unchanged rows and their neighbors are
/// regenerated when a global setting changes. Wrap every row after search filtering.
/// Keep this entry type for the controller's lifetime, including native mode.
public struct SGStyledItemListEntry<Section: SGItemListSection, BoolSetting: Hashable, SliderSetting: Hashable, OneFromManySetting: Hashable, DisclosureLink: Hashable, ActionType: Hashable>: ItemListNodeEntry {
    public let entry: SGItemListUIEntry<Section, BoolSetting, SliderSetting, OneFromManySetting, DisclosureLink, ActionType>
    public let appearance: SGExteraAppearance

    public init(entry: SGItemListUIEntry<Section, BoolSetting, SliderSetting, OneFromManySetting, DisclosureLink, ActionType>, appearance: SGExteraAppearance) {
        self.entry = entry
        self.appearance = appearance
    }

    public var stableId: Int { return self.entry.stableId }
    public var section: ItemListSectionId { return self.entry.section }
    public var tag: ItemListItemTag? { return self.entry.tag }

    public static func <(lhs: Self, rhs: Self) -> Bool { return lhs.entry < rhs.entry }

    public static func ==(lhs: Self, rhs: Self) -> Bool {
        return lhs.entry == rhs.entry && lhs.appearance == rhs.appearance
    }

    public func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SGItemListArguments<BoolSetting, SliderSetting, OneFromManySetting, DisclosureLink, ActionType>
        let styledArguments = SGItemListArguments(
            context: arguments.context,
            visualStyle: arguments.visualStyle,
            exteraAppearance: self.appearance,
            setBoolValue: arguments.setBoolValue,
            updateSliderValue: arguments.updateSliderValue,
            setOneFromManyValue: arguments.setOneFromManyValue,
            openDisclosureLink: arguments.openDisclosureLink,
            action: arguments.action,
            searchInput: arguments.searchInput,
            setExpanded: arguments.setExpanded,
            setSegmentedValue: arguments.setSegmentedValue
        )
        return self.entry.item(presentationData: presentationData, arguments: styledArguments)
    }
}
