import Foundation
import SwiftSoup

struct RezkaSubtitleCue: Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

struct RezkaSubtitleParser {
    func parse(_ text: String) throws -> [RezkaSubtitleCue] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var cues: [RezkaSubtitleCue] = []
        var index = 0
        while index < lines.count {
            let parts = lines[index].components(separatedBy: "-->")
            guard parts.count == 2, let start = timestamp(parts[0]), let end = timestamp(parts[1]), end > start else { index += 1; continue }
            index += 1
            var content: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                content.append(lines[index])
                index += 1
            }
            let html = content.joined(separator: "\n")
            let decoded = try SwiftSoup.parseBodyFragment(html).text()
            cues.append(RezkaSubtitleCue(start: start, end: end, text: decoded))
        }
        return cues.sorted { $0.start < $1.start }
    }

    private func timestamp(_ raw: String) -> TimeInterval? {
        guard let token = raw.trimmingCharacters(in: .whitespaces).split(separator: " ").first else { return nil }
        let components = token.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard (2...3).contains(components.count) else { return nil }
        var seconds: Double = 0
        for component in components {
            guard let value = Double(component), value >= 0 else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }
}
