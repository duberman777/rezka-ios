import Foundation
import SwiftSoup

struct RezkaPageParser: Sendable {
    func catalogue(html: String, baseURL: URL, page: Int = 1) throws -> RezkaCataloguePage {
        let document = try document(html, baseURL)
        let cards = try document.select(RezkaSelectors.cards).array()
        var seen = Set<String>()
        let items = try cards.compactMap { card -> MediaItem? in
            let anchor = try card.select(RezkaSelectors.cardTitle).first()
            let title = try anchor?.text() ?? ""
            let rawURL = try card.attr("data-url").nonEmpty ?? anchor?.attr("href") ?? ""
            guard !title.isEmpty, let url = resolve(rawURL, baseURL) else { return nil }
            let movieID = try card.attr("data-id").nonEmpty ?? firstMatch("(?:^|/)([0-9]+)-", in: url.path) ?? ""
            guard !movieID.isEmpty, seen.insert(movieID).inserted else { return nil }
            let info = try text(card, RezkaSelectors.cardInfo)
            let kind = mediaKind(url: url)
            let genres = info.components(separatedBy: ",").dropFirst(2).joined(separator: ", ").trimmingCharacters(in: .whitespaces)
            return MediaItem(
                id: movieID, title: title, originalTitle: nil,
                year: firstMatch("\\b((?:19|20)[0-9]{2})\\b", in: info).flatMap(Int.init),
                kind: kind, genre: genres.nonEmpty ?? info, synopsis: "", durationMinutes: nil,
                symbol: kind == .series ? "tv" : "film", paletteIndex: Int(movieID).map { $0 % 8 } ?? 0,
                streamURL: nil, posterURL: try imageURL(card, "img", baseURL),
                rezka: RezkaMedia(movieID: movieID, pageURL: url, isSeries: url.path.contains("/series/")),
                countryCodes: MediaCountry.codes(in: info).nonEmptyCountries
            )
        }
        let hasNext = try document.select(RezkaSelectors.navigation).array().contains { link in
            let label = try link.text()
            if let number = Int(label), number > page { return true }
            let href = try link.attr("href")
            return href.contains("/page/\(page + 1)/") || href.contains("page=\(page + 1)")
        }
        var categoryPaths = Set<String>()
        let categories = try document.select("a[href]").array().compactMap { anchor -> RezkaCategory? in
            guard let url = resolve(try anchor.attr("href"), baseURL),
                  url.path.range(of: "^/(films|series|cartoons|animation)/[a-z-]+/?$", options: .regularExpression) != nil,
                  !url.path.contains("/best/"), !url.path.hasSuffix("/best") else { return nil }
            let title = try anchor.text()
            guard !title.isEmpty, categoryPaths.insert(url.path).inserted else { return nil }
            return RezkaCategory(title: title, url: url, kind: mediaKind(url: url))
        }
        return RezkaCataloguePage(items: items, hasNextPage: hasNext, categories: categories)
    }

