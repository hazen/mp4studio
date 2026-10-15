import Foundation

/// The command-line utilities MP4Studio drives.
public enum Tool: String, CaseIterable, Codable, Sendable, Identifiable {
    case ffmpeg, ffprobe, ffplay
    case mkvmerge, mkvextract
    case mp4box = "MP4Box"
    case atomicParsley = "AtomicParsley"
    /// MP4Studio's own text recognition helper, shipped next to the app's executable.
    case subtitleOCR = "mp4studio-ocr"

    /// The tools users install and configure. The OCR helper comes with the app.
    public static let allCases: [Tool] = [.ffmpeg, .ffprobe, .ffplay, .mkvmerge, .mkvextract, .mp4box, .atomicParsley]

    public var id: String { rawValue }

    /// Homebrew formula that provides the tool.
    public var formula: String {
        switch self {
        case .ffmpeg, .ffprobe, .ffplay: return "ffmpeg"
        case .mkvmerge, .mkvextract: return "mkvtoolnix"
        case .mp4box: return "gpac"
        case .atomicParsley: return "atomicparsley"
        case .subtitleOCR: return ""
        }
    }

    public var purpose: String {
        switch self {
        case .ffmpeg: return "Converting and remuxing"
        case .ffprobe: return "Reading file and track info"
        case .ffplay: return "Previewing tracks"
        case .mkvmerge: return "MKV track editing, splitting, joining"
        case .mkvextract: return "Extracting tracks from MKV"
        case .mp4box: return "MP4 track editing, splitting, joining"
        case .atomicParsley: return "iTunes-style MP4 metadata and artwork"
        case .subtitleOCR: return "Reading text from image subtitles"
        }
    }
}

/// Where to find each tool. Empty overrides fall back to the standard install locations.
public struct ToolPaths: Codable, Sendable, Equatable {
    public var overrides: [String: String]

    public init(overrides: [String: String] = [:]) {
        self.overrides = overrides
    }

    public static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    public func url(for tool: Tool) -> URL? {
        let fm = FileManager.default
        if let override = overrides[tool.rawValue]?.trimmingCharacters(in: .whitespaces), !override.isEmpty {
            return fm.isExecutableFile(atPath: override) ? URL(fileURLWithPath: override) : nil
        }
        if tool == .subtitleOCR {
            let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(tool.rawValue)
            return helper.flatMap { fm.isExecutableFile(atPath: $0.path) ? $0 : nil }
        }
        for dir in Self.searchDirectories {
            let path = dir + "/" + tool.rawValue
            if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    public func require(_ tool: Tool) throws -> URL {
        guard let url = url(for: tool) else { throw ToolError.missing(tool) }
        return url
    }
}

public enum ToolError: LocalizedError, Equatable {
    case missing(Tool)
    case failed(tool: String, status: Int32, message: String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .missing(.subtitleOCR):
            return "The mp4studio-ocr helper is missing from the app. Rebuild it with scripts/build-app.sh."
        case .missing(let tool):
            return "\(tool.rawValue) isn't installed. Install it with: brew install \(tool.formula)"
        case .failed(let tool, let status, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(tool) failed (exit \(status))" + (trimmed.isEmpty ? "" : ": \(trimmed)")
        case .invalid(let message):
            return message
        }
    }
}

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessRunner {
    /// Runs a tool to completion and collects its output. For long jobs use `JobRunner` instead.
    public static func run(_ executable: URL, _ arguments: [String], currentDirectory: URL? = nil) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = toolEnvironment()
            if let currentDirectory { process.currentDirectoryURL = currentDirectory }
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = FileHandle.nullDevice

            let group = DispatchGroup()
            let collected = Collected()
            process.terminationHandler = { proc in
                group.notify(queue: .global()) {
                    continuation.resume(returning: ProcessResult(status: proc.terminationStatus, stdout: collected.out, stderr: collected.err))
                }
            }
            group.enter()
            group.enter()
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().async { collected.out = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            DispatchQueue.global().async { collected.err = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        }
    }

    /// Output gathered on two reader threads; the DispatchGroup orders the writes before the read.
    private final class Collected: @unchecked Sendable {
        var out = Data()
        var err = Data()
    }

    /// Environment for child tools: UTF-8 locale and a PATH that includes Homebrew.
    public static func toolEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        let path = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (ToolPaths.searchDirectories + [path]).joined(separator: ":")
        return env
    }
}

/// What the installed ffmpeg build can do. Detected once at launch.
public struct FFmpegCapabilities: Sendable, Equatable {
    public var encoders: Set<String>
    public var filters: Set<String>

    public init(encoders: Set<String> = [], filters: Set<String> = []) {
        self.encoders = encoders
        self.filters = filters
    }

    /// Assumes a full build; used in tests and before detection finishes.
    public static let full = FFmpegCapabilities(
        encoders: ["libx264", "libx265", "h264_videotoolbox", "hevc_videotoolbox", "aac", "aac_at", "ac3", "eac3", "mov_text", "srt"],
        filters: ["subtitles", "overlay", "scale"]
    )

    public var hasSubtitlesFilter: Bool { filters.contains("subtitles") }
    public var aacEncoder: String { encoders.contains("aac_at") ? "aac_at" : "aac" }

    public static func detect(ffmpeg: URL) async -> FFmpegCapabilities {
        async let enc = try? ProcessRunner.run(ffmpeg, ["-hide_banner", "-encoders"])
        async let fil = try? ProcessRunner.run(ffmpeg, ["-hide_banner", "-filters"])
        return FFmpegCapabilities(
            encoders: parseList(await enc?.stdoutString ?? ""),
            filters: parseList(await fil?.stdoutString ?? "")
        )
    }

    /// Lines look like " V....D libx264   description" — the name is the second column.
    static func parseList(_ text: String) -> Set<String> {
        var names = Set<String>()
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 2, cols[0].count >= 3, cols[1] != "=" else { continue }
            names.insert(String(cols[1]))
        }
        return names
    }
}

/// Quotes arguments for display in logs, so a command can be copied into Terminal.
public func shellQuoted(_ args: [String]) -> String {
    args.map { arg in
        if arg.isEmpty { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=+,@%"))
        if arg.unicodeScalars.allSatisfy({ safe.contains($0) }) { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }.joined(separator: " ")
}
