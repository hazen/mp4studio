import Foundation

// MARK: - Edit tracks (no re-encoding)

public struct EditRequest: Sendable {
    /// The file being edited. Track language/title/default/forced reflect the desired result.
    public var main: MediaFile
    /// Files whose tracks are added. Track input indexes must be 1, 2, ...
    public var added: [MediaFile]
    /// Track IDs (MediaTrack.id) to keep, across the main file and added files.
    public var keptTrackIDs: Set<String>
    public var squarePixels: Bool
    public var outputURL: URL

    public init(main: MediaFile, added: [MediaFile] = [], keptTrackIDs: Set<String>, squarePixels: Bool = false, outputURL: URL) {
        self.main = main
        self.added = added
        self.keptTrackIDs = keptTrackIDs
        self.squarePixels = squarePixels
        self.outputURL = outputURL
    }
}

public struct EditBuilder {
    public let tools: ToolPaths
    /// The file as it was probed, used to emit only the changes MP4Box needs.
    public let original: MediaFile

    public init(tools: ToolPaths, original: MediaFile) {
        self.tools = tools
        self.original = original
    }

    public func plan(_ r: EditRequest) throws -> JobPlan {
        let kept = (r.main.tracks + r.added.flatMap(\.tracks)).filter { r.keptTrackIDs.contains($0.id) && $0.kind != .attachment }
        guard !kept.isEmpty else { throw ToolError.invalid("Keep at least one track.") }
        let step: JobStep
        switch r.main.container {
        case .mp4: step = try mp4Box(r)
        case .mkv: step = try mkvmerge(r)
        case .other:
            throw ToolError.invalid("Edit Tracks works with MP4, M4V and MKV files. Use Convert to remux \(r.main.url.pathExtension.uppercased()) files.")
        }
        return JobPlan(title: "Edit \(r.main.name)", steps: [step], outputs: [r.outputURL],
                       outputFolder: r.outputURL.deletingLastPathComponent())
    }

    func mp4Box(_ r: EditRequest) throws -> JobStep {
        let exe = try tools.require(.mp4box)
        var args: [String] = []
        let before = Dictionary(uniqueKeysWithValues: original.tracks.map { ($0.streamIndex, $0) })
        for t in r.main.tracks {
            guard let tid = t.containerTrackID else { continue }
            if !r.keptTrackIDs.contains(t.id) { args += ["-rem", "\(tid)"]; continue }
            let old = before[t.streamIndex]
            if old?.language != t.language { args += ["-lang", "\(tid)=\(t.language)"] }
            if old?.title != t.title { args += ["-name", "\(tid)=\(t.title)"] }
            if old?.isDefault != t.isDefault { args += [t.isDefault ? "-enable" : "-disable", "\(tid)"] }
            // "w1:1" rewrites the H.264/HEVC bitstream too; players read the aspect ratio from there.
            if r.squarePixels && t.kind == .video && t.isAnamorphic { args += ["-par", "\(tid)=w1:1"] }
        }
        for file in r.added {
            let tracks = file.tracks.filter { $0.kind != .attachment && $0.kind != .data }
            let keep = tracks.filter { r.keptTrackIDs.contains($0.id) }
            if keep.isEmpty { continue }
            for t in keep {
                var source = file.url.path
                if tracks.count > 1 {
                    guard file.container == .mp4, let tid = t.containerTrackID else {
                        throw ToolError.invalid("MP4Box can only take individual tracks from MP4 files. Add \(file.name) through Convert instead.")
                    }
                    source += "#trackID=\(tid)"
                }
                if t.isBitmapSubtitle && t.codec != "dvd_subtitle" {
                    throw ToolError.invalid("\(t.codecLabel) subtitles from \(file.name) can't be stored in MP4.")
                }
                source += ":lang=\(t.language)"
                if !t.title.isEmpty { source += ":name=\(t.title.replacingOccurrences(of: ":", with: " "))" }
                if !t.isDefault && t.kind == .subtitle { source += ":disable" }
                args += ["-add", source]
            }
        }
        args += [r.main.url.path, "-out", r.outputURL.path]
        return JobStep(label: "Editing with MP4Box", tool: .mp4box, executable: exe, arguments: args, progress: .mp4box)
    }

