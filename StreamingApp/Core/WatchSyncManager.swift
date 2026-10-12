import Foundation
import Observation
import Security

private struct SyncAccount: Decodable {
    let id: String
    let email: String
}

private struct SyncAuthResponse: Decodable {
    let token: String
    let expiresAt: Double
    let user: SyncAccount
}

private struct SyncHistoryResponse: Decodable {
    let records: [WatchRecord]
    let clearedAt: Double

    private enum CodingKeys: String, CodingKey { case records, clearedAt }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // One record this version cannot read must not stop the rest from syncing.
        records = try container.decode(LossyArray<WatchRecord>.self, forKey: .records).elements
        clearedAt = try container.decode(Double.self, forKey: .clearedAt)
    }
}

/// Syncs viewing history through a server the user hosts. Sync stays off until its address is set in Settings.
@MainActor
@Observable
final class WatchSyncManager {
    private static let serverKey = "syncServer"
    private(set) var server: URL?
    private var token: String?
    private var debounceTask: Task<Void, Never>?
    private var pendingRecords: [WatchRecord]?
    private var generation = 0
    private(set) var email: String?
    private(set) var status = ""
    private(set) var lastError: String?

    init() {
        server = UserDefaults.standard.string(forKey: Self.serverKey).flatMap { try? SyncServerAddress.normalized($0) }
        // A session is only used with the server that issued it.
        if let server, let saved = Self.readKeychain(), saved.server == server.absoluteString, saved.expiresAt > Date().timeIntervalSince1970 * 1000 {
            token = saved.token
            email = saved.email
        } else {
            Self.deleteKeychain()
        }
        status = server == nil ? "" : "Sign in to sync viewing history across devices."
    }

    /// Switches to another server. The session for the previous server is signed out first.
    func setServer(_ text: String) async throws {
        let next = try SyncServerAddress.normalized(text)
        guard next != server else { return }
        if token != nil { await signOut() }
        server = next
        UserDefaults.standard.set(next?.absoluteString, forKey: Self.serverKey)
        lastError = nil
        status = next == nil ? "" : "Sign in to sync viewing history across devices."
    }

    func authenticate(mode: String, email: String, password: String, local: [WatchRecord]) async throws -> [WatchRecord] {
        status = "Signing in"
        lastError = nil
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let response: SyncAuthResponse = try await request("/v1/auth/\(mode)", method: "POST", body: body, as: SyncAuthResponse.self)
        token = response.token
        self.email = response.user.email
        try Self.writeKeychain(token: response.token, email: response.user.email, expiresAt: response.expiresAt, server: server?.absoluteString ?? "")
        let records = try await pullAndMerge(local: local)
        status = "Viewing history is up to date."
        return records
    }

    func restore(local: [WatchRecord]) async -> [WatchRecord] {
        guard token != nil else { return local }
        do {
            let records = try await pullAndMerge(local: local)
            status = "Viewing history is up to date."
            lastError = nil
            return records
        } catch {
            lastError = error.localizedDescription
            status = "Sync is offline. Viewing history is still saved on this iPhone."
            return local
        }
    }

    func refresh(local: [WatchRecord]) async -> [WatchRecord] {
        await restore(local: local)
    }

