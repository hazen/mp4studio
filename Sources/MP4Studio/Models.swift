import AppKit
import MP4StudioCore
import Observation
import SwiftUI

/// A file loaded in Convert, with its own track choices and settings.
@MainActor
@Observable
final class ConvertItem: Identifiable {
    let id = UUID()
    var file: MediaFile
    var extras: [MediaFile] = []
    var selected: Set<String>
    var settings: ConvertSettings
    var presetID: UUID?
    var burnTrackID: String?
    var segmentStart = ""
    var segmentEnd = ""
    var metadata: MetadataFields
    private(set) var originalMetadata: MetadataFields
    var outputName: String
    var lastError: String?

    init(file: MediaFile, preset: Preset) {
        self.file = file
        settings = preset.settings
        presetID = preset.id
        selected = preset.rules.selectedTrackIDs(in: file)
        let meta = MetadataFields.fromContainerTags(file.tags)
        metadata = meta
        originalMetadata = meta
        outputName = file.url.deletingPathExtension().lastPathComponent
        applyBurnRule(preset.rules)
    }

    var allTracks: [MediaTrack] { file.tracks + extras.flatMap(\.tracks) }
    var metadataEdited: Bool { metadata != originalMetadata }

    func apply(_ preset: Preset) {
        settings = preset.settings
        presetID = preset.id
        selected = preset.rules.selectedTrackIDs(in: file).union(extras.flatMap(\.tracks).map(\.id))
        burnTrackID = nil
        applyBurnRule(preset.rules)
    }

    private func applyBurnRule(_ rules: SelectionRules) {
        guard rules.burnForcedSubtitles, settings.videoCodec.reencodes,
              let forced = file.tracks(.subtitle).first(where: { $0.isForced }) else { return }
        burnTrackID = forced.id
    }

    /// Metadata read by AtomicParsley replaces the ffprobe guess, and doesn't count as an edit.
    func setLoadedMetadata(_ fields: MetadataFields) {
        let untouched = !metadataEdited
        originalMetadata = fields
        if untouched { metadata = fields }
    }

    func addExtra(_ extra: MediaFile) {
        let indexed = extra.reindexed(as: extras.count + 1)
        extras.append(indexed)
        selected.formUnion(indexed.tracks.filter { $0.kind == .audio || $0.kind == .subtitle }.map(\.id))
    }

    func removeExtra(_ extra: MediaFile) {
        guard let i = extras.firstIndex(where: { $0.id == extra.id }) else { return }
        for t in extras[i].tracks { selected.remove(t.id) }
        if extras[i].tracks.contains(where: { $0.id == burnTrackID }) { burnTrackID = nil }
        extras.remove(at: i)
        // Input indexes must stay contiguous.
        extras = extras.enumerated().map { $0.element.reindexed(as: $0.offset + 1) }
        let valid = Set(allTracks.map(\.id))
        selected = selected.intersection(valid)
    }

    func track(_ id: String) -> MediaTrack? { allTracks.first { $0.id == id } }

    func update(_ id: String, _ change: (inout MediaTrack) -> Void) {
        if let i = file.tracks.firstIndex(where: { $0.id == id }) { change(&file.tracks[i]); return }
        for e in extras.indices {
            if let i = extras[e].tracks.firstIndex(where: { $0.id == id }) { change(&extras[e].tracks[i]); return }
        }
    }

    var outputBaseName: String {
        outputName.trimmingCharacters(in: .whitespaces).isEmpty ? file.url.deletingPathExtension().lastPathComponent : outputName
    }

    var sourceURLs: [URL] { [file.url] + extras.map(\.url) }

    func outputURL(in folder: URL, app: AppState, existing: ExistingOutput = .keepBoth) -> URL {
        app.outputURL(in: folder, baseName: outputBaseName, extension: settings.container.fileExtension, sources: sourceURLs, existing: existing)
    }

    func existingOutput(in folder: URL, app: AppState) -> URL? {
        app.existingOutput(in: folder, baseName: outputBaseName, extension: settings.container.fileExtension, sources: sourceURLs)
    }

    func request(output: URL, temporaryDirectory: URL) throws -> ConvertRequest {
        let start = segmentStart.isEmpty ? nil : TimeCode.parse(segmentStart)
        let end = segmentEnd.isEmpty ? nil : TimeCode.parse(segmentEnd)
        if !segmentStart.isEmpty && start == nil { throw ToolError.invalid("The start time isn't valid. Use HH:MM:SS or seconds.") }
        if !segmentEnd.isEmpty && end == nil { throw ToolError.invalid("The end time isn't valid. Use HH:MM:SS or seconds.") }
        if output.standardizedFileURL == file.url.standardizedFileURL {
            throw ToolError.invalid("The output would overwrite the source file. Choose another name or folder.")
        }
        return ConvertRequest(
            main: file, extras: extras, selectedTrackIDs: selected,
            burnTrackID: settings.subtitleAction == .burn ? burnTrackID : nil,
            segmentStart: start, segmentEnd: end, settings: settings,
            metadata: metadataEdited ? metadata : nil,
            outputURL: output, temporaryDirectory: temporaryDirectory)
    }
}