    func mkvmerge(_ r: EditRequest) throws -> JobStep {
        let exe = try tools.require(.mkvmerge)
        var args = ["--gui-mode", "-o", r.outputURL.path]
        for file in [r.main] + r.added {
            args += MKVMergeOptions.trackOptions(for: file, kept: r.keptTrackIDs, squarePixels: r.squarePixels)
            args.append(file.url.path)
        }
        return JobStep(label: "Editing with mkvmerge", tool: .mkvmerge, executable: exe, arguments: args, progress: .mkvtoolnix)
    }
}

enum MKVMergeOptions {
    /// Per-file options. mkvmerge track IDs match ffprobe stream indexes for the tracks it reads.
    static func trackOptions(for file: MediaFile, kept: Set<String>, squarePixels: Bool) -> [String] {
        var args: [String] = []
        let selectable = file.tracks.filter { $0.kind == .video || $0.kind == .audio || $0.kind == .subtitle }
        for (kind, keepFlag, dropFlag) in [(TrackKind.video, "-d", "-D"), (.audio, "-a", "-A"), (.subtitle, "-s", "-S")] {
            let all = selectable.filter { $0.kind == kind }
            let keep = all.filter { kept.contains($0.id) }
            if all.isEmpty || keep.count == all.count { continue }
            args += keep.isEmpty ? [dropFlag] : [keepFlag, keep.map { "\($0.streamIndex)" }.joined(separator: ",")]
        }
        for t in selectable where kept.contains(t.id) {
            let id = t.streamIndex
            args += ["--language", "\(id):\(t.language)", "--track-name", "\(id):\(t.title)",
                     "--default-track-flag", "\(id):\(t.isDefault ? 1 : 0)"]
            if t.kind == .subtitle { args += ["--forced-display-flag", "\(id):\(t.isForced ? 1 : 0)"] }
            if squarePixels, t.kind == .video, t.isAnamorphic, let w = t.width, let h = t.height {
                args += ["--display-dimensions", "\(id):\(w)x\(h)"]
            }
        }
        return args
    }
}

// MARK: - Extract tracks

public struct ExtractBuilder {
    public let tools: ToolPaths
    public init(tools: ToolPaths) { self.tools = tools }

