import Foundation

extension RezkaSchedule.Row {
    private var episodeNumbers: [Int] {
        episode.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    var seasonNumber: Int? { episodeNumbers.count >= 2 ? episodeNumbers[0] : nil }
    var episodeNumber: Int? { episodeNumbers.count >= 2 ? episodeNumbers[1] : episodeNumbers.first }

    var releaseDate: Date? {
        let formatter = DateFormatter()
        formatter.timeZone = .current
        formatter.isLenient = false
        for locale in ["ru_RU", "en_US_POSIX"] {
            formatter.locale = Locale(identifier: locale)
            for format in ["d MMMM yyyy", "d MMMM yyyy 'года'", "d MMM yyyy", "yyyy-MM-dd", "dd.MM.yyyy"] {
                formatter.dateFormat = format
                if let result = formatter.date(from: date.trimmingCharacters(in: .whitespacesAndNewlines)) { return result }
            }
        }
        return nil
    }
}
