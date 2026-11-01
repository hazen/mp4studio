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

    @Test func mediaInfoParsing() {
        let text = """
        General
        Complete name                            : /x/a.mkv
        Format                                   : Matroska
        Overall bit rate                         : 6 553 kb/s

        Video
        ID                                       : 1
        Format profile                           : High@L4.2

        Audio #1
        Channel(s)                               : 2 channels

        Menu
        00:00:00.000                             : en:Chapter 1

        """
        let r = MediaInfoReport.parse(text)
        #expect(r.sections.map(\.title) == ["General", "Video", "Audio #1", "Menu"])
        #expect(r.sections[0].value("Overall bit rate") == "6 553 kb/s")
        #expect(r.sections[1].value("Format profile") == "High@L4.2")
        #expect(r.sections[3].fields == [.init(name: "00:00:00.000", value: "en:Chapter 1")])
    }

    @Test func tmdbParsing() throws {
        let search = #"{"results":[{"id":1,"name":"Doctor Who","first_air_date":"2005-03-26","overview":"x","poster_path":"/a.jpg"},{"id":2,"name":"No Date"}]}"#
        let results = try TMDBClient.parseSearch(Data(search.utf8), type: .tv)
        #expect(results.map(\.title) == ["Doctor Who", "No Date"])
        #expect(results[0].year == "2005" && results[1].year == nil && results[1].posterPath == nil)

        let images = #"{"posters":[{"file_path":"/fr.jpg","width":1000,"height":1500,"iso_639_1":"fr","vote_average":9},{"file_path":"/none.jpg","width":1000,"height":1500,"iso_639_1":null,"vote_average":8},{"file_path":"/en-low.jpg","width":500,"height":750,"iso_639_1":"en","vote_average":2},{"file_path":"/en-high.jpg","width":2000,"height":3000,"iso_639_1":"en","vote_average":5}]}"#
        let posters = try TMDBClient.parsePosters(Data(images.utf8), preferring: "en")
        #expect(posters.map(\.filePath) == ["/en-high.jpg", "/en-low.jpg", "/none.jpg", "/fr.jpg"])
        #expect(TMDBClient.imageURL("/a.jpg").absoluteString == "https://image.tmdb.org/t/p/w342/a.jpg")
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

    @Test func appleTVDefaultsConvertTrueHDToEAC3() throws {
        let json = """
        {"streams":[{"index":0,"codec_type":"video","codec_name":"hevc","width":3840},
         {"index":1,"codec_type":"audio","codec_name":"truehd","channels":8},
         {"index":2,"codec_type":"audio","codec_name":"ac3","channels":6},
         {"index":3,"codec_type":"audio","codec_name":"dts","channels":6}],
         "format":{"duration":"10"}}
        """
        let file = try MediaFile.parse(ffprobeJSON: Data(json.utf8), url: URL(fileURLWithPath: "/x/a.mkv"))
        let tools = ToolPaths(overrides: ["ffmpeg": "/bin/sh", "AtomicParsley": "/bin/sh"])
        let plan = try ConvertBuilder(tools: tools, capabilities: .full).plan(ConvertRequest(
            main: file, selectedTrackIDs: Set(file.tracks.map(\.id)), settings: ConvertSettings(),
            outputURL: URL(fileURLWithPath: "/tmp/o.m4v"), temporaryDirectory: URL(fileURLWithPath: "/tmp")))
        let args = plan.steps[0].arguments.joined(separator: " ")
        // Each surround track gets an AAC stereo version first: outputs 1-2 TrueHD, 3-4 AC3, 5-6 DTS.
        #expect(args.contains("-c:2 eac3 -b:2 640k -ac:2 6"))
        #expect(args.contains("-c:4 copy"))
        #expect(args.contains("-c:6 eac3 -b:6 640k"))
        #expect(args.contains("-c:1 aac_at -b:1 192k -ac:1 2"))
        #expect(Preset.builtIn[0].settings == ConvertSettings())
    }

    @Test func handBrakeAppleTV4KVideo() throws {
        let json = """
        {"streams":[{"index":0,"codec_type":"video","codec_name":"h264","width":4096,"height":2160,"pix_fmt":"yuv420p","avg_frame_rate":"120/1"},
         {"index":1,"codec_type":"audio","codec_name":"aac","channels":2}],
         "format":{"duration":"10"}}
        """
        let file = try MediaFile.parse(ffprobeJSON: Data(json.utf8), url: URL(fileURLWithPath: "/x/a.mkv"))
        let tools = ToolPaths(overrides: ["ffmpeg": "/bin/sh", "AtomicParsley": "/bin/sh"])
        var s = ConvertSettings()
        s.videoCodec = .handBrakeAppleTV4K
        s.device = .any
        let plan = try ConvertBuilder(tools: tools, capabilities: .full).plan(ConvertRequest(
            main: file, selectedTrackIDs: Set(file.tracks.map(\.id)), settings: s,
            outputURL: URL(fileURLWithPath: "/tmp/o.m4v"), temporaryDirectory: URL(fileURLWithPath: "/tmp")))
        let args = plan.steps[0].arguments
        let graph = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(graph == "[0:0]bwdif=mode=send_frame:deint=interlaced,fps=60,scale='min(3840,iw)':'min(2160,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2,format=yuv420p10le[v0]")
        let joined = args.joined(separator: " ")
        #expect(plan.steps.count == 1)
        #expect(joined.contains("-c:0 libx265 -preset:0 slow -crf:0 24 -profile:0 main10 -tag:0 hvc1 -x265-params:0 strong-intra-smoothing=0:rect=0:aq-mode=1:rd=4:psy-rd=0.75:psy-rdoq=4.0:rdoq-level=1:rskip=2:log-level=error"))
        // A stereo AAC track is copied as is, with no AC3 or E-AC3 track added.
        #expect(joined.contains("-map 0:1 -c:1 copy"))
        #expect(!joined.contains("ac3"))
        #expect(args.filter { $0 == "-map" }.count == 2)
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
