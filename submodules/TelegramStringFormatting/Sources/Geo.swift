import Foundation
import MapKit
import TelegramPresentationData
import SGSimpleSettings

/// Shared by map labels and the proximity-radius picker. Wire units here, never change metres
/// sent to TelegramEngine or locale-dependent number spelling.
public func usesMetricDistanceUnits(strings: PresentationStrings) -> Bool {
    return ExteraChatAppearanceSettings.shared.distanceUnit.usesMetricSystem(locale: localeWithStrings(strings))
}

private func applyDistanceUnits(_ formatter: MKDistanceFormatter) {
    switch ExteraChatAppearanceSettings.shared.distanceUnit {
    case .automatic: formatter.units = .default
    case .kilometers: formatter.units = .metric
    case .miles: formatter.units = .imperial
    }
}

private let distanceFormatterLock = NSLock()

private var sharedShortDistanceFormatter: MKDistanceFormatter?
public func shortStringForDistance(strings: PresentationStrings, distance: Int32) -> String {
    distanceFormatterLock.lock()
    defer { distanceFormatterLock.unlock() }
    let distanceFormatter: MKDistanceFormatter
    if let currentDistanceFormatter = sharedShortDistanceFormatter {
        distanceFormatter = currentDistanceFormatter
    } else {
        distanceFormatter = MKDistanceFormatter()
        distanceFormatter.unitStyle = .abbreviated
        sharedShortDistanceFormatter = distanceFormatter
    }
    
    let locale = localeWithStrings(strings)
    if distanceFormatter.locale != locale {
        distanceFormatter.locale = locale
    }
    
    applyDistanceUnits(distanceFormatter)
    let distance = max(1, distance)
    var result = distanceFormatter.string(fromDistance: Double(distance))
    if result.hasPrefix("0 ") {
        result = result.replacingOccurrences(of: "0 ", with: "1 ")
    }
    return result
}

private var sharedDistanceFormatter: MKDistanceFormatter?
public func stringForDistance(strings: PresentationStrings, distance: CLLocationDistance) -> String {
    distanceFormatterLock.lock()
    defer { distanceFormatterLock.unlock() }
    let distanceFormatter: MKDistanceFormatter
    if let currentDistanceFormatter = sharedDistanceFormatter {
        distanceFormatter = currentDistanceFormatter
    } else {
        distanceFormatter = MKDistanceFormatter()
        distanceFormatter.unitStyle = .full
        sharedDistanceFormatter = distanceFormatter
    }
    
    let locale = localeWithStrings(strings)
    if distanceFormatter.locale != locale {
        distanceFormatter.locale = locale
    }
    
    applyDistanceUnits(distanceFormatter)
    return distanceFormatter.string(fromDistance: distance)
}

public func flagEmoji(countryCode: String) -> String {
    if countryCode.uppercased() == "FT" {
        return "🏴‍☠️"
    }
    if countryCode.uppercased() == "XX" {
        return "🏳️"
    }
    let base : UInt32 = 127397
    var flagString = ""
    for v in countryCode.uppercased().unicodeScalars {
        flagString.unicodeScalars.append(UnicodeScalar(base + v.value)!)
    }
    return flagString
}