    func details(html: String, baseURL: URL, item: MediaItem) throws -> MediaItem {
        let document = try document(html, baseURL)
        let title = try text(document, RezkaSelectors.title)
        guard !title.isEmpty else { throw RezkaError.invalidPage("Rezka returned an unexpected title page. Try another mirror.") }
        var result = item
        result.title = title
        result.originalTitle = try text(document, RezkaSelectors.originalTitle).nonEmpty
        result.synopsis = try text(document, RezkaSelectors.description)
        // The image in b-sidecover is a thumbnail. Its lightbox link is the original cover.
        let originalCover = try document.select(".b-sidecover a[data-imagelightbox=cover]").first()?.attr("href") ?? ""
        let thumbnail = try imageURL(document, RezkaSelectors.poster, baseURL)
        result.posterURL = resolve(originalCover, baseURL) ?? thumbnail ?? item.posterURL
        result.previewPosterURL = thumbnail
        var metadata = RezkaMetadata()
        metadata.rating = try text(document, RezkaSelectors.rating).nonEmpty
        metadata.imdb = try rating(document, ".b-post__info_rates.imdb", baseURL)
        metadata.kinopoisk = try rating(document, ".b-post__info_rates.kp", baseURL)
        metadata.directors = try people(document, "[itemprop=director]", baseURL)
        metadata.actors = try people(document, "[itemprop=actor]", baseURL)
        metadata.genres = try document.select("[itemprop=genre]").array().map { try $0.text() }
        for row in try document.select(RezkaSelectors.information).array() {
            let label = try text(row, "td.l h2").trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            let value = try text(row, "td:not(.l)")
            if !label.isEmpty, !value.isEmpty { metadata.information[label] = value }
        }
        result.genre = metadata.genres.joined(separator: ", ").nonEmpty ?? item.genre
        result.durationMinutes = firstMatch("([0-9]+)", in: metadata.information["Время"] ?? "").flatMap(Int.init)
        result.year = firstMatch("\\b((?:19|20)[0-9]{2})\\b", in: metadata.information["Дата выхода"] ?? "").flatMap(Int.init) ?? item.year
        metadata.rankings = try links(document, "tr td a[href*=/best/]", baseURL)
        metadata.collections = try links(document, "tr td a[href*=/collections/]", baseURL)
        metadata.franchiseTitle = try text(document, ".b-post__franchise_link_title").nonEmpty
        metadata.franchise = try document.select(RezkaSelectors.franchise).array().compactMap { row in
            guard let anchor = try row.select(".td.title a").first(), let url = resolve(try anchor.attr("href"), baseURL) else { return nil }
            return RezkaFranchiseItem(title: try anchor.text(), url: url, year: try text(row, ".td.year"), rating: try text(row, ".td.rating i"))
        }
        metadata.schedule = try document.select(RezkaSelectors.schedule).array().map { block in
            RezkaSchedule(title: try text(block, ".b-post__schedule_block_title .title"), rows: try block.select("table.b-post__schedule_table tbody tr").array().map { row in
                RezkaSchedule.Row(episode: try text(row, ".td-1"), title: try text(row, ".td-2 b"), date: try text(row, ".td-4"))
            })
        }
        result.metadata = metadata
        result.countryCodes = MediaCountry.codes(in: metadata.information["Страна"] ?? "").nonEmptyCountries ?? item.countryCodes
        let initialization = firstMatch("initCDN(?:Movies|Series)Events\\((.*?)\\);", in: html)
        let args = initialization?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
        let movieID = args.first.flatMap { Int($0) }.map(String.init) ?? item.rezka?.movieID ?? item.id
        let hasSeasons = try !document.select(RezkaSelectors.seasons).isEmpty()
        let isSeries = html.contains("initCDNSeriesEvents") || hasSeasons
        var translators = try document.select(RezkaSelectors.translators).array().compactMap { node -> RezkaTranslator? in
            let id = try node.attr("data-translator_id")
            guard !id.isEmpty else { return nil }
            var flags: [String: String] = [:]
            for key in ["is_camrip", "is_ads", "is_director"] {
                let value = try node.attr("data-\(key)")
                if !value.isEmpty { flags[key] = value }
            }
            let visibleName = try node.text()
            return RezkaTranslator(id: id, name: visibleName.nonEmpty ?? "Стандартная озвучка", description: try node.attr("title").nonEmpty,
                                   isPremium: node.hasClass("b-prem_translator"), isSelected: node.hasClass("active"), flags: flags)
        }
        let initialTranslator = args.count > 1 ? Int(args[1]).map(String.init) : nil
        if translators.isEmpty, let initialTranslator {
            translators = [RezkaTranslator(id: initialTranslator, name: "Стандартная озвучка", isSelected: true)]
        }
        if !translators.contains(where: \.isSelected), let initialTranslator,
           let index = translators.firstIndex(where: { $0.id == initialTranslator }) {
            translators[index].isSelected = true
        }
        result.rezka = RezkaMedia(movieID: movieID, pageURL: baseURL, isSeries: isSeries,
                                 translators: translators, seasons: try seasons(document), playerFlags: translators.first(where: \.isSelected)?.flags ?? [:])
        return result
    }

