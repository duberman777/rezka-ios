import SwiftUI

struct RezkaCatalogueView: View {
    @Environment(AppModel.self) private var model
    private let link: RezkaLink?
    private let title: String
    private let cataloguePath: String?
    private let filter: String?
    @State private var items: [MediaItem] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(link: RezkaLink) {
        self.link = link
        title = link.name
        cataloguePath = nil
        filter = nil
    }

    init(title: String, cataloguePath: String? = nil, filter: String? = nil) {
        link = nil
        self.title = title
        self.cataloguePath = cataloguePath
        self.filter = filter
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                let visibleItems = model.visibleItems(items)
                if visibleItems.isEmpty && isLoading {
                    ProgressView("Loading titles")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 50)
                } else if visibleItems.isEmpty {
                    EmptyStateView(
                        icon: model.excludedCountryCodes.isEmpty ? "film" : "line.3.horizontal.decrease.circle",
                        title: errorMessage == nil ? (model.excludedCountryCodes.isEmpty ? "No titles found" : "No titles match your countries") : "Catalogue could not load",
                        message: errorMessage ?? (model.excludedCountryCodes.isEmpty ? "This section is empty right now." : "Review your excluded countries or load another page."),
                        actionTitle: errorMessage != nil ? "Try again" : model.excludedCountryCodes.isEmpty ? nil : "Review settings",
                        action: errorMessage != nil ? { Task { await load() } } : model.excludedCountryCodes.isEmpty ? nil : { model.selectedTab = 4 }
                    )
                    if hasMore && errorMessage == nil && !isLoading {
                        Button("Load more titles") { Task { await load() } }
                            .buttonStyle(.bordered)
                            .tint(AppColors.accent)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    MediaGrid(items: visibleItems)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    if isLoading {
                        ProgressView("Loading more titles")
                            .frame(maxWidth: .infinity)
                    } else if hasMore {
                        Button("Load more titles") { Task { await load() } }
                            .buttonStyle(.bordered)
                            .tint(AppColors.accent)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(20)
        }
        .background(AppColors.background)
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if page == 0 { await load() } }
        .task(id: model.excludedCountryCodes) { _ = await model.countryChecked(items) }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let url: URL? = if let link { link.url }
                else if let cataloguePath { try await model.contentSource.mirrors.activeURL().appendingPathComponent(cataloguePath) }
                else { nil }
            let result = try await model.contentSource.catalogue(url: url, page: page + 1, filter: filter)
            let checked = await model.countryChecked(result.items)
            items += checked.filter { candidate in !items.contains(where: { $0.id == candidate.id }) }
            hasMore = result.hasNextPage
            page += 1
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }
}

struct RezkaCuratedTitlesView: View {
    @Environment(AppModel.self) private var model
    let title: String
    let items: [MediaItem]

