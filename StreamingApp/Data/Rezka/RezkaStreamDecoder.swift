import Foundation
import SwiftSoup

struct RezkaStreamDecoder: Sendable {
    // Confirmed in APK vc6 and w96: every length two and three word over these symbols.
    private static let noise: [String] = {
        let symbols = ["@", "#", "!", "^", "$"]
        var words = symbols
        var result: [String] = []
        for _ in 2...3 {
            words = symbols.flatMap { symbol in words.map { symbol + $0 } }
            result += words.map { Data($0.utf8).base64EncodedString() }
        }
        return result.sorted { $0.count > $1.count }
    }()

    func decode(_ payload: String) throws -> String {
        let whitespace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))
        var cleaned = payload.trimmingCharacters(in: whitespace)
        if cleaned.hasPrefix("[") { return cleaned }
        cleaned = cleaned.replacingOccurrences(of: "#h", with: "").replacingOccurrences(of: "//_//", with: "")
        for noise in Self.noise { cleaned = cleaned.replacingOccurrences(of: noise, with: "") }
        if cleaned.hasPrefix("[") { return cleaned }
        cleaned = cleaned.filter { !$0.isWhitespace }
        // Keep valid padding; tolerate missing padding and URL-safe Base64.
        cleaned = cleaned.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        cleaned += String(repeating: "=", count: (4 - cleaned.count % 4) % 4)
        guard let data = Data(base64Encoded: cleaned), let text = String(data: data, encoding: .utf8) else {
            throw RezkaError.invalidStream
        }
        let decoded = text.trimmingCharacters(in: whitespace)
        guard decoded.hasPrefix("[") else { throw RezkaError.invalidStream }
        return decoded
    }

    func streams(_ payload: String) throws -> [VideoStream] {
        let entries = try labelledEntries(decode(payload))
        var result: [VideoStream] = []
        for entry in entries where !entry.label.contains("pjs-prem-quality") {
            // CDN endpoints can return video without a filename extension. AVFoundation
            // determines the media format from the response, not from the URL path.
            let urls = try alternatives(entry.value)
            guard let first = urls.first else { continue }
            let label = try SwiftSoup.parseBodyFragment(entry.label).text()
            if let index = result.firstIndex(where: { $0.quality == label }) {
                var existing = [result[index].url] + result[index].alternatives
                for url in urls where !existing.contains(url) { existing.append(url) }
                result[index].alternatives = Array(existing.dropFirst())
            } else {
                result.append(VideoStream(quality: label, url: first, alternatives: Array(urls.dropFirst())))
            }
        }
        guard !result.isEmpty else { throw RezkaError.invalidStream }
        return result.sorted { $0.resolution > $1.resolution }
    }

    func subtitles(_ payload: String, languages: [String: String]) throws -> [SubtitleTrack] {
        guard !payload.isEmpty else { return [] }
        return try labelledEntries(payload).compactMap { entry in
            guard let url = try alternatives(entry.value).first else { return nil }
            return SubtitleTrack(language: languages[entry.label] ?? entry.label, label: entry.label, url: url)
        }
    }

    private func labelledEntries(_ payload: String) throws -> [(label: String, value: String)] {
        let regex = try NSRegularExpression(pattern: "\\[(.*?)\\]\\s*(https?://.*?)(?=,\\s*\\[|$)", options: [.dotMatchesLineSeparators])
        return regex.matches(in: payload, range: NSRange(payload.startIndex..., in: payload)).compactMap { match in
            guard let labelRange = Range(match.range(at: 1), in: payload), let valueRange = Range(match.range(at: 2), in: payload) else { return nil }
            return (String(payload[labelRange]), String(payload[valueRange]))
        }
    }

    private func alternatives(_ value: String) throws -> [URL] {
        let separator = try NSRegularExpression(pattern: "\\s+or\\s+", options: [.caseInsensitive])
        let separated = separator.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "\n")
        var seen = Set<URL>()
        return separated.components(separatedBy: "\n").compactMap { raw in
            guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, seen.insert(url).inserted else { return nil }
            return url
        }
    }
}
