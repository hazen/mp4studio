import AppKit
import MP4StudioCore
import SwiftUI

struct QueueView: View {
    @Environment(AppState.self) private var app
    @State private var detailsJob: Job?

    var body: some View {
        let queue = app.queue
        VStack(spacing: 0) {
            if queue.jobs.isEmpty {
                ContentUnavailableView("No jobs", systemImage: "list.bullet.rectangle",
                                       description: Text("Jobs you add from Convert, Edit Tracks, Extract, Split & Join or Watch Folder appear here and run one at a time."))
            } else {
                List {
                    ForEach(queue.jobs) { job in JobRow(job: job) { detailsJob = job } }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .sheet(item: $detailsJob) { JobDetailsSheet(job: $0) }
            }
            Divider()
            HStack {
                Text("\(queue.pendingCount) waiting or running").foregroundStyle(.secondary)
                Spacer()
                Button("Open Logs Folder") { NSWorkspace.shared.open(app.logsDirectory) }
                Button("Clear Finished") { queue.clearFinished() }
                    .disabled(!queue.jobs.contains { $0.status.isFinished })
            }
            .padding(10)
        }
    }
}

private struct JobRow: View {
    @Environment(AppState.self) private var app
    let job: Job
    let showDetails: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusIcon.frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.plan.title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                switch job.status {
                case .running, .paused:
                    if job.hasDeterminateProgress {
                        ProgressView(value: job.progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(detailLine).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                default:
                    Text(detailLine).font(.caption).foregroundStyle(.secondary)
                }
                if !job.plan.warnings.isEmpty && !job.status.isFinished {
                    Text(job.plan.warnings.joined(separator: " ")).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer()
            controls
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: showDetails)
        .contextMenu {
            Button("Show Details") { showDetails() }
            Button("Show Log") { NSWorkspace.shared.open(job.logURL) }
            Button("Copy Commands") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(job.plan.steps.map(\.commandLine).joined(separator: "\n"), forType: .string)
            }
        }
    }

    var detailLine: String {
        switch job.status {
        case .queued: return "Waiting · \(job.plan.steps.map(\.tool.rawValue).joined(separator: " → "))"
        case .running, .paused:
            var parts = [job.currentStepLabel]
            if job.plan.steps.count > 1 { parts.append("step \(job.stepIndex + 1) of \(job.plan.steps.count)") }
            if job.hasDeterminateProgress { parts.append("\(Int(job.progress * 100))%") }
            if job.status == .paused { parts.append("paused") }
            else if let r = job.remaining { parts.append("about \(Self.duration(r)) left") }
            return parts.joined(separator: " · ")
        case .done:
            let took = job.startedAt.flatMap { s in job.finishedAt.map { $0.timeIntervalSince(s) } }
            return "Done" + (took.map { " in \(Self.duration($0))" } ?? "")
        case .cancelled: return "Cancelled"
        case .failed: return ""
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = t >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: max(1, t)) ?? ""
    }

