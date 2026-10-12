import Foundation

struct MediaCountry: Identifiable, Sendable {
    let id: String
    let name: String

    static let all: [MediaCountry] = {
        let english = Locale(identifier: "en")
        var countries = Locale.Region.isoRegions.compactMap { region -> MediaCountry? in
            let code = region.identifier
            guard code.count == 2, let name = english.localizedString(forRegionCode: code) else { return nil }
            return MediaCountry(id: code, name: name)
        }
        countries.append(MediaCountry(id: "SU", name: "Soviet Union"))
        countries.append(MediaCountry(id: "YU", name: "Yugoslavia"))
        return countries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    private static let aliases: [String: String] = {
        var names: [String: String] = [:]
        for country in all {
            names[normalize(country.name)] = country.id
            names[normalize(country.id)] = country.id
            for identifier in ["ru", "uk", "en"] {
                if let name = Locale(identifier: identifier).localizedString(forRegionCode: country.id) {
                    names[normalize(name)] = country.id
                }
            }
        }
        let extra = ["США": "US", "USA": "US", "U.S.A.": "US", "United States of America": "US",
                     "Россия": "RU", "Российская Федерация": "RU", "Russia": "RU",
                     "СССР": "SU", "USSR": "SU", "Югославия": "YU",
                     "Великобритания": "GB", "Англия": "GB", "UK": "GB", "Great Britain": "GB",
                     "Южная Корея": "KR", "Корея Южная": "KR", "Корея (Южная)": "KR", "South Korea": "KR",
                     "Северная Корея": "KP", "Корея Северная": "KP", "North Korea": "KP",
                     "Гонконг": "HK", "Иран": "IR", "Тайвань": "TW", "Чехия": "CZ"]
        for (name, code) in extra { names[normalize(name)] = code }
        return names
    }()

    static func codes(in value: String) -> [String] {
        var seen = Set<String>()
        return value.components(separatedBy: CharacterSet(charactersIn: ",;/\n"))
            .compactMap { aliases[normalize($0)] }
            .filter { seen.insert($0).inserted }
    }

    static func isExcluded(_ item: MediaItem, codes excluded: Set<String>) -> Bool {
        let codes = item.countryCodes?.nonEmptyCountries ?? codes(in: item.metadata?.information["Страна"] ?? "")
        return !excluded.isDisjoint(with: codes)
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))
    }
}

extension Array where Element == String {
    var nonEmptyCountries: [String]? { isEmpty ? nil : self }
}
