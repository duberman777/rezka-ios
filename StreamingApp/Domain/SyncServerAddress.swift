import Foundation

/// The address of the sync server the user hosts. Sync stays off until one is set in Settings.
enum SyncServerAddress {
    /// Returns the server's base address, or nil when the text is empty and sync is off.
    static func normalized(_ text: String) throws -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let invalid = NSError(domain: "WatchSync", code: -2, userInfo: [NSLocalizedDescriptionKey: "Enter your sync server address, for example https://sync.example.com."])
        guard var components = URLComponents(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"),
              let host = components.host, !host.isEmpty else { throw invalid }
        guard components.scheme?.lowercased() == "https" else {
            throw NSError(domain: "WatchSync", code: -2, userInfo: [NSLocalizedDescriptionKey: "The sync server address must start with https://."])
        }
        guard components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            throw NSError(domain: "WatchSync", code: -2, userInfo: [NSLocalizedDescriptionKey: "Enter only the sync server address, without a query or sign-in details."])
        }
        components.scheme = "https"
        components.host = host.lowercased()
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw invalid }
        return url
    }
}
