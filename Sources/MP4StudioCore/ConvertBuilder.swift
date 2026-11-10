import Foundation

public struct ConvertRequest: Sendable {
    public var main: MediaFile
    /// Extra files (external subtitles or audio) whose tracks can be added. Their tracks must use input indexes 1, 2, ...
    public var extras: [MediaFile]
    public var selectedTrackIDs: Set<String>
    public var burnTrackID: String?
    public var segmentStart: Double?
    public var segmentEnd: Double?
    public var settings: ConvertSettings
    public var metadata: MetadataFields?
    public var outputURL: URL
    public var temporaryDirectory: URL

    public init(main: MediaFile, extras: [MediaFile] = [], selectedTrackIDs: Set<String>, burnTrackID: String? = nil,
                segmentStart: Double? = nil, segmentEnd: Double? = nil, settings: ConvertSettings,
                metadata: MetadataFields? = nil, outputURL: URL, temporaryDirectory: URL) {
        self.main = main
        self.extras = extras
        self.selectedTrackIDs = selectedTrackIDs
        self.burnTrackID = burnTrackID
        self.segmentStart = segmentStart
        self.segmentEnd = segmentEnd
        self.settings = settings
        self.metadata = metadata
        self.outputURL = outputURL
        self.temporaryDirectory = temporaryDirectory
    }
}

public struct ConvertBuilder {
    public let tools: ToolPaths
    public let capabilities: FFmpegCapabilities

    public init(tools: ToolPaths, capabilities: FFmpegCapabilities) {
        self.tools = tools
        self.capabilities = capabilities
    }

    /// Audio codecs Apple players handle inside MP4.
    static let mp4AudioCodecs: Set<String> = ["aac", "ac3", "eac3", "alac", "mp3"]
    /// Video codecs that can be stored in MP4.
    static let mp4VideoCodecs: Set<String> = ["h264", "hevc", "av1", "mpeg4", "mpeg2video", "vp9", "mjpeg", "prores"]