    func schedule(records: [WatchRecord]) {
        guard token != nil else { return }
        pendingRecords = records
        guard debounceTask == nil else { return }
        generation += 1
        let current = generation
        debounceTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard current == generation else { return }
            let latest = pendingRecords ?? records
            pendingRecords = nil
            debounceTask = nil
            do {
                let response = try await push(latest)
                status = "Viewing history is up to date."
                lastError = nil
                _ = response
            } catch {
                lastError = error.localizedDescription
                status = "Sync is offline. Viewing history is still saved on this iPhone."
            }
        }
    }

    func syncNow(records: [WatchRecord]) async {
        guard token != nil else { return }
        generation += 1
        debounceTask?.cancel()
        debounceTask = nil
        pendingRecords = nil
        do {
            let response = try await push(records)
            status = "Viewing history is up to date."
            lastError = nil
            _ = response
        } catch {
            lastError = error.localizedDescription
            status = "Sync is offline. Viewing history is still saved on this iPhone."
        }
    }

    func clearRemoteHistory() {
        guard let token else { return }
        generation += 1
        debounceTask?.cancel()
        debounceTask = nil
        pendingRecords = nil
        Task { @MainActor in
            do {
                _ = try await request("/v1/history", method: "DELETE", bearer: token, as: SyncHistoryResponse.self)
                status = "Viewing history was cleared on your signed-in devices."
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                status = "Could not sync the cleared history yet. Connect to the internet and open Settings to retry."
            }
        }
    }

    func signOut() async {
        generation += 1
        debounceTask?.cancel()
        debounceTask = nil
        pendingRecords = nil
        if let token {
            do { _ = try await request("/v1/auth/logout", method: "POST", bearer: token, as: EmptyResponse.self) }
            catch { }
        }
        self.token = nil
        email = nil
        Self.deleteKeychain()
        status = "Viewing history remains saved on this iPhone."
        lastError = nil
    }

    private func pullAndMerge(local: [WatchRecord]) async throws -> [WatchRecord] {
        guard let token else { return local }
        let snapshot = try await request("/v1/history", method: "GET", bearer: token, as: SyncHistoryResponse.self)
        let merged = Self.merge(local: local, remote: snapshot.records, clearedAt: snapshot.clearedAt)
        let saved = try await push(merged)
        return Self.merge(local: merged, remote: saved.records, clearedAt: saved.clearedAt)
    }

    private func push(_ records: [WatchRecord]) async throws -> SyncHistoryResponse {
        guard let token else { throw URLError(.userAuthenticationRequired) }
        if records.isEmpty {
            return try await request("/v1/history", method: "GET", bearer: token, as: SyncHistoryResponse.self)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let body = try encoder.encode(["records": records])
        return try await request("/v1/history", method: "PUT", body: body, bearer: token, as: SyncHistoryResponse.self)
    }

    private func request<T: Decodable>(_ path: String, method: String, body: Data? = nil, bearer: String? = nil, as type: T.Type) async throws -> T {
        guard let server else { throw URLError(.badURL) }
        var request = URLRequest(url: server.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 18
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw NSError(domain: "WatchSync", code: -3, userInfo: [NSLocalizedDescriptionKey: "The sync server could not be reached."]) }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"]
            throw NSError(domain: "WatchSync", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message ?? "The sync server is temporarily unavailable."])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }

    private static func merge(local: [WatchRecord], remote: [WatchRecord], clearedAt: Double) -> [WatchRecord] {
        var latest: [String: WatchRecord] = [:]
        for record in remote + local where record.updatedAt.timeIntervalSince1970 * 1000 > clearedAt {
            let key = "\(record.item.id):\(record.seasonID ?? "movie"):\(record.episodeID ?? "movie")"
            if latest[key].map({ $0.updatedAt < record.updatedAt }) ?? true { latest[key] = record }
        }
        return Array(latest.values).sorted { $0.updatedAt > $1.updatedAt }.prefix(500).map { $0 }
    }

    private struct SavedCredentials: Codable {
        let token: String
        let email: String
        let expiresAt: Double
        /// Missing in sessions saved before the server became configurable, so those are not reused.
        let server: String?
    }

    private static func readKeychain() -> SavedCredentials? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SavedCredentials.self, from: data)
    }

    private static func writeKeychain(token: String, email: String, expiresAt: Double, server: String) throws {
        let data = try JSONEncoder().encode(SavedCredentials(token: token, email: email, expiresAt: expiresAt, server: server))
        deleteKeychain()
        var query = keychainQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw NSError(domain: "WatchSync", code: -1, userInfo: [NSLocalizedDescriptionKey: "Sign-in could not be saved securely."])
        }
    }

    private static func deleteKeychain() {
        SecItemDelete(keychainQuery as CFDictionary)
    }

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.personal.rezkaport.watch-sync", kSecAttrAccount as String: "session"]
    }
}

private struct EmptyResponse: Decodable {
    let ok: Bool?
}
