import AppKit
import MP4StudioCore
import SwiftUI

struct SplitJoinView: View {
    var body: some View {
        HSplitView {
            SplitPane().frame(minWidth: 360)
            JoinPane().frame(minWidth: 360)
        }
    }
}

private struct SplitPane: View {
    enum Mode: String, CaseIterable, Identifiable {
        case size = "By size", duration = "By length", segment = "Extract segment"
        var id: String { rawValue }
    }

    @Environment(AppState.self) private var app
    @State private var file: MediaFile?
    @State private var mode = Mode.size
    @State private var megabytes = 700
    @State private var length = "00:30:00"
    @State private var start = ""
    @State private var end = ""
    @State private var errors: [String] = []
    @State private var note: String?

    var body: some View {
        Form {
            Section("Split") {
                LabeledContent("File") {
                    HStack {
                        Text(file?.name ?? "None").lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(file == nil ? .secondary : .primary)
                        Spacer()
                        Button("Choose…") { open(Panels.openFiles(multiple: false)) }
                    }
                }
                if let file {
                    LabeledContent("Length", value: TimeCode.format(file.duration, millis: false))
                    if let size = file.size { LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                }
                Picker("Split", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch mode {
                case .size:
                    TextField("Part size (MB)", value: $megabytes, format: .number)
                    Text("Parts end on a keyframe, so sizes are approximate.").font(.caption).foregroundStyle(.secondary)
                case .duration:
                    TextField("Part length", text: $length, prompt: Text("00:30:00"))
                case .segment:
                    TextField("Start", text: $start, prompt: Text("00:00:00"))
                    TextField("End", text: $end, prompt: Text(file.map { TimeCode.format($0.duration, millis: false) } ?? "00:10:00"))
                    Text("All tracks are kept. The start moves to the nearest keyframe.").font(.caption).foregroundStyle(.secondary)
                }
                if let file {
                    Text(toolNote(file)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                FolderField(label: "Save to", url: Binding(get: { app.outputFolder }, set: { if let u = $0 { app.outputFolder = u } }))
                HStack {
                    ErrorList(errors: $errors)
                    StatusNote(text: note)
                    Spacer()
                    Button("Split") { split() }.buttonStyle(.borderedProminent).disabled(file == nil)
                }
            }
        }
        .formStyle(.grouped)
        .onFileDrop { open($0) }
    }

    func toolNote(_ f: MediaFile) -> String {
        switch (f.container, mode) {
        case (.mkv, _): return "Uses mkvmerge."
        case (.mp4, _): return "Uses ffmpeg (stream copy)."
        case (.other, .segment): return "Uses ffmpeg (stream copy)."
        case (.other, _): return "Uses mkvmerge. The parts are saved as MKV."
        }
    }

    func open(_ urls: [URL]) {
        guard let url = urls.first else { return }
        Task {
            do { file = try await app.probe(url); note = nil }
            catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
    }

    func split() {
        guard let file else { return }
        let splitMode: SplitMode
        switch mode {
        case .size: splitMode = .bySize(megabytes: megabytes)
        case .duration:
            guard let d = TimeCode.parse(length) else { errors.append("Enter the part length as HH:MM:SS."); return }
            splitMode = .byDuration(seconds: d)
        case .segment:
            guard let s = TimeCode.parse(start.isEmpty ? "0" : start), let e = TimeCode.parse(end.isEmpty ? "\(file.duration)" : end) else {
                errors.append("Enter start and end times as HH:MM:SS.")
                return
            }
            splitMode = .segment(start: s, end: e)
        }
        do {
            app.queue.add(try SplitBuilder(tools: app.toolPaths).plan(file: file, mode: splitMode, outputFolder: app.outputFolder))
            withAnimation { note = "Queued" }
        } catch {
            errors.append(error.localizedDescription)
        }
    }
}

private struct JoinPane: View {
    @Environment(AppState.self) private var app
    @State private var files: [MediaFile] = []
    @State private var selection: MediaFile.ID?
    @State private var name = "Joined"
    @State private var container = OutputContainer.mkv
    @State private var errors: [String] = []
    @State private var note: String?

    var body: some View {
        Form {
            Section("Join") {
                List(selection: $selection) {
                    ForEach(files) { f in
                        HStack {
                            Text(f.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(TimeCode.format(f.duration, millis: false)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .tag(f.id)
                    }
                    .onMove { files.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minHeight: 160)
                .overlay {
                    if files.isEmpty { Text("Drop files here, in order").foregroundStyle(.secondary) }
                }
                HStack {
                    Button("Add Files…") { add(Panels.openFiles()) }
                    Button("Remove") { files.removeAll { $0.id == selection } }.disabled(selection == nil)
                    Spacer()
                    Text("Drag to reorder").font(.caption).foregroundStyle(.secondary)
                }
                Text(toolNote).font(.caption).foregroundStyle(.secondary)
                if mismatch { Text("These files have different track layouts, so the result may not play correctly.").font(.callout).foregroundStyle(.orange) }
            }
            Section {
                FolderField(label: "Save to", url: Binding(get: { app.outputFolder }, set: { if let u = $0 { app.outputFolder = u } }))
                HStack {
                    TextField("Name", text: $name)
                    Picker("", selection: $container) {
                        ForEach(OutputContainer.allCases) { Text(".\($0.fileExtension)").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                HStack {
                    ErrorList(errors: $errors)
                    StatusNote(text: note)
                    Spacer()
                    Button("Join") { join() }.buttonStyle(.borderedProminent).disabled(files.count < 2)
                }
            }
        }
        .formStyle(.grouped)
        .onFileDrop { add($0) }
    }

    var toolNote: String {
        let kinds = Set(files.map(\.container))
        if kinds == [.mp4] && container.isMP4 { return "Uses MP4Box." }
        if container == .mkv && !kinds.contains(.other) { return "Uses mkvmerge." }
        return "Uses ffmpeg (stream copy)."
    }

    var mismatch: Bool {
        guard let first = files.first else { return false }
        let signature = { (f: MediaFile) in f.tracks.filter { $0.kind != .attachment }.map { "\($0.kind)\($0.codec)" } }
        return files.dropFirst().contains { signature($0) != signature(first) }
    }

    func add(_ urls: [URL]) {
        Task {
            for url in urls {
                do {
                    files.append(try await app.probe(url))
                    if files.count == 1 {
                        name = url.deletingPathExtension().lastPathComponent + " joined"
                        container = url.pathExtension.lowercased() == "m4v" ? .m4v : files[0].container == .mp4 ? .mp4 : .mkv
                    }
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    func join() {
        let output = uniqueURL(in: app.outputFolder, baseName: name.isEmpty ? "Joined" : name, extension: container.fileExtension)
        do {
            app.queue.add(try JoinBuilder(tools: app.toolPaths).plan(files: files, outputURL: output, temporaryDirectory: app.temporaryDirectory))
            withAnimation { note = "Queued \(output.lastPathComponent)" }
        } catch {
            errors.append(error.localizedDescription)
        }
    }
}
