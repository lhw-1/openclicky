//
//  AppRegion.swift
//  OpenClicky
//
//  India or the rest of the world (Settings → General → Region). Much of OpenClicky is built for
//  Indian users: Sarvam (engine, voice, key), ten Indian dictation languages, seven Indian Clicky
//  languages, the native-or-roman script. Outside India those are clutter, so the region decides
//  what the settings offer. It never changes what is set: an option already in use stays offered
//  whatever the region says.
//
//  Until someone picks, the region follows the Mac: India when its region is India or its time
//  zone is India's.
//

import Foundation

enum AppRegion: String, CaseIterable, Identifiable {
    case india
    case world
    var id: String { rawValue }

    var title: String {
        switch self {
        case .india: return "India"
        case .world: return "Rest of the world"
        }
    }

    /// What this Mac looks like it is set up for.
    static func detected(regionCode: String? = Locale.current.region?.identifier,
                         timeZoneIdentifier: String = TimeZone.current.identifier) -> AppRegion {
        if regionCode == "IN" { return .india }
        if timeZoneIdentifier == "Asia/Kolkata" || timeZoneIdentifier == "Asia/Calcutta" { return .india }
        return .world
    }

    /// Whether the settings offer what only Indian users need.
    var offersIndianOptions: Bool { self == .india }

    /// The Clicky languages from `ReplyLanguage.choices` that only India needs.
    static let indianReplyLanguageCodes: Set<String> = ["hi", "ta", "te", "bn", "mr", "kn", "ml"]
}

extension DictationLanguage {
    /// Whether this is one of the Indian languages (English counts as India's only in its en-IN form).
    var isIndian: Bool { code.hasSuffix("-IN") && code != "en-IN" }

    /// The pinnable languages the region offers, in picker order, always keeping `current`.
    static func pinnableChoices(region: AppRegion, current: DictationLanguage) -> [DictationLanguage] {
        let offered = region == .india ? indianChoices : worldChoices
        if current == .auto || offered.contains(current) { return offered }
        return offered + [current]
    }

    /// What "Pin one" starts on when nothing was pinned before.
    static func defaultPinned(region: AppRegion) -> DictationLanguage {
        region == .india ? named("en-IN") : named("en-US")
    }

    private static var indianChoices: [DictationLanguage] { choices.filter { $0 != .auto && $0.code.hasSuffix("-IN") } }
    private static var worldChoices: [DictationLanguage] { choices.filter { $0 != .auto && !$0.code.hasSuffix("-IN") } }
}

extension ReplyLanguage {
    /// The Clicky languages the region offers, always keeping `currentCode`.
    static func choices(region: AppRegion, currentCode: String) -> [Choice] {
        choices.filter { choice in
            region.offersIndianOptions || !AppRegion.indianReplyLanguageCodes.contains(choice.code) || choice.code == currentCode
        }
    }
}
