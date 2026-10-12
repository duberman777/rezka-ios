import Foundation
import XCTest
@testable import RezkaPort

@MainActor
final class RezkaScrapingTests: XCTestCase {
    private let base = URL(string: "https://hdrezka-home.tv/")!

    func testCountryNamesResolveAcrossWebsiteLanguagesAndHistoricalCountries() {
        XCTAssertEqual(MediaCountry.codes(in: "Россия, США, Великобритания"), ["RU", "US", "GB"])
        XCTAssertEqual(MediaCountry.codes(in: "Italy, South Korea, USSR"), ["IT", "KR", "SU"])
        XCTAssertEqual(MediaCountry.codes(in: "США, USA, Комедия"), ["US"])
        XCTAssertEqual(MediaCountry.codes(in: "Беларусь, Россия"), ["BY", "RU"])
    }

    func testCatalogueCountryExclusionsIncludeCoProductions() throws {
        let html = """
        <div class='b-content__inline_item' data-id='1' data-url='/films/1-test.html'>
        <div class='b-content__inline_item-link'><a href='/films/1-test.html'>Test</a><div>2026, США, Россия, Драмы</div></div></div>
        """
        let item = try XCTUnwrap(RezkaPageParser().catalogue(html: html, baseURL: base).items.first)
        XCTAssertEqual(item.countryCodes, ["US", "RU"])
        XCTAssertTrue(MediaCountry.isExcluded(item, codes: ["RU"]))
        XCTAssertFalse(MediaCountry.isExcluded(item, codes: ["IT"]))
        let oldData = try JSONEncoder().encode(item)
        var oldObject = try XCTUnwrap(JSONSerialization.jsonObject(with: oldData) as? [String: Any])
        oldObject.removeValue(forKey: "countryCodes")
        XCTAssertNil(try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: oldObject)).countryCodes)
    }

    func testCatalogueExtractsStableIDsAndRelativeURLs() throws {
        let result = try RezkaPageParser().catalogue(html: Fixtures.catalogue, baseURL: base)
        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.items[0].id, "42")
        XCTAssertEqual(result.items[0].title, "Title & name")
        XCTAssertEqual(result.items[0].posterURL?.absoluteString, "https://hdrezka-home.tv/poster.jpg")
        XCTAssertEqual(result.items[0].rezka?.pageURL.host, base.host)
        XCTAssertEqual(result.items[1].kind, .series)
        XCTAssertTrue(result.hasNextPage)
    }

    func testCatalogueDiscoversGenresWithoutRankingOrDuplicateLinks() throws {
        let navigation = """
        <a href="/films/drama/"><img></a><a href="/films/drama/">Drama</a>
        <a href="/films/drama/">Drama repeated</a><a href="/series/comedy/">Comedy</a>
        <a href="/films/best/">Ranking</a><a href="/collections/">Collections</a>
        """
        let result = try RezkaPageParser().catalogue(html: Fixtures.catalogue + navigation, baseURL: base)
        XCTAssertEqual(result.categories.map(\.title), ["Drama", "Comedy"])
        XCTAssertEqual(result.categories.map(\.kind), [.movie, .series])
        XCTAssertEqual(result.categories.first?.url.path, "/films/drama")
    }

    func testAnimationAndAnimeCategoriesUseTheCorrectGroups() throws {
        let html = "<a href='/films/drama/'>Drama</a><a href='/cartoons/family/'>Family</a><a href='/animation/mecha/'>Mecha</a>"
        let result = try RezkaPageParser().catalogue(html: html, baseURL: base)
        XCTAssertEqual(result.categories.map(\.kind), [.movie, .animation, .anime])
    }

    func testMediumArtworkDoesNotUseOriginalOrSocialThumbnail() throws {
        let html = "<meta property='og:image' content='/small.jpg'><div class='b-sidecover'><a href='/original.jpg' data-imagelightbox='cover'><img src='/medium.jpg'></a></div>"
        XCTAssertEqual(try RezkaPageParser().previewArtwork(html: html, baseURL: base), base.appendingPathComponent("medium.jpg"))
    }

    func testScheduleParsesEpisodeNumbersAndRussianReleaseDates() throws {
        let row = RezkaSchedule.Row(episode: "1 сезон 6 серия", title: "A title", date: "9 октября 2026")
        XCTAssertEqual(row.seasonNumber, 1)
        XCTAssertEqual(row.episodeNumber, 6)
        let date = try XCTUnwrap(row.releaseDate)
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: date), DateComponents(year: 2026, month: 10, day: 9))
        XCTAssertNil(RezkaSchedule.Row(episode: "Special", title: "Special episode", date: "TBA").releaseDate)
    }

    func testDetailsUseInformationLabelsAndScriptFallback() throws {
        let item = try RezkaPageParser().catalogue(html: Fixtures.catalogue, baseURL: base).items[0]
        let result = try RezkaPageParser().details(html: Fixtures.details, baseURL: base.appendingPathComponent("films/42-title.html"), item: item)
        XCTAssertEqual(result.title, "Example film")
        XCTAssertEqual(result.originalTitle, "Example")
        XCTAssertEqual(result.metadata?.information["Страна"], "Италия")
        XCTAssertEqual(result.durationMinutes, 118)
        XCTAssertEqual(result.year, 2025)
        XCTAssertEqual(result.metadata?.actors.first?.name, "A Person")
        XCTAssertEqual(result.metadata?.imdb?.value, "8.1")
        XCTAssertEqual(result.rezka?.movieID, "42")
        XCTAssertEqual(result.rezka?.translators.first?.id, "7")
        XCTAssertEqual(result.rezka?.translators.first?.name, "Стандартная озвучка")
        XCTAssertEqual(result.rezka?.isSeries, false)
    }

    func testDetailsPreferOriginalCoverAndExtractCastPhotos() throws {
        let item = try XCTUnwrap(RezkaPageParser().catalogue(html: Fixtures.catalogue, baseURL: base).items.first)
        let html = Fixtures.details.replacingOccurrences(of: "<img src=\"/poster.jpg\">", with:
            "<a href='/original-cover.jpg' data-imagelightbox='cover'><img src='/thumbnail.jpg'></a>")
            .replacingOccurrences(of: "<span itemprop=\"actor\">", with:
            "<span itemprop='actor' data-photo='/person-photo.jpg'>")
        let result = try RezkaPageParser().details(html: html, baseURL: base, item: item)
        XCTAssertEqual(result.posterURL, base.appendingPathComponent("original-cover.jpg"))
        XCTAssertEqual(result.metadata?.actors.first?.imageURL, base.appendingPathComponent("person-photo.jpg"))
        let legacy = Data(#"{"name":"Person","url":"https://hdrezka-home.tv/person/1"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(RezkaLink.self, from: legacy).imageURL)
    }

    func testPremiumTranslatorsAreHiddenEvenWhenSelectedByWebsite() throws {
        let item = try RezkaPageParser().catalogue(html: Fixtures.catalogue, baseURL: base).items[0]
        let html = Fixtures.details + """
        <div class="b-translator__item active b-prem_translator" data-translator_id="9">Premium dub</div>
        <div class="b-translator__item" data-translator_id="7">Free dub</div>
        """
        let result = try RezkaPageParser().details(html: html, baseURL: base, item: item)
        XCTAssertEqual(result.rezka?.playableTranslators.map(\.id), ["7"])
        XCTAssertEqual(result.rezka?.translators.first?.isPremium, true)
    }

    func testStreamServiceNeverSelectsPremiumDubbing() async throws {
        let transport = StubTransport(responses: [Fixtures.response(#"{"success":true,"url":"[720p]https://cdn.test/stream"}"#, base)])
        let media = RezkaMedia(movieID: "42", pageURL: base, isSeries: false, translators: [
            RezkaTranslator(id: "9", name: "Premium", isPremium: true, isSelected: true),
            RezkaTranslator(id: "7", name: "Free")])
        let service = RezkaStreamService(client: RezkaHttpClient(transport: transport))
        _ = try await service.playback(request: PlaybackRequest(mediaID: "42"), media: media, baseURL: base)
        do {
            _ = try await service.playback(request: PlaybackRequest(mediaID: "42", translatorID: "9"), media: media, baseURL: base)
            XCTFail("Premium dubbing must be rejected before sending a request")
        } catch { XCTAssertEqual(error.localizedDescription, RezkaError.missingTranslator.localizedDescription) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(Fixtures.form(requests[0])["translator_id"], "7")
    }

    func testResumeRestoresExactSecondsForSameEpisode() throws {
        let item = try RezkaPageParser().catalogue(html: Fixtures.catalogue, baseURL: base).items[1]
        let record = WatchRecord(item: item, position: 754.25, duration: 2400, updatedAt: .now,
            translatorID: "7", seasonID: "2", episodeID: "3")
        XCTAssertEqual(record.resumePosition(for: PlaybackRequest(mediaID: item.id, season: "2", episode: "3")), 754.25)
        XCTAssertNil(record.resumePosition(for: PlaybackRequest(mediaID: item.id, season: "2", episode: "4")))
        XCTAssertNil(record.resumePosition(for: PlaybackRequest(mediaID: item.id, season: "1", episode: "3")))
        XCTAssertNil(record.resumePosition(for: nil))
    }

    func testNextEpisodeCrossesSeasonsAndStopsAtFinalEpisode() {
        let seasons = [RezkaSeason(id: "1", title: "Season 1", episodes: [
            RezkaEpisode(id: "1", title: "First", seasonID: "1"), RezkaEpisode(id: "2", title: "Second", seasonID: "1")]),
            RezkaSeason(id: "2", title: "Season 2", episodes: [RezkaEpisode(id: "1", title: "Third", seasonID: "2")])]
        let request = PlaybackRequest(mediaID: "42", translatorID: "7", season: "1", episode: "2")
        let next = RezkaSeason.nextRequest(after: request, in: seasons)
        XCTAssertEqual(next?.season, "2")
        XCTAssertEqual(next?.episode, "1")
        XCTAssertEqual(next?.translatorID, "7")
        XCTAssertEqual(next?.mediaID, "42")
        XCTAssertNil(RezkaSeason.nextRequest(after: next!, in: seasons))
        XCTAssertNil(RezkaSeason.nextRequest(after: PlaybackRequest(mediaID: "42", season: "9", episode: "9"), in: seasons))
    }

    func testSeriesTranslatorAndFragmentsStayGroupedBySeason() throws {
        let result = try RezkaPageParser().episodeList(seasonsHTML: Fixtures.seasons, episodesHTML: Fixtures.episodes, baseURL: base)
        XCTAssertEqual(result.map(\.id), ["1", "2"])
        XCTAssertEqual(result[0].episodes.map(\.id), ["1", "2"])
        XCTAssertEqual(result[1].episodes.map(\.id), ["1"])
        XCTAssertEqual(result[1].episodes.first?.seasonID, "2")
    }

    func testChallengeNeverBecomesCatalogueData() {
        for marker in RezkaProtection.markers {
            XCTAssertThrowsError(try RezkaPageParser().catalogue(html: marker, baseURL: base))
        }
    }

    func testDecoderHandlesPlainQualitiesAlternativesAndPremium() throws {
        let result = try RezkaStreamDecoder().streams("[360p]https://cdn.test/low.m3u8,[1080p]https://a.test/high.m3u8?token=a%2Bb or https://b.test/high.m3u8,[<span class='pjs-prem-quality'>2160p</span>]https://cdn.test/premium.m3u8")
        XCTAssertEqual(result.map(\.quality), ["1080p", "360p"])
        XCTAssertEqual(result[0].alternatives.count, 1)
        XCTAssertEqual(result[0].url.query, "token=a%2Bb")
    }

    func testDecoderRemovesKnownAndroidNoiseAndMissingPadding() throws {
        let plain = "[720p]https://cdn.test/video.m3u8"
        let encoded = Data(plain.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let split = encoded.index(encoded.startIndex, offsetBy: 12)
        // Fixed vectors from length two and three symbol words: @@ and !^$.
        let obscured = "#h" + encoded[..<split] + "//_//QEA=IV4k" + encoded[split...]
        XCTAssertEqual(try RezkaStreamDecoder().decode(String(obscured)), plain)
        XCTAssertEqual(try RezkaStreamDecoder().streams(String(obscured)).first?.quality, "720p")
    }

    func testMalformedStreamsFailWithoutInventingURLs() {
        for payload in ["", "#hnot-base64", "[1080p]javascript:alert(1)", "[720p]ftp://cdn.test/file.mp4"] {
            XCTAssertThrowsError(try RezkaStreamDecoder().streams(payload))
        }
    }

    func testVideoFormatDoesNotDependOnFilenameExtension() throws {
        let streams = try RezkaStreamDecoder().streams("[720p]https://cdn.test/stream?id=42&signature=a%2Bb,[1080p]https://cdn.test/video.mp4:hls:manifest.m3u8")
        XCTAssertEqual(streams.count, 2)
        XCTAssertEqual(streams[1].url.path, "/stream")
        XCTAssertEqual(streams[1].url.query, "id=42&signature=a%2Bb")
    }

    func testBase64PayloadCanContainLeadingWhitespace() throws {
        let payload = "\n[720p]https://cdn.test/video.mp4\n"
        XCTAssertEqual(try RezkaStreamDecoder().streams(Data(payload.utf8).base64EncodedString()).first?.quality, "720p")
    }

    func testLiveFilmResponseAcceptsProgressiveMP4Qualities() throws {
        // Sanitized structure of the response captured on the user's iPhone.
        let response = "[360p]https://stream.voidboost.one/session/1/5/4/bg8gs.mp4,[480p]https://stream.voidboost.one/session/1/5/4/jbfw8.mp4,[720p]https://stream.voidboost.one/session/1/5/4/p63wn.mp4,[1080p]https://stream.voidboost.one/session/1/5/4/u4564.mp4,[<span class=\"pjs-prem-quality\">4K<img src=\"https://static.hdrezka.ac/prem-icon.svg\" alt=\"\"></span>]https://stream.voidboost.one/session/premium.mp4"
        let streams = try RezkaStreamDecoder().streams(response)
        XCTAssertEqual(streams.map(\.quality), ["1080p", "720p", "480p", "360p"])
        XCTAssertTrue(streams.allSatisfy { $0.url.pathExtension == "mp4" })
    }

    func testSubtitlesMapLanguagesAndNoDefault() throws {
        let response = try RezkaAjaxResponse.parse(Fixtures.response(#"{"success":true,"url":"","subtitle":"[English]https://cdn.test/en.vtt,[Русский]https://cdn.test/ru.srt","subtitle_lns":{"English":"en","Русский":"ru"},"subtitle_def":"0"}"#, base))
        let tracks = try RezkaStreamDecoder().subtitles(response.subtitle, languages: response.subtitleLanguages)
        XCTAssertEqual(tracks.map(\.language), ["en", "ru"])
        XCTAssertNil(response.defaultSubtitle)
    }

    func testServerMessageIsPreserved() {
        XCTAssertThrowsError(try RezkaAjaxResponse.parse(Fixtures.response(#"{"success":false,"message":"Title is unavailable"}"#, base))) { error in
            XCTAssertEqual(error.localizedDescription, "Title is unavailable")
        }
    }

    func testFilmRequestsConfirmedMovieActionAndHLSSelection() async throws {
        let transport = StubTransport(responses: [Fixtures.response(#"{"success":true,"url":"[1080p]https://cdn.test/video.m3u8"}"#, base)])
        let media = RezkaMedia(movieID: "42", pageURL: base.appendingPathComponent("films/42.html"), isSeries: false,
                              translators: [RezkaTranslator(id: "7", name: "Voice")])
        let result = try await RezkaStreamService(client: RezkaHttpClient(transport: transport)).playback(request: PlaybackRequest(mediaID: "42"), media: media, baseURL: base)
        XCTAssertEqual(result.streams.first?.quality, "1080p")
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        let fields = Fixtures.form(request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(fields["action"], "get_movie")
        XCTAssertEqual(fields["translator_id"], "7")
        XCTAssertEqual(fields["season"], "1")
        XCTAssertEqual(fields["episode"], "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://hdrezka-home.tv")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Requested-With"), "XMLHttpRequest")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.path, "/ajax/get_cdn_series/")
        XCTAssertNotNil(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "t" }))
    }

    func testSeriesRequestsSelectedEpisode() async throws {
        let transport = StubTransport(responses: [Fixtures.response(#"{"success":true,"url":"[720p]https://cdn.test/video.m3u8"}"#, base)])
        let media = RezkaMedia(movieID: "43", pageURL: base, isSeries: true, translators: [RezkaTranslator(id: "8", name: "Voice")])
        _ = try await RezkaStreamService(client: RezkaHttpClient(transport: transport)).playback(
            request: PlaybackRequest(mediaID: "43", translatorID: "8", season: "2", episode: "3"), media: media, baseURL: base)
        let requests = await transport.requests
        XCTAssertEqual(Fixtures.form(try XCTUnwrap(requests.first))["action"], "get_stream")
        XCTAssertEqual(Fixtures.form(requests[0])["season"], "2")
        XCTAssertEqual(Fixtures.form(requests[0])["episode"], "3")
    }

    func testSeriesWithoutEpisodeDoesNotSendRequest() async {
        let transport = StubTransport(responses: [])
        let media = RezkaMedia(movieID: "43", pageURL: base, isSeries: true, translators: [RezkaTranslator(id: "8", name: "Voice")])
        do {
            _ = try await RezkaStreamService(client: RezkaHttpClient(transport: transport)).playback(request: PlaybackRequest(mediaID: "43"), media: media, baseURL: base)
            XCTFail("Expected missing episode")
        } catch { XCTAssertTrue(error is RezkaError) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testHTTPChallengeUsesBrowserResponse() async throws {
        let transport = StubTransport(responses: [Fixtures.response("Just a moment", base, status: 403)])
        let client = RezkaHttpClient(transport: transport, browserFetch: { request in
            XCTAssertEqual(request.url?.host, "hdrezka-home.tv")
            return Fixtures.response(Fixtures.catalogue, request.url!)
        })
        let result = try await client.html(url: base)
        XCTAssertTrue(result.0.contains("Title &amp; name"))
    }

    func testHTTPRejectsUnsolvedBrowserChallenge() async {
        let transport = StubTransport(responses: [Fixtures.response("anubis_challenge", base)])
        let client = RezkaHttpClient(transport: transport, browserFetch: { request in Fixtures.response("cf-turnstile", request.url!) })
        do { _ = try await client.html(url: base); XCTFail("Expected challenge") }
        catch { XCTAssertEqual(error.localizedDescription, RezkaError.challengeRequired.localizedDescription) }
    }

    func testHTTPPropagatesStatusAndCancellation() async {
        let transport = StubTransport(responses: [Fixtures.response("Unavailable", base, status: 503)])
        do { _ = try await RezkaHttpClient(transport: transport).html(url: base); XCTFail("Expected HTTP failure") }
        catch { XCTAssertEqual(error.localizedDescription, RezkaError.httpStatus(503).localizedDescription) }
    }

    func testFormEncodingPreservesSpecialCharacters() {
        let form = RezkaEndpoints.formData(["q": "a+b & русский= #", "page": "1"])
        var request = URLRequest(url: base)
        request.httpBody = form
        XCTAssertEqual(Fixtures.form(request)["q"], "a+b & русский= #")
    }

    func testCommentsKeepRepliesAndDeduplicateNestedContainers() throws {
        let result = try RezkaPageParser().comments(html: Fixtures.comments, baseURL: base)
        XCTAssertEqual(result.comments.map(\.id), ["10", "11"])
        XCTAssertNil(result.comments[0].parentID)
        XCTAssertEqual(result.comments[1].parentID, "10")
        XCTAssertEqual(result.comments[0].text, "First comment")
        XCTAssertEqual(result.pages.count, 1)
    }

    func testCollectionsAndPersonFilmography() throws {
        let collections = try RezkaPageParser().collections(html: "<div class='b-content__collections_item' data-url='/collections/1.html'><div class='title'>Collection</div><div class='num'>12</div><img src='/image.jpg'></div>", baseURL: base)
        XCTAssertEqual(collections.first?.count, "12")
        let person = try RezkaPageParser().person(html: "<div class='b-post__title'><span itemprop='name'>Person</span><span itemprop='alternativeHeadline'>Original</span></div><span itemprop='birthDate'>1980</span><span itemprop='jobTitle'>Actor</span>" + Fixtures.catalogue, baseURL: base)
        XCTAssertEqual(person.name, "Person")
        XCTAssertEqual(person.filmography.count, 2)
    }

    func testSubtitleParserSupportsVTTAndSRT() throws {
        let vtt = "WEBVTT\n\n00:01.000 --> 00:03.500 align:center\nHello <b>world</b>\n\n"
        let srt = "1\n00:00:04,000 --> 00:00:05,000\nПривет\n\n"
        let cues = try RezkaSubtitleParser().parse(vtt + srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].start, 1)
        XCTAssertEqual(cues[0].end, 3.5)
        XCTAssertEqual(cues[0].text, "Hello world")
        XCTAssertEqual(cues[1].start, 4)
    }

    func testOlderSavedMediaStillDecodes() throws {
        let data = Data(#"{"id":"old","title":"Old title","kind":"movie","genre":"Drama","synopsis":"Text","symbol":"film","paletteIndex":0}"#.utf8)
        let item = try JSONDecoder().decode(MediaItem.self, from: data)
        XCTAssertNil(item.rezka)
        XCTAssertNil(item.posterURL)
    }

    func testMirrorValidationRejectsCredentialsAndHTTP() {
        XCTAssertEqual(RezkaMirrorManager.normalized("hdrezka-home.tv")?.scheme, "https")
        XCTAssertNil(RezkaMirrorManager.normalized("http://hdrezka-home.tv"))
        XCTAssertNil(RezkaMirrorManager.normalized("https://user:pass@hdrezka-home.tv"))
        XCTAssertNil(RezkaMirrorManager.normalized("localhost"))
    }

    func testSearchUsesHTMLPageAndPreservesQuery() async throws {
        let transport = StubTransport(responses: [Fixtures.response(Fixtures.catalogue, base)])
        let client = RezkaHttpClient(transport: transport)
        let defaults = UserDefaults(suiteName: "rezka.tests.\(UUID().uuidString)")!
        defaults.set(base.absoluteString, forKey: "rezka.activeMirror")
        let source = RezkaContentSource(client: client, mirrors: RezkaMirrorManager(client: client, defaults: defaults))
        let result = try await source.searchPage(query: "Breaking Bad + русский", page: 2)
        XCTAssertEqual(result.items.count, 2)
        let requests = await transport.requests
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false))
        let fields = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(components.path, "/search/")
        XCTAssertEqual(fields["q"], "Breaking Bad + русский")
        XCTAssertEqual(fields["do"], "search")
        XCTAssertEqual(fields["subaction"], "search")
        XCTAssertEqual(fields["page"], "2")
    }

    func testCataloguePaginationUsesPathAndFilter() async throws {
        let transport = StubTransport(responses: [Fixtures.response(Fixtures.catalogue, base)])
        let client = RezkaHttpClient(transport: transport)
        let defaults = UserDefaults(suiteName: "rezka.tests.\(UUID().uuidString)")!
        defaults.set(base.absoluteString, forKey: "rezka.activeMirror")
        let source = RezkaContentSource(client: client, mirrors: RezkaMirrorManager(client: client, defaults: defaults))
        _ = try await source.catalogue(url: base.appendingPathComponent("films/"), page: 2, filter: "popular")
        let requests = await transport.requests
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/films/page/2/")
        XCTAssertEqual(components.queryItems?.first?.value, "popular")
    }

    func testMirrorFailoverRebasesSavedPageAndKeepsMediaIDs() async throws {
        let replacement = URL(string: "https://new-mirror.test/")!
        let dead = URL(string: "https://dead-mirror.test/")!
        let configuration = #"{"mirrors":{"main":["new-mirror.test"],"cloudflare":[]}}"#
        let transport = StubTransport(responses: [
            Fixtures.response("Unavailable", dead, status: 503),
            Fixtures.response(configuration, RezkaEndpoints.mirrorConfiguration),
            Fixtures.response("Unavailable", base, status: 503),
            Fixtures.response(Fixtures.catalogue, replacement),
            Fixtures.response(Fixtures.catalogue, replacement)
        ])
        let client = RezkaHttpClient(transport: transport)
        let defaults = UserDefaults(suiteName: "rezka.tests.\(UUID().uuidString)")!
        defaults.set(dead.absoluteString, forKey: "rezka.activeMirror")
        let source = RezkaContentSource(client: client, mirrors: RezkaMirrorManager(client: client, defaults: defaults))
        let result = try await source.catalogue(url: dead.appendingPathComponent("films/"))
        XCTAssertEqual(result.items.first?.id, "42")
        XCTAssertEqual(result.items.first?.rezka?.pageURL.host, "new-mirror.test")
        let requests = await transport.requests
        XCTAssertEqual(requests.last?.url?.host, "new-mirror.test")
        XCTAssertEqual(requests.last?.url?.path, "/films")
    }

    func testEpisodeRequestParsesJSONWrappingHTML() async throws {
        let json = try JSONSerialization.data(withJSONObject: ["success": true, "seasons": Fixtures.seasons, "episodes": Fixtures.episodes])
        let transport = StubTransport(responses: [RezkaHTTPResponse(data: json, url: base, statusCode: 200)])
        let result = try await RezkaEpisodeService(client: RezkaHttpClient(transport: transport)).episodes(movieID: "43", translatorID: "8", pageURL: base, baseURL: base)
        XCTAssertEqual(result.count, 2)
        let requests = await transport.requests
        let fields = Fixtures.form(try XCTUnwrap(requests.first))
        XCTAssertEqual(fields["action"], "get_episodes")
        XCTAssertEqual(fields["translator_id"], "8")
    }
}

private actor StubTransport: RezkaTransport {
    var requests: [URLRequest] = []
    var responses: [RezkaHTTPResponse]
    init(responses: [RezkaHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> RezkaHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
}

private enum Fixtures {
    static func response(_ text: String, _ url: URL, status: Int = 200) -> RezkaHTTPResponse {
        RezkaHTTPResponse(data: Data(text.utf8), url: url, statusCode: status)
    }

    static func form(_ request: URLRequest) -> [String: String] {
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let fields = URLComponents(string: "https://test.invalid/?" + body)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") })
    }

    static let catalogue = """
    <div class="b-content__inline_item" data-id="42" data-url="/films/42-title.html"><img src="/poster.jpg"><div class="b-content__inline_item-link"><a href="/films/42-title.html">Title &amp; name</a><div>2025, Italy, Drama</div></div></div>
    <div class="b-content__inline_item" data-id="43" data-url="/series/43-series.html"><img data-src="//cdn.test/series.jpg"><div class="b-content__inline_item-link"><a>Series</a><div>2024, Drama</div></div></div>
    <div class="b-content__inline_item" data-id="42" data-url="/films/42-title.html"><div class="b-content__inline_item-link"><a>Duplicate</a></div></div>
    <div class="b-navigation"><a href="/page/2/">2</a></div>
    """
    static let details = """
    <div class="b-content__main"><div class="b-post__title"><h1 itemprop="name">Example film</h1></div><div class="b-post__origtitle">Example</div><div class="b-sidecover"><img src="/poster.jpg"></div><div class="b-post__description_text">A description.</div><table class="b-post__info"><tr><td class="l"><h2>Страна:</h2></td><td>Италия</td></tr><tr><td class="l"><h2>Время:</h2></td><td>118 мин.</td></tr><tr><td class="l"><h2>Дата выхода:</h2></td><td>2025</td></tr></table><span itemprop="actor"><a href="/person/1"><span itemprop="name">A Person</span></a></span><div class="b-post__info_rates imdb"><b class="bold">8.1</b><a href="https://imdb.com/title/tt123/">IMDb</a></div></div><script>sof.tv.initCDNMoviesEvents(42, 7, 0);</script>
    """
    static let seasons = "<li class='b-simple_season__item' data-tab_id='1'>Season 1</li><li class='b-simple_season__item' data-tab_id='2'>Season 2</li>"
    static let episodes = "<ul id='simple-episodes-list-1'><li class='b-simple_episode__item' data-episode_id='1'>Episode 1</li><li class='b-simple_episode__item' data-episode_id='2'>Episode 2</li></ul><ul id='simple-episodes-list-2'><li class='b-simple_episode__item' data-episode_id='1'>Episode 1</li></ul>"
    static let comments = """
    <li class="comments-tree-item" data-id="10" data-indent="0"><div id="comment-id-10"><div class="b-comment"><div class="message"><div class="info"><span class="name">A</span><span class="date">Today</span></div><div class="text"><div id="comm-id-10">First comment</div></div></div></div></div></li><li class="comments-tree-item" data-id="11" data-indent="1"><div id="comment-id-11"><div class="b-comment"><div class="message"><div class="info"><span class="name">B</span></div><div class="text"><div id="comm-id-11">Reply</div></div></div></div></div></li><div class="b-navigation"><a href="?cstart=2">2</a></div>
    """
}