    var body: some View {
        ScrollView {
            MediaGrid(items: model.visibleItems(items))
                .padding(20)
        }
        .background(AppColors.background)
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RezkaPersonView: View {
    @Environment(AppModel.self) private var model
    let link: RezkaLink
    @State private var person: RezkaPerson?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let person {
                    HStack(alignment: .center, spacing: 16) {
                        CachedArtwork(url: person.imageURL, transaction: Transaction(animation: .easeInOut(duration: 0.24))) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill().transition(.opacity)
                            } else {
                                AppColors.raised.overlay {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 28, weight: .light))
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                            }
                        }
                        .frame(width: 92, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        VStack(alignment: .leading, spacing: 7) {
                            Text(person.originalName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                            if !person.birthDate.isEmpty {
                                Text("Born \(person.birthDate)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            ForEach(person.jobs, id: \.self) { job in
                                Text(job)
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppColors.mutedText)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    SectionHeading(title: "Filmography")
                    MediaGrid(items: model.visibleItems(person.filmography))
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.secondary)
                    Button("Try again") { Task { await load() } }
                } else { ProgressView("Loading person") }
            }.padding(20)
        }
        .background(AppColors.background)
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle(person?.name ?? link.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .task(id: model.excludedCountryCodes) { _ = await model.countryChecked(person?.filmography ?? []) }
    }

    private func load() async {
        errorMessage = nil
        do {
            var result = try await model.contentSource.person(url: link.url)
            result.filmography = await model.countryChecked(result.filmography)
            person = result
        }
        catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }
}

struct RezkaCommentsView: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    @State private var comments: [RezkaComment] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(comments) { comment in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            CachedArtwork(url: comment.avatarURL) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill()
                                } else {
                                    Image(systemName: "person.crop.circle.fill")
                                        .resizable()
                                        .scaledToFit()
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                            }
                            .frame(width: 38, height: 38)
                            .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text(comment.author)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(comment.date)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            Spacer(minLength: 0)
                            if !comment.likes.isEmpty {
                                Label(comment.likes, systemImage: "hand.thumbsup")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                        }
                        Text(comment.text)
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineSpacing(3)
                    }
                    .padding(14)
                    .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.white.opacity(0.05), lineWidth: 1)
                    }
                    .padding(.leading, CGFloat(min(comment.indent, 3)) * 12)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
                if isLoading { ProgressView("Loading comments") }
                else if hasMore { Button(page == 0 ? "Reload" : "Load more comments") { Task { await load() } } }
                else if comments.isEmpty { Text("No comments yet.").foregroundStyle(.secondary) }
            }.padding(20)
        }
        .background(AppColors.background)
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle("Comments")
        .task { if page == 0 { await load() } }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await model.contentSource.comments(item: item, page: page + 1)
            comments += result.comments.filter { candidate in !comments.contains(where: { $0.id == candidate.id }) }
            page += 1
            hasMore = result.pages.contains { (Int($0.name) ?? 0) > page }
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }
}

struct RezkaCategoriesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedKind = MediaKind.movie

    private var categories: [RezkaCategory] {
        model.categories.filter { $0.kind == selectedKind }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 24) {
                if model.categories.isEmpty {
                    if model.isLoadingHome {
                        ProgressView("Loading categories")
                            .frame(maxWidth: .infinity).padding(.vertical, 48)
                    } else {
                        EmptyStateView(icon: "square.grid.2x2", title: "Categories are unavailable",
                            message: model.homeError ?? "Try loading the catalogue again.",
                            actionTitle: "Try again", action: { Task { await model.loadHome() } })
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(MediaKind.allCases.filter { kind in model.categories.contains { $0.kind == kind } }) { kind in
                                Button { selectedKind = kind } label: {
                                    Text(kind == .movie ? "Movies" : kind == .series ? "TV series" : kind.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 10).frame(height: 44)
                                        .background(selectedKind == kind ? AppColors.accent : AppColors.surface, in: Capsule())
                                        .overlay(Capsule().stroke(.white.opacity(selectedKind == kind ? 0 : 0.08), lineWidth: 1))
                                }
                                .premiumTapFeedback()
                                .accessibilityAddTraits(selectedKind == kind ? .isSelected : [])
                            }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 4)
                    }
                    .padding(.horizontal, -20)
                    HStack(alignment: .firstTextBaseline) {
                        Text("Explore \(selectedKind == .movie ? "movies" : selectedKind == .series ? "TV series" : selectedKind.title.lowercased())")
                            .font(AppTypography.sectionTitle)
                        Spacer(minLength: 8)
                        Text("\(categories.count) categories")
                            .font(.caption).foregroundStyle(AppColors.secondaryText)
                    }
                    LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize
                        ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 148, maximum: 240), spacing: 12)], spacing: 12) {
                        ForEach(categories) { category in
                            NavigationLink { RezkaCatalogueView(link: RezkaLink(name: category.title, url: category.url)) } label: {
                                RezkaCategoryTile(category: category)
                            }
                            .posterPressFeedback()
                            .accessibilityIdentifier("category-\(category.kind.rawValue)-\(category.url.lastPathComponent)")
                        }
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: selectedKind)
                }
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 32)
        }
        .background(AppColors.background.ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: selectedKind)
        .task { if model.categories.isEmpty { await model.loadHome() } }
    }
}

