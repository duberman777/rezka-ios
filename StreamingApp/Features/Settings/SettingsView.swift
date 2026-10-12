import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingClearHistoryAlert = false
    @State private var mirrorHost = ""
    @State private var syncEmail = ""
    @State private var syncPassword = ""
    @State private var syncMode = "login"
    @State private var syncBusy = false
    @State private var syncError: String?
    @State private var syncServer = ""

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

            Section("Sync across devices") {
                TextField("https://sync.example.com", text: $syncServer)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityLabel("Sync server address")
                Button("Use this server") {
                    Task {
                        syncBusy = true
                        syncError = nil
                        defer { syncBusy = false }
                        do {
                            try await model.watchSync.setServer(syncServer)
                            syncServer = model.watchSync.server?.absoluteString ?? ""
                        } catch { syncError = error.localizedDescription }
                    }
                }
                .disabled(syncBusy || syncServer == (model.watchSync.server?.absoluteString ?? ""))
                Text("Continue watching on any device. Sync uses a server you host yourself. Leave the address empty to keep your history on this iPhone only.")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                if model.watchSync.server != nil, let email = model.watchSync.email {
                    LabeledContent("Signed in", value: email)
                    Button("Sign out") {
                        Task { await model.watchSync.signOut() }
                    }
                    .disabled(syncBusy)
                } else if model.watchSync.server != nil {
                    TextField("Email", text: $syncEmail)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                    SecureField("Password", text: $syncPassword)
                        .textContentType(syncMode == "login" ? .password : .newPassword)
                    Text("Use the same account on each device. Passwords are protected and are never stored in the app.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    Button(syncBusy ? "Connecting" : syncMode == "login" ? "Sign in" : "Create account") {
                        Task {
                            syncBusy = true
                            syncError = nil
                            defer { syncBusy = false }
                            do {
                                let records = try await model.watchSync.authenticate(mode: syncMode, email: syncEmail, password: syncPassword, local: model.cloudHistoryRecords)
                                model.installCloudHistory(records)
                                syncPassword = ""
                            } catch { syncError = error.localizedDescription }
                        }
                    }
                    .disabled(syncBusy || syncEmail.isEmpty || syncPassword.count < 10)
                    Button(syncMode == "login" ? "Create an account" : "I already have an account") {
                        syncMode = syncMode == "login" ? "register" : "login"
                        syncError = nil
                    }
                    .disabled(syncBusy)
                }
                if let status = syncError ?? (model.watchSync.status.isEmpty ? nil : model.watchSync.status) {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(syncError == nil ? AppColors.secondaryText : .red)
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
        .onAppear { syncServer = model.watchSync.server?.absoluteString ?? "" }
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