    func episodeList(seasonsHTML: String, episodesHTML: String, baseURL: URL) throws -> [RezkaSeason] {
        let seasonDocument = try document(seasonsHTML, baseURL)
        let episodeDocument = try document(episodesHTML, baseURL)
        return try seasons(seasonDocument, episodeDocument: episodeDocument)
    }

    func collections(html: String, baseURL: URL) throws -> [RezkaCollection] {
        let document = try document(html, baseURL)
        return try document.select(RezkaSelectors.collections).array().compactMap { card in
            let anchor = try card.select("a").first()
            let raw = try card.attr("data-url").nonEmpty ?? anchor?.attr("href") ?? ""
            guard let url = resolve(raw, baseURL) else { return nil }
            return RezkaCollection(title: try text(card, ".title"), url: url, imageURL: try imageURL(card, "img", baseURL), count: try text(card, ".num"))
        }
    }

    func comments(html: String, baseURL: URL) throws -> RezkaCommentPage {
        let document = try document(html, baseURL)
        var seen = Set<String>()
        var stack: [(indent: Int, id: String)] = []
        var comments: [RezkaComment] = []
        for node in try document.select(RezkaSelectors.comments).array() {
            let message = try node.select(".message").first()
            guard let message else { continue }
            let container = try node.select("div[id^=comment-id-]").first()
            let rawID = try node.attr("data-id").nonEmpty ?? container?.attr("id").replacingOccurrences(of: "comment-id-", with: "") ?? node.id().replacingOccurrences(of: "comment-id-", with: "")
            guard !rawID.isEmpty, seen.insert(rawID).inserted else { continue }
            let indent = Int(try node.attr("data-indent")) ?? 0
            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            comments.append(RezkaComment(id: rawID, parentID: stack.last?.id, indent: indent,
                author: try text(message, ".info .name"), date: try text(message, ".info .date"),
                text: try text(message, ".text div[id^=comm-id-]").nonEmpty ?? text(message, ".text"),
                likes: try text(node, ".b-comment__likes_count i"), avatarURL: try imageURL(node, ".ava img", baseURL)))
            stack.append((indent, rawID))
        }
        return RezkaCommentPage(comments: comments, pages: try links(document, RezkaSelectors.navigation, baseURL))
    }

    func person(html: String, baseURL: URL) throws -> RezkaPerson {
        let document = try document(html, baseURL)
        let name = try text(document, ".b-post__title [itemprop=name]")
        guard !name.isEmpty else { throw RezkaError.invalidPage("This person page could not be read.") }
        return RezkaPerson(name: name, originalName: try text(document, ".b-post__title [itemprop=alternativeHeadline]"),
            imageURL: try imageURL(document, ".b-post__infotable_left [itemprop=image]", baseURL),
            birthDate: try text(document, "[itemprop=birthDate]"), jobs: try document.select("[itemprop=jobTitle]").array().map { try $0.text() },
            careers: try links(document, ".b-person__career a", baseURL), filmography: try catalogue(html: html, baseURL: baseURL).items)
    }

    private func seasons(_ document: Document, episodeDocument: Document? = nil) throws -> [RezkaSeason] {
        let episodeNodes = try (episodeDocument ?? document).select(RezkaSelectors.episodes).array()
        let seasonNodes = try document.select(RezkaSelectors.seasons).array()
        var result = try seasonNodes.compactMap { node -> RezkaSeason? in
            let id = try node.attr("data-tab_id")
            guard !id.isEmpty else { return nil }
            return RezkaSeason(id: id, title: try node.text(), episodes: [])
        }
        for node in episodeNodes {
            let id = try node.attr("data-episode_id")
            guard !id.isEmpty else { continue }
            var seasonID = try node.attr("data-season_id")
            var parent = node.parent()
            while seasonID.isEmpty, let ancestor = parent {
                let containerID = ancestor.id()
                if containerID.hasPrefix("simple-episodes-list-") {
                    seasonID = String(containerID.dropFirst("simple-episodes-list-".count))
                }
                parent = ancestor.parent()
            }
            if seasonID.isEmpty, result.count == 1 { seasonID = result[0].id }
            guard !seasonID.isEmpty else { continue }
            if !result.contains(where: { $0.id == seasonID }) {
                result.append(RezkaSeason(id: seasonID, title: "Season \(seasonID)", episodes: []))
            }
            if let index = result.firstIndex(where: { $0.id == seasonID }), !result[index].episodes.contains(where: { $0.id == id }) {
                result[index].episodes.append(RezkaEpisode(id: id, title: try node.text(), seasonID: seasonID))
            }
        }
        return result
    }

