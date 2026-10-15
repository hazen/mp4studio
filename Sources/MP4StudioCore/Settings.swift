import Foundation

public enum OutputContainer: String, Codable, Sendable, CaseIterable, Identifiable {
    case m4v, mp4, mkv
    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
    public var isMP4: Bool { self != .mkv }
    public var label: String {
        switch self {
        case .m4v: return "M4V (Apple TV, iTunes)"
        case .mp4: return "MP4"
        case .mkv: return "MKV"
        }
    }
}

public enum VideoCodecChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    case passthrough, x264, x264TwoPass, x265, h264Hardware, hevcHardware
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .passthrough: return "Pass through (no re-encode)"
        case .x264: return "H.264 – x264, constant quality"
        case .x264TwoPass: return "H.264 – x264, 2-pass bitrate"
        case .x265: return "HEVC – x265, constant quality"
        case .h264Hardware: return "H.264 – Apple hardware (fast)"
        case .hevcHardware: return "HEVC – Apple hardware (fast)"
        }
    }

    public var reencodes: Bool { self != .passthrough }
    public var usesCRF: Bool { self == .x264 || self == .x265 }
    public var usesHardwareQuality: Bool { self == .h264Hardware || self == .hevcHardware }
    public var usesBitrate: Bool { self == .x264TwoPass }
    public var usesEncoderPreset: Bool { self == .x264 || self == .x264TwoPass || self == .x265 }
    public var isHEVC: Bool { self == .x265 || self == .hevcHardware }
    public var encoderName: String? {
        switch self {
        case .passthrough: return nil
        case .x264, .x264TwoPass: return "libx264"
        case .x265: return "libx265"
        case .h264Hardware: return "h264_videotoolbox"
        case .hevcHardware: return "hevc_videotoolbox"
        }
    }
}

/// Mirrors MP4tools' target-device choice: caps resolution and sets the H.264 profile/level.
public enum DeviceTarget: String, Codable, Sendable, CaseIterable, Identifiable {
    case any, appleTV4K, appleTVHD, iPhoneIPad, universal
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .any: return "No device limits"
        case .appleTV4K: return "Apple TV 4K"
        case .appleTVHD: return "Apple TV HD / Mac"
        case .iPhoneIPad: return "iPhone / iPad"
        case .universal: return "Universal (older devices)"
        }
    }

    public var maxWidth: Int? {
        switch self {
        case .any: return nil
        case .appleTV4K: return 3840
        case .appleTVHD, .iPhoneIPad: return 1920
        case .universal: return 1280
        }
    }

    public var h264Profile: String? {
        switch self {
        case .any: return nil
        case .universal: return "main"
        default: return "high"
        }
    }

    public var h264Level: String? {
        switch self {
        case .any: return nil
        case .appleTV4K: return "5.1"
        case .appleTVHD, .iPhoneIPad: return "4.1"
        case .universal: return "3.1"
        }
    }
}

public enum StereoAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case passthrough, aac
    public var id: String { rawValue }
    public var label: String { self == .passthrough ? "Pass through" : "AAC" }
}

public enum SurroundAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case passthrough, ac3, eac3, aacStereo
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .passthrough: return "Pass through"
        case .ac3: return "AC3 (Dolby Digital)"
        case .eac3: return "E-AC3 (Dolby Digital Plus), keep AC3"
        case .aacStereo: return "AAC stereo only"
        }
    }
}

public enum SubtitleAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case soft, burn
    public var id: String { rawValue }
    public var label: String { self == .soft ? "Mux (soft, can be turned off)" : "Burn in (hard, re-encodes video)" }
}

public struct ConvertSettings: Codable, Equatable, Sendable {
    // Defaults target Apple TV: M4V, Apple TV 4K limits, and surround that it can play.
    public var container: OutputContainer = .m4v
    public var device: DeviceTarget = .appleTV4K

    public var videoCodec: VideoCodecChoice = .passthrough
    public var crf: Int = 20
    public var hardwareQuality: Int = 65
    public var videoBitrateKbps: Int = 5000
    public var encoderPreset: String = "medium"
    /// 0 keeps the source width (still capped by the device).
    public var maxWidth: Int = 0
    public var squarePixels: Bool = false

    public var stereoAction: StereoAction = .passthrough
    public var surroundAction: SurroundAction = .eac3
    public var addStereoVersion: Bool = true
    public var stereoBitrateKbps: Int = 192
    public var surroundBitrateKbps: Int = 640

    public var subtitleAction: SubtitleAction = .soft

    public var webOptimized: Bool = true
    public var copyChapters: Bool = true

    public init() {}

    public static let encoderPresets = ["ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"]
    public static let widthChoices = [0, 3840, 2560, 1920, 1280, 1024, 720, 640]
    public static let stereoBitrates = [96, 128, 160, 192, 256, 320]
    public static let surroundBitrates = [384, 448, 640, 768, 1024]

    /// The tighter of the user's width cap and the device's.
    public var effectiveMaxWidth: Int? {
        let caps = [maxWidth > 0 ? maxWidth : nil, device.maxWidth].compactMap { $0 }
        return caps.min()
    }

