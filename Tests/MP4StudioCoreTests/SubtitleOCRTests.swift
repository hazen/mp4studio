import Foundation
import Testing
@testable import MP4StudioCore

@Suite(.serialized)
struct SubtitleOCRTests {
    let tools: ToolPaths
    let work: URL
    let cues = [
        SubtitleFixtures.Cue(start: 1.0, end: 3.5, text: "Hello there"),
        SubtitleFixtures.Cue(start: 4.25, end: 6.0, text: "Where are you going?"),
        SubtitleFixtures.Cue(start: 7.0, end: 9.0, text: "I don't know.\nMaybe home."),
    ]

    init() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("MP4StudioOCRTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // `swift test` builds the helper along with the tests.
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/mp4studio-ocr")
        tools = ToolPaths(overrides: [Tool.subtitleOCR.rawValue: helper.path])
    }

    /// VobSub stop times are in 1024/90000 s steps. Through MP4 each subtitle lasts until the next, so only starts are checked.
    func expectCues(_ srt: String, endTolerance: Double? = 0) {
        let blocks = srt.components(separatedBy: "\n\n").map { $0.split(separator: "\n", maxSplits: 2).map(String.init) }
        #expect(blocks.count == cues.count, "\(srt)")
        for (block, cue) in zip(blocks, cues) where block.count == 3 {
            let times = block[1].components(separatedBy: " --> ")
            #expect(times.first == SubtitleOCR.timestamp(cue.start))
            if let tolerance = endTolerance, let end = times.last.flatMap(seconds) {
                #expect(abs(end - cue.end) <= tolerance + 0.0005, "\(block[1])")
            }
            #expect(block[2].trimmingCharacters(in: .newlines) == cue.text)
        }
    }

    func seconds(_ timestamp: String) -> Double? {
        let parts = timestamp.replacingOccurrences(of: ",", with: ":").split(separator: ":").compactMap { Double($0) }
        return parts.count == 4 ? parts[0] * 3600 + parts[1] * 60 + parts[2] + parts[3] / 1000 : nil
    }

    @Test func readsPGS() throws {
        let sup = work.appendingPathComponent("t.sup")
        try SubtitleFixtures.writeSUP(cues, to: sup)
        let images = try SubtitleOCR.readImages(sup)
        #expect(images.map(\.start) == cues.map(\.start))
        #expect(images.map(\.end) == cues.map(\.end))
        #expect(images.allSatisfy { $0.ink.contains(255) })
        let result = SubtitleOCR.recognize(images, language: "eng")
        expectCues(SubtitleOCR.srt(result.cues))
        #expect(result.unreadable.isEmpty)
    }

    @Test func readsVobSub() throws {
        let idx = work.appendingPathComponent("t.idx")
        try SubtitleFixtures.writeVobSub(cues, idx: idx)
        let images = try SubtitleOCR.readImages(idx)
        #expect(images.count == cues.count)
        for (image, cue) in zip(images, cues) {
            #expect(abs(image.start - cue.start) < 0.001)
            #expect(abs(image.end - cue.end) < 0.012)   // stop times are in 1024/90000 s steps
        }
        let result = SubtitleOCR.recognize(images, language: "eng")
        #expect(result.cues.map(\.text) == cues.map(\.text))
    }

    @Test func mergesFadesAndSkipsBlankImages() {
        let blank = SubtitleImage(start: 0, end: 1, width: 10, height: 10, ink: Array(repeating: 0, count: 100))
        #expect(SubtitleOCR.recognize([blank], language: nil).cues.isEmpty)
        #expect(SubtitleOCR.timestamp(3725.5) == "01:02:05,500")
        let joined = SubtitleOCR.join([(CGRect(x: 0.5, y: 0.1, width: 0.3, height: 0.2), "world"),
                                       (CGRect(x: 0.1, y: 0.12, width: 0.3, height: 0.2), "Hello"),
                                       (CGRect(x: 0.1, y: 0.6, width: 0.5, height: 0.2), "Top line")])
        #expect(joined == "Top line\nHello world")
    }

    /// Image subtitles in MKV and MP4 go through Extract with recognition on, using the real tools and helper.
    @Test func extractsAsSRT() async throws {
        guard tools.url(for: .subtitleOCR) != nil,
              [Tool.ffmpeg, .ffprobe, .mkvmerge, .mkvextract].allSatisfy({ tools.url(for: $0) != nil }) else { return }
        let sup = work.appendingPathComponent("pgs.sup"), idx = work.appendingPathComponent("vob.idx")
        try SubtitleFixtures.writeSUP(cues, to: sup)
        try SubtitleFixtures.writeVobSub(cues, idx: idx)
        // Subtitle times are relative to the start of the movie, so it needs a video track starting at 0.
        let video = work.appendingPathComponent("video.mkv")
        let ffmpeg = try tools.require(.ffmpeg)
        let encode = try await ProcessRunner.run(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=10",
                                                          "-c:v", "libx264", "-preset", "ultrafast", video.path])
        #expect(encode.status == 0, "\(encode.stderrString)")
        let mkv = work.appendingPathComponent("Movie.mkv")
        let mux = try await ProcessRunner.run(try tools.require(.mkvmerge),
                                              ["-o", mkv.path, video.path, "--language", "0:eng", sup.path, "--language", "0:eng", idx.path])
        #expect(mux.status == 0, "\(mux.stdoutString)")
        // MP4 can hold VobSub but not PGS.
        let mp4 = work.appendingPathComponent("Movie.mp4")
        let remux = try await ProcessRunner.run(ffmpeg, ["-v", "error", "-i", mkv.path, "-map", "0:0", "-map", "0:2", "-c", "copy", mp4.path])
        #expect(remux.status == 0, "\(remux.stderrString)")

        let prober = Prober(ffprobe: try tools.require(.ffprobe))
        for url in [mkv, mp4] {
            let file = try await prober.probe(url, inputIndex: 0)
            let out = work.appendingPathComponent("out-\(url.pathExtension)")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let subtitles = file.tracks.filter { $0.kind == .subtitle }
            #expect(subtitles.count == (url == mkv ? 2 : 1))
            let plan = try ExtractBuilder(tools: tools).plan(file: file, trackIDs: Set(subtitles.map(\.id)), outputFolder: out,
                                                             ocrTemporaryDirectory: work)
            #expect(plan.outputs.map(\.pathExtension) == Array(repeating: "srt", count: subtitles.count))
            for step in plan.steps {
                try await StepRunner(step: step, logURL: work.appendingPathComponent("ocr.log")).run { _ in }
            }
            for (track, output) in zip(subtitles, plan.outputs) {
                let tolerance: Double? = track.codec == "hdmv_pgs_subtitle" ? 0 : url == mkv ? 0.012 : nil
                expectCues(try String(contentsOf: output, encoding: .utf8), endTolerance: tolerance)
            }
        }
    }
}
