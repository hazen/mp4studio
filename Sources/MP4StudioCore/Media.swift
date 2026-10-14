import Foundation

public enum TrackKind: String, Codable, Sendable, CaseIterable {
    case video, audio, subtitle, attachment, data

    public var label: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        case .subtitle: return "Subtitle"
        case .attachment: return "Attachment"
        case .data: return "Data"
        }
    }

    public var symbol: String {
        switch self {
        case .video: return "film"
        case .audio: return "speaker.wave.2"
        case .subtitle: return "captions.bubble"
        case .attachment: return "paperclip"
        case .data: return "doc"
        }
    }
}

public enum ContainerKind: Sendable, Equatable {
    case mp4, mkv, other

    public static func of(_ url: URL) -> ContainerKind {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": return .mp4
        case "mkv", "mka", "mks": return .mkv
        default: return .other
        }
    }
}

public struct MediaTrack: Identifiable, Hashable, Sendable {
    /// Unique within a job: "<input index>:<stream index>", which is also ffmpeg's -map syntax.
    public var id: String { "\(inputIndex):\(streamIndex)" }

    public var inputIndex: Int
    public let streamIndex: Int
    /// The container's own track ID (MP4 track_ID). Nil for MKV, where mkvmerge IDs equal stream indexes.
    public let containerTrackID: Int?
    public let kind: TrackKind
    public let codec: String
    public let profile: String?
    public var language: String
    public var title: String
    public let channels: Int?
    public let channelLayout: String?
    public let sampleRate: Int?
    public let width: Int?
    public let height: Int?
    public let pixelFormat: String?
    public let sampleAspectRatio: String?
    public let frameRate: Double?
    public let bitRate: Int?
    public var isDefault: Bool
    public var isForced: Bool
    public let isAttachedPicture: Bool
    public let sourceURL: URL

    public static let bitmapSubtitleCodecs: Set<String> = ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub", "dvb_teletext"]
    public static let textSubtitleCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text", "microdvd", "subviewer", "ttml"]

    public var isBitmapSubtitle: Bool { kind == .subtitle && Self.bitmapSubtitleCodecs.contains(codec) }
    public var isTextSubtitle: Bool { kind == .subtitle && Self.textSubtitleCodecs.contains(codec) }
    public var isSurround: Bool { (channels ?? 2) > 2 }
    public var isTenBit: Bool { pixelFormat.map { $0.contains("10") || $0.contains("12") } ?? false }

    /// True when the pixels aren't square (anamorphic video).
    public var isAnamorphic: Bool {
        guard let sar = sampleAspectRatio, sar != "0:1" else { return false }
        return sar != "1:1"
    }

    public var codecLabel: String {
        switch codec {
        case "h264": return "H.264"
        case "hevc": return "HEVC"
        case "av1": return "AV1"
        case "mpeg2video": return "MPEG-2"
        case "mpeg4": return "MPEG-4"
        case "aac": return "AAC"
        case "ac3": return "AC3"
        case "eac3": return "E-AC3"
        case "dts": return profile.map { "DTS (\($0))" } ?? "DTS"
        case "truehd": return "TrueHD"
        case "subrip": return "SRT"
        case "hdmv_pgs_subtitle": return "PGS"
        case "dvd_subtitle": return "VobSub"
        case "mov_text": return "Text (tx3g)"
        case "ass", "ssa": return codec.uppercased()
        case "webvtt": return "WebVTT"
        default: return codec
        }
    }