    @ViewBuilder var statusIcon: some View {
        switch job.status {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: Image(systemName: "gearshape.2.fill").foregroundStyle(.blue)
        case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder var controls: some View {
        let queue = app.queue
        HStack(spacing: 6) {
            Button(action: showDetails) { Image(systemName: "info.circle") }.help("Show encoding details")
            switch job.status {
            case .running:
                Button { queue.pause(job) } label: { Image(systemName: "pause.fill") }.help("Pause")
                Button { queue.cancel(job) } label: { Image(systemName: "stop.fill") }.help("Stop and delete the partial output")
            case .paused:
                Button { queue.resume(job) } label: { Image(systemName: "play.fill") }.help("Resume")
                Button { queue.cancel(job) } label: { Image(systemName: "stop.fill") }.help("Stop")
            case .queued:
                Button { queue.cancel(job) } label: { Image(systemName: "xmark") }.help("Cancel")
            case .done:
                Button { NSWorkspace.shared.activateFileViewerSelecting(existingOutputs) } label: { Image(systemName: "magnifyingglass") }
                    .help("Show in Finder")
                Button { queue.remove(job) } label: { Image(systemName: "xmark") }.help("Remove from list")
            case .failed, .cancelled:
                Button { NSWorkspace.shared.open(job.logURL) } label: { Image(systemName: "doc.text") }.help("Show log")
                Button { queue.retry(job) } label: { Image(systemName: "arrow.clockwise") }.help("Retry")
                Button { queue.remove(job) } label: { Image(systemName: "xmark") }.help("Remove from list")
            }
        }
        .buttonStyle(.borderless)
    }

    var existingOutputs: [URL] {
        let found = job.plan.outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
        return found.isEmpty ? [job.plan.outputFolder] : found
    }
}

/// Everything about how a job encodes (or encoded) its files: the plan, each command, and the finished output.
private struct JobDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let job: Job
    @State private var tab = "plan"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(job.plan.title).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let output {
                    Picker("", selection: $tab) {
                        Text("Settings").tag("plan")
                        Text("Output File").tag("output")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("Output File shows MediaInfo's report on \(output.lastPathComponent)")
                }
            }
            .padding(12)
            Divider()
            if tab == "output", let output {
                MediaInfoPanel(url: output)
            } else {
                plan
            }
            Divider()
            HStack {
                Button("Show Log") { NSWorkspace.shared.open(job.logURL) }
                    .disabled(!FileManager.default.fileExists(atPath: job.logURL.path))
                Button("Copy Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fullText, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 620)
    }

    /// The first output that exists once the job has finished.
    var output: URL? {
        guard job.status == .done else { return nil }
        return job.plan.outputs.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    var plan: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailsSection(title: "Job", symbol: "list.bullet.rectangle", rows: jobRows)
                ForEach(Array(job.plan.details.enumerated()), id: \.offset) { _, section in
                    DetailsSection(title: section.title, symbol: symbol(for: section.title),
                                   rows: section.rows.map { ($0.label, $0.value) })
                }
                if !job.plan.warnings.isEmpty {
                    DetailsSection(title: "Warnings", symbol: "exclamationmark.triangle",
                                   rows: job.plan.warnings.map { ("", $0) })
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("Commands", systemImage: "terminal").font(.subheadline.weight(.semibold))
                    ForEach(Array(job.plan.steps.enumerated()), id: \.offset) { i, step in
                        CommandView(index: i, step: step, state: stepState(i))
                    }
                }
            }
            .padding(12)
        }
    }

    var jobRows: [(String, String)] {
        var rows = [("Status", statusText)]
        if let startedAt = job.startedAt { rows.append(("Started", startedAt.formatted(date: .abbreviated, time: .standard))) }
        if let finishedAt = job.finishedAt { rows.append(("Finished", finishedAt.formatted(date: .abbreviated, time: .standard))) }
        if let startedAt = job.startedAt {
            rows.append(("Elapsed", JobRow.duration((job.finishedAt ?? Date()).timeIntervalSince(startedAt))))
        }
        let outputs = job.plan.outputs.map(\.path)
        rows.append((outputs.count > 1 ? "Outputs" : "Output", outputs.isEmpty ? job.plan.outputFolder.path : outputs.joined(separator: "\n")))
        rows.append(("Log", job.logURL.path))
        return rows
    }

