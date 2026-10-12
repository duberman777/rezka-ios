import SwiftUI

struct RezkaReleaseScheduleView: View {
    let schedule: RezkaSchedule
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var rows: [RezkaSchedule.Row] {
        schedule.rows.filter { !$0.episode.isEmpty || !$0.title.isEmpty || !$0.date.isEmpty }
            .enumerated().sorted { left, right in
                if let a = left.element.episodeNumber, let b = right.element.episodeNumber, a != b { return a < b }
                return left.offset < right.offset
            }.map(\.element)
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(rows.first?.seasonNumber.map { "Season \($0)" } ?? "Episodes")
                        .font(.headline).foregroundStyle(.white)
                    Spacer()
                    Text(rows.count == 1 ? "1 episode" : "\(rows.count) episodes")
                        .font(.caption).foregroundStyle(AppColors.secondaryText)
                }
                VStack(spacing: 0) {
                    ForEach(Array((expanded ? rows : Array(rows.prefix(3))).enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider().padding(.leading, 62) }
                        scheduleRow(row).padding(.vertical, 12)
                    }
                }
                if rows.count > 3 {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { expanded.toggle() }
                    } label: {
                        HStack {
                            Text(expanded ? "Show fewer episodes" : "See all \(rows.count) episodes")
                            Spacer()
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold))
                        }
                        .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .premiumTapFeedback()
                    .accessibilityIdentifier("expand-release-schedule")
                }
            }
            .padding(16)
            .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.06), lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("release-schedule")
        }
    }

    private func scheduleRow(_ row: RezkaSchedule.Row) -> some View {
        HStack(alignment: .center, spacing: 14) {
            if let date = row.releaseDate {
                VStack(spacing: 2) {
                    Text(String(Calendar.current.component(.day, from: date)))
                        .font(.title3.weight(.semibold)).monospacedDigit()
                    Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                        .font(.caption2.weight(.medium)).foregroundStyle(AppColors.secondaryText)
                }
                .frame(width: 48, height: 52)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel(date.formatted(date: .long, time: .omitted))
            } else {
                Image(systemName: "calendar")
                    .font(.title3).foregroundStyle(AppColors.secondaryText)
                    .frame(width: 48, height: 52)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(row.episodeNumber.map { "Episode \($0)" } ?? row.episode)
                    .font(.caption.weight(.medium)).foregroundStyle(AppColors.secondaryText)
                Text(row.title.isEmpty ? row.episode : row.title)
                    .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if row.releaseDate == nil || row.releaseDate.map({ Calendar.current.component(.year, from: $0) != Calendar.current.component(.year, from: .now) }) == true {
                    Text(row.date).font(.caption).foregroundStyle(AppColors.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let date = row.releaseDate, Calendar.current.startOfDay(for: date) > Calendar.current.startOfDay(for: .now) {
                Text("Upcoming").font(.caption2.weight(.medium))
                    .foregroundStyle(AppColors.accent)
                    .padding(6).background(AppColors.accent.opacity(0.12), in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
    }
}