    /// With `ocrTemporaryDirectory` set, PGS and VobSub tracks are read with text recognition and saved as SRT.
    public func plan(file: MediaFile, trackIDs: Set<String>, outputFolder: URL, ocrTemporaryDirectory: URL? = nil) throws -> JobPlan {
        var tracks = file.tracks.filter { trackIDs.contains($0.id) }
        guard !tracks.isEmpty else { throw ToolError.invalid("Select the tracks to extract.") }
        let base = file.url.deletingPathExtension().lastPathComponent
        var reserved = Set<URL>()
        var steps: [JobStep] = []
        var urls: [URL] = []
        var temporaryFiles: [URL] = []
        if let temp = ocrTemporaryDirectory {
            let ocrTracks = tracks.filter { SubtitleOCR.supportedCodecs.contains($0.codec) }
            tracks.removeAll { SubtitleOCR.supportedCodecs.contains($0.codec) }
            for t in ocrTracks {
                let lang = t.language == "und" ? "" : ".\(t.language)"
                let url = uniqueURL(in: outputFolder, baseName: "\(base).track\(t.streamIndex)\(lang)", extension: "srt", reserved: reserved)
                reserved.insert(url)
                let ocr = try SubtitleOCRBuilder(tools: tools).steps(file: file, track: t, output: url, temporaryDirectory: temp)
                steps += ocr.steps
                temporaryFiles += ocr.temporaryFiles
                urls.append(url)
            }
        }
        guard !tracks.isEmpty else {
            return JobPlan(title: "Extract from \(file.name)", steps: steps, outputs: urls, outputFolder: outputFolder, temporaryFiles: temporaryFiles)
        }
        var outputs: [(MediaTrack, URL)] = []
        let useMKVExtract = file.container == .mkv && tools.url(for: .mkvextract) != nil
        for t in tracks {
            let ext = useMKVExtract ? Self.mkvextractExtension(t) : Self.ffmpegExtension(t)
            let lang = t.language == "und" ? "" : ".\(t.language)"
            let url = uniqueURL(in: outputFolder, baseName: "\(base).track\(t.streamIndex)\(lang)", extension: ext, reserved: reserved)
            reserved.insert(url)
            outputs.append((t, url))
        }

        let step: JobStep
        if useMKVExtract {
            let exe = try tools.require(.mkvextract)
            var args = ["--gui-mode", file.url.path, "tracks"]
            args += outputs.map { "\($0.0.streamIndex):\($0.1.path)" }
            step = JobStep(label: "Extracting with mkvextract", tool: .mkvextract, executable: exe, arguments: args, progress: .mkvtoolnix)
        } else {
            let exe = try tools.require(.ffmpeg)
            var args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "warning", "-progress", "pipe:1", "-nostats", "-i", file.url.path]
            for (t, url) in outputs {
                args += ["-map", "0:\(t.streamIndex)", "-c", t.codec == "mov_text" ? "srt" : "copy"]
                if let format = Self.ffmpegFormat(t) { args += ["-f", format] }
                args.append(url.path)
            }
            step = JobStep(label: "Extracting with ffmpeg", tool: .ffmpeg, executable: exe, arguments: args,
                           progress: .ffmpeg(totalSeconds: file.duration))
        }
        urls += outputs.map(\.1)
        // VobSub extraction writes an .idx plus a matching .sub.
        urls += outputs.filter { $0.1.pathExtension == "idx" }.map { $0.1.deletingPathExtension().appendingPathExtension("sub") }
        return JobPlan(title: "Extract from \(file.name)", steps: [step] + steps, outputs: urls, outputFolder: outputFolder,
                       temporaryFiles: temporaryFiles)
    }

    static func mkvextractExtension(_ t: MediaTrack) -> String {
        switch t.codec {
        case "h264": return "h264"
        case "hevc": return "h265"
        case "av1": return "obu"
        case "vp8", "vp9": return "ivf"
        case "mpeg2video": return "m2v"
        case "aac": return "aac"
        case "ac3": return "ac3"
        case "eac3": return "eac3"
        case "dts": return "dts"
        case "truehd": return "thd"
        case "flac": return "flac"
        case "opus", "vorbis": return "ogg"
        case "mp3": return "mp3"
        case let c where c.hasPrefix("pcm_"): return "wav"
        case "subrip": return "srt"
        case "ass": return "ass"
        case "ssa": return "ssa"
        case "webvtt": return "vtt"
        case "hdmv_pgs_subtitle": return "sup"
        case "dvd_subtitle": return "idx"
        default: return t.kind == .video ? "mkv" : t.kind == .audio ? "mka" : "mks"
        }
    }

    static func ffmpegExtension(_ t: MediaTrack) -> String {
        switch t.codec {
        case "h264": return "h264"
        case "hevc": return "h265"
        case "aac": return "m4a"
        case "ac3": return "ac3"
        case "eac3": return "eac3"
        case "dts": return "dts"
        case "truehd": return "thd"
        case "flac": return "flac"
        case "mp3": return "mp3"
        case "alac": return "m4a"
        case "opus": return "opus"
        case let c where c.hasPrefix("pcm_"): return "wav"
        case "subrip", "mov_text", "text": return "srt"
        case "ass", "ssa": return "ass"
        case "webvtt": return "vtt"
        case "hdmv_pgs_subtitle": return "sup"
        default: return t.kind == .video ? "mkv" : t.kind == .audio ? "mka" : "mks"
        }
    }

    static func ffmpegFormat(_ t: MediaTrack) -> String? {
        switch ffmpegExtension(t) {
        case "mkv", "mka", "mks": return "matroska"
        case "m4a": return "ipod"
        case "thd": return "truehd"
        case "h265": return "hevc"
        default: return nil
        }
    }
}