    public func plan(_ request: ConvertRequest) throws -> JobPlan {
        let ffmpeg = try tools.require(.ffmpeg)
        let s = request.settings
        let inputs = [request.main] + request.extras
        let allTracks = inputs.flatMap(\.tracks)
        let selected = allTracks.filter { request.selectedTrackIDs.contains($0.id) }
        let videos = selected.filter { $0.kind == .video && !$0.isAttachedPicture }
        let audios = selected.filter { $0.kind == .audio }
        let burn = request.burnTrackID.flatMap { id in allTracks.first { $0.id == id && $0.kind == .subtitle } }
        let subtitles = selected.filter { $0.kind == .subtitle && $0.id != burn?.id }
        var warnings: [String] = []

        guard !videos.isEmpty || !audios.isEmpty else {
            throw ToolError.invalid("Select at least one video or audio track.")
        }
        if let start = request.segmentStart, let end = request.segmentEnd, end <= start {
            throw ToolError.invalid("The segment end time must be after the start time.")
        }
        if let burn {
            guard !videos.isEmpty else { throw ToolError.invalid("Burning subtitles needs a video track.") }
            guard s.videoCodec.reencodes else {
                throw ToolError.invalid("Burning subtitles re-encodes the video. Choose a video codec other than Pass through.")
            }
            if !burn.isBitmapSubtitle && !capabilities.hasSubtitlesFilter {
                throw ToolError.invalid("This ffmpeg build can't burn text subtitles because it lacks libass. Mux the subtitles instead, or install an ffmpeg built with libass.")
            }
        }
        if let encoder = s.videoCodec.encoderName, !capabilities.encoders.isEmpty, !capabilities.encoders.contains(encoder) {
            throw ToolError.invalid("This ffmpeg build doesn't include the \(encoder) encoder.")
        }

        let start = request.segmentStart.flatMap { $0 > 0 ? $0 : nil }
        let end = request.segmentEnd
        let total = (end ?? request.main.duration) - (start ?? 0)

        var base = ["-hide_banner", "-nostdin", "-y", "-loglevel", "warning", "-progress", "pipe:1", "-nostats"]
        for file in inputs {
            if let start { base += ["-ss", seconds(start)] }
            if let end { base += ["-to", seconds(end)] }
            base += ["-i", file.url.path]
        }

        // Video: maps, filter graph and codec options. Kept separate so pass 1 of a 2-pass encode can reuse it.
        var graph: [String] = []
        var videoArgs: [String] = []
        var out = 0
        let passLog = request.temporaryDirectory.appendingPathComponent("passlog-\(UUID().uuidString)").path
        var videoCodecArgsByPass: [(Int) -> [String]] = []
        var details: [PlanSection] = []
        var sourceRows = [PlanSection.Row("File", request.main.name), PlanSection.Row("Duration", TimeCode.format(total))]
        if start != nil || end != nil {
            sourceRows.append(.init("Segment", "\(TimeCode.format(start ?? 0)) to \(end.map { TimeCode.format($0) } ?? "end")"))
        }
        if !request.extras.isEmpty { sourceRows.append(.init("Added files", request.extras.map(\.name).joined(separator: ", "))) }
        details.append(PlanSection("Source", sourceRows))

        for (vi, v) in videos.enumerated() {
            let o = out
            var rows = [PlanSection.Row("Track \(v.id)", Self.summary(of: v))]
            if s.videoCodec.reencodes {
                var filters: [String] = []
                var notes: [String] = []
                var source = "[\(v.id)]"
                if let burn, vi == 0 {
                    notes.append("Burn in \(burn.codecLabel) subtitles from track \(burn.id)")
                    if burn.isBitmapSubtitle {
                        source = "[\(v.id)][\(burn.id)]overlay=eof_action=pass"
                    } else {
                        let file = inputs[burn.inputIndex]
                        let si = file.tracks(.subtitle).firstIndex { $0.id == burn.id } ?? 0
                        let sub = "subtitles=filename=\(filterEscape(file.url.path)):si=\(si)"
                        // The subtitles filter reads the file from 0, so shift timestamps when the input was seeked.
                        if let start { filters += ["setpts=PTS+\(seconds(start))/TB", sub, "setpts=PTS-STARTPTS"] } else { filters.append(sub) }
                    }
                }
                if s.videoCodec == .handBrakeAppleTV4K {
                    // HandBrake's decomb and 60 fps peak frame rate.
                    filters.append("bwdif=mode=send_frame:deint=interlaced")
                    notes.append("Deinterlace interlaced frames (bwdif)")
                    if (v.frameRate ?? 0) > 60.5 {
                        filters.append("fps=60")
                        notes.append("Limit to 60 fps")
                    }
                }
                if s.squarePixels && v.isAnamorphic {
                    notes.append("Convert to square pixels")
                    // Shrink whichever dimension is too long, so the output is never larger than the source.
                    filters.append("scale='if(gt(sar,1),iw,trunc(iw*sar/2)*2)':'if(gt(sar,1),trunc(ih/sar/2)*2,ih)'")
                }
                let tooTall = s.videoCodec.maxHeight.map { (v.height ?? 0) > $0 } ?? false
                if let maxW = s.effectiveMaxWidth, (v.width ?? .max) > maxW || (s.squarePixels && v.isAnamorphic) || tooTall {
                    if let maxH = s.videoCodec.maxHeight {
                        filters.append("scale='min(\(maxW),iw)':'min(\(maxH),ih)':force_original_aspect_ratio=decrease:force_divisible_by=2")
                        notes.append("Fit within \(maxW)×\(maxH)")
                    } else {
                        filters.append("scale='min(\(maxW),iw)':-2")
                        notes.append("Scale to at most \(maxW) wide")
                    }
                }
                if s.squarePixels && v.isAnamorphic { filters.append("setsar=1") }
                filters.append("format=\(pixelFormat(for: v, codec: s.videoCodec))")
                let joinedFilters = filters.joined(separator: ",")
                let separator = source.hasSuffix("]") ? "" : ","
                graph.append("\(source)\(separator)\(joinedFilters)[v\(vi)]")
                videoArgs += ["-map", "[v\(vi)]"]
                videoCodecArgsByPass.append { pass in self.videoCodecArgs(o, v, s, pass: pass, passLog: passLog) }
                rows += videoEncodeRows(o, v, s)
                if let size = outputSize(of: v, settings: s) { rows.append(.init("Output size", size)) }
                rows.append(.init("Pixel format", pixelFormat(for: v, codec: s.videoCodec)))
                rows.append(.init("Filters", notes.isEmpty ? "None" : notes.joined(separator: ", ")))
            } else {
                rows.append(.init("Codec", "Copy (no re-encode)"))
                videoArgs += ["-map", v.id, "-c:\(o)", "copy"]
                if s.container.isMP4 && !Self.mp4VideoCodecs.contains(v.codec) {
                    throw ToolError.invalid("\(v.codecLabel) video can't be passed through into MP4. Choose MKV or re-encode the video.")
                }
                if s.container.isMP4 && v.codec == "hevc" {
                    videoArgs += ["-tag:\(o)", "hvc1"]
                    rows.append(.init("Tag", "hvc1, so Apple players accept it"))
                }
                if s.squarePixels && v.isAnamorphic {
                    if v.codec == "h264" || v.codec == "hevc" { rows.append(.init("Pixel aspect", "Marked 1:1 without re-encoding")) }
                    if v.codec == "h264" { videoArgs += ["-bsf:\(o)", "h264_metadata=sample_aspect_ratio=1/1"] }
                    else if v.codec == "hevc" { videoArgs += ["-bsf:\(o)", "hevc_metadata=sample_aspect_ratio=1/1"] }
                    else { warnings.append("Square pixels needs re-encoding for \(v.codecLabel) video; the pixel aspect ratio was kept.") }
                }
                videoCodecArgsByPass.append { _ in [] }
            }
            videoArgs += trackMetadata(o, language: v.language, title: v.title, isMP4: s.container.isMP4)
            details.append(PlanSection(videos.count > 1 ? "Video \(vi + 1)" : "Video", rows))
            out += 1
        }

        func videoSection(pass: Int) -> [String] {
            var args = graph.isEmpty ? [] : ["-filter_complex", graph.joined(separator: ";")]
            args += videoArgs
            for f in videoCodecArgsByPass { args += f(pass) }
            return args
        }

        // Audio
        var audioArgs: [String] = []
        var audioRows: [PlanSection.Row] = []
        var firstAudio = true
        func emitAudio(_ a: MediaTrack, _ codec: (args: [String], summary: String), title: String) {
            audioArgs += ["-map", a.id] + codec.args.map { $0.replacingOccurrences(of: "{o}", with: "\(out)") }
            audioArgs += trackMetadata(out, language: a.language, title: title, isMP4: s.container.isMP4)
            audioArgs += ["-disposition:\(out)", firstAudio ? "default" : "0"]
            var result = [codec.summary]
            if !title.isEmpty { result.append("“\(title)”") }
            if firstAudio { result.append("default") }
            audioRows.append(.init("Track \(a.id)", "\(Self.summary(of: a)) → \(result.joined(separator: " · "))"))
            firstAudio = false
            out += 1
        }
        let copy = (args: ["-c:{o}", "copy"], summary: "Copy")
        func aac(_ kbps: Int) -> (args: [String], summary: String) {
            (["-c:{o}", capabilities.aacEncoder, "-b:{o}", "\(kbps)k", "-ac:{o}", "2"], "AAC stereo, \(kbps) kbps (\(capabilities.aacEncoder))")
        }
        func dolby(_ codec: String, _ kbps: Int, channels: Int?) -> (args: [String], summary: String) {
            let rate = codec == "ac3" ? min(kbps, 640) : kbps
            var a = ["-c:{o}", codec, "-b:{o}", "\(rate)k"]
            var summary = "\(codec == "ac3" ? "AC3" : "E-AC3"), \(rate) kbps"
            if (channels ?? 0) > 6 {
                a += ["-ac:{o}", "6"]
                summary += ", downmixed to 5.1"
            }
            return (a, summary)
        }
        func canCopy(_ a: MediaTrack) -> Bool { !s.container.isMP4 || Self.mp4AudioCodecs.contains(a.codec) }

        for a in audios {
            if a.isSurround {
                let surroundTitle = a.title.isEmpty ? "Surround" : a.title
                if s.addStereoVersion || s.surroundAction == .aacStereo {
                    emitAudio(a, aac(s.stereoBitrateKbps), title: a.title.isEmpty || s.surroundAction != .aacStereo ? "Stereo" : a.title)
                }
                switch s.surroundAction {
                case .passthrough:
                    if canCopy(a) {
                        emitAudio(a, copy, title: surroundTitle)
                    } else {
                        warnings.append("\(a.codecLabel) audio can't go in MP4, so track \(a.streamIndex) is converted to AC3.")
                        emitAudio(a, dolby("ac3", s.surroundBitrateKbps, channels: a.channels), title: surroundTitle)
                    }
                case .ac3:
                    emitAudio(a, a.codec == "ac3" ? copy : dolby("ac3", s.surroundBitrateKbps, channels: a.channels), title: surroundTitle)
                case .eac3:
                    // AC3 plays everywhere E-AC3 does, so only TrueHD, DTS and the like are converted.
                    let dolbyAlready = a.codec == "eac3" || a.codec == "ac3"
                    emitAudio(a, dolbyAlready ? copy : dolby("eac3", s.surroundBitrateKbps, channels: a.channels), title: surroundTitle)
                case .aacStereo:
                    break
                }
            } else {
                let keep = a.codec == "aac" || (s.stereoAction == .passthrough && canCopy(a))
                if s.stereoAction == .passthrough && !canCopy(a) {
                    warnings.append("\(a.codecLabel) audio can't go in MP4, so track \(a.streamIndex) is converted to AAC.")
                }
                emitAudio(a, keep ? copy : aac(s.stereoBitrateKbps), title: a.title)
            }
        }

        // Subtitles
        var subtitleArgs: [String] = []
        var subtitleRows: [PlanSection.Row] = []
        if let burn { subtitleRows.append(.init("Track \(burn.id)", "\(Self.summary(of: burn)) → Burned into the video")) }
        for t in subtitles {
            let codec: String
            if s.container.isMP4 {
                if t.isTextSubtitle { codec = "mov_text" }
                else if t.codec == "dvd_subtitle" { codec = "copy" }
                else {
                    warnings.append("Skipped subtitle track \(t.streamIndex): \(t.codecLabel) subtitles can't be stored in MP4. Burn them in or choose MKV.")
                    subtitleRows.append(.init("Track \(t.id)", "\(Self.summary(of: t)) → Skipped, can't be stored in MP4"))
                    continue
                }
            } else {
                codec = t.codec == "mov_text" ? "srt" : "copy"
            }
            subtitleArgs += ["-map", t.id, "-c:\(out)", codec]
            subtitleArgs += trackMetadata(out, language: t.language, title: t.title, isMP4: s.container.isMP4)
            var disposition: [String] = []
            if t.isDefault { disposition.append("default") }
            if t.isForced { disposition.append("forced") }
            subtitleArgs += ["-disposition:\(out)", disposition.isEmpty ? "0" : disposition.joined(separator: "+")]
            let result = [codec == "copy" ? "Copy" : codec == "mov_text" ? "Text (mov_text)" : "SRT"] + disposition
            subtitleRows.append(.init("Track \(t.id)", "\(Self.summary(of: t)) → \(result.joined(separator: " · "))"))
            out += 1
        }

        // Cover art travels as an attached-picture video stream.
        if s.container.isMP4, let art = request.main.tracks.first(where: { $0.isAttachedPicture }),
           ["mjpeg", "png"].contains(art.codec), request.metadata?.artworkPath == nil, request.metadata?.removeArtwork != true {
            subtitleArgs += ["-map", art.id, "-c:\(out)", "copy", "-disposition:\(out)", "attached_pic"]
            out += 1
        }
        if !audioRows.isEmpty { details.append(PlanSection("Audio", audioRows)) }
        if !subtitleRows.isEmpty { details.append(PlanSection("Subtitles", subtitleRows)) }

        // Container
        var tail: [String] = []
        var container = [PlanSection.Row("Format", s.container.label), PlanSection.Row("Target device", s.device.label)]
        if !request.main.tracks(.attachment).isEmpty && !s.container.isMP4 {
            tail += ["-map", "0:t?", "-c:t", "copy"]
            container.append(.init("Attachments", "Copied"))
        }
        tail += ["-map_metadata", "0", "-map_chapters", s.copyChapters ? "0" : "-1", "-max_muxing_queue_size", "4096"]
        container.append(.init("Chapters", s.copyChapters ? (request.main.chapters.isEmpty ? "None in source" : "Copied (\(request.main.chapters.count))") : "Removed"))
        if s.container.isMP4 {
            if request.main.tracks.contains(where: \.isAttachedPicture), subtitleArgs.contains("attached_pic") { container.append(.init("Cover art", "Copied from source")) }
            if let v = videos.first, let hd = hdVideoFlag(for: v, settings: s) {
                tail += ["-metadata", "hd_video=\(hd)"]
                container.append(.init("HD flag", ["720p", "1080p", "4K"][hd - 1]))
            }
            if s.webOptimized { tail += ["-movflags", "+faststart"] }
            container.append(.init("Web optimized", s.webOptimized ? "Yes (moov atom first)" : "No"))
            tail += ["-f", "mp4"]
        } else {
            if let title = request.metadata?.title, !title.isEmpty { tail += ["-metadata", "title=\(title)"] }
            tail += ["-f", "matroska"]
        }

        var steps: [JobStep] = []
        var temporaryFiles: [URL] = []
        let name = request.main.name
        if s.videoCodec.isTwoPass && !videos.isEmpty {
            steps.append(JobStep(label: "Pass 1 of 2 (analysis)", tool: .ffmpeg, executable: ffmpeg,
                                 arguments: base + videoSection(pass: 1) + ["-an", "-sn", "-dn", "-f", "null", "/dev/null"],
                                 progress: .ffmpeg(totalSeconds: total)))
            temporaryFiles += [passLog + "-0.log", passLog + "-0.log.mbtree"].map { URL(fileURLWithPath: $0) }
        }
        let pass = s.videoCodec.isTwoPass ? 2 : 0
        steps.append(JobStep(label: pass == 2 ? "Pass 2 of 2 (encode)" : "Converting",
                             tool: .ffmpeg, executable: ffmpeg,
                             arguments: base + videoSection(pass: pass) + audioArgs + subtitleArgs + tail + [request.outputURL.path],
                             progress: .ffmpeg(totalSeconds: total)))

        if s.container.isMP4, let metadata = request.metadata, !metadata.isEmpty {
            container.append(.init("Metadata", "Written with AtomicParsley" + (metadata.title.isEmpty ? "" : ": “\(metadata.title)”")))
            let ap = try tools.require(.atomicParsley)
            steps.append(JobStep(label: "Writing metadata", tool: .atomicParsley, executable: ap,
                                 arguments: [request.outputURL.path] + metadata.atomicParsleyArguments() + ["--overWrite"],
                                 progress: .indeterminate))
        }

        details.append(PlanSection("Container", container))

        return JobPlan(title: "Convert \(name)", steps: steps, outputs: [request.outputURL],
                       outputFolder: request.outputURL.deletingLastPathComponent(),
                       temporaryFiles: temporaryFiles, warnings: warnings, details: details)
    }

