import SwiftUI

struct FavoritesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                if model.favorites.isEmpty {
                    EmptyStateView(
                        icon: "bookmark",
                        title: "Your saved list is empty",
                        message: "Save a title to keep it close, even when you are offline.",
                        actionTitle: "Explore titles",
                        action: { model.selectedTab = 0 }
                    )
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Saved titles")
                            .font(AppTypography.sectionTitle)
                            .foregroundStyle(.white)
                        Spacer()
                        Text("\(model.favorites.count)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    MediaGrid(items: model.favorites)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
        .background(AppColors.background.ignoresSafeArea())
        .navigationTitle("Saved")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct DownloadsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(model.downloadProgress.keys.sorted(), id: \.self) { id in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.downloadTitles[id] ?? "Downloading video").font(.headline)
                        ProgressView(value: model.downloadProgress[id] ?? 0).tint(AppColors.accent)
                        Text("Downloading").font(.caption).foregroundStyle(AppColors.secondaryText)
                    }.padding(16).background(AppColors.surface, in: RoundedRectangle(cornerRadius: 14))
                }
                if model.downloadedItems.isEmpty && model.downloadProgress.isEmpty {
                    EmptyStateView(
                        icon: "arrow.down.circle",
                        title: "No downloads yet",
                        message: "Download a movie or episode from its title page to watch offline.",
                        actionTitle: "Find something to watch",
                        action: { model.selectedTab = 1 }
                    )
                } else {
                    Text("Available on this iPhone")
                        .font(.system(size: 14))
                        .foregroundStyle(AppColors.secondaryText)
                    ForEach(model.downloadedItems) { item in
                        HStack(spacing: 14) {
                            NavigationLink { DetailView(item: item) } label: {
                                HStack(spacing: 14) {
                                    ArtworkView(item: item).frame(width: 68, height: 92).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                        Text("Available offline").font(.caption).foregroundStyle(AppColors.secondaryText)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Menu {
                                Button("Remove download", role: .destructive) { model.removeDownload(item) }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        }.padding(12).background(AppColors.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .background(AppColors.background.ignoresSafeArea())
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.large)
        .appErrorAlert()
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var showingClearHistoryAlert = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                if model.history.isEmpty {
                    EmptyStateView(
                        icon: "clock.arrow.circlepath",
                        title: "No watch history",
                        message: "Titles you play will appear here.",
                        actionTitle: "Explore titles",
                        action: { model.selectedTab = 0 }
                    )
                } else {
                    HStack {
                        Text("Recently watched")
                            .font(.system(size: 14))
                            .foregroundStyle(AppColors.secondaryText)
                        Spacer()
                        Button("Clear history", role: .destructive) { showingClearHistoryAlert = true }
                        .font(.system(size: 13, weight: .semibold))
                    }

                    LazyVStack(spacing: 10) {
                        ForEach(model.history) { record in
                            NavigationLink { DetailView(item: record.item) } label: {
                                HStack(spacing: 13) {
                                    ArtworkView(item: record.item)
                                        .frame(width: 66, height: 88)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(record.item.title)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .lineLimit(2)
                                        Text(record.item.kind.title)
                                            .font(.system(size: 12))
                                            .foregroundStyle(AppColors.secondaryText)
                                        if let year = record.item.year {
                                            Text(String(year))
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(AppColors.mutedText)
                                        }
                                        if record.duration > 0 {
                                            ProgressView(value: record.progress)
                                                .tint(AppColors.accent)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(AppColors.mutedText)
                                }
                                .padding(10)
                                .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .background(AppColors.background.ignoresSafeArea())
        .navigationTitle("Watch history")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog("Clear all watch history?", isPresented: $showingClearHistoryAlert, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes saved playback progress from this iPhone.")
        }
    }
}
