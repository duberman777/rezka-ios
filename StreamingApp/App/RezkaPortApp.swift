import SwiftUI

@main
struct RezkaPortApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainTabsView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(AppColors.accent)
        }
    }
}

struct MainTabsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView(selection: Binding(get: { model.selectedTab }, set: { model.selectedTab = $0 })) {
            NavigationStack {
                HomeView()
            }
            .tabItem { Label("Home", systemImage: "house.fill") }
            .tag(0)

            NavigationStack {
                SearchView()
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(1)

            NavigationStack {
                FavoritesView()
            }
            .tabItem { Label("Saved", systemImage: "bookmark.fill") }
            .tag(2)

            NavigationStack {
                DownloadsView()
            }
            .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            .tag(3)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(4)
        }
        .toolbarBackground(.automatic, for: .tabBar)
        .sensoryFeedback(.selection, trigger: model.selectedTab)
        .task(id: model.excludedCountryCodes) { await model.checkCatalogueCountries() }
        .sheet(isPresented: Binding(get: { model.browser.isPresented }, set: { if !$0 { model.browser.cancel() } })) {
            RezkaVerificationView(session: model.browser)
        }
        .task {
            #if DEBUG
            try? await Task.sleep(for: .seconds(2))
            RezkaLayoutDiagnostics.capture()
            if ProcessInfo.processInfo.arguments.contains("--rezka-playback-probe") {
                await RezkaPlaybackDiagnostics.probe(source: model.contentSource)
            }
            #endif
        }
        .task { await model.syncHistoryOnLaunch() }
        .onChange(of: scenePhase) { _, phase in
            Task {
                if phase == .active { await model.refreshCloudHistory() }
                else { await model.syncHistoryBeforeLeaving() }
            }
        }
    }
}
