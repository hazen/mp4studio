import CoreGraphics
import Foundation
import Vision

public struct SubtitleCue: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Turns PGS and VobSub image subtitles into text with the Vision framework.
public enum SubtitleOCR {
    public static let supportedCodecs: Set<String> = ["hdmv_pgs_subtitle", "dvd_subtitle"]

    /// Reads a .sup or .idx (with its .sub).
    public static func readImages(_ url: URL) throws -> [SubtitleImage] {
        switch url.pathExtension.lowercased() {
        case "sup": return try PGSReader.read(url)
        case "idx": return try VobSubReader.read(idx: url)
        default: throw ToolError.invalid("Text recognition reads PGS (.sup) or VobSub (.idx/.sub) subtitles.")
        }
    }

    public struct Result: Sendable {
        public var cues: [SubtitleCue]
        /// Images with no readable text.
        public var unreadable: [SubtitleImage]
    }

    /// Recognizes every image, several at a time. `language` is an ISO 639-2 code; nil or "und" lets Vision detect it.
    public static func recognize(_ images: [SubtitleImage], language: String?, progress: @escaping @Sendable (Double) -> Void = { _ in }) -> Result {
        let languages = visionLanguages(for: language)
        let texts = Texts(count: images.count)
        DispatchQueue.concurrentPerform(iterations: images.count) { n in
            let text = autoreleasepool { recognize(images[n], languages: languages) }
            progress(texts.set(n, text))
        }
        var cues: [SubtitleCue] = []
        var unreadable: [SubtitleImage] = []
        for (image, text) in zip(images, texts.values) {
            guard let text, !text.isEmpty else {
                if image.ink.contains(where: { $0 > 64 }) { unreadable.append(image) }
                continue
            }
            // Fades are drawn as several images of the same text; join them into one cue.
            if let last = cues.last, last.text == text, image.start - last.end < 0.25 {
                cues[cues.count - 1].end = max(last.end, image.end)
            } else {
                cues.append(SubtitleCue(start: image.start, end: image.end, text: text))
            }
        }
        // Keep cues from overlapping the next one.
        for n in cues.indices.dropLast() where cues[n].end > cues[n + 1].start {
            cues[n].end = max(cues[n].start, cues[n + 1].start)
        }
        return Result(cues: cues, unreadable: unreadable)
    }

    private final class Texts: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var values: [String?]
        private var done = 0
        init(count: Int) { values = Array(repeating: nil, count: count) }
        /// Stores a result and returns the fraction finished.
        func set(_ n: Int, _ text: String?) -> Double {
            lock.withLock {
                values[n] = text
                done += 1
                return Double(done) / Double(values.count)
            }
        }
    }

    static func recognize(_ image: SubtitleImage, languages: [String]) -> String? {
        guard let cg = prepare(image) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = languages
        }
        do {
            try VNImageRequestHandler(cgImage: cg).perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap { obs -> (box: CGRect, text: String)? in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            return (obs.boundingBox, text)
        }
        return join(lines)
    }

    /// Vision's boxes have their origin at the bottom left. Boxes at the same height are one line, read left to right.
    static func join(_ boxes: [(box: CGRect, text: String)]) -> String {
        var rows: [[(box: CGRect, text: String)]] = []
        for item in boxes.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let last = rows.last?.first, abs(last.box.midY - item.box.midY) < min(last.box.height, item.box.height) / 2 {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows
            .map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Crops to the text, makes it dark on white at full contrast, and enlarges small (DVD) images.
    static func prepare(_ image: SubtitleImage) -> CGImage? {
        let w = image.width, h = image.height
        var minX = w, minY = h, maxX = -1, maxY = -1, peak: UInt8 = 0
        for y in 0..<h {
            for x in 0..<w where image.ink[y * w + x] > 24 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                peak = max(peak, image.ink[y * w + x])
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let cw = maxX - minX + 1, ch = maxY - minY + 1
        let gain = 255 / Double(peak)
        var pixels = [UInt8](repeating: 255, count: cw * ch)
        for y in 0..<ch {
            for x in 0..<cw {
                let ink = Double(image.ink[(y + minY) * w + x + minX]) * gain
                pixels[y * cw + x] = UInt8(max(0, 255 - ink.rounded()))
            }
        }
        let gray = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cropped = CGImage(width: cw, height: ch, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: cw, space: gray,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                    decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }

        // DVD text is often under 30 px tall; Vision does better with it doubled or tripled. Margins help too.
        let scale = ch < 60 ? 3 : ch < 120 ? 2 : 1
        let pad = 24
        let outW = cw * scale + pad * 2, outH = ch * scale + pad * 2
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: outW, space: gray,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: pad, y: pad, width: cw * scale, height: ch * scale))
        return ctx.makeImage()
    }

    /// Vision's codes for an ISO 639-2 language, e.g. "fre" -> ["fr-FR"]. Empty when Vision can't read it.
    static func visionLanguages(for code: String?) -> [String] {
        let normalized = Languages.normalize(code)
        guard let alpha2 = Languages.all.first(where: { $0.code == normalized })?.alpha2 else { return [] }
        let supported = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
        return supported.filter { $0 == alpha2 || $0.hasPrefix(alpha2 + "-") }.prefix(1).map { $0 }
    }

    public static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { n, cue in
            "\(n + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    public static func timestamp(_ seconds: Double) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
