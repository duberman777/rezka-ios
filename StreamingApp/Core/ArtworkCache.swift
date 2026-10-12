import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UIKit

private enum ArtworkError: Error {
    case invalidImage
}

/// Original image bytes survive app launches. Hash keys keep URLs out of filenames.
private actor ArtworkDiskCache {
    static let shared = ArtworkDiskCache()
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RezkaArtwork", isDirectory: true)
    private var pending: [URL: Task<Data, Error>] = [:]
    private var lastTrim = Date.distantPast
    private let limit = 256 * 1_024 * 1_024

    func data(for url: URL) async throws -> Data {
        if url.isFileURL {
            let data = try Data(contentsOf: url)
            guard isImage(data) else { throw ArtworkError.invalidImage }
            return data
        }
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(key)
        if let data = try? Data(contentsOf: file), isImage(data) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            trimIfNeeded()
            return data
        }
        if let task = pending[url] { return try await task.value }
        let task = Task<Data, Error> {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  data.count < 20 * 1_024 * 1_024, isImage(data) else { throw ArtworkError.invalidImage }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return data
        }
        pending[url] = task
        defer { pending[url] = nil }
        let data = try await task.value
        trimIfNeeded(force: true)
        return data
    }

    private func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    private func trimIfNeeded(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastTrim) > 60 else { return }
        lastTrim = Date()
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles) else { return }
        let entries = files.compactMap { file -> (URL, Date, Int)? in
            guard let values = try? file.resourceValues(forKeys: keys) else { return nil }
            return (file, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 < $1.1 }
        var bytes = entries.reduce(0) { $0 + $1.2 }
        let expiry = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        for (file, date, size) in entries where date < expiry || bytes > limit {
            if (try? FileManager.default.removeItem(at: file)) != nil { bytes -= size }
        }
    }
}

@MainActor
private final class ArtworkMemoryCache {
    static let shared = ArtworkMemoryCache()
    private let images = NSCache<NSURL, UIImage>()

    private init() {
        images.totalCostLimit = 64 * 1_024 * 1_024
        images.countLimit = 160
    }

    func image(for url: URL) async throws -> UIImage {
        if let image = images.object(forKey: url as NSURL) { return image }
        let data = try await ArtworkDiskCache.shared.data(for: url)
        try Task.checkCancellation()
        guard let decoded = UIImage(data: data) else { throw ArtworkError.invalidImage }
        let image = await decoded.byPreparingForDisplay() ?? decoded
        try Task.checkCancellation()
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
        images.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }
}

struct CachedArtwork<Content: View>: View {
    let url: URL?
    let transaction: Transaction
    let keepsPreviousImageWhileLoading: Bool
    let content: (AsyncImagePhase) -> Content
    @State private var phase = AsyncImagePhase.empty
    @State private var loadedURL: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(url: URL?, transaction: Transaction = Transaction(), keepsPreviousImageWhileLoading: Bool = false,
         @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.transaction = transaction
        self.keepsPreviousImageWhileLoading = keepsPreviousImageWhileLoading
        self.content = content
    }

    var body: some View {
        ZStack {
            Color.clear
            content(phase)
        }
            .task(id: url) {
                if loadedURL != url, !keepsPreviousImageWhileLoading { phase = .empty }
                guard let url else { phase = .empty; return }
                do {
                    let image = try await ArtworkMemoryCache.shared.image(for: url)
                    try Task.checkCancellation()
                    withTransaction(reduceMotion ? Transaction() : transaction) {
                        phase = .success(Image(uiImage: image))
                        loadedURL = url
                    }
                } catch is CancellationError { }
                catch { if !keepsPreviousImageWhileLoading || phase.image == nil { phase = .failure(error) } }
            }
    }
}
