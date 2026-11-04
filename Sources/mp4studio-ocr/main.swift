import Foundation
import MP4StudioCore

// mp4studio-ocr <input.sup|input.idx> <output.srt> [language]
// Reads image subtitles, recognizes their text with Vision and writes SRT.
// Prints progress the way mkvtoolnix's --gui-mode does, so the job queue can parse it.

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: mp4studio-ocr <input.sup|input.idx> <output.srt> [language]\n".utf8))
    exit(2)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let language = args.count > 3 ? args[3] : nil

@Sendable func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

do {
    let images = try SubtitleOCR.readImages(input)
    say("Read \(images.count) subtitle images from \(input.lastPathComponent)")
    let lastPercent = Mutex(-1)
    let result = SubtitleOCR.recognize(images, language: language) { fraction in
        let percent = Int(fraction * 100)
        if lastPercent.swap(percent) != percent { say("#GUI#progress \(percent)%") }
    }
    try SubtitleOCR.srt(result.cues).write(to: output, atomically: true, encoding: .utf8)
    say("Wrote \(result.cues.count) subtitles to \(output.lastPathComponent)")
    if !result.unreadable.isEmpty {
        let times = result.unreadable.prefix(10).map { SubtitleOCR.timestamp($0.start) }.joined(separator: ", ")
        say("Warning: no text found in \(result.unreadable.count) image(s), starting at \(times)\(result.unreadable.count > 10 ? ", …" : "")")
    }
    if images.isEmpty || result.cues.isEmpty {
        FileHandle.standardError.write(Data("No text was recognized in \(input.lastPathComponent).\n".utf8))
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}

final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    /// Stores a new value and returns the old one.
    func swap(_ new: Value) -> Value { lock.withLock { defer { value = new }; return value } }
}
