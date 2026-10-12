import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class RezkaBrowserSession: NSObject, WKNavigationDelegate {
    var isPresented = false
    var status = "Complete the website verification, then continue."
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var pending: URLRequest?
    @ObservationIgnored private var continuation: CheckedContinuation<RezkaHTTPResponse, Error>?
    @ObservationIgnored private var pendingID: UUID?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var isFetching = false
    @ObservationIgnored private var navigationStatus = 200

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.customUserAgent = RezkaHttpClient.userAgent
        webView.navigationDelegate = self
    }

    func fetch(_ request: URLRequest) async throws -> RezkaHTTPResponse {
        // A single visible browser owns verification and its cookies.
        while pendingID != nil { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                pending = request
                pendingID = id
                isPresented = true
                status = "Complete the website verification, then continue."
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(180)) } catch { return }
                    self?.finish(.failure(RezkaError.challengeRequired), id: id)
                }
                Task { [weak self] in
                    guard let self else { return }
                    let store = webView.configuration.websiteDataStore.httpCookieStore
                    for cookie in HTTPCookieStorage.shared.cookies ?? [] { await store.setCookie(cookie) }
                    guard pendingID == id else { return }
                    let referer = request.value(forHTTPHeaderField: "Referer").flatMap(URL.init(string:))
                    guard let url = request.httpMethod == "POST" ? (referer ?? request.url) : request.url else {
                        finish(.failure(RezkaError.invalidURL), id: id)
                        return
                    }
                    webView.load(URLRequest(url: url))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError()), id: id) }
        }
    }

    func cancel() {
        if let pendingID { finish(.failure(RezkaError.browserCancelled), id: pendingID) }
    }

    func continueRequest() {
        guard let request = pending, let id = pendingID, !isFetching else { return }
        isFetching = true
        Task { [weak self] in
            guard let self else { return }
            defer { isFetching = false }
            do {
                guard let html = try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String else {
                    throw RezkaError.unsupportedEncoding
                }
                guard !RezkaProtection.isChallenge(html) else {
                    status = "The website is still verifying this session. Complete the page and continue."
                    return
                }
                let response: RezkaHTTPResponse
                if request.httpMethod != "POST", let url = webView.url {
                    response = RezkaHTTPResponse(data: Data(html.utf8), url: url, statusCode: navigationStatus)
                } else {
                    // Values are passed as arguments rather than interpolated into JavaScript.
                    let script = """
                    if (new URL(target).origin !== window.location.origin) {
                        throw new Error('The verification page changed its website address.');
                    }
                    const response = await fetch(target, {
                        method: method, body: body, credentials: 'include',
                        headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
                                  'X-Requested-With': 'XMLHttpRequest'}
                    });
                    return JSON.stringify({text: await response.text(), status: response.status, url: response.url});
                    """
                    let value = try await webView.callAsyncJavaScript(script,
                        arguments: ["target": request.url!.absoluteString, "method": request.httpMethod ?? "GET",
                                    "body": request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""],
                        in: nil, contentWorld: .page)
                    guard let string = value as? String, let data = string.data(using: .utf8) else { throw RezkaError.unsupportedEncoding }
                    let result = try JSONDecoder().decode(BrowserResult.self, from: data)
                    response = RezkaHTTPResponse(data: Data(result.text.utf8), url: result.url, statusCode: result.status)
                }
                guard !RezkaProtection.isChallenge(try response.text()) else {
                    status = "The website needs another verification. Reload the page and continue."
                    return
                }
                for cookie in await webView.configuration.websiteDataStore.httpCookieStore.allCookies() {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
                finish(.success(response), id: id)
            } catch {
                finish(.failure(error), id: id)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continueRequest()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse {
            navigationStatus = response.statusCode
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        if let pendingID { finish(.failure(error), id: pendingID) }
    }

    private func finish(_ result: Result<RezkaHTTPResponse, Error>, id: UUID) {
        guard pendingID == id else { return }
        let callback = continuation
        continuation = nil
        pending = nil
        pendingID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        webView.stopLoading()
        isPresented = false
        callback?.resume(with: result)
    }

    private struct BrowserResult: Decodable {
        let text: String
        let status: Int
        let url: URL
    }
}
