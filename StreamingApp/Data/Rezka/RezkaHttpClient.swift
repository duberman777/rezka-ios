import Foundation

struct RezkaHTTPResponse: Sendable {
    var data: Data
    var url: URL
    var statusCode: Int

    func text() throws -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1251) { return text }
        throw RezkaError.unsupportedEncoding
    }
}

protocol RezkaTransport: Sendable {
    func send(_ request: URLRequest) async throws -> RezkaHTTPResponse
}

struct RezkaURLSessionTransport: RezkaTransport {
    let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 18
        configuration.timeoutIntervalForResource = 35
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> RezkaHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, let url = response.url else { throw URLError(.badServerResponse) }
        return RezkaHTTPResponse(data: data, url: url, statusCode: response.statusCode)
    }
}

struct RezkaHttpClient: Sendable {
    typealias BrowserFetch = @MainActor @Sendable (URLRequest) async throws -> RezkaHTTPResponse
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    let transport: any RezkaTransport
    let browserFetch: BrowserFetch?

    init(transport: any RezkaTransport = RezkaURLSessionTransport(), browserFetch: BrowserFetch? = nil) {
        self.transport = transport
        self.browserFetch = browserFetch
    }

    func request(url: URL, referer: URL? = nil, form: [String: String]? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue(referer?.absoluteString ?? origin(url) + "/", forHTTPHeaderField: "Referer")
        if let form {
            request.httpMethod = "POST"
            request.httpBody = RezkaEndpoints.formData(form)
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            request.setValue(origin(url), forHTTPHeaderField: "Origin")
        }
        return request
    }

    func fetch(_ request: URLRequest, allowBrowser: Bool = true) async throws -> RezkaHTTPResponse {
        try Task.checkCancellation()
        guard let url = request.url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw RezkaError.invalidURL
        }
        let response: RezkaHTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            try Task.checkCancellation()
            // TLS and connectivity failures belong to mirror failover, not browser verification.
            throw error
        }
        if RezkaProtection.isChallenge((try? response.text()) ?? "") {
            guard allowBrowser, let browserFetch else { throw RezkaError.challengeRequired }
            let browserResponse = try await browserFetch(request)
            return try validated(browserResponse)
        }
        return try validated(response)
    }

    func html(url: URL, referer: URL? = nil) async throws -> (String, URL) {
        let response = try await fetch(request(url: url, referer: referer))
        return (try response.text(), response.url)
    }

    private func validated(_ response: RezkaHTTPResponse) throws -> RezkaHTTPResponse {
        guard !RezkaProtection.isChallenge((try? response.text()) ?? "") else { throw RezkaError.challengeRequired }
        guard (200..<300).contains(response.statusCode) else { throw RezkaError.httpStatus(response.statusCode) }
        return response
    }

    private func origin(_ url: URL) -> String {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        return components.string ?? ""
    }
}
