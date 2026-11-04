import Foundation

/// Searches The Movie Database (themoviedb.org) for movies and TV shows and their posters.
public struct TMDBClient: Sendable {
    public enum MediaType: String, Sendable, CaseIterable, Identifiable {
        case movie, tv
        public var id: String { rawValue }
        public var label: String { self == .movie ? "Movie" : "TV Show" }
    }

    public struct SearchResult: Identifiable, Hashable, Sendable {
        public let id: Int
        public let type: MediaType
        public let title: String
        public let year: String?
        public let overview: String
        public let posterPath: String?
    }

    public struct Poster: Identifiable, Hashable, Sendable {
        public var id: String { filePath }
        public let filePath: String
        public let width: Int
        public let height: Int
        public let language: String?
        public let votes: Double
        /// "Season 2" for season posters, nil for the show or movie.
        public var group: String?
    }

    /// A v4 read access token (Bearer) or a v3 API key.
    public let credential: String
    public let language: String

    public init(credential: String, language: String = "en") {
        self.credential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language
    }

    public static func imageURL(_ path: String, size: String = "w342") -> URL {
        URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")!
    }

    public func search(_ query: String, type: MediaType, year: String? = nil) async throws -> [SearchResult] {
        var items = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "include_adult", value: "false")]
        if let year, !year.isEmpty {
            items.append(URLQueryItem(name: type == .movie ? "year" : "first_air_date_year", value: year))
        }
        return try Self.parseSearch(try await get("search/\(type.rawValue)", items), type: type)
    }

    /// Posters for a movie or show. For a show with a season, the season's posters come first.
    public func posters(for result: SearchResult, season: Int? = nil) async throws -> [Poster] {
        let languages = [URLQueryItem(name: "include_image_language", value: "\(language),null")]
        var posters: [Poster] = []
        if result.type == .tv, let season {
            // Not every show has season posters; fall back to the show's own.
            if let data = try? await get("tv/\(result.id)/season/\(season)/images", languages) {
                posters += try Self.parsePosters(data, preferring: language).map { var p = $0; p.group = "Season \(season)"; return p }
            }
        }
        posters += try Self.parsePosters(try await get("\(result.type.rawValue)/\(result.id)/images", languages), preferring: language)
        return posters
    }

    /// Saves the full-size poster into `folder` and returns its path.
    public func download(_ poster: Poster, to folder: URL) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: Self.imageURL(poster.filePath, size: "original"))
        try Self.check(response, data)
        let ext = (poster.filePath as NSString).pathExtension.lowercased()
        let url = folder.appendingPathComponent("tmdb-\(UUID().uuidString).\(ext.isEmpty ? "jpg" : ext)")
        try data.write(to: url)
        return url
    }

    func get(_ path: String, _ items: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)")!
        var query = items + [URLQueryItem(name: "language", value: language)]
        // v4 read access tokens are JWTs; anything else is treated as a v3 API key.
        let isToken = credential.hasPrefix("eyJ")
        if !isToken { query.append(URLQueryItem(name: "api_key", value: credential)) }
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if isToken { request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return data
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        if http.statusCode == 401 { throw ToolError.invalid("TMDB rejected the API key. Check it in Settings ▸ General.") }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.status_message ?? "HTTP \(http.statusCode)"
        throw ToolError.invalid("TMDB request failed: \(message)")
    }

    private struct ErrorBody: Decodable { let status_message: String? }

    static func parseSearch(_ data: Data, type: MediaType) throws -> [SearchResult] {
        struct Body: Decodable {
            struct Item: Decodable {
                let id: Int
                let title: String?
                let name: String?
                let release_date: String?
                let first_air_date: String?
                let overview: String?
                let poster_path: String?
            }
            let results: [Item]
        }
        return try JSONDecoder().decode(Body.self, from: data).results.map { item in
            let date = item.release_date ?? item.first_air_date ?? ""
            return SearchResult(id: item.id, type: type, title: item.title ?? item.name ?? "Untitled",
                                year: date.count >= 4 ? String(date.prefix(4)) : nil,
                                overview: item.overview ?? "", posterPath: item.poster_path)
        }
    }

    /// Posters in the preferred language first, then ones without text, each by vote average.
    static func parsePosters(_ data: Data, preferring language: String) throws -> [Poster] {
        struct Body: Decodable {
            struct Item: Decodable {
                let file_path: String
                let width: Int
                let height: Int
                let iso_639_1: String?
                let vote_average: Double?
            }
            let posters: [Item]?
        }
        let posters = (try JSONDecoder().decode(Body.self, from: data).posters ?? []).map {
            Poster(filePath: $0.file_path, width: $0.width, height: $0.height, language: $0.iso_639_1, votes: $0.vote_average ?? 0)
        }
        func rank(_ p: Poster) -> Int { p.language == language ? 0 : p.language == nil ? 1 : 2 }
        return posters.sorted { (rank($0), -$0.votes) < (rank($1), -$1.votes) }
    }
}
