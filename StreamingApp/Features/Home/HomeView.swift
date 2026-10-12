import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedKind: MediaKind?
    @State private var categoryItems: [MediaItem] = []
    @State private var isLoadingCategory = false
    @State private var categoryError: String?
    @State private var didAttemptInitialLoad = false
    @State private var featuredArtwork: MediaItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var recommendation: (seed: MediaItem, items: [MediaItem])? {
        guard let seed = model.continueWatching.first?.item ?? model.favorites.first else { return nil }
        let seedGenres = genreTokens(seed.genre)
        guard !seedGenres.isEmpty else { return nil }
        var seen = Set<String>([seed.id])
        let candidates = model.visibleItems(model.items + model.popularPicks + model.popularSeriesPicks)
        let matches = candidates.filter { item in
            guard seen.insert(item.id).inserted else { return false }
            return !seedGenres.isDisjoint(with: genreTokens(item.genre))
        }
        guard !matches.isEmpty else { return nil }
        return (seed, Array(matches.prefix(12)))
    }

    var body: some View {
        GeometryReader { geometry in
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {
                topBar

                if let featured = model.items.first {
                    featuredCard(featured, height: max(235, min(geometry.size.width * 0.82, min(geometry.size.height * 0.45, 370))))
                        .padding(.horizontal, -20)
                }

                if !model.continueWatching.isEmpty {
                    continueSection
                }

                kindPicker

                if model.isLoadingHome && model.items.isEmpty { ProgressView("Loading catalogue").frame(maxWidth: .infinity) }
                if didAttemptInitialLoad && model.items.isEmpty && !model.isLoadingHome && model.homeError == nil {
                    EmptyStateView(
                        icon: "film",
                        title: "No titles to show",
                        message: "Refresh the catalogue to try again.",
                        actionTitle: "Refresh catalogue",
                        action: { Task { await model.loadHome() } }
                    )
                }
                if let message = model.homeError {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Catalogue could not load", systemImage: "wifi.exclamationmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundStyle(AppColors.secondaryText)
                        Button("Try again") { Task { await model.loadHome() } }
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                HStack(spacing: 12) {
                    NavigationLink { RezkaCategoriesView() } label: {
                        Label("Categories", systemImage: "square.grid.2x2")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(AppColors.surface, in: Capsule())
                    }
                    NavigationLink { RezkaCollectionsView() } label: {
                        Label("Collections", systemImage: "square.stack.3d.up")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(AppColors.surface, in: Capsule())
                    }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .tint(.white)
                .premiumTapFeedback()

                if selectedKind == nil {
                    titleRow("Popular movies", items: model.popularPicks) {
                        RezkaCatalogueView(title: "Popular movies", cataloguePath: MediaKind.movie.cataloguePath, filter: "popular")
                    }
                    titleRow("Popular series", items: model.popularSeriesPicks) {
                        RezkaCatalogueView(title: "Popular series", cataloguePath: MediaKind.series.cataloguePath, filter: "popular")
                    }
                    if let recommendation {
                        titleRow("For you", items: recommendation.items, subtitle: "Because you watched \(recommendation.seed.title)") {
                            RezkaCuratedTitlesView(title: "For you", items: recommendation.items)
                        }
                    }
                    titleRow("Recently added", items: model.items) {
                        RezkaCatalogueView(title: "Recently added")
                    }
                    if !model.collectionPicks.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            sectionHeading("Collection picks") { RezkaCollectionsView() }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 14) {
                                    ForEach(model.collectionPicks.prefix(12)) { collection in
                                        RezkaCollectionCard(collection: collection)
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                            .padding(.horizontal, -20)
                        }
                    }
                } else {
                    if isLoadingCategory && categoryItems.isEmpty { ProgressView("Loading category") }
                    if let categoryError {
                        Text(categoryError).font(.subheadline).foregroundStyle(AppColors.secondaryText)
                        Button("Try again") { Task { await loadCategory() } }
                    }
                    if let selectedKind {
                        let visibleCategoryItems = model.visibleItems(categoryItems)
                        if !visibleCategoryItems.isEmpty {
                            titleRow(selectedKind.title, items: visibleCategoryItems) {
                                RezkaCatalogueView(title: selectedKind.title, cataloguePath: selectedKind.cataloguePath)
                            }
                        } else if !isLoadingCategory && categoryError == nil {
                            EmptyStateView(
                                icon: "film",
                                title: "No titles in this category",
                                message: model.excludedCountryCodes.isEmpty ? "Try another category." : "Your country settings may be hiding these titles.",
                                actionTitle: model.excludedCountryCodes.isEmpty ? nil : "Review settings",
                                action: model.excludedCountryCodes.isEmpty ? nil : { model.selectedTab = 4 }
                            )
                        }
                    }
                    let genres = model.categories.filter { $0.kind == selectedKind }
                    if !genres.isEmpty {
                        SectionHeading(title: "Genres")
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                            ForEach(genres) { category in
                                NavigationLink(category.title) { RezkaCatalogueView(link: RezkaLink(name: category.title, url: category.url)) }
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(AppColors.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: model.items.first?.id) { await loadFeaturedArtwork() }
        .appErrorAlert()
        .task {
            if model.catalogueItems.isEmpty { await model.loadHome() }
            didAttemptInitialLoad = true
            await model.loadDiscovery()
        }
        .task(id: selectedKind) { await loadCategory() }
        .task(id: model.excludedCountryCodes) { _ = await model.countryChecked(categoryItems) }
        .refreshable { await model.loadHome(); await model.loadDiscovery(force: true) }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            BrandWordmark()
            Spacer()
            Button { model.selectedTab = 1 } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(AppColors.surface, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.07), lineWidth: 1))
            }
            .accessibilityLabel("Search titles")
            .premiumTapFeedback()
        }
        .padding(.bottom, 1)
    }

    private func featuredCard(_ item: MediaItem, height: CGFloat) -> some View {
        NavigationLink { DetailView(item: item) } label: {
            ZStack(alignment: .bottomLeading) {
                ArtworkView(item: featuredArtworkItem(for: item), alignment: .top, useOriginal: true)
                    .frame(height: height)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.42), .black.opacity(0.92)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkle")
                        Text("Featured")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.5), in: Capsule())

                    Text(item.title)
                        .font(AppTypography.heroTitle)
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.year.map { "Released in \(String($0))" } ?? "Recently added")
                        Text(genreTokensForDisplay(item.genre))
                    }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Image(systemName: item.streamURL == nil && item.rezka == nil ? "info.circle.fill" : "play.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(item.streamURL == nil && item.rezka == nil ? "View details" : "Watch now")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(AppColors.accent, in: Capsule())
                    .padding(.top, 3)
                }
                .padding(22)
            }
            .clipShape(Rectangle())
        }
        .posterPressFeedback()
        .accessibilityIdentifier("featured-title")
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("Continue watching") { HistoryView() }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(model.continueWatching) { record in
                        NavigationLink { DetailView(item: record.item) } label: {
                            HStack(spacing: 12) {
                                ArtworkView(item: model.item(id: record.item.id) ?? record.item, alignment: .top)
                                    .frame(width: 76, height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(record.item.title)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(2)
                                    if let season = record.seasonID, let episode = record.episodeID {
                                        Text("Season \(season), episode \(episode)")
                                            .font(.caption2)
                                            .foregroundStyle(AppColors.secondaryText)
                                    }
                                    Text(record.remainingMinutes.map { "\($0) min left" } ?? record.item.kind.title)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(AppColors.secondaryText)
                                    ProgressView(value: record.progress)
                                        .tint(AppColors.accent)
                                }
                                .frame(width: 156, alignment: .leading)
                            }
                            .padding(10)
                            .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .posterPressFeedback()
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.horizontal, -20)
            .scrollClipDisabled()
        }
    }

    private var kindPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                kindChip(title: "All", kind: nil)
                ForEach(MediaKind.allCases) { kind in
                    kindChip(title: kind.title, kind: kind)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.horizontal, -20)
    }

    private func kindChip(title: String, kind: MediaKind?) -> some View {
        let isSelected = selectedKind == kind
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { selectedKind = kind }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isSelected ? 1 : 0.8))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(isSelected ? AppColors.accent : AppColors.surface, in: Capsule())
        }
        .premiumTapFeedback()
    }
    @ViewBuilder
    private func titleRow<Destination: View>(
        _ title: String,
        items: [MediaItem],
        subtitle: String? = nil,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        let visibleItems = model.visibleItems(items)
        if !visibleItems.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading(title) { destination() }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(AppColors.secondaryText)
                        .lineLimit(1)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(visibleItems) { item in
                            NavigationLink { DetailView(item: item) } label: {
                                VStack(alignment: .leading, spacing: 9) {
                                    ArtworkView(item: item)
                                        .frame(width: 144, height: 210)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .stroke(.white.opacity(0.08), lineWidth: 1)
                                        }
                                    Text(item.title)
                                        .font(AppTypography.cardTitle)
                                        .foregroundStyle(.white.opacity(0.94))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(width: 144, alignment: .leading)
                            }
                            .posterPressFeedback()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                    .scrollTargetLayout()
                }
                .padding(.horizontal, -20)
                .scrollClipDisabled()
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    private func featuredArtworkItem(for item: MediaItem) -> MediaItem {
        if let featuredArtwork, featuredArtwork.id == item.id { return featuredArtwork }
        if model.hasOriginalArtwork(for: item) || item.rezka == nil { return model.artworkItem(for: item) }
        var placeholder = item
        placeholder.posterURL = nil
        return placeholder
    }

    private func loadFeaturedArtwork() async {
        guard let item = model.items.first else { return }
        if item.metadata != nil || item.rezka == nil { featuredArtwork = item; return }
        do {
            let detailed = try await model.loadDetails(item)
            try Task.checkCancellation()
            guard model.items.first?.id == item.id else { return }
            featuredArtwork = detailed
        } catch is CancellationError { }
        catch { featuredArtwork = item }
    }

    private func genreTokensForDisplay(_ genre: String) -> String {
        genre.components(separatedBy: ",").prefix(2)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
    }

    private func sectionHeading<Destination: View>(
        _ title: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(AppTypography.sectionTitle)
                .tracking(-0.25)
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            NavigationLink { destination() } label: {
                HStack(spacing: 5) {
                    Text("See all")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColors.secondaryText)
                .fixedSize()
            }
            .accessibilityLabel("See all \(title)")
        }
    }

    private func genreTokens(_ genre: String) -> Set<String> {
        Set(genre.components(separatedBy: CharacterSet(charactersIn: ",;/"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.count >= 3 })
    }

    private func loadCategory() async {
        guard let kind = selectedKind else { categoryItems = []; return }
        categoryItems = []
        categoryError = nil
        isLoadingCategory = true
        defer { if selectedKind == kind { isLoadingCategory = false } }
        do {
            let base = try await model.contentSource.mirrors.activeURL()
            let result = try await model.contentSource.catalogue(url: base.appendingPathComponent(kind.cataloguePath))
            try Task.checkCancellation()
            let checked = await model.countryChecked(result.items)
            if selectedKind == kind { categoryItems = checked }
        } catch is CancellationError { }
        catch { if selectedKind == kind { categoryError = error.localizedDescription } }
    }

}
