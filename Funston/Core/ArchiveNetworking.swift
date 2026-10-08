import Foundation

enum ArchiveURLs {
    private static func url(path: [String], query: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "https"; components.host = "archive.org"
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%?#")
        components.percentEncodedPath = "/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        // Scheme, host, and percent-encoded path are constructed exclusively here.
        return components.url!
    }

    static func item(identifier: String) -> URL { url(path: ["details", identifier]) }
    static func thumbnail(identifier: String) -> URL { url(path: ["services", "img", identifier]) }
    static func metadata(identifier: String) -> URL { url(path: ["metadata", identifier]) }
    static func download(identifier: String, fileName: String) -> URL {
        url(path: ["download", identifier] + fileName.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
    }

    static func search(_ request: SearchRequest) -> URL {
        // Phrase quoting disables field operators, wildcards and boolean syntax in plain search.
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var clauses: [String] = []
        if !request.text.isEmpty { clauses.append(quoted(request.text)) }
        if request.scope == .audio { clauses.append("mediatype:(audio OR etree)") }
        else if request.scope != .all && request.scope != .unknown { clauses.append("mediatype:" + quoted(request.scope.rawValue)) }
        if let collection = request.collection, !collection.isEmpty { clauses.append("collection:" + quoted(collection)) }
        let query = clauses.isEmpty ? "mediatype:(audio OR movies OR texts OR image OR software OR collection)" : clauses.joined(separator: " AND ")
        var parameters = [URLQueryItem(name: "q", value: "(" + query + ") AND -collection:access-restricted-item AND -access-restricted-item:true"), URLQueryItem(name: "output", value: "json"),
                          URLQueryItem(name: "page", value: String(request.page)), URLQueryItem(name: "rows", value: String(request.pageSize))]
        parameters += ["identifier", "title", "creator", "author", "date", "year", "mediatype", "collection", "access-restricted-item"].map { URLQueryItem(name: "fl[]", value: $0) }
        if request.text.isEmpty {
            parameters.append(URLQueryItem(name: "sort[]", value: "downloads desc"))
            parameters.append(URLQueryItem(name: "sort[]", value: "identifier asc"))
        }
        return url(path: ["advancedsearch.php"], query: parameters)
    }
}

struct ArchiveHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let headers: [String: String]
    init(data: Data, statusCode: Int = 200, headers: [String: String] = [:]) {
        self.data = data; self.statusCode = statusCode; self.headers = headers
    }
}

protocol ArchiveTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ArchiveHTTPResponse
}

struct URLSessionArchiveTransport: ArchiveTransport {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    func send(_ request: URLRequest) async throws -> ArchiveHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ArchiveError.invalidResponse }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let key = entry.key as? String { result[key.lowercased()] = String(describing: entry.value) }
        }
        return ArchiveHTTPResponse(data: data, statusCode: response.statusCode, headers: headers)
    }
}

protocol ArchiveRepository: Sendable {
    func search(_ request: SearchRequest) async throws -> SearchPage
    func detail(identifier: String) async throws -> ArtifactDetail
}

actor NetworkArchiveRepository: ArchiveRepository {
    private let transport: any ArchiveTransport
    private let normalizer: ArchiveNormalizer
    init(transport: any ArchiveTransport = URLSessionArchiveTransport(), normalizer: ArchiveNormalizer = ArchiveNormalizer()) {
        self.transport = transport; self.normalizer = normalizer
    }

    func search(_ request: SearchRequest) async throws -> SearchPage {
        let data = try await fetch(ArchiveURLs.search(request))
        let page = try await normalizer.search(data: data, request: request)
        try Task.checkCancellation()
        return page
    }

    func detail(identifier: String) async throws -> ArtifactDetail {
        let data = try await fetch(ArchiveURLs.metadata(identifier: identifier))
        let detail = try await normalizer.detail(data: data, identifier: identifier)
        try Task.checkCancellation()
        return detail
    }

    private func fetch(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await transport.send(request)
        try Task.checkCancellation()
        guard (200...299).contains(response.statusCode) else {
            throw ArchiveError.http(status: response.statusCode, retryAfter: response.headers.first { $0.key.lowercased() == "retry-after" }?.value)
        }
        return response.data
    }
}
