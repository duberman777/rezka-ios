import SwiftUI

private struct DetailCastMember: Identifiable {
    let person: RezkaLink
    let role: String
    var id: String { "\(role)-\(person.id)" }
}

private struct DetailPersonPortrait: View {
    let person: RezkaLink
    let size: CGFloat

    private var initials: String {
        person.name.split(whereSeparator: { !$0.isLetter }).prefix(2)
            .map { String($0.prefix(1)) }.joined().uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(AppColors.raised)
            Text(initials).font(.title3.weight(.medium)).foregroundStyle(AppColors.secondaryText)
            CachedArtwork(url: person.imageURL, transaction: Transaction(animation: .easeInOut(duration: 0.3))) { phase in
                if let image = phase.image { image.resizable().scaledToFill().transition(.opacity) }
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

private struct DetailCastListView: View {
    let members: [DetailCastMember]

    var body: some View {
        List(members) { member in
            NavigationLink { RezkaPersonView(link: member.person) } label: {
                HStack(spacing: 16) {
                    DetailPersonPortrait(person: member.person, size: 60)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(member.person.name).font(.body.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(member.role).font(.subheadline).foregroundStyle(AppColors.secondaryText)
                    }
                    .padding(.vertical, 6)
                }
            }
            .listRowBackground(Color.clear)
            .premiumTapFeedback()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppColors.background.ignoresSafeArea())
        .navigationTitle("Cast and crew")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DetailInformation: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

private struct DetailScrollTracking: ViewModifier {
    let heroHeight: CGFloat
    @Binding var isPastHero: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > heroHeight - 100
            } action: { _, value in
                isPastHero = value
            }
        } else {
            content
        }
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model
    @State private var showingPlayer = false
    @State private var loadedItem: MediaItem?
    @State private var isLoadingDetails = false
    @State private var detailError: String?
    @State private var translatorID = ""
    @State private var seasons: [RezkaSeason] = []
    @State private var seasonID = ""
    @State private var episodeID = ""
    @State private var isLoadingEpisodes = false
    @State private var episodeError: String?
    @State private var isResolvingPlayback = false
    @State private var playbackSource: PlaybackSource?
    @State private var playbackRequest: PlaybackRequest?
    @State private var websitePlaybackURL: URL?
    @State private var websiteStartOver = false
    @State private var expandedSynopsis = false
    @State private var expandedLinkSections: Set<String> = []
    @State private var isPastHero = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let item: MediaItem

    private var currentItem: MediaItem {
        model.downloadedItems.first(where: { $0.id == item.id })
            ?? model.customItems.first(where: { $0.id == item.id && $0.streamURL != nil })
            ?? loadedItem
            ?? model.item(id: item.id)
            ?? item
    }

    var body: some View {
        GeometryReader { geometry in
        let heroHeight = max(260, min(geometry.size.width * 1.08, min(geometry.size.height * 0.5, 440)))
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                hero(height: heroHeight)

                VStack(alignment: .leading, spacing: 15) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(currentItem.title)
                                .font(AppTypography.pageTitle)
                                .foregroundStyle(.white)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(metadataLine)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AppColors.secondaryText)
                                .lineLimit(2)
                            Text(currentItem.genre)
                                .font(.subheadline)
                                .foregroundStyle(AppColors.mutedText)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Button { model.toggleFavorite(currentItem) } label: {
                            Image(systemName: model.isFavorite(currentItem) ? "bookmark.fill" : "bookmark")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(model.isFavorite(currentItem) ? AppColors.accent : .white)
                                .frame(width: 46, height: 46)
                                .background(.black.opacity(0.48), in: Circle())
                                .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))
                                .symbolEffect(.bounce, value: model.isFavorite(currentItem))
                        }
                        .accessibilityLabel(model.isFavorite(currentItem) ? "Remove from saved" : "Save title")
                        .premiumTapFeedback()
                    }

                    if canPlay {
                        Button {
                            Task { await play() }
                        } label: {
                            HStack(spacing: 9) {
                                if isResolvingPlayback { ProgressView().tint(.white) }
                                Label(playLabel, systemImage: "play.fill")
                            }
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(AppColors.accent, in: Capsule())
                        }
                        .disabled(isLoadingDetails || isLoadingEpisodes || isResolvingPlayback || (currentItem.rezka != nil && translatorID.isEmpty) || (currentItem.rezka?.isSeries == true && episodeID.isEmpty))
                        .accessibilityIdentifier("play-title")
                        .premiumTapFeedback()
                    } else {
                        Label("Not available to stream", systemImage: "play.slash.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(AppColors.secondaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    if canDownload {
                        let id = model.downloadID(for: currentItem, request: selectedRequest)
                        let downloaded = model.downloadedItems.contains { $0.id == id }
                        Button {
                            Task { await model.saveOfflineCopy(of: currentItem, request: selectedRequest) }
                        } label: {
                            HStack {
                                Label(downloaded ? "Downloaded" : model.downloadProgress[id] != nil ? "Downloading" : "Download", systemImage: downloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                                if let progress = model.downloadProgress[id] { Spacer(); ProgressView(value: progress).frame(width: 80).tint(AppColors.accent) }
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 52)
                            .frame(maxWidth: .infinity)
                            .background(AppColors.raised, in: Capsule())
                        }
                        .disabled(downloaded || model.downloadProgress[id] != nil || isLoadingDetails || isLoadingEpisodes || translatorID.isEmpty && currentItem.rezka != nil || currentItem.rezka?.isSeries == true && episodeID.isEmpty)
                        .accessibilityIdentifier("download-title")
                        .premiumTapFeedback()
                    }

                    if let record = selectedWatchRecord, record.position > 0 {
                        HStack {
                            ProgressView(value: record.progress).tint(AppColors.accent)
                            if let minutes = record.remainingMinutes {
                                Text("\(minutes) min left").font(.caption).foregroundStyle(AppColors.secondaryText)
                            }
                        }
                        Button("Start over") { Task { await play(startOver: true) } }
                            .font(.subheadline)
                            .premiumTapFeedback()
                    }

                    playbackOptions
                    episodesSection
                    aboutSection

                    if isLoadingDetails { ProgressView("Loading title details") }
                    if let detailError {
                        Text(detailError).font(.subheadline).foregroundStyle(AppColors.secondaryText)
                        Button("Reload details") { Task { await loadDetails() } }
                    }

                    if currentItem.rezka != nil {
                        metadata
                        NavigationLink {
                            RezkaCommentsView(item: currentItem)
                        } label: {
                            Label("Read comments", systemImage: "text.bubble")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(15)
                                .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.06), lineWidth: 1))
                        }
                        .premiumTapFeedback()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 48)
            }
        }
        .modifier(DetailScrollTracking(heroHeight: heroHeight, isPastHero: $isPastHero))
        }
        .ignoresSafeArea(edges: .top)
        .background(AppColors.background.ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle(isPastHero ? currentItem.title : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarBackground(isPastHero ? .visible : .hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .fullScreenCover(isPresented: $showingPlayer, onDismiss: {
            // Send the stopping point now so another device can resume from it right away.
            Task { await model.syncHistoryNow() }
            if let record = model.history.first(where: { $0.item.id == item.id }), let season = record.seasonID, let episode = record.episodeID {
                seasonID = season
                episodeID = episode
            }
        }) {
            if let websitePlaybackURL, let playbackRequest {
                WebsitePlayerView(item: currentItem, pageURL: websitePlaybackURL, request: playbackRequest, startOver: websiteStartOver)
            } else if let playbackSource {
                PlayerView(item: currentItem, source: playbackSource, preferredQuality: model.preferredQuality, request: playbackRequest, seasons: seasons,
                           onFailure: {
                               detailError = $0
                               if let playbackRequest {
                                   Task { await model.contentSource.invalidatePreparedPlayback(request: playbackRequest) }
                               }
                           })
            }
        }
        .appErrorAlert()
        .task(id: item.id) { await loadDetails() }
        .task(id: translatorID) { await loadEpisodes() }
        .task(id: selectedRequest) {
            guard model.playbackEngine == "native", let request = selectedRequest, !translatorID.isEmpty,
                  currentItem.rezka?.isSeries != true || (request.season != nil && request.episode != nil) else { return }
            await model.contentSource.preparePlayback(request: request)
        }
    }

    private func hero(height: CGFloat) -> some View {
        GeometryReader { geometry in
            Group {
                if let posterURL = heroArtwork.posterURL {
                    CachedArtwork(url: posterURL, transaction: Transaction(animation: .easeInOut(duration: 0.35))) { phase in
                        if let image = phase.image {
                            image.resizable()
                                .scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                                .clipped()
                            .transition(.opacity)
                        } else {
                            ArtworkView(item: heroArtwork, alignment: .top)
                        }
                    }
                } else {
                    ArtworkView(item: heroArtwork, alignment: .top)
                }
            }
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, AppColors.background],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: min(160, geometry.size.height * 0.38))
                .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 130).allowsHitTesting(false)
            }
            .clipped()
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private var heroArtwork: MediaItem {
        var artwork = model.artworkItem(for: currentItem)
        if artwork.rezka != nil && !model.hasOriginalArtwork(for: artwork) && detailError == nil { artwork.posterURL = nil }
        return artwork
    }

    private var selectedWatchRecord: WatchRecord? {
        if let request = selectedRequest, let season = request.season, let episode = request.episode {
            return model.episodeRecord(mediaID: item.id, season: season, episode: episode)
        }
        return model.history.first(where: { $0.item.id == item.id })
    }

    private var metadataLine: String {
        guard let year = currentItem.year else { return currentItem.kind.title }
        return "\(currentItem.kind.title) from \(year)"
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("About")
                    .font(AppTypography.sectionTitle)
                    .foregroundStyle(.white)
                Spacer()
                if currentItem.kind == .series {
                    Text("SERIES")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }

            if !currentItem.synopsis.isEmpty {
                Text(currentItem.synopsis)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineSpacing(4)
                    .lineLimit(expandedSynopsis || currentItem.synopsis.count <= 100 ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)

                if currentItem.synopsis.count > 100 {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                            expandedSynopsis.toggle()
                        }
                    } label: {
                        Label(expandedSynopsis ? "Show less" : "Read more", systemImage: expandedSynopsis ? "chevron.up" : "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .premiumTapFeedback()
                }
            } else if isLoadingDetails {
                ProgressView("Loading story")
                    .font(.caption)
                    .tint(AppColors.secondaryText)
            } else {
                Text("Story details are not available for this title.")
                    .font(.system(size: 14))
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.045), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var playLabel: String {
        if isResolvingPlayback { return "Loading video" }
        let request = currentItem.rezka == nil ? nil : PlaybackRequest(mediaID: currentItem.id,
            translatorID: translatorID.nonEmpty, season: seasonID.nonEmpty, episode: episodeID.nonEmpty)
        if let record = selectedWatchRecord, record.progress < 1,
           record.resumePosition(for: request) != nil {
            if let season = request?.season, let episode = request?.episode {
                return "Resume S\(season) E\(episode) · \(record.positionLabel)"
            }
            return "Resume from \(record.positionLabel)"
        }
        if let season = request?.season, let episode = request?.episode { return "Play S\(season) E\(episode)" }
        return "Play"
    }

    private var canPlay: Bool {
        currentItem.streamURL != nil || currentItem.rezka != nil
    }

    private var selectedRequest: PlaybackRequest? {
        guard currentItem.rezka != nil else { return nil }
        return PlaybackRequest(mediaID: currentItem.id, translatorID: translatorID.nonEmpty,
            season: seasonID.nonEmpty, episode: episodeID.nonEmpty, pageURL: currentItem.rezka?.pageURL)
    }

    private var canDownload: Bool {
        currentItem.rezka != nil || currentItem.streamURL.map { !$0.isFileURL } == true
    }

    private var castMembers: [DetailCastMember] {
        guard let metadata = currentItem.metadata else { return [] }
        return metadata.directors.map { DetailCastMember(person: $0, role: "Director") }
            + metadata.actors.map { DetailCastMember(person: $0, role: "Cast") }
    }

    private var informationEntries: [DetailInformation] {
        guard let metadata = currentItem.metadata else { return [] }
        let preferred: [(key: String, label: String)] = [
            ("Дата выхода", "Released"),
            ("Время", "Runtime"),
            ("Возраст", "Age rating"),
            ("Страна", "Country"),
            ("Слоган", "Tagline")
        ]
        var entries = preferred.compactMap { field -> DetailInformation? in
            guard let value = metadata.information[field.key]?.nonEmpty else { return nil }
            return DetailInformation(label: field.label, value: value)
        }
        if metadata.information["Дата выхода"] == nil, let year = currentItem.year {
            entries.insert(DetailInformation(label: "Released", value: String(year)), at: 0)
        }
        if metadata.information["Время"] == nil, let duration = currentItem.durationMinutes {
            entries.append(DetailInformation(label: "Runtime", value: "\(duration) min"))
        }
        if let originalTitle = currentItem.originalTitle?.nonEmpty, originalTitle != currentItem.title {
            entries.append(DetailInformation(label: "Original title", value: originalTitle))
        }
        return entries
    }

    private func loadDetails() async {
        guard item.rezka != nil else { return }
        isLoadingDetails = true
        detailError = nil
        defer { isLoadingDetails = false }
        do {
            let result = try await model.loadDetails(item)
            try Task.checkCancellation()
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.34)) {
                loadedItem = result
                let translators = result.rezka?.playableTranslators ?? []
                let savedTranslator = model.history.first(where: { $0.item.id == item.id })?.translatorID
                translatorID = translators.first(where: { $0.id == savedTranslator })?.id
                    ?? translators.first(where: \.isSelected)?.id ?? translators.first?.id ?? ""
            }
        } catch is CancellationError { }
        catch { detailError = error.localizedDescription }
    }

    private func loadEpisodes() async {
        guard let media = currentItem.rezka, media.isSeries, !translatorID.isEmpty else { return }
        let translation = translatorID
        isLoadingEpisodes = true
        episodeError = nil
        seasonID = ""
        episodeID = ""
        seasons = []
        defer { if translatorID == translation { isLoadingEpisodes = false } }
        do {
            let result = try await model.contentSource.episodes(item: currentItem, translatorID: translation)
            try Task.checkCancellation()
            guard translatorID == translation else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                seasons = result
                let saved = model.history.first(where: { $0.item.id == item.id })
                let selectedSeason = result.first(where: { $0.id == saved?.seasonID }) ?? result.first
                seasonID = selectedSeason?.id ?? ""
                episodeID = selectedSeason?.episodes.first(where: { $0.id == saved?.episodeID })?.id ?? selectedSeason?.episodes.first?.id ?? ""
            }
        } catch is CancellationError { }
        catch { if translatorID == translation { episodeError = error.localizedDescription } }
    }

    private func play(startOver: Bool = false) async {
        model.errorMessage = nil
        isResolvingPlayback = true
        defer { isResolvingPlayback = false }
        websitePlaybackURL = nil
        if model.playbackEngine == "website", currentItem.streamURL == nil, let request = selectedRequest,
           let pageURL = currentItem.rezka?.pageURL {
            websiteStartOver = startOver
            playbackRequest = request
            playbackSource = nil
            websitePlaybackURL = pageURL
            showingPlayer = true
            return
        }
        // Another device may have saved a later position since this one last synced.
        async let cloudRefresh: Void = startOver ? () : model.refreshCloudHistory()
        do {
            if let url = currentItem.streamURL {
                playbackRequest = nil
                playbackSource = PlaybackSource(streams: [VideoStream(quality: "Original", url: url)], subtitles: [])
            } else {
                let request = PlaybackRequest(mediaID: currentItem.id, translatorID: translatorID.nonEmpty,
                    season: seasonID.nonEmpty, episode: episodeID.nonEmpty, pageURL: currentItem.rezka?.pageURL)
                playbackSource = try await model.contentSource.playback(request: request)
                playbackRequest = request
            }
            await cloudRefresh
            if startOver {
                model.recordProgress(for: currentItem, position: 0, duration: 0, request: playbackRequest)
            } else if let request = playbackRequest, let season = request.season, let episode = request.episode,
                      let record = model.episodeRecord(mediaID: item.id, season: season, episode: episode), record.progress < 1.0 {
                model.recordProgress(for: currentItem, position: record.position, duration: record.duration, request: request)
            }
            showingPlayer = true
        } catch is CancellationError { }
        catch { model.errorMessage = error.localizedDescription }
    }

    @ViewBuilder
    private var playbackOptions: some View {
        if let media = currentItem.rezka {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Label("Quality", systemImage: "4k.tv")
                        .foregroundStyle(AppColors.secondaryText)
                    Spacer()
                    Picker("Video quality", selection: Binding(
                        get: { model.preferredQuality }, set: { model.preferredQuality = $0 }
                    )) {
                        ForEach(["Auto", "2160p", "1440p", "1080p", "720p", "480p", "360p"], id: \.self) { quality in
                            Text(quality).tag(quality)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(model.playbackEngine == "website")
                    .tint(.white)
                    .sensoryFeedback(.selection, trigger: model.preferredQuality)
                }
                .frame(minHeight: 48)
                if model.playbackEngine == "website" {
                    Text("Якість та буферизація налаштовуються у вебплеєрі сайту.")
                        .font(.caption).foregroundStyle(AppColors.secondaryText)
                }
                Divider().overlay(.white.opacity(0.04))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Label("Audio", systemImage: "waveform")
                            .foregroundStyle(AppColors.secondaryText)
                        Spacer(minLength: 0)
                        Menu {
                            Picker("Translation", selection: $translatorID) {
                                ForEach(media.playableTranslators) { translator in
                                    Text(translator.name).tag(translator.id)
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(media.playableTranslators.first(where: { $0.id == translatorID })?.name ?? "Unavailable")
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .trailing)
                            .contentShape(Rectangle())
                        }
                        .tint(.white)
                        .sensoryFeedback(.selection, trigger: translatorID)
                        .disabled(media.playableTranslators.isEmpty)
                    }
                    .frame(minHeight: 48)
                    if media.playableTranslators.isEmpty {
                        Text("No standard translation is available.")
                            .font(.caption).foregroundStyle(AppColors.secondaryText)
                            .padding(.bottom, 10)
                    }
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.06), lineWidth: 1))
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var episodesSection: some View {
        if currentItem.rezka?.isSeries == true {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeading(title: "Episodes")
                    if !seasons.isEmpty {
                        Picker("Season", selection: Binding(get: { seasonID }, set: { newSeason in
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                                seasonID = newSeason
                                episodeID = seasons.first(where: { $0.id == newSeason })?.episodes.first?.id ?? ""
                            }
                        })) {
                            ForEach(seasons) { season in Text(season.title).tag(season.id) }
                        }
                        .pickerStyle(.menu)
                        .tint(.white)
                        .sensoryFeedback(.selection, trigger: seasonID)
                    }
                }
                if isLoadingEpisodes { ProgressView("Loading episodes") }
                if let episodeError {
                    Text(episodeError).font(.subheadline).foregroundStyle(AppColors.secondaryText)
                    Button("Reload episodes") { Task { await loadEpisodes() } }.premiumTapFeedback()
                }
                if let season = seasons.first(where: { $0.id == seasonID }) {
                    Text(season.episodes.count == 1 ? "1 episode" : "\(season.episodes.count) episodes")
                        .font(.caption).foregroundStyle(AppColors.secondaryText)
                    LazyVStack(spacing: 12) {
                        ForEach(season.episodes) { episode in
                            episodeRow(episode).transition(.opacity)
                        }
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: seasonID)
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func episodeRow(_ episode: RezkaEpisode) -> some View {
        let record = model.episodeRecord(mediaID: item.id, season: seasonID, episode: episode.id)
        let request = PlaybackRequest(mediaID: currentItem.id, translatorID: translatorID.nonEmpty, season: seasonID, episode: episode.id, pageURL: currentItem.rezka?.pageURL)
        let id = model.downloadID(for: currentItem, request: request)
        let downloaded = model.downloadedItems.contains { $0.id == id }
        return HStack(spacing: 4) {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                episodeID = episode.id
            }
            Task { await play() }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    ArtworkView(item: currentItem)
                        .frame(width: 104, height: 64)
                        .clipped()
                    Image(systemName: (record?.progress ?? 0) >= 1.0 ? "checkmark.circle.fill" : "play.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 6) {
                    Text(episode.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    if let record, record.progress >= 1.0 {
                        Text("Watched").font(.caption).foregroundStyle(AppColors.secondaryText)
                    } else if let record, record.position > 0 {
                        Text("Resume from \(record.positionLabel)").font(.caption).foregroundStyle(AppColors.secondaryText)
                        ProgressView(value: record.progress).tint(AppColors.accent)
                    } else {
                        Text("Play episode").font(.caption).foregroundStyle(AppColors.secondaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(episodeID == episode.id ? AppColors.raised : AppColors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(episodeID == episode.id ? .white.opacity(0.2) : .white.opacity(0.04), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .premiumTapFeedback()
        .disabled(isResolvingPlayback || isLoadingEpisodes)
        .accessibilityIdentifier("episode-\(seasonID)-\(episode.id)")
        Button {
            Task { await model.saveOfflineCopy(of: currentItem, request: request) }
        } label: {
            if let progress = model.downloadProgress[id] {
                ProgressView(value: progress).frame(width: 28).tint(AppColors.accent)
            } else {
                Image(systemName: downloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 21)).foregroundStyle(AppColors.secondaryText)
                    .frame(width: 44, height: 44)
            }
        }
        .disabled(downloaded || model.downloadProgress[id] != nil)
        .accessibilityLabel(downloaded ? "Episode downloaded" : "Download episode")
        .premiumTapFeedback()
        }
    }

    @ViewBuilder
    private var metadata: some View {
        if let metadata = currentItem.metadata {
            VStack(alignment: .leading, spacing: 24) {
                ratingsSection(metadata)
                castSection
                informationSection
                linkSection(title: "Collections", links: metadata.collections)
                linkSection(title: "Rankings", links: metadata.rankings)
                franchiseSection(metadata)
                scheduleSection(metadata)
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .animation(reduceMotion ? nil : .smooth(duration: 0.34), value: currentItem.metadata?.information.count ?? 0)
        }
    }

    @ViewBuilder
    private func ratingsSection(_ metadata: RezkaMetadata) -> some View {
        if metadata.imdb != nil || metadata.kinopoisk != nil || metadata.rating != nil {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: "Ratings")
                HStack(spacing: 16) {
                    if let imdb = metadata.imdb {
                        ratingCard(title: "IMDb", value: imdb.value, url: imdb.url)
                    }
                    if let kinopoisk = metadata.kinopoisk {
                        ratingCard(title: "Kinopoisk", value: kinopoisk.value, url: kinopoisk.url)
                    }
                    if let rating = metadata.rating {
                        ratingCard(title: "Rezka", value: rating, url: nil)
                    }
                }
                .padding(16)
                .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }

    @ViewBuilder
    private func ratingCard(title: String, value: String, url: URL?) -> some View {
        let content = VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(title)
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) rating \(value) out of 10")

        if let url {
            Link(destination: url) { content }.premiumTapFeedback()
        } else {
            content
        }
    }

    @ViewBuilder
    private var castSection: some View {
        if !castMembers.isEmpty {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeading(title: "Cast and crew")
                    NavigationLink { DetailCastListView(members: castMembers) } label: {
                        Text("See all").font(.subheadline).foregroundStyle(AppColors.secondaryText)
                    }
                    .premiumTapFeedback()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(castMembers) { member in
                            NavigationLink {
                                RezkaPersonView(link: member.person)
                            } label: {
                                castCard(member)
                            }
                            .premiumTapFeedback()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 2)
                }
                .padding(.horizontal, -20)
            }
        }
    }

    private func castCard(_ member: DetailCastMember) -> some View {
        VStack(spacing: 12) {
            DetailPersonPortrait(person: member.person, size: 96)
            VStack(spacing: 4) {
                Text(member.person.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(member.role)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
            .multilineTextAlignment(.center)
        }
        .frame(width: 120, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var informationSection: some View {
        if !informationEntries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading(title: "Information")
                ForEach(Array(informationEntries.enumerated()), id: \.element.id) { index, entry in
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 6) { informationContent(entry) }
                        } else {
                            HStack(alignment: .top, spacing: 20) {
                                Text(entry.label)
                                    .font(.subheadline)
                                    .foregroundStyle(AppColors.secondaryText)
                                    .frame(width: 96, alignment: .leading)
                                Text(entry.value)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.92))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    .accessibilityElement(children: .combine)
                    if index < informationEntries.count - 1 { Divider().overlay(.white.opacity(0.04)) }
                }
            }
        }
    }

    @ViewBuilder
    private func informationContent(_ entry: DetailInformation) -> some View {
        Text(entry.label).font(.subheadline).foregroundStyle(AppColors.secondaryText)
        Text(entry.value).font(.body).foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func linkSection(title: String, links: [RezkaLink]) -> some View {
        if !links.isEmpty {
            let visible = expandedLinkSections.contains(title) ? links : Array(links.prefix(3))
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: title)
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, link in
                        NavigationLink { RezkaCatalogueView(link: link) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: title == "Rankings" ? "chart.bar" : "square.stack")
                                    .font(.system(size: 16))
                                    .foregroundStyle(AppColors.secondaryText)
                                    .frame(width: 24)
                                Text(link.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppColors.mutedText)
                            }
                            .padding(.vertical, 15)
                            .contentShape(Rectangle())
                        }
                        .premiumTapFeedback()
                        if index < visible.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 16)
                .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 18))
                if links.count > 3 {
                    Button(expandedLinkSections.contains(title) ? "Show less" : "See all \(links.count)") {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                            if expandedLinkSections.contains(title) { expandedLinkSections.remove(title) }
                            else { expandedLinkSections.insert(title) }
                        }
                    }
                    .font(.subheadline.weight(.medium)).foregroundStyle(.white).premiumTapFeedback()
                }
            }
        }
    }

    @ViewBuilder
    private func franchiseSection(_ metadata: RezkaMetadata) -> some View {
        if !metadata.franchise.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: "More in this franchise")
                if let title = metadata.franchiseTitle {
                    Text(title).font(.caption).foregroundStyle(AppColors.secondaryText)
                }
                VStack(spacing: 0) {
                    ForEach(Array(metadata.franchise.enumerated()), id: \.element.id) { index, entry in
                        NavigationLink { DetailView(item: linkedTitle(entry)) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "play.circle")
                                    .font(.title2.weight(.light))
                                    .foregroundStyle(AppColors.secondaryText)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(entry.title)
                                        .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: 12) {
                                        if !entry.year.isEmpty { Text(entry.year) }
                                        if !entry.rating.isEmpty { Label(entry.rating, systemImage: "star") }
                                    }
                                    .font(.caption).foregroundStyle(AppColors.secondaryText)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppColors.mutedText)
                            }
                            .padding(.vertical, 15)
                            .contentShape(Rectangle())
                        }
                        .premiumTapFeedback()
                        if index < metadata.franchise.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 16)
                .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }

    private func linkedTitle(_ entry: RezkaFranchiseItem) -> MediaItem {
        let component = entry.url.lastPathComponent
        let id = String(component.prefix(while: { $0.isNumber }))
        let isSeries = entry.url.path.contains("/series/")
        return MediaItem(id: id.isEmpty ? entry.id : id, title: entry.title,
            year: Int(entry.year.prefix(4)), kind: isSeries ? .series : .movie,
            genre: "", synopsis: "", symbol: isSeries ? "tv" : "film", paletteIndex: 0,
            rezka: RezkaMedia(movieID: id, pageURL: entry.url, isSeries: isSeries))
    }

    @ViewBuilder
    private func scheduleSection(_ metadata: RezkaMetadata) -> some View {
        if !metadata.schedule.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: "Release schedule")
                ForEach(Array(metadata.schedule.enumerated()), id: \.offset) { _, schedule in
                    RezkaReleaseScheduleView(schedule: schedule)
                }
            }
        }
    }

}
