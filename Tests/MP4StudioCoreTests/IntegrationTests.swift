import Foundation
import Testing
@testable import MP4StudioCore

/// End-to-end tests that run the real tools on generated sample media.
@Suite(.serialized)
struct IntegrationTests {
    let tools = ToolPaths()
    let work: URL

    init() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("MP4StudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    var available: Bool { Tool.allCases.allSatisfy { tools.url(for: $0) != nil } }

    func probe(_ url: URL, input: Int = 0) async throws -> MediaFile {
        try await Prober(ffprobe: try tools.require(.ffprobe)).probe(url, inputIndex: input)
    }

    func run(_ plan: JobPlan) async throws {
        for step in plan.steps {
            let log = work.appendingPathComponent("test.log")
            try await StepRunner(step: step, logURL: log).run { _ in }
        }
    }

    func ffmpeg(_ args: [String]) async throws {
        let r = try await ProcessRunner.run(try tools.require(.ffmpeg), ["-hide_banner", "-loglevel", "error", "-y"] + args)
        #expect(r.status == 0, "\(r.stderrString)")
    }

    /// 720x480 anamorphic H.264, 5.1 AC3 (eng), stereo AAC (fre), SRT (eng), 10 s.
    func makeSample(_ ext: String = "mkv") async throws -> URL {
        let srt = work.appendingPathComponent("Sample.en.srt")
        try "1\n00:00:01,000 --> 00:00:03,000\nHello there\n\n2\n00:00:04,000 --> 00:00:06,000\nSecond\n".write(to: srt, atomically: true, encoding: .utf8)
        let mkv = work.appendingPathComponent("Sample.mkv")
        try await ffmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=720x480:rate=24000/1001:duration=10",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=10", "-f", "lavfi", "-i", "sine=frequency=660:duration=10", "-i", srt.path,
            "-filter_complex", "[1:a]pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0[a51]",
            "-map", "0:v", "-map", "[a51]", "-map", "2:a", "-map", "3:s",
            "-c:v", "libx264", "-preset", "ultrafast", "-g", "24", "-vf", "setsar=32/27",
            "-c:a:0", "ac3", "-b:a:0", "384k", "-c:a:1", "aac", "-c:s", "srt",
            "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=fre", "-metadata:s:s:0", "language=eng", mkv.path,
        ])
        if ext == "mkv" { return mkv }
        let mp4 = work.appendingPathComponent("Sample.\(ext)")
        try await ffmpeg(["-i", mkv.path, "-map", "0", "-c", "copy", "-c:s", "mov_text", "-f", "mp4", mp4.path])
        return mp4
    }

    func makeSidecar(_ name: String, _ body: String) throws -> URL {
        let url = work.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func probeReadsTracks() async throws {
        guard available else { return }
        let file = try await probe(try await makeSample())
        #expect(file.tracks.map(\.kind) == [.video, .audio, .audio, .subtitle])
        #expect(file.tracks[0].isAnamorphic)
        #expect(file.tracks[1].channels == 6 && file.tracks[1].language == "eng")
        #expect(file.tracks[2].language == "fre")
        #expect(abs(file.duration - 10) < 0.2)
    }

    @Test func sidecarLanguageAndForcedFromFileName() async throws {
        guard available else { return }
        let srt = try makeSidecar("Movie.fr.forced.srt", "1\n00:00:01,000 --> 00:00:02,000\nOui\n")
        let file = try await probe(srt, input: 1)
        #expect(file.tracks[0].language == "fre")
        #expect(file.tracks[0].isForced)
        #expect(file.tracks[0].id == "1:0")
    }

    @Test func remuxToM4VWithStereoAddedAndMetadata() async throws {
        guard available else { return }
        let main = try await probe(try await makeSample())
        let extra = try await probe(try makeSidecar("Sample.fr.forced.srt", "1\n00:00:02,000 --> 00:00:04,000\nForcé\n"), input: 1)
        var settings = ConvertSettings()
        settings.container = .m4v
        var meta = MetadataFields()
        meta.title = "Sample Movie"
        meta.year = "2019"
        meta.cast = "Jane Doe, John Roe"
        meta.ratingID = "mpaa|PG-13"
        let out = work.appendingPathComponent("out.m4v")
        let caps = await FFmpegCapabilities.detect(ffmpeg: try tools.require(.ffmpeg))
        let plan = try ConvertBuilder(tools: tools, capabilities: caps).plan(ConvertRequest(
            main: main, extras: [extra], selectedTrackIDs: Set((main.tracks + extra.tracks).map(\.id)),
            settings: settings, metadata: meta, outputURL: out, temporaryDirectory: work))
        try await run(plan)

        let result = try await probe(out)
        #expect(result.tracks.map(\.codec) == ["h264", "aac", "ac3", "aac", "mov_text", "mov_text"])
        #expect(result.tracks[1].channels == 2 && result.tracks[2].channels == 6)
        #expect(result.tracks[1].isDefault && !result.tracks[2].isDefault)
        #expect(result.tracks[5].language == "fre" && result.tracks[5].isForced)

        let read = try await MetadataBuilder(tools: tools).read(out)
        #expect(read.fields.title == "Sample Movie")
        #expect(read.fields.year == "2019")
        #expect(read.fields.cast == "Jane Doe, John Roe")
        #expect(read.fields.ratingID == "mpaa|PG-13")
    }

    @Test func x264TwoPassSegmentSquarePixelsScaled() async throws {
        guard available else { return }
        let main = try await probe(try await makeSample())
        var s = ConvertSettings()
        s.container = .mp4
        s.videoCodec = .x264TwoPass
        s.videoBitrateKbps = 800
        s.encoderPreset = "ultrafast"
        s.squarePixels = true
        s.maxWidth = 640
        s.stereoAction = .aac
        s.surroundAction = .aacStereo
        s.addStereoVersion = false
        let out = work.appendingPathComponent("twopass.mp4")
        let plan = try ConvertBuilder(tools: tools, capabilities: .full).plan(ConvertRequest(
            main: main, selectedTrackIDs: Set(main.tracks.map(\.id)), segmentStart: 2, segmentEnd: 6,
            settings: s, outputURL: out, temporaryDirectory: work))
        #expect(plan.steps.count == 2)
        try await run(plan)
        let r = try await probe(out)
        #expect(abs(r.duration - 4) < 0.3)
        let v = r.tracks[0]
        #expect(v.width == 640 && !v.isAnamorphic)
        #expect(r.tracks.filter { $0.kind == .audio }.allSatisfy { $0.codec == "aac" && ($0.channels ?? 0) <= 2 })
    }

    @Test func hevcHardwareTenBitWithDTSFallback() async throws {
        guard available else { return }
        let src = work.appendingPathComponent("dts.mkv")
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=24:duration=3", "-f", "lavfi", "-i", "sine=duration=3",
                          "-filter_complex", "[1:a]pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0[a]", "-map", "0:v", "-map", "[a]",
                          "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p10le", "-c:a", "dca", "-strict", "-2", src.path])
        let main = try await probe(src)
        var s = ConvertSettings()
        s.videoCodec = .hevcHardware
        s.device = .appleTVHD
        s.surroundAction = .passthrough
        s.addStereoVersion = false
        let out = work.appendingPathComponent("hevc.m4v")
        let plan = try ConvertBuilder(tools: tools, capabilities: .full).plan(ConvertRequest(
            main: main, selectedTrackIDs: Set(main.tracks.map(\.id)), settings: s, outputURL: out, temporaryDirectory: work))
        #expect(plan.warnings.contains { $0.contains("AC3") })
        try await run(plan)
        let r = try await probe(out)
        #expect(r.tracks[0].codec == "hevc" && r.tracks[0].isTenBit)
        #expect(r.tracks[1].codec == "ac3")
    }

    /// HandBrake's Apple TV 4K video settings: 10-bit HEVC capped at 60 fps, with stereo AAC copied and no AC3 added.
    @Test func handBrakeAppleTV4KWithStereoAAC() async throws {
        guard available else { return }
        let src = work.appendingPathComponent("hb.mkv")
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=120:duration=1", "-f", "lavfi", "-i", "sine=duration=1",
                          "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-ac", "2", src.path])
        let main = try await probe(src)
        var s = ConvertSettings()
        s.videoCodec = .handBrakeAppleTV4K
        let out = work.appendingPathComponent("hb.m4v")
        let plan = try ConvertBuilder(tools: tools, capabilities: .full).plan(ConvertRequest(
            main: main, selectedTrackIDs: Set(main.tracks.map(\.id)), settings: s, outputURL: out, temporaryDirectory: work))
        try await run(plan)
        let r = try await probe(out)
        #expect(r.tracks.map(\.codec) == ["hevc", "aac"])
        #expect(r.tracks[0].isTenBit && r.tracks[0].width == 640)
        #expect(abs((r.tracks[0].frameRate ?? 0) - 60) < 0.5)
    }

    /// The default (Apple TV) settings turn TrueHD into E-AC3 plus an AAC stereo version, keeping the video as is.
    /// (ffmpeg only encodes TrueHD up to 5.1; the 7.1 downmix is covered by the unit tests.)
    @Test func defaultsConvertTrueHDToEAC3() async throws {
        guard available else { return }
        let src = work.appendingPathComponent("truehd.mkv")
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=24:duration=3",
                          "-f", "lavfi", "-i", "sine=duration=3,aformat=channel_layouts=5.1",
                          "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "truehd", "-strict", "-2", src.path])
        let main = try await probe(src)
        #expect(main.tracks[1].codec == "truehd" && main.tracks[1].channels == 6)
        let out = work.appendingPathComponent("truehd.m4v")
        let plan = try ConvertBuilder(tools: tools, capabilities: .full).plan(ConvertRequest(
            main: main, selectedTrackIDs: Set(main.tracks.map(\.id)), settings: ConvertSettings(), outputURL: out, temporaryDirectory: work))
        try await run(plan)
        let r = try await probe(out)
        #expect(r.tracks.map(\.codec) == ["h264", "aac", "eac3"])
        #expect(r.tracks[1].channels == 2 && r.tracks[2].channels == 6)
        #expect(r.tracks[1].isDefault && !r.tracks[2].isDefault)
    }

    @Test func editMP4WithMP4Box() async throws {
        guard available else { return }
        let original = try await probe(try await makeSample("mp4"))
        var main = original
        main.tracks[1].language = "spa"
        main.tracks[1].title = "Spanish Dub"
        let added = try await probe(try makeSidecar("Sample.de.srt", "1\n00:00:01,000 --> 00:00:02,000\nHallo\n"), input: 1)
        var keep = Set(main.tracks.map(\.id) + added.tracks.map(\.id))
        keep.remove(main.tracks[2].id)
        let out = work.appendingPathComponent("edited.mp4")
        let plan = try EditBuilder(tools: tools, original: original).plan(EditRequest(
            main: main, added: [added], keptTrackIDs: keep, squarePixels: true, outputURL: out))
        try await run(plan)
        let r = try await probe(out)
        #expect(r.tracks.count == 4)
        #expect(r.tracks.filter { $0.kind == .audio }.count == 1)
        #expect(r.tracks[1].language == "spa" && r.tracks[1].title == "Spanish Dub")
        #expect(r.tracks.contains { $0.kind == .subtitle && $0.language == "ger" })
        #expect(!r.tracks[0].isAnamorphic)
    }

    @Test func editMKVWithMKVMerge() async throws {
        guard available else { return }
        let original = try await probe(try await makeSample())
        var main = original
        main.tracks[2].title = "Français"
        main.tracks[2].isDefault = true
        main.tracks[1].isDefault = false
        let added = try await probe(try makeSidecar("Sample.fr.forced.srt", "1\n00:00:01,000 --> 00:00:02,000\nOui\n"), input: 1)
        var keep = Set(main.tracks.map(\.id) + added.tracks.map(\.id))
        keep.remove(main.tracks[3].id)
        let out = work.appendingPathComponent("edited.mkv")
        try await run(try EditBuilder(tools: tools, original: original).plan(EditRequest(
            main: main, added: [added], keptTrackIDs: keep, outputURL: out)))
        let r = try await probe(out)
        #expect(r.tracks.map(\.kind) == [.video, .audio, .audio, .subtitle])
        #expect(r.tracks[2].title == "Français" && r.tracks[2].isDefault && !r.tracks[1].isDefault)
        #expect(r.tracks[3].language == "fre" && r.tracks[3].isForced)
    }

    @Test func extractFromMKVAndMP4() async throws {
        guard available else { return }
        let mkv = try await probe(try await makeSample())
        let dir1 = work.appendingPathComponent("x1")
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        let plan1 = try ExtractBuilder(tools: tools).plan(file: mkv, trackIDs: Set(mkv.tracks.dropFirst().map(\.id)), outputFolder: dir1)
        try await run(plan1)
        #expect(plan1.outputs.map(\.pathExtension) == ["ac3", "aac", "srt"])
        #expect(plan1.outputs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        let mp4URL = work.appendingPathComponent("Sample.mp4")
        try await ffmpeg(["-i", mkv.url.path, "-map", "0", "-c", "copy", "-c:s", "mov_text", mp4URL.path])
        let mp4 = try await probe(mp4URL)
        let dir2 = work.appendingPathComponent("x2")
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        let plan2 = try ExtractBuilder(tools: tools).plan(file: mp4, trackIDs: Set(mp4.tracks.map(\.id)), outputFolder: dir2)
        try await run(plan2)
        for url in plan2.outputs {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            #expect(size > 0, "\(url.lastPathComponent)")
        }
        let srt = try String(contentsOf: plan2.outputs[3], encoding: .utf8)
        #expect(srt.contains("Hello there"))
    }

    @Test func splitAndJoin() async throws {
        guard available else { return }
        let mkv = try await probe(try await makeSample())
        let mp4URL = work.appendingPathComponent("Sample.mp4")
        try await ffmpeg(["-i", mkv.url.path, "-map", "0", "-c", "copy", "-c:s", "mov_text", mp4URL.path])
        let mp4 = try await probe(mp4URL)
        let dir = work.appendingPathComponent("split")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try await run(try SplitBuilder(tools: tools).plan(file: mkv, mode: .byDuration(seconds: 4), outputFolder: dir))
        let mkvParts = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mkv" }.sorted { $0.path < $1.path }
        #expect(mkvParts.count == 3)

        try await run(try SplitBuilder(tools: tools).plan(file: mp4, mode: .byDuration(seconds: 4), outputFolder: dir))
        let mp4Parts = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mp4" }.sorted { $0.path < $1.path }
        #expect(mp4Parts.count >= 2)

        let sizeDir = work.appendingPathComponent("bysize")
        try FileManager.default.createDirectory(at: sizeDir, withIntermediateDirectories: true)
        let mb = max(1, Int((mp4.size ?? 0) / 3_000_000))
        try await run(try SplitBuilder(tools: tools).plan(file: mp4, mode: .bySize(megabytes: mb), outputFolder: sizeDir))
        #expect(try FileManager.default.contentsOfDirectory(atPath: sizeDir.path).count >= 2)

        let seg = try SplitBuilder(tools: tools).plan(file: mp4, mode: .segment(start: 2, end: 7), outputFolder: dir)
        try await run(seg)
        let segFile = try await probe(seg.outputs[0])
        #expect(abs(segFile.duration - 5) < 1.1)

        var parts: [MediaFile] = []
        for p in mkvParts { parts.append(try await probe(p)) }
        let joined = work.appendingPathComponent("joined.mkv")
        try await run(try JoinBuilder(tools: tools).plan(files: parts, outputURL: joined, temporaryDirectory: work))
        #expect(try await videoFrames(joined) == 240)

        var mp4s: [MediaFile] = []
        for p in mp4Parts { mp4s.append(try await probe(p)) }
        let joinedMP4 = work.appendingPathComponent("joined.mp4")
        try await run(try JoinBuilder(tools: tools).plan(files: mp4s, outputURL: joinedMP4, temporaryDirectory: work))
        let mp4Frames = try await videoFrames(joinedMP4)
        #expect(mp4Frames == 240)
    }

    /// 10 s at 23.976 fps = 240 frames.
    /// Uses the MP4 sample count when present (packet counts are skewed by MP4Box's edit lists), else counts MKV packets.
    func videoFrames(_ url: URL) async throws -> Int {
        let ffprobe = try tools.require(.ffprobe)
        let stored = try await ProcessRunner.run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=nb_frames",
                                                           "-of", "csv=p=0", url.path])
        if let n = Int(stored.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) { return n }
        let r = try await ProcessRunner.run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-count_packets",
                                                      "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", url.path])
        return Int(r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    @Test func metadataTagAndClear() async throws {
        guard available else { return }
        let mp4 = try await makeSample("m4v")
        let art = work.appendingPathComponent("art.jpg")
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=300x450", "-frames:v", "1", art.path])
        var f = MetadataFields()
        f.kind = .tvShow
        f.title = "Pilot"
        f.tvShow = "Show"
        f.tvSeason = "1"
        f.tvEpisodeNumber = "1"
        f.directors = "A. Director"
        f.artworkPath = art.path
        let mb = MetadataBuilder(tools: tools)
        try await run(try mb.plan(file: mp4, fields: f))
        var read = try await mb.read(mp4)
        #expect(read.hasArtwork)
        #expect(read.fields.kind == .tvShow && read.fields.tvShow == "Show" && read.fields.directors == "A. Director")

        f = read.fields
        f.tvShow = ""
        f.directors = ""
        f.removeArtwork = true
        try await run(try mb.plan(file: mp4, fields: f))
        read = try await mb.read(mp4)
        #expect(!read.hasArtwork && read.fields.tvShow.isEmpty && read.fields.directors.isEmpty && read.fields.title == "Pilot")
    }
}