// MARK: - Subtitle OCR

/// Image subtitles to SRT: copy the track out as .sup or .idx/.sub if needed, then run the OCR helper on it.
public struct SubtitleOCRBuilder {
    public let tools: ToolPaths
    public init(tools: ToolPaths) { self.tools = tools }

    public func steps(file: MediaFile, track t: MediaTrack, output: URL, temporaryDirectory: URL) throws -> (steps: [JobStep], temporaryFiles: [URL]) {
        guard SubtitleOCR.supportedCodecs.contains(t.codec) else {
            throw ToolError.invalid("\(t.codecLabel) subtitles can't be read as text. Text recognition works with PGS and VobSub.")
        }
        let helper = try tools.require(.subtitleOCR)
        let ext = file.url.pathExtension.lowercased()
        let stem = temporaryDirectory.appendingPathComponent("ocr-\(UUID().uuidString)")
        var steps: [JobStep] = []
        var temporaryFiles: [URL] = []
        let source: URL

        if t.codec == "hdmv_pgs_subtitle" {
            if ext == "sup" {
                source = file.url
            } else {
                source = stem.appendingPathExtension("sup")
                temporaryFiles.append(source)
                steps.append(JobStep(label: "Copying PGS subtitles", tool: .ffmpeg, executable: try tools.require(.ffmpeg),
                                     arguments: ["-hide_banner", "-nostdin", "-y", "-loglevel", "warning", "-progress", "pipe:1", "-nostats",
                                                 "-i", file.url.path, "-map", "0:\(t.streamIndex)", "-c", "copy", "-f", "sup", source.path],
                                     progress: .ffmpeg(totalSeconds: file.duration)))
            }
        } else if ext == "idx" {
            source = file.url
        } else {
            // Only mkvextract writes .idx/.sub, so VobSub from other containers goes through a Matroska copy first.
            let mkvextract = try tools.require(.mkvextract)
            var mkv = file.url, trackID = t.streamIndex
            if file.container != .mkv {
                mkv = stem.appendingPathExtension("mks")
                trackID = 0
                temporaryFiles.append(mkv)
                steps.append(JobStep(label: "Copying VobSub subtitles", tool: .ffmpeg, executable: try tools.require(.ffmpeg),
                                     arguments: ["-hide_banner", "-nostdin", "-y", "-loglevel", "warning", "-progress", "pipe:1", "-nostats",
                                                 "-i", file.url.path, "-map", "0:\(t.streamIndex)", "-c", "copy", "-f", "matroska", mkv.path],
                                     progress: .ffmpeg(totalSeconds: file.duration)))
            }
            source = stem.appendingPathExtension("idx")
            temporaryFiles += [source, stem.appendingPathExtension("sub")]
            steps.append(JobStep(label: "Extracting VobSub subtitles", tool: .mkvextract, executable: mkvextract,
                                 arguments: ["--gui-mode", mkv.path, "tracks", "\(trackID):\(source.path)"], progress: .mkvtoolnix))
        }
        // The helper reports progress in mkvtoolnix's --gui-mode format.
        steps.append(JobStep(label: "Recognizing subtitle text", tool: .subtitleOCR, executable: helper,
                             arguments: [source.path, output.path, t.language], progress: .mkvtoolnix))
        return (steps, temporaryFiles)
    }
}

// MARK: - Split

public enum SplitMode: Sendable, Equatable {
    case bySize(megabytes: Int)
    case byDuration(seconds: Double)
    case segment(start: Double, end: Double)
}

public struct SplitBuilder {
    public let tools: ToolPaths
    public init(tools: ToolPaths) { self.tools = tools }