    /// "HEVC · 3840×2160 · 23.976 fps · 10-bit · eng", for the job details.
    static func summary(of t: MediaTrack) -> String {
        var parts = [t.codecLabel]
        if !t.details.isEmpty, t.kind != .subtitle { parts.append(t.details) }
        if t.language != "und" { parts.append(t.language) }
        if t.isForced { parts.append("forced") }
        return parts.joined(separator: " · ")
    }

    /// Describes the encoder settings that videoCodecArgs passes to ffmpeg.
    func videoEncodeRows(_ o: Int, _ v: MediaTrack, _ s: ConvertSettings) -> [PlanSection.Row] {
        var rows = [PlanSection.Row("Codec", s.videoCodec.label), PlanSection.Row("Encoder", s.videoCodec.encoderName ?? "")]
        switch s.videoCodec {
        case .passthrough: break
        case .x264, .x265: rows.append(.init("Quality", "Constant quality, CRF \(s.crf), preset \(s.encoderPreset)"))
        case .x264TwoPass: rows.append(.init("Quality", "\(s.videoBitrateKbps) kbps average, 2 passes, preset \(s.encoderPreset)"))
        case .handBrakeAppleTV4K:
            rows.append(.init("Quality", "Constant quality, CRF 24, preset slow"))
            rows.append(.init("x265 options", Self.handBrakeX265Params))
        case .h264Hardware, .hevcHardware: rows.append(.init("Quality", "VideoToolbox quality \(s.hardwareQuality) of 100"))
        }
        let args = videoCodecArgs(o, v, s, pass: 0, passLog: "")
        func value(_ option: String) -> String? { args.firstIndex(of: "\(option):\(o)").map { args[$0 + 1] } }
        if let profile = value("-profile") { rows.append(.init("Profile", [profile, value("-level").map { "level \($0)" }].compactMap { $0 }.joined(separator: ", "))) }
        return rows
    }

