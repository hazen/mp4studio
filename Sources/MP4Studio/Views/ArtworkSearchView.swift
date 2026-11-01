import AppKit
import MP4StudioCore
import SwiftUI

/// Searches TMDB for a movie or show, shows its posters, and replaces the artwork with the one picked.
struct ArtworkSearchSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Binding var fields: MetadataFields
    let current: NSImage?

    @State private var type = TMDBClient.MediaType.movie
    @State private var query = ""
    @State private var year = ""
    @State private var results: [TMDBClient.SearchResult] = []
    @State private var result: TMDBClient.SearchResult?
    @State private var posters: [TMDBClient.Poster] = []
    @State private var poster: TMDBClient.Poster?
    @State private var busy = false
    @State private var error: String?

    var client: TMDBClient { TMDBClient(credential: app.tmdbKey, language: Locale.current.language.languageCode?.identifier ?? "en") }
    var season: Int? { Int(fields.tvSeason.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        VStack(spacing: 0) {
            if app.tmdbKey.isEmpty {
                ContentUnavailableView {
                    Label("Add a TMDB API Key", systemImage: "key")
                } description: {
                    Text("Artwork comes from The Movie Database. Create a free key at themoviedb.org/settings/api, then add it in Settings ▸ General.")
                } actions: {
                    SettingsLink { Text("Open Settings…") }
                }
            } else {
                searchBar.padding(12)
                Divider()
                HSplitView {
                    resultList.frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
                    posterGrid.frame(minWidth: 380)
                }
            }
            Divider()
            footer.padding(12)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 540, idealHeight: 620)
        .onAppear(perform: prefill)
    }

    private var searchBar: some View {
        HStack {
            Picker("", selection: $type) {
                ForEach(TMDBClient.MediaType.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            TextField("Title", text: $query).onSubmit { Task { await search() } }
            TextField("Year", text: $year).frame(width: 60).onSubmit { Task { await search() } }
            Button("Search") { Task { await search() } }
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || busy)
        }
    }

    private var resultList: some View {
        List(results, selection: Binding(get: { result?.id }, set: { id in
            result = results.first { $0.id == id }
            Task { await loadPosters() }
        })) { r in
            HStack(alignment: .top, spacing: 8) {
                AsyncImage(url: r.posterPath.map { TMDBClient.imageURL($0, size: "w92") }) { $0.resizable().scaledToFit() }
                    placeholder: { Color.secondary.opacity(0.15) }
                    .frame(width: 36, height: 54).clipShape(RoundedRectangle(cornerRadius: 3))
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title).lineLimit(2)
                    if let y = r.year { Text(y).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .tag(r.id)
            .help(r.overview)
        }
        .overlay {
            if results.isEmpty && !busy { Text("No results").foregroundStyle(.secondary) }
        }
    }

    private var posterGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                ForEach(posters) { p in
                    Button { poster = p } label: {
                        VStack(spacing: 3) {
                            AsyncImage(url: TMDBClient.imageURL(p.filePath)) { $0.resizable().scaledToFit() }
                                placeholder: { Color.secondary.opacity(0.15).aspectRatio(2 / 3, contentMode: .fit) }
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: poster == p ? 3 : 0))
                            Text([p.group, "\(p.width)×\(p.height)", p.language?.uppercased()].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .overlay {
            if busy { ProgressView() }
            else if result != nil && posters.isEmpty { Text("No posters").foregroundStyle(.secondary) }
            else if result == nil { Text("Choose a title to see its posters").foregroundStyle(.secondary) }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            thumbnail(current.map { Image(nsImage: $0) }, label: "Current")
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            thumbnail(nil, url: poster.map { TMDBClient.imageURL($0.filePath) }, label: "New")
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).font(.callout)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Replace Artwork") { Task { await replace() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(poster == nil || busy)
        }
    }

    private func thumbnail(_ image: Image?, url: URL? = nil, label: String) -> some View {
        VStack(spacing: 2) {
            Group {
                if let image { image.resizable().scaledToFit() }
                else if let url { AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { ProgressView() } }
                else { Image(systemName: "photo").foregroundStyle(.tertiary) }
            }
            .frame(width: 40, height: 60)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Starts from the file's tags: the show name for TV, otherwise the title and year.
    private func prefill() {
        if fields.kind == .tvShow {
            type = .tv
            query = fields.tvShow.isEmpty ? fields.title : fields.tvShow
        } else {
            query = fields.title
            let y = fields.year.prefix(4)
            year = y.count == 4 && y.allSatisfy(\.isNumber) ? String(y) : ""
        }
        if !app.tmdbKey.isEmpty && !query.isEmpty { Task { await search() } }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            results = try await client.search(q, type: type, year: year.trimmingCharacters(in: .whitespaces))
            result = results.first
            posters = []
            poster = nil
            if result != nil { await loadPosters() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadPosters() async {
        guard let result else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let found = try await client.posters(for: result, season: result.type == .tv ? season : nil)
            guard self.result == result else { return }
            posters = found
            poster = found.first
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func replace() async {
        guard let poster else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let url = try await client.download(poster, to: app.temporaryDirectory)
            fields.artworkPath = url.path
            fields.removeArtwork = false
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