private struct RezkaCategoryTile: View {
    let category: RezkaCategory
    private static let artworkByGenre: [String: String] = [
        "action": "action",
        "adult": "adult",
        "adventures": "adventures",
        "anime": "animation",
        "arthouse": "arthouse",
        "biographical": "biographical",
        "cognitive": "cognitive",
        "comedy": "comedy",
        "concert": "music",
        "crime": "crime",
        "detective": "detective",
        "documentary": "documentary",
        "drama": "drama",
        "ecchi": "ecchi",
        "educational": "educational",
        "erotic": "erotic",
        "everyday": "everyday",
        "fairytale": "fairytale",
        "family": "family",
        "fantasy": "fantasy",
        "fiction": "scifi",
        "fighting": "fighting",
        "foreign": "foreign",
        "full-length": "full-length",
        "historical": "historical",
        "horror": "horror",
        "kids": "kids",
        "kodomo": "kodomo",
        "mahoushoujo": "mahoushoujo",
        "mecha": "mecha",
        "melodrama": "melodrama",
        "military": "military",
        "multseries": "multseries",
        "musical": "musical",
        "mystery": "mystery",
        "parody": "parody",
        "realtv": "realtv",
        "romance": "romance",
        "russian": "russian",
        "samurai": "samurai",
        "school": "school",
        "short": "short",
        "shoujo": "shoujo",
        "shoujoai": "shoujoai",
        "shounen": "shounen",
        "shounenai": "shounenai",
        "soyzmyltfilm": "soyzmyltfilm",
        "sport": "sport",
        "standup": "standup",
        "telecasts": "telecasts",
        "theatre": "theatre",
        "thriller": "thriller",
        "travel": "travel",
        "ukrainian": "ukrainian",
        "western": "western"
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                AppColors.surface
                if let artwork = Self.artworkByGenre[category.url.lastPathComponent] {
                    Image("Category_\(artwork)")
                        .resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "sparkles.tv")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(AppColors.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityHidden(true)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
                Text(category.title)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                    .shadow(color: .black.opacity(0.8), radius: 5, y: 2)
                    .padding(18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.09), lineWidth: 0.5))
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(category.title)
    }
}

struct RezkaCollectionCard: View {
    let collection: RezkaCollection
    var body: some View {
        NavigationLink { RezkaCatalogueView(link: RezkaLink(name: collection.title, url: collection.url)) } label: {
            VStack(alignment: .leading, spacing: 8) {
                CachedArtwork(url: collection.imageURL, transaction: Transaction(animation: .easeInOut(duration: 0.24))) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill().transition(.opacity)
                    } else {
                        AppColors.surface.overlay {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 30, weight: .light))
                                .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                }
                .frame(width: 152, height: 184)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                        .frame(height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(alignment: .bottomLeading) {
                            Text(collection.count.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(.white.opacity(0.88))
                                .padding(12)
                        }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                }
                Text(collection.title)
                    .font(AppTypography.cardTitle)
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(width: 152, alignment: .leading)
        }.posterPressFeedback()
        .accessibilityIdentifier("collection-\(collection.title)")
    }
}

struct RezkaCollectionsView: View {
    @Environment(AppModel.self) private var model
    @State private var collections: [RezkaCollection] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if collections.isEmpty && isLoading {
                    ProgressView("Loading collections")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 50)
                } else if collections.isEmpty {
                    EmptyStateView(
                        icon: "square.stack.3d.up",
                        title: "No collections found",
                        message: errorMessage ?? "Collections will appear here when they are available.",
                        actionTitle: errorMessage == nil ? nil : "Try again",
                        action: errorMessage == nil ? nil : { Task { await load() } }
                    )
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 20) {
                        ForEach(collections) { collection in RezkaCollectionCard(collection: collection) }
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.subheadline).foregroundStyle(AppColors.secondaryText)
                    }
                    if isLoading {
                        ProgressView("Loading more collections")
                    } else if hasMore {
                        Button("Load more collections") { Task { await load() } }
                            .buttonStyle(.bordered)
                            .tint(AppColors.accent)
                    }
                }
            }
            .padding(20)
        }
        .background(AppColors.background)
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle("Collections")
        .navigationBarTitleDisplayMode(.inline)
        .task { if collections.isEmpty { await load() } }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            let result = try await model.contentSource.collections(page: page)
            let new = result.filter { candidate in !collections.contains(where: { $0.id == candidate.id }) }
            collections += new
            hasMore = !new.isEmpty
            page += 1
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }
}