    public func plan(file: MediaFile, mode: SplitMode, outputFolder: URL) throws -> JobPlan {
        if case .segment(let s, let e) = mode, e <= s { throw ToolError.invalid("The end time must be after the start time.") }
        if case .bySize(let mb) = mode, mb <= 0 { throw ToolError.invalid("Enter a part size in megabytes.") }
        if case .byDuration(let d) = mode, d <= 0 { throw ToolError.invalid("Enter a part length.") }
        let base = file.url.deletingPathExtension().lastPathComponent
        let step: JobStep
        var outputs: [URL] = []

        switch (file.container, mode) {
        // MP4Box's -split/-splits silently stop early on files with sparse subtitle tracks, so MP4 uses ffmpeg's segmenter.
        case (.mp4, .bySize), (.mp4, .byDuration):
            let exe = try tools.require(.ffmpeg)
            var partSeconds: Double
            if case .bySize(let mb) = mode {
                let bitsPerSecond = Double(file.bitRate ?? 0) > 0 ? Double(file.bitRate!)
                    : Double(file.size ?? 0) * 8 / max(file.duration, 1)
                guard bitsPerSecond > 0 else { throw ToolError.invalid("Couldn't work out the bitrate of \(file.name) to split it by size.") }
                // Parts end at the next keyframe, so aim a little under the requested size.
                partSeconds = Double(mb) * 8_000_000 / bitsPerSecond * 0.95
            } else if case .byDuration(let d) = mode {
                partSeconds = d
            } else { partSeconds = 0 }
            let ext = file.url.pathExtension.lowercased()
            let pattern = outputFolder.appendingPathComponent("\(base.replacingOccurrences(of: "%", with: "%%")) part %03d.\(ext)")
            step = JobStep(label: "Splitting with ffmpeg", tool: .ffmpeg, executable: exe,
                           arguments: ["-hide_banner", "-nostdin", "-y", "-loglevel", "warning", "-progress", "pipe:1", "-nostats",
                                       "-i", file.url.path, "-map", "0", "-c", "copy", "-f", "segment",
                                       "-segment_time", seconds(partSeconds), "-reset_timestamps", "1",
                                       "-segment_format", "mp4", "-segment_start_number", "1", pattern.path],
                           progress: .ffmpeg(totalSeconds: file.duration))

        case (.mkv, _), (.other, .bySize), (.other, .byDuration):
            let exe = try tools.require(.mkvmerge)
            var split: String
            var out: URL
            switch mode {
            case .bySize(let mb):
                split = "size:\(mb)M"
                out = outputFolder.appendingPathComponent("\(base) part.mkv")
            case .byDuration(let d):
                split = "duration:\(TimeCode.format(d))"
                out = outputFolder.appendingPathComponent("\(base) part.mkv")
            case .segment(let s, let e):
                split = "parts:\(TimeCode.format(s))-\(TimeCode.format(e))"
                out = uniqueURL(in: outputFolder, baseName: "\(base) segment", extension: "mkv")
                outputs = [out]
            }
            step = JobStep(label: "Splitting with mkvmerge", tool: .mkvmerge, executable: exe,
                           arguments: ["--gui-mode", "-o", out.path, "--split", split, file.url.path], progress: .mkvtoolnix)

        case (.mp4, .segment(let s, let e)), (.other, .segment(let s, let e)):
            let exe = try tools.require(.ffmpeg)
            let ext = file.url.pathExtension.isEmpty ? "mkv" : file.url.pathExtension
            let url = uniqueURL(in: outputFolder, baseName: "\(base) segment", extension: ext)
            outputs = [url]
            step = JobStep(label: "Cutting with ffmpeg", tool: .ffmpeg, executable: exe,
                           arguments: ["-hide_banner", "-nostdin", "-y", "-loglevel", "warning", "-progress", "pipe:1", "-nostats",
                                       "-ss", seconds(s), "-to", seconds(e), "-i", file.url.path, "-map", "0", "-c", "copy", url.path],
                           progress: .ffmpeg(totalSeconds: e - s))
        }
        return JobPlan(title: "Split \(file.name)", steps: [step], outputs: outputs, outputFolder: outputFolder)
    }
}

