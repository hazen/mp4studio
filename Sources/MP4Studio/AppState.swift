import AppKit
import MP4StudioCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum AppSection: String, CaseIterable, Identifiable {
    case convert, editTracks, extract, splitJoin, metadata, queue, watch
    var id: String { rawValue }

    var title: String {
        switch self {
        case .convert: return "Convert"
        case .editTracks: return "Edit Tracks"
        case .extract: return "Extract Tracks"
        case .splitJoin: return "Split & Join"
        case .metadata: return "Metadata"
        case .queue: return "Queue"
        case .watch: return "Watch Folder"
        }
    }

    var symbol: String {
        switch self {
        case .convert: return "arrow.triangle.2.circlepath"
        case .editTracks: return "slider.horizontal.3"
        case .extract: return "square.and.arrow.up.on.square"
        case .splitJoin: return "scissors"
        case .metadata: return "tag"
        case .queue: return "list.bullet.rectangle"
        case .watch: return "eye"
        }
    }
}

@MainActor
@Observable
final class AppState {
    var section: AppSection = .convert

    var toolPaths: ToolPaths { didSet { Defaults.save(toolPaths, "toolPaths"); refreshCapabilities() } }
    var capabilities = FFmpegCapabilities()
    var presets: [Preset] { didSet { Defaults.save(presets, "presets") } }
    var defaultPresetID: UUID? { didSet { Defaults.save(defaultPresetID, "defaultPresetID") } }
    var outputFolder: URL { didSet { UserDefaults.standard.set(outputFolder.path, forKey: "outputFolder") } }
    var keepLogs: Bool { didSet { UserDefaults.standard.set(keepLogs, forKey: "keepLogs") } }

    let queue: JobQueue
    let convert: ConvertModel
    let watch: WatchFolderModel

    let temporaryDirectory: URL
    let logsDirectory: URL

    init() {
        let defaults = UserDefaults.standard
        toolPaths = Defaults.load(ToolPaths.self, "toolPaths") ?? ToolPaths()
        presets = Defaults.load([Preset].self, "presets") ?? Preset.builtIn
        defaultPresetID = Defaults.load(UUID.self, "defaultPresetID")
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        outputFolder = defaults.string(forKey: "outputFolder").map { URL(fileURLWithPath: $0) } ?? movies
        keepLogs = defaults.object(forKey: "keepLogs") as? Bool ?? true

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MP4Studio")
        temporaryDirectory = support.appendingPathComponent("tmp")
        logsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/MP4Studio")
        for dir in [temporaryDirectory, logsDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        queue = JobQueue(logsDirectory: logsDirectory)
        convert = ConvertModel()
        watch = WatchFolderModel()
        queue.keepLogs = { [weak self] in self?.keepLogs ?? true }
        if defaultPresetID == nil { defaultPresetID = presets.first?.id }
        refreshCapabilities()
    }

    var defaultPreset: Preset { presets.first { $0.id == defaultPresetID } ?? presets.first ?? Preset(name: "Default") }

    func preset(_ id: UUID?) -> Preset? { presets.first { $0.id == id } }

    var missingTools: [Tool] { Tool.allCases.filter { toolPaths.url(for: $0) == nil } }

    func refreshCapabilities() {
        guard let ffmpeg = toolPaths.url(for: .ffmpeg) else { capabilities = FFmpegCapabilities(); return }
        Task { capabilities = await FFmpegCapabilities.detect(ffmpeg: ffmpeg) }
    }

    func probe(_ url: URL, inputIndex: Int = 0) async throws -> MediaFile {
        try await Prober(ffprobe: try toolPaths.require(.ffprobe)).probe(url, inputIndex: inputIndex)
    }

    func convertBuilder() -> ConvertBuilder {
        // Before detection finishes, assume a full build rather than blocking the user.
        ConvertBuilder(tools: toolPaths, capabilities: capabilities.encoders.isEmpty ? .full : capabilities)
    }

    /// Plays the file with ffplay using the chosen audio and subtitle streams.
    func preview(_ file: MediaFile, audio: MediaTrack?, subtitle: MediaTrack?) {
        guard let ffplay = toolPaths.url(for: .ffplay) else { NSSound.beep(); return }
        var args = ["-autoexit", "-window_title", file.name]
        if let audio, audio.inputIndex == 0 { args += ["-ast", "\(audio.streamIndex)"] }
        if let subtitle, subtitle.inputIndex == 0 { args += ["-sst", "\(subtitle.streamIndex)"] }
        args.append(file.url.path)
        let p = Process()
        p.executableURL = ffplay
        p.arguments = args
        p.environment = ProcessRunner.toolEnvironment()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

enum Defaults {
    static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

enum Panels {
    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "mts", "wmv", "mpg", "mpeg", "webm", "flv", "vob", "ogm", "3gp"]
    static let trackExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sup", "idx", "sub", "ac3", "eac3", "aac", "m4a", "dts", "mp3", "flac", "wav", "mka", "mks", "h264", "h265", "264", "265"]

    static func openFiles(multiple: Bool = true, prompt: String = "Open", extensions: Set<String>? = nil) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        panel.prompt = prompt
        if let extensions {
            panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        }
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseFolder(prompt: String = "Choose", start: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseImage() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.prompt = "Use Image"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
