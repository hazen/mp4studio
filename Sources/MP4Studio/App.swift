import AppKit
import MP4StudioCore
import SwiftUI

@main
struct MP4StudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()

    var body: some Scene {
        Window("MP4Studio", id: "main") {
            ContentView()
                .environment(app)
                .frame(minWidth: 980, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open for Conversion…") {
                    app.section = .convert
                    app.convert.open(Panels.openFiles(), app: app)
                }
                .keyboardShortcut("o")
            }
            CommandGroup(after: .sidebar) {
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) { app.section = section }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Files dropped on the Dock icon or opened with "Open With" go to Convert.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            guard let app = AppStateHolder.app else { AppStateHolder.pendingURLs += urls; return }
            app.section = .convert
            app.convert.open(urls, app: app)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = MainActor.assumeIsolated { AppStateHolder.app?.queue.current != nil }
        guard running else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A job is still running."
        alert.informativeText = "Quitting stops it and deletes its partial output."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        MainActor.assumeIsolated {
            if let queue = AppStateHolder.app?.queue, let job = queue.current { queue.cancel(job) }
        }
        return .terminateNow
    }
}

/// Lets the app delegate reach the state without owning it.
@MainActor
enum AppStateHolder {
    static weak var app: AppState?
    static var pendingURLs: [URL] = []
}

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: Binding(get: { app.section }, set: { if let s = $0 { app.section = s } })) {
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .badge(section == .queue ? app.queue.pendingCount : 0)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                if !app.missingTools.isEmpty { MissingToolsBanner(tools: app.missingTools) }
                Group {
                    switch app.section {
                    case .convert: ConvertView()
                    case .editTracks: EditTracksView()
                    case .extract: ExtractView()
                    case .splitJoin: SplitJoinView()
                    case .metadata: MetadataView()
                    case .queue: QueueView()
                    case .watch: WatchFolderView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(app.section.title)
        }
        .onAppear {
            AppStateHolder.app = app
            if !AppStateHolder.pendingURLs.isEmpty {
                app.convert.open(AppStateHolder.pendingURLs, app: app)
                AppStateHolder.pendingURLs = []
            }
        }
    }
}

struct MissingToolsBanner: View {
    let tools: [Tool]

    var body: some View {
        let formulas = Array(Set(tools.map(\.formula))).sorted()
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Missing: \(tools.map(\.rawValue).joined(separator: ", "))").bold()
                Text("Install with  brew install \(formulas.joined(separator: " "))  or set the paths in Settings.")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            SettingsLink { Text("Settings…") }
        }
        .padding(10)
        .background(.yellow.opacity(0.12))
    }
}
