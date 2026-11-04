import AppKit
import MP4StudioCore
import SwiftUI

/// What to do when an output file already exists.
enum ExistingOutput { case replace, keepBoth }

/// Output files that already exist; `resolve` runs with the user's choice.
struct OutputConflict {
    let existing: [URL]
    let resolve: (ExistingOutput) -> Void

    var title: String {
        existing.count == 1 ? "“\(existing[0].lastPathComponent)” already exists." : "\(existing.count) output files already exist."
    }

    var message: String {
        let files = existing.count == 1 ? "the existing file" : "the existing files (\(existing.map(\.lastPathComponent).joined(separator: ", ")))"
        return "Replace moves \(files) to the Trash. Keep Both saves the new \(existing.count == 1 ? "file" : "files") with a number added to the name."
    }
}

extension View {
    /// Asks whether to replace existing output files or keep both.
    func outputConflictAlert(_ conflict: Binding<OutputConflict?>) -> some View {
        alert(conflict.wrappedValue?.title ?? "",
              isPresented: Binding(get: { conflict.wrappedValue != nil }, set: { if !$0 { conflict.wrappedValue = nil } }),
              presenting: conflict.wrappedValue) { c in
            Button("Replace", role: .destructive) { c.resolve(.replace) }
            Button("Keep Both") { c.resolve(.keepBoth) }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text(c.message)
        }
    }
}

/// Large drop target shown when nothing is loaded.
struct DropPrompt: View {
    let title: String
    let detail: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(buttonTitle, action: action).controlSize(.large).keyboardShortcut("o")
        }
        .frame(maxWidth: 420)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(.quaternary)
                .padding(24)
        )
    }
}

struct LanguagePicker: View {
    @Binding var code: String

    var body: some View {
        Picker("", selection: $code) {
            if !Languages.all.contains(where: { $0.code == code }) {
                Text(code).tag(code)
            }
            ForEach(Languages.all) { lang in
                Text(lang.code == "und" ? "Undetermined" : "\(lang.name) (\(lang.code))").tag(lang.code)
            }
        }
        .labelsHidden()
    }
}

/// Track table shared by Convert, Edit Tracks and Extract.
struct TrackTable: View {
    struct Options {
        var checkLabel = "Use"
        var editable = true
        var showForced = true
        var allowRemoveExtra = false
    }

    let tracks: [MediaTrack]
    @Binding var checked: Set<String>
    var options = Options()
    var update: (String, (inout MediaTrack) -> Void) -> Void = { _, _ in }
    var removeSource: ((MediaTrack) -> Void)?

    var body: some View {
        Table(tracks) {
            TableColumn(options.checkLabel) { t in
                Toggle("", isOn: Binding(
                    get: { checked.contains(t.id) },
                    set: { on in if on { checked.insert(t.id) } else { checked.remove(t.id) } }))
                .labelsHidden()
                .disabled(t.kind == .attachment || t.kind == .data)
            }
            .width(30)
            TableColumn("#") { t in
                Text(t.inputIndex == 0 ? "\(t.streamIndex)" : "+\(t.inputIndex).\(t.streamIndex)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help(t.inputIndex == 0 ? "Stream \(t.streamIndex)" : "From \(t.sourceURL.lastPathComponent)")
            }
            .width(34)
            TableColumn("Type") { t in
                Label(t.kind.label, systemImage: t.kind.symbol)
            }
            .width(min: 70, ideal: 80)
            TableColumn("Codec") { t in Text(t.codecLabel) }
                .width(min: 50, ideal: 64)
            TableColumn("Details") { t in
                Text(t.details).foregroundStyle(.secondary).help(t.inputIndex == 0 ? t.details : t.sourceURL.lastPathComponent)
            }
            .width(min: 80, ideal: 130)
            TableColumn("Language") { t in
                if options.editable && t.kind != .attachment {
                    LanguagePicker(code: Binding(get: { t.language }, set: { v in update(t.id) { $0.language = v } }))
                } else {
                    Text(Languages.name(for: t.language))
                }
            }
            .width(min: 100, ideal: 130)
            TableColumn("Title") { t in
                if options.editable && t.kind != .attachment {
                    TextField("", text: Binding(get: { t.title }, set: { v in update(t.id) { $0.title = v } }))
                } else {
                    Text(t.title)
                }
            }
            .width(min: 70, ideal: 100)
            TableColumn("Default") { t in
                Toggle("", isOn: Binding(get: { t.isDefault }, set: { v in update(t.id) { $0.isDefault = v } }))
                    .labelsHidden()
                    .disabled(!options.editable || t.kind == .attachment)
            }
            .width(48)
            TableColumn("Forced") { t in
                if t.kind == .subtitle && options.showForced {
                    Toggle("", isOn: Binding(get: { t.isForced }, set: { v in update(t.id) { $0.isForced = v } }))
                        .labelsHidden()
                        .disabled(!options.editable)
                }
            }
            .width(46)
            TableColumn("") { t in
                if t.inputIndex > 0, let removeSource {
                    Button { removeSource(t) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove \(t.sourceURL.lastPathComponent)")
                }
            }
            .width(24)
        }
    }
}

struct FolderField: View {
    let label: String
    @Binding var url: URL?

    var body: some View {
        LabeledContent(label) {
            HStack {
                Text(url?.path(percentEncoded: false) ?? "None")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(url?.path ?? "")
                Button("Choose…") { if let u = Panels.chooseFolder(start: url) { url = u } }
                if let url {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "arrow.right.circle") }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                }
            }
        }
    }
}

struct ErrorList: View {
    @Binding var errors: [String]

    var body: some View {
        if !errors.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(errors.enumerated()), id: \.offset) { _, e in
                    Label(e, systemImage: "xmark.octagon.fill")
                        .symbolRenderingMode(.multicolor)
                        .textSelection(.enabled)
                }
                Button("Dismiss") { errors.removeAll() }.buttonStyle(.link)
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct WarningList: View {
    let warnings: [String]

    var body: some View {
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A one-line status message shown after queueing or saving.
struct StatusNote: View {
    let text: String?

    var body: some View {
        if let text {
            Label(text, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
                .transition(.opacity)
        }
    }
}

extension View {
    /// Accepts dropped file URLs.
    func onFileDrop(_ handler: @escaping ([URL]) -> Void) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            handler(files)
            return true
        }
    }
}
