import Foundation

enum RezkaEndpoints {
    static let mirrorConfiguration = URL(string: "https://raw.githubusercontent.com/lastrowcritic/rezka-ios/main/mirrors.json")!
    static let fallbackHosts = ["hdrezka-home.tv", "hdrezka.ink", "hdrezka.loan", "hdrezka.tv", "rezka-ua.co", "rezka.ag"]
    static let search = "/search/"
    static let player = "/ajax/get_cdn_series/"
    static let comments = "/ajax/get_comments/"
    static let collections = "/collections/"

    static func ajaxURL(path: String, baseURL: URL, now: Date = .now) throws -> URL {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true) else {
            throw RezkaError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "t", value: String(Int64(now.timeIntervalSince1970 * 1000)))]
        guard let url = components.url else { throw RezkaError.invalidURL }
        return url
    }

    static func formData(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._*"))
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        return Data(fields.sorted(by: { $0.key < $1.key }).map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&").utf8)
    }
}

enum RezkaSelectors {
    static let cards = ".b-content__inline_item"
    static let cardTitle = ".b-content__inline_item-link a"
    static let cardInfo = ".b-content__inline_item-link div"
    static let title = ".b-content__main .b-post__title [itemprop=name], .b-post__title [itemprop=name]"
    static let originalTitle = ".b-content__main .b-post__origtitle"
    static let poster = ".b-content__main .b-sidecover img"
    static let description = ".b-content__main .b-post__description_text"
    static let rating = ".b-content__main span [itemprop=average]"
    static let information = "table.b-post__info tr"
    static let translators = ".b-translator__item"
    static let seasons = ".b-simple_season__item"
    static let episodes = ".b-simple_episode__item"
    static let collections = ".b-content__collections_item"
    static let franchise = ".b-post__partcontent_item"
    static let schedule = ".b-post__schedule_block"
    static let comments = ".b-comment, li.comments-tree-item, div[id^=comment-id-]"
    static let navigation = ".b-navigation a"
}

enum RezkaProtection {
    static let markers = ["just a moment", "attention required", "cf-browser-verification", "cf-turnstile", "challenge-platform", "anubis_challenge"]

    static func isChallenge(_ html: String) -> Bool {
        let lower = html.lowercased()
        return markers.contains { lower.contains($0) }
    }
}