    /// The approximate output frame size after the scale filters, e.g. "3840×2160 → 1920×1080".
    func outputSize(of v: MediaTrack, settings s: ConvertSettings) -> String? {
        guard let w0 = v.width, let h0 = v.height, w0 > 0, h0 > 0 else { return nil }
        var w = Double(w0), h = Double(h0)
        if s.squarePixels, v.isAnamorphic, let sar = v.sampleAspectRatio.flatMap(Self.ratio), sar > 0 {
            if sar > 1 { h /= sar } else { w *= sar }
        }
        if let maxW = s.effectiveMaxWidth.map(Double.init) {
            let maxH = s.videoCodec.maxHeight.map(Double.init) ?? .infinity
            let factor = min(1, maxW / w, maxH / h)
            w *= factor
            h *= factor
        }
        func even(_ x: Double) -> Int { Int((x / 2).rounded()) * 2 }
        let result = "\(even(w))×\(even(h))"
        return result == "\(w0)×\(h0)" ? "\(result) (unchanged)" : "\(w0)×\(h0) → \(result)"
    }

    static func ratio(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 && parts[1] != 0 ? parts[0] / parts[1] : nil
    }

    func videoCodecArgs(_ o: Int, _ v: MediaTrack, _ s: ConvertSettings, pass: Int, passLog: String) -> [String] {
        var a: [String]
        let tenBitHEVC = s.videoCodec.isHEVC && v.isTenBit
        switch s.videoCodec {
        case .passthrough:
            return []
        case .x264:
            a = ["-c:\(o)", "libx264", "-preset:\(o)", s.encoderPreset, "-crf:\(o)", "\(s.crf)"]
        case .x264TwoPass:
            a = ["-c:\(o)", "libx264", "-preset:\(o)", s.encoderPreset, "-b:\(o)", "\(s.videoBitrateKbps)k",
                 "-pass:\(o)", "\(pass)", "-passlogfile:\(o)", passLog]
        case .x265:
            a = ["-c:\(o)", "libx265", "-preset:\(o)", s.encoderPreset, "-crf:\(o)", "\(s.crf)", "-tag:\(o)", "hvc1",
                 "-x265-params:\(o)", "log-level=error"]
        case .handBrakeAppleTV4K:
            // Video settings of HandBrake's "Apple 2160p60 4K HEVC Surround" preset.
            a = ["-c:\(o)", "libx265", "-preset:\(o)", "slow", "-crf:\(o)", "24", "-profile:\(o)", "main10", "-tag:\(o)", "hvc1",
                 "-x265-params:\(o)", Self.handBrakeX265Params + ":log-level=error"]
            return a
        case .h264Hardware:
            a = ["-c:\(o)", "h264_videotoolbox", "-q:\(o)", "\(s.hardwareQuality)"]
        case .hevcHardware:
            a = ["-c:\(o)", "hevc_videotoolbox", "-q:\(o)", "\(s.hardwareQuality)", "-tag:\(o)", "hvc1"]
        }
        if tenBitHEVC { a += ["-profile:\(o)", "main10"] }
        if !s.videoCodec.isHEVC, let profile = s.device.h264Profile {
            a += ["-profile:\(o)", profile]
            if s.videoCodec != .h264Hardware, let level = s.device.h264Level { a += ["-level:\(o)", level] }
        }
        return a
    }

