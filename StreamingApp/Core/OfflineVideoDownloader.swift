import AVFoundation
import Foundation

struct OfflineVideoDownloader {
    var session: URLSession = .shared
    @MainActor
    func download(url: URL, headers: [String: String], title: String,
                  progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> URL {
        if url.pathExtension.lowercased() == "m3u8" {
            return try await HLSVideoDownload().download(url: url, headers: headers, title: title, progress: progress)
        }
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let delegate = VideoDownloadProgress(progress: progress)
        let (temporary, response) = try await session.download(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !(http.mimeType ?? "").contains("text"), (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
            throw URLError(.badServerResponse)
        }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("OfflineMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        try FileManager.default.moveItem(at: temporary, to: destination)
        var file = destination
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? file.setResourceValues(values)
        progress(1)
        return destination
    }
}

private final class VideoDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @MainActor @Sendable (Double) -> Void
    init(progress: @escaping @MainActor @Sendable (Double) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1)
        Task { @MainActor in progress(fraction) }
    }
}

@MainActor
private final class HLSVideoDownload: NSObject, @preconcurrency AVAssetDownloadDelegate {
    private var session: AVAssetDownloadURLSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var location: URL?
    private var progress: (@MainActor @Sendable (Double) -> Void)?

    func download(url: URL, headers: [String: String], title: String,
                  progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> URL {
        self.progress = progress
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.personal.rezkaport.hls.\(UUID().uuidString)")
        let session = AVAssetDownloadURLSession(configuration: configuration, assetDownloadDelegate: self, delegateQueue: .main)
        self.session = session
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let downloadConfiguration = AVAssetDownloadConfiguration(asset: asset, title: title)
        let task = session.makeAssetDownloadTask(downloadConfiguration: downloadConfiguration)
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        self.location = location
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        let expected = timeRangeExpectedToLoad.duration.seconds
        guard expected.isFinite, expected > 0 else { return }
        let loaded = loadedTimeRanges.reduce(0) { $0 + $1.timeRangeValue.duration.seconds }
        progress?(min(loaded / expected, 1))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { continuation = nil; self.session?.finishTasksAndInvalidate(); self.session = nil }
        if let error { continuation?.resume(throwing: error) }
        else if let location { progress?(1); continuation?.resume(returning: location) }
        else { continuation?.resume(throwing: URLError(.cannotCreateFile)) }
    }
}
