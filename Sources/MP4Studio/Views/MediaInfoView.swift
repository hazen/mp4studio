import AppKit
import MP4StudioCore
import SwiftUI

extension View {
    /// Adds an Info button to the toolbar that shows MediaInfo's report for `url` beside the content.
    func mediaInfoInspector(url: URL?) -> some View {
        modifier(MediaInfoInspector(url: url))
    }
}

private struct MediaInfoInspector: ViewModifier {
    let url: URL?
    @AppStorage("showMediaInfo") private var show = true

    func body(content: Content) -> some View {
        content
            .inspector(isPresented: Binding(get: { show && url != nil }, set: { show = $0 })) {
                if let url { MediaInfoPanel(url: url).inspectorColumnWidth(min: 280, ideal: 360, max: 560) }
            }
            .toolbar {
                if url != nil {
                    Button { show.toggle() } label: { Label("Info", systemImage: "info.circle") }
                        .help(show ? "Hide file info" : "Show file info")
                }
            }
    }
}

/// MediaInfo's report for one file, one section per track.
struct MediaInfoPanel: View {
    @Environment(AppState.self) private var app
    let url: URL
    @State private var report: MediaInfoReport?
    @State private var error: String?

    var body: some View {
        Group {
            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(report.sections.enumerated()), id: \.offset) { _, section in
                            SectionView(section: section)
                        }
                    }
                    .padding(12)
                }
                .safeAreaInset(edge: .top, spacing: 0) { header(report) }
            } else if let error {
                ContentUnavailableView("No File Info", systemImage: "info.circle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) { await load() }
    }

    func header(_ report: MediaInfoReport) -> some View {
        HStack {
            Text(url.lastPathComponent).font(.headline).lineLimit(2).truncationMode(.middle)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report.text, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy the full MediaInfo report")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    func load() async {
        report = nil
        error = nil
        guard let mediainfo = app.toolPaths.url(for: .mediainfo) else {
            error = "Install MediaInfo to see detailed file info:\nbrew install media-info"
            return
        }
        do { report = try await MediaInfoReport.read(url, mediainfo: mediainfo) }
        catch { self.error = error.localizedDescription }
    }
}

private struct SectionView: View {
    let section: MediaInfoReport.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
            if let summary { Text(summary).font(.callout).foregroundStyle(.secondary) }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(Array(section.fields.enumerated()), id: \.offset) { _, field in
                    GridRow {
                        Text(field.name).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        FieldValue(value: field.value)
                    }
                }
            }
            .font(.callout)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    var kind: String { section.title.components(separatedBy: " #").first ?? section.title }

    var title: String {
        switch kind {
        case "Text": return section.title.replacingOccurrences(of: "Text", with: "Subtitles")
        case "Menu": return "Chapters"
        default: return section.title
        }
    }

    var symbol: String {
        switch kind {
        case "General": return "doc"
        case "Video": return "film"
        case "Audio": return "speaker.wave.2"
        case "Text": return "captions.bubble"
        case "Menu": return "list.bullet"
        case "Image": return "photo"
        default: return "square.stack"
        }
    }

    /// A one-line digest of the most telling fields, e.g. "HEVC · 1 920 × 1 080 · 50.000 FPS · 30.0 Mb/s".
    var summary: String? {
        let s = section
        let parts: [String?]
        switch kind {
        case "General":
            parts = [s.value("Format"), s.value("File size"), s.value("Duration"), s.value("Overall bit rate")]
        case "Video":
            let size = s.value("Width").flatMap { w in s.value("Height").map { "\(w) × \($0)".replacingOccurrences(of: " pixels", with: "") } }
            // "Dolby Vision, Version 1.0, Profile 8.1, ..." is shortened to its first part.
            let hdr = s.value("HDR format")?.components(separatedBy: ",").first
            parts = [s.value("Format"), size, s.value("Frame rate"), s.value("Bit depth"), hdr, s.value("Bit rate")]
        case "Audio":
            parts = [s.value("Commercial name") ?? s.value("Format"), s.value("Channel(s)"), s.value("Sampling rate"), s.value("Bit rate"), s.value("Language")]
        case "Text":
            parts = [s.value("Format"), s.value("Language"), s.value("Forced") == "Yes" ? "forced" : nil]
        default:
            return nil
        }
        let present = parts.compactMap { $0 }
        return present.isEmpty ? nil : present.joined(separator: " · ")
    }
}

/// Long values such as encoder settings start collapsed.
private struct FieldValue: View {
    let value: String
    @State private var expanded = false

    var body: some View {
        let long = value.count > 140
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .lineLimit(long && !expanded ? 2 : nil)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if long {
                Button(expanded ? "Less" : "More") { expanded.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }
}