@MainActor
@Observable
final class ConvertModel {
    var items: [ConvertItem] = []
    var selection: ConvertItem.ID?
    var isLoading = false
    var errors: [String] = []

    var current: ConvertItem? { items.first { $0.id == selection } ?? items.first }

    func open(_ urls: [URL], app: AppState) {
        let videos = urls.filter { !$0.hasDirectoryPath }
        guard !videos.isEmpty else { return }
        isLoading = true
        Task {
            for url in videos where !items.contains(where: { $0.file.url == url }) {
                do {
                    let file = try await app.probe(url)
                    guard !file.tracks(.video).isEmpty || !file.tracks(.audio).isEmpty else {
                        errors.append("\(url.lastPathComponent) doesn't contain video or audio.")
                        continue
                    }
                    let item = ConvertItem(file: file, preset: app.defaultPreset)
                    items.append(item)
                    if selection == nil { selection = item.id }
                    if file.container == .mp4, app.toolPaths.url(for: .atomicParsley) != nil,
                       let read = try? await MetadataBuilder(tools: app.toolPaths).read(url) {
                        item.setLoadedMetadata(read.fields)
                    }
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            isLoading = false
        }
    }

    func remove(_ item: ConvertItem) {
        items.removeAll { $0.id == item.id }
        if selection == item.id { selection = items.first?.id }
    }
}

/// Watches a folder and queues new video files with a preset, like MP4tools' Watch Mode.
@MainActor
@Observable
final class WatchFolderModel {
    var folder: URL? { didSet { UserDefaults.standard.set(folder?.path, forKey: "watchFolder") } }
    var outputFolder: URL? { didSet { UserDefaults.standard.set(outputFolder?.path, forKey: "watchOutput") } }
    var presetID: UUID? { didSet { Defaults.save(presetID, "watchPreset") } }
    private(set) var isWatching = false
    private(set) var events: [(date: Date, text: String)] = []

    private var timer: Timer?
    private var seen = Set<String>()
    private var pendingSizes: [String: Int64] = [:]

    init() {
        let d = UserDefaults.standard
        folder = d.string(forKey: "watchFolder").map { URL(fileURLWithPath: $0) }
        outputFolder = d.string(forKey: "watchOutput").map { URL(fileURLWithPath: $0) }
        presetID = Defaults.load(UUID.self, "watchPreset")
    }

    func start(app: AppState) {
        guard let folder, let outputFolder else { return }
        guard folder.standardizedFileURL != outputFolder.standardizedFileURL else {
            log("The output folder must be different from the watched folder.")
            return
        }
        // Files already there when watching starts are left alone.
        seen = Set(videoFiles(in: folder).map(\.path))
        pendingSizes = [:]
        isWatching = true
        log("Watching \(folder.path) — \(seen.count) existing file(s) skipped.")
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self, weak app] _ in
            Task { @MainActor in
                guard let self, let app else { return }
                self.poll(app: app)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isWatching = false
        log("Stopped watching.")
    }

    private func videoFiles(in folder: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.filter { Panels.videoExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// A file is queued once its size stops changing between polls (so copies in progress are skipped).
    private func poll(app: AppState) {
        guard let folder, let outputFolder else { return }
        for url in videoFiles(in: folder) where !seen.contains(url.path) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
            if let previous = pendingSizes[url.path], previous == size, size > 0 {
                seen.insert(url.path)
                pendingSizes[url.path] = nil
                Task { await enqueue(url, app: app, outputFolder: outputFolder) }
            } else {
                pendingSizes[url.path] = size
            }
        }
    }

    private func enqueue(_ url: URL, app: AppState, outputFolder: URL) async {
        let preset = app.preset(presetID) ?? app.defaultPreset
        do {
            let file = try await app.probe(url)
            let item = ConvertItem(file: file, preset: preset)
            let output = item.outputURL(in: outputFolder, app: app)
            let plan = try app.convertBuilder().plan(try item.request(output: output, temporaryDirectory: app.temporaryDirectory))
            app.queue.add(plan)
            log("Queued \(url.lastPathComponent) with “\(preset.name)”.")
        } catch {
            log("Couldn't queue \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func log(_ text: String) {
        events.insert((Date(), text), at: 0)
        if events.count > 200 { events.removeLast() }
    }
}
