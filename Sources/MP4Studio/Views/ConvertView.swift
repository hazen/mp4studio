import AppKit
import MP4StudioCore
import SwiftUI

struct ConvertView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let model = app.convert
        Group {
            if model.items.isEmpty {
                VStack {
                    ErrorList(errors: Binding(get: { model.errors }, set: { model.errors = $0 })).padding([.horizontal, .top])
                    DropPrompt(title: "Drop video files here",
                               detail: "MKV, MP4, AVI, TS and more. Each file gets the default preset, and you can adjust its tracks and settings before queueing.",
                               buttonTitle: "Open Files…") { model.open(Panels.openFiles(), app: app) }
                }
            } else {
                HSplitView {
                    FileSidebar()
                        .frame(minWidth: 170, idealWidth: 210, maxWidth: 240)
                    if let item = model.current {
                        ConvertDetail(item: item)
                            .id(item.id)
                            .frame(minWidth: 600)
                    }
                }
            }
        }
        .overlay { if model.isLoading { ProgressView().controlSize(.large) } }
        .onFileDrop { model.open($0, app: app) }
    }
}

private struct FileSidebar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let model = app.convert
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.selection }, set: { model.selection = $0 })) {
                ForEach(model.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.file.name).lineLimit(1).truncationMode(.middle)
                        Text("\(TimeCode.format(item.file.duration, millis: false)) · \(presetLabel(item))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(item.id)
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.file.url]) }
                        Button("Remove") { model.remove(item) }
                    }
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button { model.open(Panels.openFiles(), app: app) } label: { Image(systemName: "plus") }
                    .help("Open files")
                Button {
                    if let item = model.current { model.remove(item) }
                } label: { Image(systemName: "minus") }
                    .disabled(model.current == nil)
                    .help("Remove the selected file")
                Spacer()
                Button("Queue All") { queueAll() }
                    .help("Add every file to the queue with its current settings")
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    func presetLabel(_ item: ConvertItem) -> String {
        guard let p = app.preset(item.presetID) else { return "Custom" }
        return p.settings == item.settings ? p.name : "\(p.name) (modified)"
    }

    func queueAll() {
        let model = app.convert
        var queued: [ConvertItem] = []
        for item in model.items {
            do {
                let plan = try app.convertBuilder().plan(try item.request(outputFolder: app.outputFolder, temporaryDirectory: app.temporaryDirectory))
                app.queue.add(plan)
                queued.append(item)
            } catch {
                item.lastError = error.localizedDescription
                model.errors.append("\(item.file.name): \(error.localizedDescription)")
            }
        }
        for item in queued { model.remove(item) }
    }
}

