import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var page = 1
    @State private var hasMore = false
    @State private var requestID = UUID()
    private var displayedResults: [MediaItem] { model.visibleItems(results) }
    private var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    BrandWordmark(compact: true)
                    Spacer()
                    Text("Discover")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppColors.secondaryText)
                }

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(AppColors.secondaryText)
                    TextField("Search Rezka titles", text: $query)
                        .font(.system(size: 15))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                        .onSubmit { model.rememberSearch(query) }
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(AppColors.surface, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.07), lineWidth: 1))

                if !hasQuery {
                    recentSearches
                    VStack(alignment: .leading, spacing: 15) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Popular right now")
                                .font(AppTypography.sectionTitle)
                                .foregroundStyle(.white)
                            Spacer()
                            NavigationLink {
                                RezkaCatalogueView(title: "Popular movies", cataloguePath: MediaKind.movie.cataloguePath, filter: "popular")
                            } label: {
                                HStack(spacing: 6) {
                                    Text("See all")
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                        }
                        let popular = model.popularPicks.isEmpty ? model.items : model.popularPicks
                        MediaGrid(items: Array(popular.prefix(4)))
                    }
                } else if isSearching && results.isEmpty {
                    ProgressView("Searching Rezka").frame(maxWidth: .infinity)
                } else if displayedResults.isEmpty, let searchError {
                    EmptyStateView(
                        icon: "wifi.exclamationmark",
                        title: "Search could not load",
                        message: searchError,
                        actionTitle: "Try again",
                        action: { Task { await loadResults() } }
                    )
                } else if displayedResults.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "No results yet",
                        message: model.excludedCountryCodes.isEmpty ? "Try another title." : "Try another title or change your excluded countries in Settings."
                    )
                } else {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Results")
                                .font(AppTypography.sectionTitle)
                                .foregroundStyle(.white)
                            Spacer()
                            Text("\(displayedResults.count) titles")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        MediaGrid(items: displayedResults)
                        if let searchError {
                            Text(searchError)
                                .font(.subheadline)
                                .foregroundStyle(AppColors.secondaryText)
                            Button("Try again") { Task { await loadResults(reset: false) } }
                        }
                        if isSearching { ProgressView().frame(maxWidth: .infinity) }
                        if hasMore {
                            Button("Load more results") { Task { await loadResults(reset: false) } }
                                .disabled(isSearching)
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
        .task(id: model.excludedCountryCodes) { _ = await model.countryChecked(results) }
        .task(id: query) {
            guard hasQuery else {
                results = []
                searchError = nil
                isSearching = false
                return
            }
            results = []
            searchError = nil
            isSearching = true
            do {
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
                await loadResults()
            } catch { }
        }
    }

    private func loadResults(reset: Bool = true) async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID()
        requestID = id
        guard !term.isEmpty else { results = []; searchError = nil; isSearching = false; return }
        isSearching = true
        searchError = nil
        if reset { results = [] }
        defer { if requestID == id { isSearching = false } }
        do {
            let nextPage = reset ? 1 : page + 1
            let result = try await model.contentSource.searchPage(query: term, page: nextPage)
            let checked = await model.countryChecked(result.items)
            try Task.checkCancellation()
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == term, requestID == id else { return }
            if reset { results = checked }
            else { results += checked.filter { candidate in !results.contains(where: { $0.id == candidate.id }) } }
            page = nextPage
            hasMore = result.hasNextPage
        } catch is CancellationError { }
        catch { if requestID == id { searchError = error.localizedDescription } }
    }

    @ViewBuilder
    private var recentSearches: some View {
        if !model.recentSearches.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "Recent searches", actionTitle: "Clear") {
                    model.clearSearchHistory()
                }
                ForEach(model.recentSearches, id: \.self) { term in
                    Button {
                        query = term
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock")
                                .foregroundStyle(AppColors.secondaryText)
                            Text(term)
                                .foregroundStyle(.white.opacity(0.88))
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppColors.mutedText)
                        }
                        .font(.system(size: 14))
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
