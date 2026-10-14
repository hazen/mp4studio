import AppKit
import MP4StudioCore
import SwiftUI

/// iTunes-style tagging of existing MP4/M4V files with AtomicParsley. Edits the files in place.
struct MetadataView: View {
    @Observable
    final class Entry: Identifiable {
        let id = UUID()
        let url: URL
        var fields = MetadataFields()
        var saved = MetadataFields()
        var artwork: NSImage?
        var loaded = false

        init(url: URL) { self.url = url }
        var dirty: Bool { fields != saved }
    }

    @Environment(AppState.self) private var app
    @State private var entries: [Entry] = []
    @State private var selection: Entry.ID?
    @State private var errors: [String] = []
    @State private var saving = false
    @State private var note: String?

    var current: Entry? { entries.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            ErrorList(errors: $errors).padding(.horizontal).padding(.top, errors.isEmpty ? 0 : 8)
            if entries.isEmpty {
                DropPrompt(title: "Drop MP4 or M4V files",
                           detail: "Edit titles, TV show details, descriptions, cast, rating and artwork so files look right in the TV app and Plex. Files are tagged in place with AtomicParsley.",
                           buttonTitle: "Open Files…") { add(Panels.openFiles(extensions: ["mp4", "m4v"])) }
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        List(selection: $selection) {
                            ForEach(entries) { e in
                                HStack {
                                    Text(e.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if e.dirty { Circle().fill(.orange).frame(width: 7, height: 7).help("Unsaved changes") }
                                }
                                .tag(e.id)
                            }
                        }
                        Divider()
                        HStack {
                            Button { add(Panels.openFiles(extensions: ["mp4", "m4v"])) } label: { Image(systemName: "plus") }
                            Button { entries.removeAll { $0.id == selection }; selection = entries.first?.id } label: { Image(systemName: "minus") }
                                .disabled(selection == nil)
                            Spacer()
                        }
                        .buttonStyle(.borderless)
                        .padding(6)
                    }
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 340)

                    if let entry = current {
                        VStack(spacing: 0) {
                            if entry.loaded {
                                MetadataForm(fields: Binding(get: { entry.fields }, set: { entry.fields = $0 }), existingArtwork: entry.artwork)
                            } else {
                                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            Divider()
                            HStack {
                                Button("Revert") { entry.fields = entry.saved }.disabled(!entry.dirty)
                                Button("Copy Show Info to All") { copyShowInfo(from: entry) }
                                    .help("Copies media type, show, season, network, genre, year, rating and artwork to every file in the list")
                                    .disabled(entries.count < 2)
                                Spacer()
                                StatusNote(text: note)
                                if saving { ProgressView().controlSize(.small) }
                                Button("Save All") { Task { await save(entries.filter(\.dirty)) } }
                                    .disabled(saving || !entries.contains(where: \.dirty))
                                Button("Save") { Task { await save([entry]) } }
                                    .buttonStyle(.borderedProminent)
                                    .keyboardShortcut("s")
                                    .disabled(saving || !entry.dirty)
                            }
                            .padding(10)
                        }
                        .frame(minWidth: 480)
                    }
                }
            }
        }
        .onFileDrop { add($0) }
    }

    func add(_ urls: [URL]) {
        let mp4s = urls.filter { ContainerKind.of($0) == .mp4 }
        if mp4s.count < urls.count { errors.append("Only MP4 and M4V files can be tagged. Convert other files first.") }
        for url in mp4s where !entries.contains(where: { $0.url == url }) {
            let entry = Entry(url: url)
            entries.append(entry)
            if selection == nil { selection = entry.id }
            Task { await load(entry) }
        }
    }

    func load(_ entry: Entry) async {
        do {
            let read = try await MetadataBuilder(tools: app.toolPaths).read(entry.url)
            entry.fields = read.fields
            entry.saved = read.fields
            entry.artwork = read.hasArtwork ? await extractArtwork(entry.url) : nil
        } catch {
            errors.append("\(entry.url.lastPathComponent): \(error.localizedDescription)")
        }
        entry.loaded = true
    }

    /// `-e <base>` writes the artwork as <base>_artwork_1.jpg (or .png).
    func extractArtwork(_ url: URL) async -> NSImage? {
        guard let ap = app.toolPaths.url(for: .atomicParsley) else { return nil }
        let base = app.temporaryDirectory.appendingPathComponent("art-\(UUID().uuidString)")
        _ = try? await ProcessRunner.run(ap, [url.path, "-e", base.path])
        let dir = app.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard let art = files.first(where: { $0.lastPathComponent.hasPrefix(base.lastPathComponent) }) else { return nil }
        defer { for f in files where f.lastPathComponent.hasPrefix(base.lastPathComponent) { try? FileManager.default.removeItem(at: f) } }
        return NSImage(contentsOf: art)
    }

    func save(_ list: [Entry]) async {
        saving = true
        defer { saving = false }
        var count = 0
        for entry in list {
            do {
                let plan = try MetadataBuilder(tools: app.toolPaths).plan(file: entry.url, fields: entry.fields)
                for step in plan.steps { try await StepRunner(step: step, logURL: nil).run { _ in } }
                count += 1
                entry.loaded = false
                await load(entry)
            } catch {
                errors.append("\(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if count > 0 { withAnimation { note = "Saved \(count) file\(count == 1 ? "" : "s")" } }
    }

    func copyShowInfo(from source: Entry) {
        for e in entries where e.id != source.id {
            e.fields.kind = source.fields.kind
            e.fields.tvShow = source.fields.tvShow
            e.fields.tvSeason = source.fields.tvSeason
            e.fields.tvNetwork = source.fields.tvNetwork
            e.fields.genre = source.fields.genre
            e.fields.year = source.fields.year
            e.fields.ratingID = source.fields.ratingID
            if let art = source.fields.artworkPath {
                e.fields.artworkPath = art
                e.fields.removeArtwork = false
            }
        }
    }
}