private struct ConvertDetail: View {
    @Environment(AppState.self) private var app
    @Bindable var item: ConvertItem
    @State private var tab = "video"
    @State private var note: String?

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 8) {
                header
                TrackTable(tracks: item.allTracks, checked: $item.selected,
                           options: .init(checkLabel: "Use", editable: true, showForced: true),
                           update: { id, change in item.update(id, change) },
                           removeSource: { t in
                               if let extra = item.extras.first(where: { $0.url == t.sourceURL }) { item.removeExtra(extra) }
                           })
            }
            .padding([.horizontal, .top], 12)
            .padding(.bottom, 6)
            .frame(minHeight: 180, idealHeight: 240)

            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Video").tag("video")
                    Text("Audio").tag("audio")
                    Text("Subtitles").tag("subtitles")
                    Text("Segment").tag("segment")
                    Text("Metadata").tag("metadata")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 480)
                .padding(.top, 10)

                Group {
                    switch tab {
                    case "audio": AudioSettingsForm(s: $item.settings)
                    case "subtitles": SubtitleOptions(item: item)
                    case "segment": SegmentOptions(item: item)
                    case "metadata": metadataTab
                    default: VideoSettingsForm(s: $item.settings, capabilities: app.capabilities)
                    }
                }
                .frame(maxHeight: .infinity)
                footer
            }
            .frame(minHeight: 300)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.file.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(fileSummary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Preset", selection: Binding(get: { item.presetID }, set: { id in
                if let p = app.preset(id) { item.apply(p) }
            })) {
                if item.presetID == nil || app.preset(item.presetID) == nil { Text("Custom").tag(UUID?.none) }
                ForEach(app.presets) { Text($0.name).tag(Optional($0.id)) }
            }
            .frame(maxWidth: 300)
            if let p = app.preset(item.presetID), p.settings != item.settings {
                Text("modified").font(.caption).foregroundStyle(.secondary)
            }
            Menu {
                Button("Save Settings as New Preset…") { savePreset() }
                if let p = app.preset(item.presetID) {
                    Button("Update “\(p.name)” with These Settings") {
                        if let i = app.presets.firstIndex(where: { $0.id == p.id }) { app.presets[i].settings = item.settings }
                    }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            Button("Add Tracks…") { addTracks() }
                .help("Add external subtitle or audio files, e.g. an .srt")
            Button { preview() } label: { Label("Preview", systemImage: "play.fill") }
                .help("Play with ffplay using the first selected audio and subtitle tracks")
                .disabled(app.toolPaths.url(for: .ffplay) == nil)
        }
    }

    private var fileSummary: String {
        var parts = [TimeCode.format(item.file.duration, millis: false)]
        if let size = item.file.size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if !item.file.chapters.isEmpty { parts.append("\(item.file.chapters.count) chapters") }
        parts.append(item.file.formatName.components(separatedBy: ",").first ?? "")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var metadataTab: some View {
        if item.settings.container.isMP4 {
            VStack(spacing: 0) {
                MetadataForm(fields: $item.metadata)
                if item.metadataEdited {
                    Text("These tags are written with AtomicParsley after conversion.")
                        .font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
                }
            }
        } else {
            Form {
                TextField("Title", text: $item.metadata.title)
                Text("MKV files store a title only. Choose M4V or MP4 for iTunes-style tags and artwork.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        }
    }

    private var footer: some View {
        let preview = Result { try app.convertBuilder().plan(try item.request(outputFolder: app.outputFolder, temporaryDirectory: app.temporaryDirectory)) }
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            switch preview {
            case .success(let plan): WarningList(warnings: plan.warnings)
            case .failure(let error):
                Label(error.localizedDescription, systemImage: "xmark.octagon.fill").symbolRenderingMode(.multicolor).font(.callout)
            }
            HStack(spacing: 10) {
                FolderField(label: "Save to", url: Binding(get: { app.outputFolder }, set: { if let u = $0 { app.outputFolder = u } }))
                TextField("Name", text: $item.outputName).frame(width: 220)
                Text(".\(item.settings.container.fileExtension)").foregroundStyle(.secondary)
                StatusNote(text: note)
                Button("Add to Queue") { queue() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled((try? preview.get()) == nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    func queue() {
        do {
            let plan = try app.convertBuilder().plan(try item.request(outputFolder: app.outputFolder, temporaryDirectory: app.temporaryDirectory))
            app.queue.add(plan)
            withAnimation { note = "Queued \(plan.outputs.first?.lastPathComponent ?? "")" }
        } catch {
            app.convert.errors.append(error.localizedDescription)
        }
    }

    func addTracks() {
        let urls = Panels.openFiles(prompt: "Add")
        Task {
            for url in urls {
                do { item.addExtra(try await app.probe(url, inputIndex: item.extras.count + 1)) }
                catch { app.convert.errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
        }
    }

    func preview() {
        let selected = item.file.tracks.filter { item.selected.contains($0.id) }
        app.preview(item.file, audio: selected.first { $0.kind == .audio }, subtitle: selected.first { $0.kind == .subtitle })
    }

    func savePreset() {
        let alert = NSAlert()
        alert.messageText = "Save Preset"
        alert.informativeText = "Saves this file's video, audio and subtitle settings. Track selection rules are copied from the current preset."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Preset name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let preset = Preset(name: name, settings: item.settings, rules: app.preset(item.presetID)?.rules ?? SelectionRules())
        app.presets.append(preset)
        item.presetID = preset.id
    }
}

private struct SubtitleOptions: View {
    @Environment(AppState.self) private var app
    @Bindable var item: ConvertItem

    var body: some View {
        let subs = item.allTracks.filter { $0.kind == .subtitle }
        Form {
            Picker("Subtitles", selection: $item.settings.subtitleAction) {
                ForEach(SubtitleAction.allCases) { Text($0.label).tag($0) }
            }
            if item.settings.subtitleAction == .burn {
                Picker("Track to burn in", selection: $item.burnTrackID) {
                    Text("None").tag(String?.none)
                    ForEach(subs) { t in
                        Text("\(t.inputIndex == 0 ? "#\(t.streamIndex)" : t.sourceURL.lastPathComponent) – \(Languages.name(for: t.language)) \(t.codecLabel)\(t.isForced ? " (forced)" : "")")
                            .tag(Optional(t.id))
                    }
                }
                if !item.settings.videoCodec.reencodes {
                    Text("Burning in needs a video codec other than Pass through (Video tab).").foregroundStyle(.red).font(.callout)
                }
                if !app.capabilities.encoders.isEmpty && !app.capabilities.hasSubtitlesFilter {
                    Text("This ffmpeg can burn image subtitles (PGS, VobSub) but not text subtitles (SRT, ASS) because it was built without libass.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("Other selected subtitle tracks are still muxed as soft subtitles.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Soft subtitles: text formats become MP4 text tracks (tx3g) in MP4/M4V and are kept as-is in MKV. PGS subtitles can't go in MP4, so burn them in or choose MKV.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Set Default and Forced in the track table. Use Add Tracks… to bring in an external .srt.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SegmentOptions: View {
    @Bindable var item: ConvertItem

    var body: some View {
        Form {
            Section {
                TextField("Start", text: $item.segmentStart, prompt: Text("00:00:00"))
                TextField("End", text: $item.segmentEnd, prompt: Text(TimeCode.format(item.file.duration, millis: false)))
            } footer: {
                Text("Leave blank to convert the whole file. Use HH:MM:SS, MM:SS or seconds. With pass-through video the cut snaps to the nearest keyframe.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let s = TimeCode.parse(item.segmentStart.isEmpty ? "0" : item.segmentStart),
               let e = TimeCode.parse(item.segmentEnd.isEmpty ? "\(item.file.duration)" : item.segmentEnd), e > s {
                LabeledContent("Segment length", value: TimeCode.format(e - s))
            }
            if !item.file.chapters.isEmpty {
                Section("Chapters") {
                    ForEach(Array(item.file.chapters.enumerated()), id: \.offset) { i, ch in
                        HStack {
                            Text(ch.title.isEmpty ? "Chapter \(i + 1)" : ch.title)
                            Spacer()
                            Text(TimeCode.format(ch.start, millis: false)).monospacedDigit().foregroundStyle(.secondary)
                            Button("Start") { item.segmentStart = TimeCode.format(ch.start) }.buttonStyle(.link)
                            Button("End") { item.segmentEnd = TimeCode.format(ch.end) }.buttonStyle(.link)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