    private func document(_ html: String, _ baseURL: URL) throws -> Document {
        guard !RezkaProtection.isChallenge(html) else { throw RezkaError.challengeRequired }
        return try SwiftSoup.parse(html, baseURL.absoluteString)
    }

    private func text(_ node: Element, _ selector: String) throws -> String {
        try node.select(selector).first()?.text() ?? ""
    }

    private func imageURL(_ node: Element, _ selector: String, _ baseURL: URL) throws -> URL? {
        guard let image = try node.select(selector).first() else { return nil }
        if let srcset = try image.attr("data-srcset").nonEmpty ?? image.attr("srcset").nonEmpty,
           let bestSource = largestImageSource(in: srcset, baseURL: baseURL) {
            return bestSource
        }
        for attribute in ["data-original", "data-lazy-src", "data-src", "src", "content"] {
            if let url = resolve(try image.attr(attribute), baseURL) { return url }
        }
        return nil
    }

    private func largestImageSource(in srcset: String, baseURL: URL) -> URL? {
        let candidates = srcset.split(separator: ",").compactMap { candidate -> (url: URL, resolution: Double)? in
            let parts = candidate.split(whereSeparator: \.isWhitespace)
            guard let rawURL = parts.first, let url = resolve(String(rawURL), baseURL) else { return nil }
            guard let descriptor = parts.dropFirst().first.map(String.init) else { return (url, 1) }
            let resolution: Double
            if descriptor.hasSuffix("w") {
                resolution = Double(descriptor.dropLast()) ?? 0
            } else if descriptor.hasSuffix("x") {
                resolution = (Double(descriptor.dropLast()) ?? 0) * 1_000
            } else {
                resolution = 1
            }
            return (url, resolution)
        }
        return candidates.max(by: { $0.resolution < $1.resolution })?.url
    }

    private func resolve(_ raw: String, _ baseURL: URL) -> URL? {
        guard !raw.isEmpty, let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    private func links(_ node: Element, _ selector: String, _ baseURL: URL) throws -> [RezkaLink] {
        var seen = Set<URL>()
        return try node.select(selector).array().compactMap { anchor in
            guard let url = resolve(try anchor.attr("href"), baseURL), seen.insert(url).inserted else { return nil }
            return RezkaLink(name: try anchor.text(), url: url)
        }
    }

    private func people(_ node: Element, _ selector: String, _ baseURL: URL) throws -> [RezkaLink] {
        try node.select(selector).array().compactMap { person in
            let anchor = try person.select("a").first()
            guard let anchor, let url = resolve(try anchor.attr("href"), baseURL) else { return nil }
            return RezkaLink(name: try text(person, "span[itemprop=name]").nonEmpty ?? anchor.text(), url: url,
                imageURL: resolve(try person.attr("data-photo"), baseURL))
        }
    }

    private func rating(_ node: Element, _ selector: String, _ baseURL: URL) throws -> RezkaRating? {
        guard let rating = try node.select(selector).first() else { return nil }
        let value = try text(rating, ".bold")
        guard !value.isEmpty else { return nil }
        return RezkaRating(value: value, url: try rating.select("a").first().flatMap { resolve(try $0.attr("href"), baseURL) })
    }

    func previewArtwork(html: String, baseURL: URL) throws -> URL? {
        try imageURL(document(html, baseURL), ".b-sidecover img", baseURL)
    }

    private func mediaKind(url: URL) -> MediaKind {
        if url.path.contains("/cartoons/") { return .animation }
        if url.path.contains("/animation/") || url.path.contains("/anime/") { return .anime }
        if url.path.contains("/series/") { return .series }
        return .movie
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
