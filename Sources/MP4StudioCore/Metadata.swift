import Foundation

public enum MediaKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case movie, tvShow, musicVideo, homeVideo, normal
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .movie: return "Movie"
        case .tvShow: return "TV Show"
        case .musicVideo: return "Music Video"
        case .homeVideo: return "Home Video"
        case .normal: return "Normal"
        }
    }

    /// The value AtomicParsley's --stik option takes.
    var stikArgument: String { self == .homeVideo ? "value=0" : label }

    init?(atomicParsleyValue: String) {
        guard let match = MediaKind.allCases.first(where: { $0.label == atomicParsleyValue }) else { return nil }
        self = match
    }
}

public struct ContentRating: Hashable, Sendable, Identifiable {
    public let system: String   // "mpaa" or "us-tv"
    public let label: String
    public let code: Int
    public var id: String { "\(system)|\(label)" }

    /// Value of the iTunEXTC atom, e.g. "mpaa|PG-13|300|".
    public var atomValue: String { "\(system)|\(label)|\(code)|" }

    public static let all: [ContentRating] = [
        ("mpaa", "G", 100), ("mpaa", "PG", 200), ("mpaa", "PG-13", 300), ("mpaa", "R", 400), ("mpaa", "NC-17", 500),
        ("mpaa", "Unrated", 600),
        ("us-tv", "TV-Y", 100), ("us-tv", "TV-Y7", 200), ("us-tv", "TV-G", 300), ("us-tv", "TV-PG", 400),
        ("us-tv", "TV-14", 500), ("us-tv", "TV-MA", 600),
    ].map { ContentRating(system: $0.0, label: $0.1, code: $0.2) }

    public static func parse(_ value: String) -> ContentRating? {
        let parts = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        return all.first { $0.system == parts[0] && $0.label == parts[1] }
            ?? ContentRating(system: parts[0], label: parts[1], code: parts.count > 2 ? Int(parts[2]) ?? 0 : 0)
    }
}

/// iTunes-style tags, written to MP4/M4V files with AtomicParsley.
public struct MetadataFields: Codable, Equatable, Sendable {
    public var kind: MediaKind = .movie
    public var title = ""
    public var year = ""
    public var genre = ""
    public var shortDescription = ""
    public var longDescription = ""
    public var tvShow = ""
    public var tvSeason = ""
    public var tvEpisodeNumber = ""
    public var tvEpisodeID = ""
    public var tvNetwork = ""
    public var ratingID = ""          // ContentRating.id, empty for none
    public var cast = ""              // comma-separated
    public var directors = ""
    public var screenwriters = ""
    public var producers = ""
    /// Path to new artwork. Nil keeps whatever artwork the file already has.
    public var artworkPath: String?
    public var removeArtwork = false

    public init() {}

    public var isEmpty: Bool {
        var blank = MetadataFields()
        blank.kind = kind
        return self == blank
    }

    public var rating: ContentRating? { ContentRating.all.first { $0.id == ratingID } }

    /// Arguments that set every field, clearing blanks, so the file matches the form exactly.
    public func atomicParsleyArguments() -> [String] {
        var args = [
            "--stik", kind.stikArgument,
            "--title", title,
            "--year", year,
            "--genre", genre,
            "--description", String(shortDescription.prefix(255)),
            "--longdesc", longDescription,
            "--TVShowName", tvShow,
            "--TVSeasonNum", digits(tvSeason),
            "--TVEpisodeNum", digits(tvEpisodeNumber),
            "--TVEpisode", tvEpisodeID,
            "--TVNetwork", tvNetwork,
            "--rDNSatom", rating?.atomValue ?? "", "name=iTunEXTC", "domain=com.apple.iTunes",
            "--rDNSatom", creditsPlist() ?? "", "name=iTunMOVI", "domain=com.apple.iTunes",
        ]
        if removeArtwork || artworkPath != nil { args += ["--artwork", "REMOVE_ALL"] }
        if let artworkPath, !removeArtwork { args += ["--artwork", artworkPath] }
        return args
    }

    private func digits(_ s: String) -> String { s.filter(\.isNumber) }

    static func names(_ list: String) -> [String] {
        list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The iTunMOVI plist that holds cast and crew.
    func creditsPlist() -> String? {
        var dict: [String: Any] = [:]
        for (key, value) in [("cast", cast), ("directors", directors), ("screenwriters", screenwriters), ("producers", producers)] {
            let people = Self.names(value)
            if !people.isEmpty { dict[key] = people.map { ["name": $0] } }
        }
        guard !dict.isEmpty,
              let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Reading

    /// Parses the output of `AtomicParsley file -t`.
    public static func parse(atomicParsleyOutput text: String) -> (fields: MetadataFields, hasArtwork: Bool) {
        var atoms: [(name: String, value: String)] = []
        for rawLine in text.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: "\n") {
            if rawLine.hasPrefix("Atom \""), let range = rawLine.range(of: " contains: ") {
                let header = rawLine[rawLine.startIndex..<range.lowerBound]
                var name = String(header.dropFirst(6).prefix { $0 != "\"" })
                if name == "----", let open = header.firstIndex(of: "["), let close = header.firstIndex(of: "]") {
                    name = String(header[header.index(after: open)..<close]).components(separatedBy: ";").last ?? name
                }
                atoms.append((name, String(rawLine[range.upperBound...])))
            } else if !atoms.isEmpty, !rawLine.isEmpty {
                atoms[atoms.count - 1].value += "\n" + rawLine   // multi-line plist values
            }
        }
        var f = MetadataFields()
        var hasArtwork = false
        for (name, value) in atoms {
            switch name {
            case "©nam": f.title = value
            case "©day": f.year = String(value.prefix(4))
            case "©gen", "gnre": f.genre = value
            case "desc": f.shortDescription = value
            case "ldes": f.longDescription = value
            case "stik": f.kind = MediaKind(atomicParsleyValue: value) ?? f.kind
            case "tvsh": f.tvShow = value
            case "tvsn": f.tvSeason = value
            case "tves": f.tvEpisodeNumber = value
            case "tven": f.tvEpisodeID = value
            case "tvnn": f.tvNetwork = value
            case "iTunEXTC": f.ratingID = ContentRating.parse(value)?.id ?? ""
            case "iTunMOVI": f.applyCredits(plist: value)
            case "covr": hasArtwork = !value.hasPrefix("0 ")
            default: break
            }
        }
        return (f, hasArtwork)
    }

    mutating func applyCredits(plist: String) {
        guard let data = plist.data(using: .utf8),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        func joined(_ key: String) -> String {
            ((dict[key] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
        }
        cast = joined("cast")
        directors = joined("directors")
        screenwriters = joined("screenwriters")
        producers = joined("producers")
    }

    /// Best-effort fill from ffprobe container tags, for files AtomicParsley can't read.
    public static func fromContainerTags(_ tags: [String: String]) -> MetadataFields {
        var f = MetadataFields()
        f.title = tags["title"] ?? ""
        f.year = String((tags["date"] ?? tags["year"] ?? "").prefix(4))
        f.genre = tags["genre"] ?? ""
        f.shortDescription = tags["description"] ?? tags["comment"] ?? ""
        f.longDescription = tags["synopsis"] ?? ""
        f.tvShow = tags["show"] ?? ""
        f.tvSeason = tags["season_number"] ?? ""
        f.tvEpisodeNumber = tags["episode_sort"] ?? ""
        f.tvEpisodeID = tags["episode_id"] ?? ""
        f.tvNetwork = tags["network"] ?? ""
        if !f.tvShow.isEmpty { f.kind = .tvShow }
        return f
    }
}
