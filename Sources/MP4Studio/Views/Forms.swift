import AppKit
import MP4StudioCore
import SwiftUI

/// Video settings, used by Convert and the preset editor.
struct VideoSettingsForm: View {
    @Binding var s: ConvertSettings
    let capabilities: FFmpegCapabilities

    var body: some View {
        Form {
            Picker("Container", selection: $s.container) {
                ForEach(OutputContainer.allCases) { Text($0.label).tag($0) }
            }
            Picker("Target device", selection: $s.device) {
                ForEach(DeviceTarget.allCases) { Text($0.label).tag($0) }
            }
            .help("Caps the resolution and sets the H.264 profile and level for the device.")
            Picker("Video", selection: $s.videoCodec) {
                ForEach(VideoCodecChoice.allCases) { codec in
                    Text(codec.label).tag(codec)
                        .foregroundStyle(isAvailable(codec) ? .primary : .secondary)
                }
            }
            if !isAvailable(s.videoCodec) {
                Text("This ffmpeg build doesn't include \(s.videoCodec.encoderName ?? "").").foregroundStyle(.red).font(.callout)
            }
            if s.videoCodec.usesCRF {
                LabeledContent("Quality (CRF)") {
                    HStack {
                        Slider(value: Binding(get: { Double(s.crf) }, set: { s.crf = Int($0) }), in: 14...30, step: 1)
                        Text("\(s.crf)").monospacedDigit().frame(width: 28)
                    }
                }
                Text("Lower is better quality and bigger files. 18–22 is typical for H.264, 20–24 for HEVC.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if s.videoCodec.usesHardwareQuality {
                LabeledContent("Quality") {
                    HStack {
                        Slider(value: Binding(get: { Double(s.hardwareQuality) }, set: { s.hardwareQuality = Int($0) }), in: 30...90, step: 1)
                        Text("\(s.hardwareQuality)").monospacedDigit().frame(width: 28)
                    }
                }
                Text("Higher is better quality. 60–70 is a good balance on Apple silicon.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if s.videoCodec == .handBrakeAppleTV4K {
                Text("Matches the video settings of HandBrake's Apple 2160p60 4K HEVC Surround preset: x265 10-bit, slow, up to 3840×2160 and 60 fps, with decomb deinterlacing. Encodes at a 30 Mbps average bitrate in 2 passes, so it's slow.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if s.videoCodec.usesBitrate {
                TextField("Bitrate (kbps)", value: $s.videoBitrateKbps, format: .number)
            }
            if s.videoCodec.usesEncoderPreset {
                Picker("Encoder speed", selection: $s.encoderPreset) {
                    ForEach(ConvertSettings.encoderPresets, id: \.self) { Text($0).tag($0) }
                }
            }
            Picker("Max width", selection: $s.maxWidth) {
                ForEach(ConvertSettings.widthChoices, id: \.self) { w in
                    Text(w == 0 ? "Keep original" : "\(w) px").tag(w)
                }
            }
            .disabled(!s.videoCodec.reencodes)
            Toggle("Square pixels (fix anamorphic video)", isOn: $s.squarePixels)
                .help("Sets the pixel aspect ratio to 1:1. With pass-through this rewrites the H.264/HEVC header; otherwise the video is rescaled, shrinking the longer side rather than enlarging the other.")
            Toggle("Copy chapters", isOn: $s.copyChapters)
            if s.container.isMP4 {
                Toggle("Optimize for streaming (fast start)", isOn: $s.webOptimized)
            }
        }
        .formStyle(.grouped)
    }

    func isAvailable(_ codec: VideoCodecChoice) -> Bool {
        guard let encoder = codec.encoderName, !capabilities.encoders.isEmpty else { return true }
        return capabilities.encoders.contains(encoder)
    }
}

struct AudioSettingsForm: View {
    @Binding var s: ConvertSettings

    var body: some View {
        Form {
            Section("Stereo and mono tracks") {
                Picker("Action", selection: $s.stereoAction) {
                    ForEach(StereoAction.allCases) { Text($0.label).tag($0) }
                }
                Picker("AAC bitrate", selection: $s.stereoBitrateKbps) {
                    ForEach(ConvertSettings.stereoBitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                }
            }
            Section("Surround tracks") {
                Picker("Action", selection: $s.surroundAction) {
                    ForEach(SurroundAction.allCases) { Text($0.label).tag($0) }
                }
                Picker("Bitrate", selection: $s.surroundBitrateKbps) {
                    ForEach(ConvertSettings.surroundBitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                }
                .disabled(s.surroundAction == .passthrough || s.surroundAction == .aacStereo)
                Toggle("Add an AAC stereo version before each surround track", isOn: $s.addStereoVersion)
                    .disabled(s.surroundAction == .aacStereo)
                Text("E-AC3 keeps AC3 and E-AC3 tracks and converts TrueHD, DTS and others to 5.1 E-AC3 for Apple TV. Atmos isn't kept, and 7.1 becomes 5.1.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Pass-through keeps DTS and TrueHD in MKV. For MP4 they're converted to AC3, since Apple players can't play them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct RulesForm: View {
    @Binding var rules: SelectionRules

    var body: some View {
        Form {
            Section("Audio tracks to select") {
                Picker("Select", selection: $rules.audio) {
                    ForEach(TrackPick.allCases) { Text($0.label).tag($0) }
                }
                if rules.audio == .byLanguage {
                    LanguageListField(codes: $rules.audioLanguages)
                    Toggle("If no language matches, use the first track", isOn: $rules.audioFallbackToFirst)
                }
            }
            Section("Subtitle tracks to select") {
                Picker("Select", selection: $rules.subtitles) {
                    ForEach(TrackPick.allCases) { Text($0.label).tag($0) }
                }
                if rules.subtitles == .byLanguage {
                    LanguageListField(codes: $rules.subtitleLanguages)
                    Toggle("If no language matches, use the first track", isOn: $rules.subtitleFallbackToFirst)
                }
                Toggle("Burn in the first forced subtitle track", isOn: $rules.burnForcedSubtitles)
                    .help("Only when the preset re-encodes video.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Comma-separated language codes, e.g. "eng, fre".
struct LanguageListField: View {
    @Binding var codes: [String]
    @State private var text = ""

    var body: some View {
        TextField("Languages", text: $text, prompt: Text("eng, fre"))
            .onAppear { text = codes.joined(separator: ", ") }
            .onChange(of: text) { _, new in
                codes = new.split(separator: ",").map { Languages.normalize(String($0)) }.filter { $0 != "und" }
            }
            .help("ISO 639-2 codes such as eng, fre, ger, spa, jpn. Two-letter codes work too.")
    }
}

struct MetadataForm: View {
    @Binding var fields: MetadataFields
    /// Existing artwork in the file, shown when no new image is chosen.
    var existingArtwork: NSImage?

    var body: some View {
        Form {
            Section {
                Picker("Media type", selection: $fields.kind) {
                    ForEach(MediaKind.allCases) { Text($0.label).tag($0) }
                }
                TextField(fields.kind == .tvShow ? "Episode title" : "Title", text: $fields.title)
                HStack {
                    TextField("Year", text: $fields.year).frame(maxWidth: 160)
                    TextField("Genre", text: $fields.genre)
                }
                Picker("Rating", selection: $fields.ratingID) {
                    Text("None").tag("")
                    ForEach(ContentRating.all) { Text("\($0.label) (\($0.system == "mpaa" ? "film" : "TV"))").tag($0.id) }
                    if !fields.ratingID.isEmpty, !ContentRating.all.contains(where: { $0.id == fields.ratingID }) {
                        Text(fields.ratingID).tag(fields.ratingID)
                    }
                }
            }
            if fields.kind == .tvShow {
                Section("TV show") {
                    TextField("Show", text: $fields.tvShow)
                    HStack {
                        TextField("Season", text: $fields.tvSeason)
                        TextField("Episode", text: $fields.tvEpisodeNumber)
                    }
                    TextField("Episode ID", text: $fields.tvEpisodeID, prompt: Text("S01E01"))
                    TextField("Network", text: $fields.tvNetwork)
                }
            }
            Section("Description") {
                TextField("Short description", text: $fields.shortDescription, axis: .vertical).lineLimit(2...4)
                TextField("Long description", text: $fields.longDescription, axis: .vertical).lineLimit(3...8)
            }
            Section("Cast and crew (comma-separated)") {
                TextField("Cast", text: $fields.cast)
                TextField("Directors", text: $fields.directors)
                TextField("Screenwriters", text: $fields.screenwriters)
                TextField("Producers", text: $fields.producers)
            }
            Section("Artwork") {
                ArtworkWell(fields: $fields, existing: existingArtwork)
            }
        }
        .formStyle(.grouped)
    }
}

struct ArtworkWell: View {
    @Binding var fields: MetadataFields
    var existing: NSImage?

    var image: NSImage? {
        if fields.removeArtwork { return nil }
        if let path = fields.artworkPath { return NSImage(contentsOfFile: path) }
        return existing
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5))
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 110, height: 160)
            .onFileDrop { urls in
                if let url = urls.first(where: { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }) {
                    fields.artworkPath = url.path
                    fields.removeArtwork = false
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Button("Choose Image…") {
                    if let url = Panels.chooseImage() {
                        fields.artworkPath = url.path
                        fields.removeArtwork = false
                    }
                }
                Button("Remove Artwork") {
                    fields.artworkPath = nil
                    fields.removeArtwork = true
                }
                .disabled(image == nil)
                Text("Drop a JPEG or PNG on the box. Posters look best at 2:3.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
