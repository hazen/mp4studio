import Foundation
import Testing
@testable import MP4StudioCore

struct UnitTests {
    @Test func timeCodes() {
        #expect(TimeCode.parse("1:02:03.5") == 3723.5)
        #expect(TimeCode.parse("02:03") == 123)
        #expect(TimeCode.parse("90") == 90)
        #expect(TimeCode.parse("") == nil)
        #expect(TimeCode.parse("a:b") == nil)
        #expect(TimeCode.format(3723.5) == "01:02:03.500")
    }

    @Test func languages() {
        #expect(Languages.normalize("fra") == "fre")
        #expect(Languages.normalize("en") == "eng")
        #expect(Languages.normalize("pt-BR") == "por")
        #expect(Languages.normalize(nil) == "und")
        let g = Languages.guess(fromFileName: URL(fileURLWithPath: "/x/Movie.2019.de.forced.srt"))
        #expect(g.language == "ger" && g.forced)
        #expect(Languages.guess(fromFileName: URL(fileURLWithPath: "/x/Movie.srt")).language == nil)
    }

    @Test func progressParsing() {
        #expect(ProgressParser.fraction(from: "out_time_us=5000000", kind: .ffmpeg(totalSeconds: 10)) == 0.5)
        #expect(ProgressParser.fraction(from: "progress=end", kind: .ffmpeg(totalSeconds: 10)) == 1)
        #expect(ProgressParser.fraction(from: "out_time_us=N/A", kind: .ffmpeg(totalSeconds: 10)) == nil)
        #expect(ProgressParser.fraction(from: "#GUI#progress 42%", kind: .mkvtoolnix) == 0.42)
        #expect(ProgressParser.fraction(from: "Splitting: |=====     | (50/100)", kind: .mp4box) == 0.5)
        #expect(ProgressParser.fraction(from: "splitting:  12.50 %", kind: .mp4box) == 0.125)
        #expect(StepRunner.stripANSI("\u{1B}[37mhello\u{1B}[0m") == "hello")
    }

    @Test func filterEscaping() {
        #expect(filterEscape("/a b/it's:x.srt") == #"/a b/it\\\'s\\:x.srt"#)
        #expect(filterEscape("/x/[a],b;c.srt") == #"/x/\[a\]\,b\;c.srt"#)
    }

    @Test func atomicParsleyParsing() {
        let text = "\u{FEFF}Atom \"©nam\" contains: My Title\nAtom \"stik\" contains: TV Show\n" +
            "Atom \"----\" [com.apple.iTunes;iTunEXTC] contains: mpaa|R|400|\n" +
            "Atom \"----\" [com.apple.iTunes;iTunMOVI] contains: <?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
            "<plist version=\"1.0\"><dict><key>cast</key><array><dict><key>name</key><string>A</string></dict>\n" +
            "<dict><key>name</key><string>B</string></dict></array></dict></plist>\n" +
            "Atom \"covr\" contains: 1 piece of artwork\n"
        let (f, art) = MetadataFields.parse(atomicParsleyOutput: text)
        #expect(f.title == "My Title" && f.kind == .tvShow && f.ratingID == "mpaa|R" && f.cast == "A, B" && art)
    }

    @Test func selectionRules() throws {
        let json = """
        {"streams":[{"index":0,"codec_type":"video","codec_name":"h264"},
         {"index":1,"codec_type":"audio","codec_name":"ac3","channels":6,"tags":{"language":"fre"}},
         {"index":2,"codec_type":"audio","codec_name":"aac","channels":2,"tags":{"language":"eng"}},
         {"index":3,"codec_type":"subtitle","codec_name":"subrip","tags":{"language":"eng"}},
         {"index":4,"codec_type":"subtitle","codec_name":"subrip","tags":{"language":"spa"}}],
         "format":{"duration":"10"}}
        """
        let file = try MediaFile.parse(ffprobeJSON: Data(json.utf8), url: URL(fileURLWithPath: "/x/a.mkv"))
        var rules = SelectionRules()
        rules.audio = .byLanguage
        rules.audioLanguages = ["eng"]
        rules.subtitles = .byLanguage
        rules.subtitleLanguages = ["ita"]
        #expect(rules.selectedTrackIDs(in: file) == ["0:0", "0:2"])
        rules.subtitleFallbackToFirst = true
        #expect(rules.selectedTrackIDs(in: file) == ["0:0", "0:2", "0:3"])
    }

    @Test func builderRejectsBadRequests() throws {
        let json = #"{"streams":[{"index":0,"codec_type":"video","codec_name":"h264","width":1920},{"index":1,"codec_type":"subtitle","codec_name":"subrip"}],"format":{"duration":"10"}}"#
        let file = try MediaFile.parse(ffprobeJSON: Data(json.utf8), url: URL(fileURLWithPath: "/x/a.mkv"))
        let tools = ToolPaths(overrides: ["ffmpeg": "/bin/sh", "AtomicParsley": "/bin/sh"])
        let out = URL(fileURLWithPath: "/tmp/o.m4v")
        var s = ConvertSettings()
        let noLibass = FFmpegCapabilities(encoders: ["libx264"], filters: ["overlay"])
        #expect(throws: ToolError.self) {
            try ConvertBuilder(tools: tools, capabilities: noLibass).plan(ConvertRequest(
                main: file, selectedTrackIDs: ["0:0"], burnTrackID: "0:1", settings: s, outputURL: out, temporaryDirectory: URL(fileURLWithPath: "/tmp")))
        }
        s.videoCodec = .x264
        #expect(throws: ToolError.self) {
            try ConvertBuilder(tools: tools, capabilities: noLibass).plan(ConvertRequest(
                main: file, selectedTrackIDs: ["0:0"], burnTrackID: "0:1", settings: s, outputURL: out, temporaryDirectory: URL(fileURLWithPath: "/tmp")))
        }
        let plan = try ConvertBuilder(tools: tools, capabilities: .full).plan(ConvertRequest(
            main: file, selectedTrackIDs: ["0:0"], burnTrackID: "0:1", settings: s, outputURL: out, temporaryDirectory: URL(fileURLWithPath: "/tmp")))
        let args = plan.steps[0].arguments
        let graph = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(graph == "[0:0]subtitles=filename=/x/a.mkv:si=0,format=yuv420p[v0]")
    }
}
