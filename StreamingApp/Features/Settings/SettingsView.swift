import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingClearHistoryAlert = false
    @State private var mirrorHost = ""

    private let qualities = ["Auto", "2160p", "1440p", "1080p", "720p", "480p", "360p"]

    var body: some View {
        List {
            Section("Rezka website") {
                LabeledContent("Current mirror", value: model.activeMirror)
                TextField("Mirror domain", text: $mirrorHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Use this mirror") { Task { await model.selectMirror(mirrorHost) } }
                    .disabled(mirrorHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("The app chooses a working mirror automatically. You can enter another domain here.")
                    .font(.caption).foregroundStyle(AppColors.secondaryText)
            }
            Section("Catalogue preferences") {
                NavigationLink {
                    ExcludedCountriesView()
                } label: {
                    LabeledContent("Excluded countries", value: model.excludedCountryCodes.isEmpty ? "None" : "\(model.excludedCountryCodes.count) selected")
                }
                .accessibilityIdentifier("excluded-countries")
                Text("Hide titles made in countries you choose from the catalogue and search results.")
                    .font(.caption).foregroundStyle(AppColors.secondaryText)
            }
            Section("Playback") {
                Picker("Default quality", selection: Binding(
                    get: { model.preferredQuality },
                    set: { model.preferredQuality = $0 }
                )) {
                    ForEach(qualities, id: \.self) { quality in
                        Text(quality).tag(quality)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Auto play next episode", isOn: Binding(
                    get: { model.autoPlayNext },
                    set: { model.autoPlayNext = $0 }
                ))

                NavigationLink {
                    HistoryView()
                } label: {
                    Label("Watch history", systemImage: "clock.arrow.circlepath")
                }
            }

            Section("Library") {
                LabeledContent("Saved titles", value: "\(model.favorites.count)")
                LabeledContent("Offline videos", value: "\(model.downloadedItems.count)")
                Button("Clear watch history", role: .destructive) {
                    showingClearHistoryAlert = true
                }
            }


            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.10")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "12")
                Text("Rezka catalogue and video library for iPhone")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.background)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog("Clear all watch history?", isPresented: $showingClearHistoryAlert, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes saved playback progress from this iPhone.")
        }
    }
}

struct ExcludedCountriesView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    private var countries: [MediaCountry] {
        MediaCountry.all.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section {
                if !model.excludedCountryCodes.isEmpty {
                    Button("Show all countries") { model.excludedCountryCodes = [] }
                        .accessibilityIdentifier("clear-country-exclusions")
                }
            } footer: {
                Text("Titles made in any selected country are hidden from Home, search, categories and collections. This also hides co-productions. Your saved titles and downloads stay available.")
            }
            Section("Countries to exclude") {
                ForEach(countries) { country in
                    Toggle(country.name, isOn: Binding(
                        get: { model.excludedCountryCodes.contains(country.id) },
                        set: { excluded in
                            if excluded { model.excludedCountryCodes.insert(country.id) }
                            else { model.excludedCountryCodes.remove(country.id) }
                        }
                    ))
                    .tint(AppColors.accent)
                    .accessibilityIdentifier("exclude-country-\(country.id)")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.background)
        .navigationTitle("Excluded countries")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a country")
    }
}