    public var details: String {
        switch kind {
        case .video:
            var parts: [String] = []
            if let w = width, let h = height { parts.append("\(w)×\(h)") }
            if let fps = frameRate, fps > 0 { parts.append(String(format: fps.rounded() == fps ? "%.0f fps" : "%.3f fps", fps)) }
            if isAnamorphic, let sar = sampleAspectRatio { parts.append("PAR \(sar)") }
            if isTenBit { parts.append("10-bit") }
            if isAttachedPicture { parts.append("cover art") }
            if let br = bitRate { parts.append("\(br / 1000) kbps") }
            return parts.joined(separator: " · ")
        case .audio:
            var parts: [String] = []
            if let layout = channelLayout, !layout.isEmpty { parts.append(layout) } else if let ch = channels { parts.append("\(ch) ch") }
            if let sr = sampleRate { parts.append("\(sr / 1000) kHz") }
            if let br = bitRate { parts.append("\(br / 1000) kbps") }
            return parts.joined(separator: " · ")
        case .subtitle:
            return isBitmapSubtitle ? "image-based" : "text"
        case .attachment, .data:
            return title
        }
    }
}

public struct Chapter: Hashable, Sendable {
    public let start: Double
    public let end: Double
    public let title: String
}

public struct MediaFile: Identifiable, Sendable {
    public let id = UUID()
    public let url: URL
    public let formatName: String
    public let duration: Double
    public let bitRate: Int?
    public let size: Int64?
    public var tracks: [MediaTrack]
    public let chapters: [Chapter]
    public let tags: [String: String]

    public var name: String { url.lastPathComponent }
    public var container: ContainerKind { ContainerKind.of(url) }

    public func tracks(_ kind: TrackKind) -> [MediaTrack] {
        tracks.filter { $0.kind == kind && !($0.kind == .video && $0.isAttachedPicture) }
    }

    /// The input index is the position of this file in an ffmpeg command (0 = main file).
    public func reindexed(as inputIndex: Int) -> MediaFile {
        var copy = self
        for i in copy.tracks.indices { copy.tracks[i].inputIndex = inputIndex }
        return copy
    }
}

// MARK: - ffprobe

public struct Prober: Sendable {
    public let ffprobe: URL

    public init(ffprobe: URL) {
        self.ffprobe = ffprobe
    }

    public func probe(_ url: URL, inputIndex: Int = 0) async throws -> MediaFile {
        let result = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-print_format", "json",
            "-show_format", "-show_streams", "-show_chapters", url.path,
        ])
        guard result.status == 0 else {
            throw ToolError.failed(tool: "ffprobe", status: result.status, message: result.stderrString)
        }
        return try MediaFile.parse(ffprobeJSON: result.stdout, url: url, inputIndex: inputIndex)
    }
}

struct FFProbeOutput: Decodable {
    struct Stream: Decodable {
        let index: Int
        let codec_name: String?
        let codec_type: String?
        let profile: String?
        let width: Int?
        let height: Int?
        let pix_fmt: String?
        let sample_aspect_ratio: String?
        let avg_frame_rate: String?
        let r_frame_rate: String?
        let channels: Int?
        let channel_layout: String?
        let sample_rate: String?
        let bit_rate: String?
        let id: String?
        let disposition: [String: Int]?
        let tags: [String: String]?
    }
    struct Format: Decodable {
        let format_name: String?
        let duration: String?
        let bit_rate: String?
        let size: String?
        let tags: [String: String]?
    }
    struct Chapter: Decodable {
        let start_time: String?
        let end_time: String?
        let tags: [String: String]?
    }
    let streams: [Stream]?
    let format: Format?
    let chapters: [Chapter]?
}