// MARK: - Join

public struct JoinBuilder {
    public let tools: ToolPaths
    public init(tools: ToolPaths) { self.tools = tools }

    public func plan(files: [MediaFile], outputURL: URL, temporaryDirectory: URL) throws -> JobPlan {
        guard files.count >= 2 else { throw ToolError.invalid("Add at least two files to join.") }
        let kinds = Set(files.map(\.container))
        let outKind = ContainerKind.of(outputURL)
        var temporaryFiles: [URL] = []
        let step: JobStep

        if kinds == [.mp4] && outKind == .mp4 {
            let exe = try tools.require(.mp4box)
            var args = ["-add", files[0].url.path]
            for f in files.dropFirst() { args += ["-cat", f.url.path] }
            args += ["-new", outputURL.path]
            step = JobStep(label: "Joining with MP4Box", tool: .mp4box, executable: exe, arguments: args, progress: .mp4box)
        } else if outKind == .mkv && !kinds.contains(.other) {
            let exe = try tools.require(.mkvmerge)
            // Track mode appends each track after its own end, so a subtitle that runs long doesn't push the video later.
            var args = ["--gui-mode", "-o", outputURL.path, "--append-mode", "track", files[0].url.path]
            for f in files.dropFirst() { args += ["+", f.url.path] }
            step = JobStep(label: "Joining with mkvmerge", tool: .mkvmerge, executable: exe, arguments: args, progress: .mkvtoolnix)
        } else {
            let exe = try tools.require(.ffmpeg)
            let list = temporaryDirectory.appendingPathComponent("join-\(UUID().uuidString).txt")
            let body = files.map { "file '" + $0.url.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: "\n") + "\n"
            try body.write(to: list, atomically: true, encoding: .utf8)
            temporaryFiles.append(list)
            var args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "warning", "-progress", "pipe:1", "-nostats",
                        "-f", "concat", "-safe", "0", "-i", list.path, "-map", "0", "-c", "copy"]
            if outKind == .mp4 { args += ["-movflags", "+faststart", "-f", "mp4"] }
            args.append(outputURL.path)
            step = JobStep(label: "Joining with ffmpeg", tool: .ffmpeg, executable: exe, arguments: args,
                           progress: .ffmpeg(totalSeconds: files.reduce(0) { $0 + $1.duration }))
        }
        return JobPlan(title: "Join \(files.count) files", steps: [step], outputs: [outputURL],
                       outputFolder: outputURL.deletingLastPathComponent(), temporaryFiles: temporaryFiles)
    }
}

// MARK: - Metadata

public struct MetadataBuilder {
    public let tools: ToolPaths
    public init(tools: ToolPaths) { self.tools = tools }

    public func read(_ url: URL) async throws -> (fields: MetadataFields, hasArtwork: Bool) {
        let exe = try tools.require(.atomicParsley)
        let result = try await ProcessRunner.run(exe, [url.path, "-t"])
        guard result.status == 0 else { throw ToolError.failed(tool: "AtomicParsley", status: result.status, message: result.stderrString) }
        return MetadataFields.parse(atomicParsleyOutput: result.stdoutString)
    }

    public func plan(file: URL, fields: MetadataFields) throws -> JobPlan {
        guard ContainerKind.of(file) == .mp4 else { throw ToolError.invalid("Metadata tagging works with MP4 and M4V files.") }
        let exe = try tools.require(.atomicParsley)
        let step = JobStep(label: "Writing metadata", tool: .atomicParsley, executable: exe,
                           arguments: [file.path] + fields.atomicParsleyArguments() + ["--overWrite"], progress: .indeterminate)
        // The file is edited in place, so it isn't listed as an output (a failure must not delete it).
        return JobPlan(title: "Tag \(file.lastPathComponent)", steps: [step], outputs: [], outputFolder: file.deletingLastPathComponent())
    }
}