    // Tolerate settings saved by older versions that lack newer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ConvertSettings.defaults
        container = (try? c.decode(OutputContainer.self, forKey: .container)) ?? d.container
        device = (try? c.decode(DeviceTarget.self, forKey: .device)) ?? d.device
        videoCodec = (try? c.decode(VideoCodecChoice.self, forKey: .videoCodec)) ?? d.videoCodec
        crf = (try? c.decode(Int.self, forKey: .crf)) ?? d.crf
        hardwareQuality = (try? c.decode(Int.self, forKey: .hardwareQuality)) ?? d.hardwareQuality
        videoBitrateKbps = (try? c.decode(Int.self, forKey: .videoBitrateKbps)) ?? d.videoBitrateKbps
        encoderPreset = (try? c.decode(String.self, forKey: .encoderPreset)) ?? d.encoderPreset
        maxWidth = (try? c.decode(Int.self, forKey: .maxWidth)) ?? d.maxWidth
        squarePixels = (try? c.decode(Bool.self, forKey: .squarePixels)) ?? d.squarePixels
        stereoAction = (try? c.decode(StereoAction.self, forKey: .stereoAction)) ?? d.stereoAction
        surroundAction = (try? c.decode(SurroundAction.self, forKey: .surroundAction)) ?? d.surroundAction
        addStereoVersion = (try? c.decode(Bool.self, forKey: .addStereoVersion)) ?? d.addStereoVersion
        stereoBitrateKbps = (try? c.decode(Int.self, forKey: .stereoBitrateKbps)) ?? d.stereoBitrateKbps
        surroundBitrateKbps = (try? c.decode(Int.self, forKey: .surroundBitrateKbps)) ?? d.surroundBitrateKbps
        subtitleAction = (try? c.decode(SubtitleAction.self, forKey: .subtitleAction)) ?? d.subtitleAction
        webOptimized = (try? c.decode(Bool.self, forKey: .webOptimized)) ?? d.webOptimized
        copyChapters = (try? c.decode(Bool.self, forKey: .copyChapters)) ?? d.copyChapters
    }

    static let defaults = ConvertSettings()
}

// MARK: - Track selection rules

public enum TrackPick: String, Codable, Sendable, CaseIterable, Identifiable {
    case all, first, byLanguage, none
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .all: return "All tracks"
        case .first: return "First track"
        case .byLanguage: return "By language"
        case .none: return "None"
        }
    }
}

/// How a preset picks tracks automatically, like MP4tools' track filters.
public struct SelectionRules: Codable, Equatable, Sendable {
    public var audio: TrackPick = .all
    public var audioLanguages: [String] = ["eng"]
    public var audioFallbackToFirst: Bool = true
    public var subtitles: TrackPick = .all
    public var subtitleLanguages: [String] = ["eng"]
    public var subtitleFallbackToFirst: Bool = false
    /// Burn the first forced subtitle track into the video (needs a re-encoding video codec).
    public var burnForcedSubtitles: Bool = false

    public init() {}

    public func selectedTrackIDs(in file: MediaFile) -> Set<String> {
        var ids = Set(file.tracks(.video).prefix(1).map(\.id))
        ids.formUnion(pick(file.tracks(.audio), rule: audio, languages: audioLanguages, fallback: audioFallbackToFirst))
        ids.formUnion(pick(file.tracks(.subtitle), rule: subtitles, languages: subtitleLanguages, fallback: subtitleFallbackToFirst))
        return ids
    }

    func pick(_ tracks: [MediaTrack], rule: TrackPick, languages: [String], fallback: Bool) -> [String] {
        switch rule {
        case .all: return tracks.map(\.id)
        case .first: return tracks.prefix(1).map(\.id)
        case .none: return []
        case .byLanguage:
            let wanted = Set(languages.map { Languages.normalize($0) })
            let matches = tracks.filter { wanted.contains($0.language) }.map(\.id)
            return matches.isEmpty && fallback ? tracks.prefix(1).map(\.id) : matches
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SelectionRules()
        audio = (try? c.decode(TrackPick.self, forKey: .audio)) ?? d.audio
        audioLanguages = (try? c.decode([String].self, forKey: .audioLanguages)) ?? d.audioLanguages
        audioFallbackToFirst = (try? c.decode(Bool.self, forKey: .audioFallbackToFirst)) ?? d.audioFallbackToFirst
        subtitles = (try? c.decode(TrackPick.self, forKey: .subtitles)) ?? d.subtitles
        subtitleLanguages = (try? c.decode([String].self, forKey: .subtitleLanguages)) ?? d.subtitleLanguages
        subtitleFallbackToFirst = (try? c.decode(Bool.self, forKey: .subtitleFallbackToFirst)) ?? d.subtitleFallbackToFirst
        burnForcedSubtitles = (try? c.decode(Bool.self, forKey: .burnForcedSubtitles)) ?? d.burnForcedSubtitles
    }
}

public struct Preset: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var settings: ConvertSettings
    public var rules: SelectionRules

    public init(id: UUID = UUID(), name: String, settings: ConvertSettings = .init(), rules: SelectionRules = .init()) {
        self.id = id
        self.name = name
        self.settings = settings
        self.rules = rules
    }

    /// The first one is the default for new installs.
    public static var builtIn: [Preset] {
        let appleTV = ConvertSettings()

        var hevc = ConvertSettings()
        hevc.videoCodec = .hevcHardware

        var keepAudio = ConvertSettings()
        keepAudio.surroundAction = .passthrough
        keepAudio.surroundBitrateKbps = 448

        var universal = ConvertSettings()
        universal.container = .mp4
        universal.device = .universal
        universal.videoCodec = .x264
        universal.crf = 21
        universal.stereoAction = .aac
        universal.surroundAction = .aacStereo
        universal.addStereoVersion = false

        var mkv = ConvertSettings()
        mkv.container = .mkv
        mkv.device = .any
        mkv.surroundAction = .passthrough

        return [
            Preset(name: "Apple TV – remux, E-AC3 surround", settings: appleTV),
            Preset(name: "Apple TV 4K – HEVC hardware", settings: hevc),
            Preset(name: "Remux – keep original surround", settings: keepAudio),
            Preset(name: "Universal H.264 (stereo)", settings: universal),
            Preset(name: "MKV remux", settings: mkv),
        ]
    }
}