extension MediaFile {
    public static func parse(ffprobeJSON data: Data, url: URL, inputIndex: Int = 0) throws -> MediaFile {
        let probe: FFProbeOutput
        do {
            probe = try JSONDecoder().decode(FFProbeOutput.self, from: data)
        } catch {
            throw ToolError.invalid("Couldn't read the track info for \(url.lastPathComponent).")
        }
        guard let streams = probe.streams, !streams.isEmpty else {
            throw ToolError.invalid("\(url.lastPathComponent) doesn't contain any tracks MP4Studio can read.")
        }
        let guessed = Languages.guess(fromFileName: url)
        let isSidecar = streams.count == 1

        let tracks: [MediaTrack] = streams.map { s in
            let tags = lowercasedKeys(s.tags)
            let disposition = s.disposition ?? [:]
            let kind = TrackKind(rawValue: s.codec_type ?? "") ?? .data
            var language = Languages.normalize(tags["language"])
            if language == "und", isSidecar, let g = guessed.language { language = g }
            let title = tags["title"] ?? tags["handler_name"].flatMap(cleanHandlerName) ?? (kind == .attachment ? tags["filename"] ?? "" : "")
            return MediaTrack(
                inputIndex: inputIndex,
                streamIndex: s.index,
                containerTrackID: s.id.flatMap(parseTrackID),
                kind: kind,
                codec: s.codec_name ?? "unknown",
                profile: s.profile,
                language: language,
                title: title,
                channels: s.channels,
                channelLayout: s.channel_layout,
                sampleRate: s.sample_rate.flatMap { Int($0) },
                width: s.width,
                height: s.height,
                pixelFormat: s.pix_fmt,
                sampleAspectRatio: s.sample_aspect_ratio,
                frameRate: parseRate(s.avg_frame_rate) ?? parseRate(s.r_frame_rate),
                bitRate: s.bit_rate.flatMap { Int($0) },
                isDefault: disposition["default"] == 1,
                isForced: disposition["forced"] == 1 || (isSidecar && guessed.forced),
                isAttachedPicture: disposition["attached_pic"] == 1,
                sourceURL: url
            )
        }

        let chapters = (probe.chapters ?? []).map {
            Chapter(start: Double($0.start_time ?? "") ?? 0, end: Double($0.end_time ?? "") ?? 0,
                    title: lowercasedKeys($0.tags)["title"] ?? "")
        }
        return MediaFile(
            url: url,
            formatName: probe.format?.format_name ?? "",
            duration: Double(probe.format?.duration ?? "") ?? 0,
            bitRate: probe.format?.bit_rate.flatMap { Int($0) },
            size: probe.format?.size.flatMap { Int64($0) },
            tracks: tracks,
            chapters: chapters,
            tags: lowercasedKeys(probe.format?.tags)
        )
    }
}

private func lowercasedKeys(_ tags: [String: String]?) -> [String: String] {
    var out: [String: String] = [:]
    for (k, v) in tags ?? [:] { out[k.lowercased()] = v }
    return out
}

/// MP4 track IDs come back as "0x1".
private func parseTrackID(_ raw: String) -> Int? {
    raw.hasPrefix("0x") ? Int(raw.dropFirst(2), radix: 16) : Int(raw)
}

private func parseRate(_ raw: String?) -> Double? {
    guard let raw else { return nil }
    let parts = raw.split(separator: "/")
    guard parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0 else { return Double(raw) }
    return n / d
}

/// Tools write default handler names like "SoundHandler" — those aren't titles.
private func cleanHandlerName(_ name: String) -> String? {
    let generic: Set<String> = ["SoundHandler", "VideoHandler", "SubtitleHandler", "Core Media Audio", "Core Media Video",
                                "Core Media Text", "ISO Media file produced by Google Inc.", "GPAC ISO Video Handler",
                                "GPAC ISO Audio Handler", "Apple Video Media Handler", "Apple Sound Media Handler", "Text"]
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty || generic.contains(trimmed) || trimmed.hasPrefix("GPAC ") ? nil : trimmed
}

// MARK: - Time

public enum TimeCode {
    /// Accepts "1:02:03.5", "02:03", "123" or "123.4". Returns nil for blank or invalid input.
    public static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part.replacingOccurrences(of: ",", with: ".")), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    public static func format(_ seconds: Double, millis: Bool = true) -> String {
        let s = max(0, seconds)
        let h = Int(s) / 3600, m = Int(s) / 60 % 60
        let sec = s - Double(h * 3600 + m * 60)
        return millis ? String(format: "%02d:%02d:%06.3f", h, m, sec) : String(format: "%02d:%02d:%02d", h, m, Int(sec))
    }
}