    static let handBrakeX265Params = "strong-intra-smoothing=0:rect=0:aq-mode=1:rd=4:psy-rd=0.75:psy-rdoq=4.0:rdoq-level=1:rskip=2"

    func pixelFormat(for v: MediaTrack, codec: VideoCodecChoice) -> String {
        switch codec {
        case .handBrakeAppleTV4K: return "yuv420p10le"
        case .x265: return v.isTenBit ? "yuv420p10le" : "yuv420p"
        case .hevcHardware: return v.isTenBit ? "p010le" : "nv12"
        case .h264Hardware: return "nv12"
        default: return "yuv420p"
        }
    }

    /// The iTunes HD flag: 1 = 720p, 2 = 1080p, 3 = 4K.
    func hdVideoFlag(for v: MediaTrack, settings s: ConvertSettings) -> Int? {
        guard var width = v.width else { return nil }
        if s.videoCodec.reencodes, let maxW = s.effectiveMaxWidth { width = min(width, maxW) }
        switch width {
        case 3000...: return 3
        case 1900...: return 2
        case 1260...: return 1
        default: return nil
        }
    }

    func trackMetadata(_ o: Int, language: String, title: String, isMP4: Bool) -> [String] {
        var a = ["-metadata:s:\(o)", "language=\(language)", "-metadata:s:\(o)", "title=\(title)"]
        if isMP4 && !title.isEmpty { a += ["-metadata:s:\(o)", "handler_name=\(title)"] }
        return a
    }
}

func seconds(_ value: Double) -> String { String(format: "%.3f", value) }

/// Escapes a value for use inside a filter option in a filtergraph (two levels of escaping).
func filterEscape(_ value: String) -> String {
    var level1 = ""
    for c in value {
        if c == "\\" || c == "'" || c == ":" { level1.append("\\") }
        level1.append(c)
    }
    var level2 = ""
    for c in level1 {
        if "\\'[],;".contains(c) { level2.append("\\") }
        level2.append(c)
    }
    return level2
}