    var statusText: String {
        switch job.status {
        case .queued: return "Waiting"
        case .running, .paused:
            let state = job.status == .paused ? "Paused" : "Running"
            return "\(state) · step \(job.stepIndex + 1) of \(job.plan.steps.count) · \(Int(job.progress * 100))%"
        case .done: return "Done"
        case .cancelled: return "Cancelled"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    func stepState(_ i: Int) -> CommandView.State {
        switch job.status {
        case .done: return .done
        case .queued: return .waiting
        case .running, .paused: return i < job.stepIndex ? .done : i == job.stepIndex ? .running : .waiting
        case .failed, .cancelled: return i < job.stepIndex ? .done : i == job.stepIndex ? .stopped : .waiting
        }
    }

    func symbol(for title: String) -> String {
        switch title {
        case "Source": return "doc"
        case let t where t.hasPrefix("Video"): return "film"
        case "Audio": return "speaker.wave.2"
        case "Subtitles": return "captions.bubble"
        case "Container": return "shippingbox"
        default: return "square.stack"
        }
    }

    var fullText: String {
        var parts = [job.plan.title, jobRows.map { "  \($0): \($1)" }.joined(separator: "\n")]
        if !job.plan.details.isEmpty { parts.append(job.plan.detailsText) }
        if !job.plan.warnings.isEmpty { parts.append((["Warnings"] + job.plan.warnings.map { "  \($0)" }).joined(separator: "\n")) }
        parts.append((["Commands"] + job.plan.steps.map { "  \($0.label): \($0.commandLine)" }).joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }
}

private struct DetailsSection: View {
    let title: String
    let symbol: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(row.1).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.callout)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// One step's full command line, with a copy button.
private struct CommandView: View {
    enum State { case waiting, running, done, stopped }
    let index: Int
    let step: JobStep
    let state: State

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                icon
                Text("\(index + 1). \(step.label)").font(.callout.weight(.medium))
                Text(step.tool.rawValue).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(step.commandLine, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy this command")
            }
            Text(step.commandLine)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder var icon: some View {
        switch state {
        case .waiting: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: Image(systemName: "gearshape.2.fill").foregroundStyle(.blue)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .stopped: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

struct WatchFolderView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let watch = app.watch
        Form {
            Section {
                FolderField(label: "Watch", url: Binding(get: { watch.folder }, set: { watch.folder = $0 }))
                FolderField(label: "Save to", url: Binding(get: { watch.outputFolder }, set: { watch.outputFolder = $0 }))
                Picker("Preset", selection: Binding(get: { watch.presetID ?? app.defaultPreset.id }, set: { watch.presetID = $0 })) {
                    ForEach(app.presets) { Text($0.name).tag($0.id) }
                }
                HStack {
                    Text(watch.isWatching ? "Watching for new files…" : "Not watching")
                        .foregroundStyle(watch.isWatching ? .green : .secondary)
                    Spacer()
                    Button(watch.isWatching ? "Stop Watching" : "Start Watching") {
                        if watch.isWatching { watch.stop() } else { watch.start(app: app) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!watch.isWatching && (watch.folder == nil || watch.outputFolder == nil))
                }
            } header: {
                Text("Watch Folder")
            } footer: {
                Text("New video files added to the folder are converted with the preset once they finish copying, using its track selection rules. Files already in the folder are skipped. MP4Studio has to stay open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Activity") {
                if watch.events.isEmpty {
                    Text("Nothing yet").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(watch.events.enumerated()), id: \.offset) { _, e in
                        HStack(alignment: .firstTextBaseline) {
                            Text(e.date, style: .time).foregroundStyle(.secondary).monospacedDigit()
                            Text(e.text).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ToolSettings().tabItem { Label("Tools", systemImage: "hammer") }
            PresetSettings().tabItem { Label("Presets", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 720, height: 560)
    }
}

private struct GeneralSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            FolderField(label: "Default output folder", url: Binding(get: { app.outputFolder }, set: { if let u = $0 { app.outputFolder = u } }))
            Picker("Preset for newly opened files", selection: Binding(get: { app.defaultPreset.id }, set: { app.defaultPresetID = $0 })) {
                ForEach(app.presets) { Text($0.name).tag($0.id) }
            }
            Toggle("Keep logs of successful jobs", isOn: $app.keepLogs)
            LabeledContent("Logs") {
                Button("Show in Finder") { NSWorkspace.shared.open(app.logsDirectory) }
            }
            Section {
                SecureField("TMDB API key", text: $app.tmdbKey, prompt: Text("API key or read access token"))
            } header: {
                Text("Artwork search")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Find Online in the Artwork section searches The Movie Database. Create a free key at [themoviedb.org/settings/api](https://www.themoviedb.org/settings/api). It's stored in your keychain.")
                    Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ToolSettings: View {
    @Environment(AppState.self) private var app
    @State private var architectures: [Tool: String] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(Tool.allCases) { tool in
                    ToolRow(tool: tool, architecture: architectures[tool])
                }
            } footer: {
                Text("Leave a path blank to use the Homebrew install (/opt/homebrew/bin). Install everything with: brew install ffmpeg mkvtoolnix gpac atomicparsley media-info, or brew bundle in the source folder.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !app.capabilities.encoders.isEmpty {
                Section("ffmpeg build") {
                    capability("libx264 (H.264)", app.capabilities.encoders.contains("libx264"))
                    capability("libx265 (HEVC)", app.capabilities.encoders.contains("libx265"))
                    capability("VideoToolbox hardware encoders", app.capabilities.encoders.contains("hevc_videotoolbox"))
                    capability("Apple AAC encoder (AudioToolbox)", app.capabilities.encoders.contains("aac_at"))
                    capability("Text subtitle burn-in (libass)", app.capabilities.hasSubtitlesFilter)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: app.toolPaths) { await loadArchitectures() }
    }

    func capability(_ label: String, _ ok: Bool) -> some View {
        LabeledContent(label) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(ok ? .green : .secondary)
        }
    }

    /// Confirms each tool is a native Apple silicon binary.
    func loadArchitectures() async {
        var result: [Tool: String] = [:]
        for tool in Tool.allCases {
            guard let url = app.toolPaths.url(for: tool) else { continue }
            let real = url.resolvingSymlinksInPath()
            if let r = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/lipo"), ["-archs", real.path]) {
                result[tool] = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        architectures = result
    }
}

private struct ToolRow: View {
    @Environment(AppState.self) private var app
    let tool: Tool
    let architecture: String?

    var body: some View {
        let url = app.toolPaths.url(for: tool)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: url == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(url == nil ? .red : .green)
                Text(tool.rawValue).bold()
                Text(tool.purpose).foregroundStyle(.secondary)
                Spacer()
                if let architecture, !architecture.isEmpty {
                    Text(architecture.contains("arm64") ? "Apple silicon" : architecture)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((architecture.contains("arm64") ? Color.green : Color.orange).opacity(0.15), in: Capsule())
                }
            }
            HStack {
                TextField("Path", text: Binding(
                    get: { app.toolPaths.overrides[tool.rawValue] ?? "" },
                    set: { app.toolPaths.overrides[tool.rawValue] = $0.isEmpty ? nil : $0 }),
                    prompt: Text(url?.path ?? "Not found — brew install \(tool.formula)"))
                Button("Browse…") {
                    if let u = Panels.openFiles(multiple: false, prompt: "Use").first { app.toolPaths.overrides[tool.rawValue] = u.path }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PresetSettings: View {
    @Environment(AppState.self) private var app
    @State private var selection: UUID?
    @State private var tab = "video"

    var body: some View {
        @Bindable var app = app
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(app.presets) { p in
                        HStack {
                            Text(p.name)
                            if p.id == app.defaultPreset.id { Text("default").font(.caption).foregroundStyle(.secondary) }
                        }
                        .tag(p.id)
                    }
                    .onMove { app.presets.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                HStack {
                    Button { add() } label: { Image(systemName: "plus") }.help("New preset")
                    Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }
                        .help("Duplicate").disabled(selection == nil)
                    Button { delete() } label: { Image(systemName: "minus") }
                        .help("Delete").disabled(selection == nil || app.presets.count < 2)
                    Spacer()
                    Menu("Reset") {
                        Button("Restore Built-in Presets") { app.presets += Preset.builtIn }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 200, maxWidth: 260)

            if let i = app.presets.firstIndex(where: { $0.id == selection }) {
                VStack(spacing: 0) {
                    TextField("Name", text: $app.presets[i].name).textFieldStyle(.roundedBorder).padding([.horizontal, .top], 12)
                    Picker("", selection: $tab) {
                        Text("Video").tag("video")
                        Text("Audio").tag("audio")
                        Text("Subtitles").tag("subtitles")
                        Text("Track Selection").tag("rules")
                    }
                    .pickerStyle(.segmented).labelsHidden().padding(.top, 8).padding(.horizontal, 12)
                    switch tab {
                    case "audio": AudioSettingsForm(s: $app.presets[i].settings)
                    case "subtitles":
                        Form {
                            Picker("Subtitles", selection: $app.presets[i].settings.subtitleAction) {
                                ForEach(SubtitleAction.allCases) { Text($0.label).tag($0) }
                            }
                        }
                        .formStyle(.grouped)
                    case "rules": RulesForm(rules: $app.presets[i].rules)
                    default: VideoSettingsForm(s: $app.presets[i].settings, capabilities: app.capabilities)
                    }
                }
            } else {
                Text("Select a preset").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = app.presets.first?.id } }
    }

    func add() {
        let p = Preset(name: "New Preset")
        app.presets.append(p)
        selection = p.id
    }

    func duplicate() {
        guard let p = app.presets.first(where: { $0.id == selection }) else { return }
        let copy = Preset(name: p.name + " copy", settings: p.settings, rules: p.rules)
        app.presets.append(copy)
        selection = copy.id
    }

    func delete() {
        app.presets.removeAll { $0.id == selection }
        if app.preset(app.defaultPresetID) == nil { app.defaultPresetID = app.presets.first?.id }
        selection = app.presets.first?.id
    }
}
