import Foundation

actor RezkaMirrorManager {
    private let client: RezkaHttpClient
    private let defaults: UserDefaults
    private var candidates: [URL] = []
    private var loadedConfiguration = false
    private var active: URL?
    private var configurationTask: Task<[String]?, Never>?
    private var selectionTask: Task<URL, Error>?

    init(client: RezkaHttpClient, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        active = defaults.string(forKey: "rezka.activeMirror").flatMap(Self.normalized)
    }

    func activeURL() async throws -> URL {
        if let active { return active }
        return try await selectWorkingMirror()
    }

    func availableMirrors() async -> [URL] {
        await loadConfiguration()
        return candidates
    }

    func select(_ raw: String) throws {
        guard let url = Self.normalized(raw) else { throw RezkaError.invalidURL }
        active = url
        defaults.set(url.absoluteString, forKey: "rezka.activeMirror")
    }

    func selectWorkingMirror(excluding excluded: Set<String> = []) async throws -> URL {
        if let selectionTask { return try await selectionTask.value }
        let task = Task { try await self.probe(excluding: excluded) }
        selectionTask = task
        defer { selectionTask = nil }
        return try await task.value
    }

    private func probe(excluding excluded: Set<String>) async throws -> URL {
        await loadConfiguration()
        var protectedMirror: URL?
        for candidate in candidates where !excluded.contains(candidate.host ?? "") {
            try Task.checkCancellation()
            var request = client.request(url: candidate)
            request.timeoutInterval = 6
            do {
                let response = try await client.fetch(request, allowBrowser: false)
                let html = try response.text()
                // Avoid accepting redirects to parked domains or empty landing pages.
                if html.contains("b-content__inline_item") || html.contains("b-content__main") {
                    let mirror = Self.normalized(response.url.absoluteString) ?? candidate
                    try select(mirror.absoluteString)
                    return mirror
                }
            } catch RezkaError.challengeRequired {
                // Let the native browser establish a session without probing dozens of domains.
                protectedMirror = candidate
                break
            } catch {
                try Task.checkCancellation()
            }
        }
        if let protectedMirror {
            try select(protectedMirror.absoluteString)
            return protectedMirror
        }
        throw RezkaError.noWorkingMirror
    }

    func rebased(_ url: URL, onto base: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { throw RezkaError.invalidURL }
        components.scheme = base.scheme
        components.host = base.host
        components.port = base.port
        guard let result = components.url else { throw RezkaError.invalidURL }
        return result
    }

    static func normalized(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
              url.scheme == "https", let host = url.host, host.contains("."),
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        return URL(string: "https://\(host.lowercased())/")
    }

    private func loadConfiguration() async {
        guard !loadedConfiguration else { return }
        var hosts = defaults.stringArray(forKey: "rezka.mirrors") ?? []
        let task: Task<[String]?, Never>
        if let configurationTask { task = configurationTask }
        else {
            task = Task { [client] in
                do {
                    var request = URLRequest(url: RezkaEndpoints.mirrorConfiguration)
                    request.timeoutInterval = 8
                    let response = try await client.transport.send(request)
                    guard (200..<300).contains(response.statusCode) else { return nil }
                    let configuration = try JSONDecoder().decode(MirrorConfiguration.self, from: response.data)
                    return configuration.mirrors.main + configuration.mirrors.cloudflare
                } catch { return nil }
            }
            configurationTask = task
        }
        if let remoteHosts = await task.value {
            hosts = remoteHosts
            defaults.set(hosts, forKey: "rezka.mirrors")
        }
        // Try a known bundled mirror first, then the maintained remote list.
        let ordered = (active.map { [$0.absoluteString] } ?? []) + [RezkaEndpoints.fallbackHosts[0]] + hosts + RezkaEndpoints.fallbackHosts
        var seen = Set<String>()
        candidates = ordered.compactMap(Self.normalized).filter { seen.insert($0.host ?? "").inserted }
        loadedConfiguration = true
        configurationTask = nil
    }

    private struct MirrorConfiguration: Decodable {
        let mirrors: Groups
        struct Groups: Decodable {
            let main: [String]
            let cloudflare: [String]
        }
    }
}
