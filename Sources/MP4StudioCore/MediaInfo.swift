import Foundation

/// MediaInfo's text report, split into its sections (General, Video, Audio #1, ...).
public struct MediaInfoReport: Sendable, Equatable {
    public struct Field: Sendable, Equatable {
        public let name: String
        public let value: String
    }

    public struct Section: Sendable, Equatable {
        public let title: String
        public let fields: [Field]

        public func value(_ name: String) -> String? { fields.first { $0.name == name }?.value }
    }

    public let sections: [Section]
    /// The report as MediaInfo printed it, for copying.
    public let text: String

    public static func read(_ url: URL, mediainfo: URL) async throws -> MediaInfoReport {
        let result = try await ProcessRunner.run(mediainfo, [url.path])
        guard result.status == 0 else {
            throw ToolError.failed(tool: "mediainfo", status: result.status, message: result.stderrString)
        }
        return parse(result.stdoutString)
    }

    /// Sections are separated by blank lines; each starts with its title, followed by "Name   : value" lines.
    public static func parse(_ text: String) -> MediaInfoReport {
        var sections: [Section] = []
        var title: String?
        var fields: [Field] = []
        func finish() {
            if let title { sections.append(Section(title: title, fields: fields)) }
            title = nil
            fields = []
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { finish(); continue }
            if title == nil { title = trimmed; continue }
            guard let colon = line.range(of: " : ") ?? line.range(of: " :") else { continue }
            let name = line[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = line[colon.upperBound...].trimmingCharacters(in: .whitespaces)
            fields.append(Field(name: name, value: value))
        }
        finish()
        return MediaInfoReport(sections: sections, text: text)
    }
}
