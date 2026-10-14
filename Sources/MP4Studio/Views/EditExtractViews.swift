import AppKit
import MP4StudioCore
import SwiftUI

/// Remux without re-encoding: drop or add tracks, fix languages, names and flags. MP4Box for MP4/M4V, mkvmerge for MKV.
struct EditTracksView: View {
    @Environment(AppState.self) private var app
    @State private var original: MediaFile?
    @State private var file: MediaFile?
    @State private var added: [MediaFile] = []
    @State private var kept: Set<String> = []
    @State private var squarePixels = false
    @State private var outputName = ""
    @State private var errors: [String] = []
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ErrorList(errors: $errors)
            if let file {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).font(.headline)
                        Text(toolNote(file)).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add Tracks…") { addTracks() }
                    Button("Open Another…") { open(Panels.openFiles(multiple: false)) }
                }
                TrackTable(tracks: file.tracks + added.flatMap(\.tracks), checked: $kept,
                           options: .init(checkLabel: "Keep", editable: true, showForced: file.container == .mkv),
                           update: update,
                           removeSource: { t in
                               added.removeAll { $0.url == t.sourceURL }
                               added = added.enumerated().map { $0.element.reindexed(as: $0.offset + 1) }
                               kept = kept.intersection(Set((file.tracks + added.flatMap(\.tracks)).map(\.id)))
                           })
                Toggle("Square pixels (fix anamorphic video without re-encoding)", isOn: $squarePixels)
                    .disabled(!file.tracks(.video).contains { $0.isAnamorphic })
                if file.container == .mp4 {
                    Text("In MP4 the Default box sets whether a track is enabled. Forced flags aren't available for MP4 here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: 10) {
                    FolderField(label: "Save to", url: Binding(get: { app.outputFolder }, set: { if let u = $0 { app.outputFolder = u } }))
                    TextField("Name", text: $outputName).frame(width: 220)
                    Text(".\(outputExtension(file))").foregroundStyle(.secondary)
                    StatusNote(text: note)
                    Button("Add to Queue") { queue() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(file.container == .other)
                }
                Text("The original file is never changed.").font(.caption).foregroundStyle(.secondary)
            } else {
                DropPrompt(title: "Drop an MP4, M4V or MKV file",
                           detail: "Remove tracks, add subtitle or audio files, and fix languages, names and default flags without re-encoding.",
                           buttonTitle: "Open File…") { open(Panels.openFiles(multiple: false)) }
            }
        }
        .padding(12)
        .onFileDrop { urls in
            if file == nil { open(urls) } else { add(urls) }
        }
    }

    func toolNote(_ f: MediaFile) -> String {
        switch f.container {
        case .mp4: return "Edited with MP4Box"
        case .mkv: return "Edited with mkvmerge"
        case .other: return "Edit Tracks works with MP4, M4V and MKV. Use Convert to remux this file."
        }
    }

    func outputExtension(_ f: MediaFile) -> String {
        f.container == .mkv ? "mkv" : f.url.pathExtension.lowercased()
    }

    func update(_ id: String, _ change: (inout MediaTrack) -> Void) {
        if let i = file?.tracks.firstIndex(where: { $0.id == id }) { change(&file!.tracks[i]); return }
        for a in added.indices {
            if let i = added[a].tracks.firstIndex(where: { $0.id == id }) { change(&added[a].tracks[i]); return }
        }
    }

    func open(_ urls: [URL]) {
        guard let url = urls.first else { return }
        Task {
            do {
                let f = try await app.probe(url)
                original = f
                file = f
                added = []
                kept = Set(f.tracks.filter { $0.kind != .attachment && $0.kind != .data }.map(\.id))
                squarePixels = false
                outputName = url.deletingPathExtension().lastPathComponent + " edited"
                note = nil
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    func addTracks() { add(Panels.openFiles(prompt: "Add")) }

    func add(_ urls: [URL]) {
        Task {
            for url in urls {
                do {
                    let f = try await app.probe(url, inputIndex: added.count + 1)
                    added.append(f)
                    kept.formUnion(f.tracks.filter { $0.kind != .attachment && $0.kind != .data }.map(\.id))
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    func queue() {
        guard let file, let original else { return }
        let name = outputName.trimmingCharacters(in: .whitespaces).isEmpty ? file.url.deletingPathExtension().lastPathComponent + " edited" : outputName
        let output = uniqueURL(in: app.outputFolder, baseName: name, extension: outputExtension(file), reserved: [file.url])
        do {
            let plan = try EditBuilder(tools: app.toolPaths, original: original).plan(EditRequest(
                main: file, added: added, keptTrackIDs: kept, squarePixels: squarePixels, outputURL: output))
            app.queue.add(plan)
            withAnimation { note = "Queued \(output.lastPathComponent)" }
        } catch {
            errors.append(error.localizedDescription)
        }
    }
}

struct ExtractView: View {
    @Environment(AppState.self) private var app
    @State private var file: MediaFile?
    @State private var checked: Set<String> = []
    @State private var folder: URL?
    @State private var errors: [String] = []
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ErrorList(errors: $errors)
            if let file {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).font(.headline)
                        Text(file.container == .mkv ? "Extracted with mkvextract" : "Extracted with ffmpeg (stream copy)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Another…") { open(Panels.openFiles(multiple: false)) }
                }
                TrackTable(tracks: file.tracks.filter { $0.kind != .attachment }, checked: $checked,
                           options: .init(checkLabel: "Extract", editable: false, showForced: true))
                Text("Each track is saved as its own file, e.g. .srt, .ac3, .h264 or .sup. Text subtitles from MP4 are saved as SRT.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack(spacing: 10) {
                    FolderField(label: "Save to", url: Binding(get: { folder ?? file.url.deletingLastPathComponent() }, set: { folder = $0 }))
                    StatusNote(text: note)
                    Button("Extract") { extract() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(checked.isEmpty)
                }
            } else {
                DropPrompt(title: "Drop a video file",
                           detail: "Pull subtitle, audio or video tracks out into separate files.",
                           buttonTitle: "Open File…") { open(Panels.openFiles(multiple: false)) }
            }
        }
        .padding(12)
        .onFileDrop { open($0) }
    }

    func open(_ urls: [URL]) {
        guard let url = urls.first else { return }
        Task {
            do {
                file = try await app.probe(url)
                checked = Set(file!.tracks.filter { $0.kind == .subtitle }.map(\.id))
                note = nil
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    func extract() {
        guard let file else { return }
        do {
            let plan = try ExtractBuilder(tools: app.toolPaths).plan(file: file, trackIDs: checked,
                                                                     outputFolder: folder ?? file.url.deletingLastPathComponent())
            app.queue.add(plan)
            withAnimation { note = "Queued \(plan.outputs.count) file(s)" }
        } catch {
            errors.append(error.localizedDescription)
        }
    }
}
