import AppKit
import Foundation

/// Writes real PGS (.sup) and VobSub (.idx/.sub) files from text, for testing text recognition.
/// Text is white with a black outline on a transparent background, like most disc subtitles.
enum SubtitleFixtures {
    struct Cue { var start: Double; var end: Double; var text: String }

    /// Palette indexes: 0 transparent, 1 text, 2 outline.
    static func render(_ text: String, fontSize: CGFloat, bold: Bool = false) -> (width: Int, height: Int, pixels: [UInt8]) {
        let font = NSFont(name: bold ? "Helvetica Neue Bold" : "Helvetica Neue", size: fontSize) ?? .systemFont(ofSize: fontSize)
        let lines = text.split(separator: "\n").map {
            NSAttributedString(string: String($0), attributes: [.font: font, .foregroundColor: NSColor.white,
                                                                .strokeColor: NSColor.black, .strokeWidth: -5])
        }
        let lineHeight = ceil(fontSize * 1.3)
        let width = Int(ceil(lines.map { $0.size().width }.max()! + fontSize))
        let height = Int(lineHeight) * lines.count + Int(fontSize / 2)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (n, line) in lines.enumerated() {
            let x = (CGFloat(width) - line.size().width) / 2
            line.draw(at: CGPoint(x: x, y: CGFloat(height) - lineHeight * CGFloat(n + 1)))
        }
        NSGraphicsContext.restoreGraphicsState()
        let rgba = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: width * height)
        // Row 0 of the bitmap is the top of the image.
        for i in 0..<(width * height) where rgba[i * 4 + 3] >= 96 {
            let alpha = Double(rgba[i * 4 + 3])
            let luma = Double(rgba[i * 4]) / alpha * 255
            pixels[i] = luma > 128 ? 1 : 2
        }
        return (width, height, pixels)
    }

    // MARK: PGS

    static func writeSUP(_ cues: [Cue], to url: URL, screen: (w: Int, h: Int) = (1920, 1080), fontSize: CGFloat = 48) throws {
        var out = Data()
        func segment(_ pts: Double, _ type: UInt8, _ payload: [UInt8]) {
            let t = UInt32(pts * 90_000)
            out += [0x50, 0x47] + be32(t) + be32(t) + [type] + be16(payload.count) + payload
        }
        for (n, cue) in cues.enumerated() {
            let img = render(cue.text, fontSize: fontSize)
            let x = (screen.w - img.width) / 2, y = screen.h - img.height - 60
            // Show: composition (epoch start, one object), window, palette, object, end.
            segment(cue.start, 0x16, be16(screen.w) + be16(screen.h) + [0x10] + be16(n * 2) + [0x80, 0, 0, 1]
                    + be16(0) + [0, 0] + be16(x) + be16(y))
            segment(cue.start, 0x17, [1, 0] + be16(x) + be16(y) + be16(img.width) + be16(img.height))
            segment(cue.start, 0x14, [0, 0, 1, 235, 128, 128, 255, 2, 16, 128, 128, 255])
            let rle = pgsRLE(img.pixels, width: img.width, height: img.height)
            segment(cue.start, 0x15, be16(0) + [0, 0xC0] + be24(rle.count + 4) + be16(img.width) + be16(img.height) + rle)
            segment(cue.start, 0x80, [])
            // Clear: an empty composition.
            segment(cue.end, 0x16, be16(screen.w) + be16(screen.h) + [0x10] + be16(n * 2 + 1) + [0, 0, 0, 0])
            segment(cue.end, 0x17, [1, 0] + be16(x) + be16(y) + be16(img.width) + be16(img.height))
            segment(cue.end, 0x80, [])
        }
        try out.write(to: url)
    }

    static func pgsRLE(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out: [UInt8] = []
        for y in 0..<height {
            var x = 0
            while x < width {
                let c = pixels[y * width + x]
                var run = 1
                while x + run < width, pixels[y * width + x + run] == c, run < 16383 { run += 1 }
                switch (c, run) {
                case (0, ..<64): out += [0, UInt8(run)]
                case (0, _): out += [0, UInt8(0x40 | run >> 8), UInt8(run & 0xFF)]
                case (_, ...2): out += Array(repeating: c, count: run)
                case (_, ..<64): out += [0, UInt8(0x80 | run), c]
                default: out += [0, UInt8(0xC0 | run >> 8), UInt8(run & 0xFF), c]
                }
                x += run
            }
            out += [0, 0]
        }
        return out
    }

    // MARK: VobSub

    static func writeVobSub(_ cues: [Cue], idx: URL, screen: (w: Int, h: Int) = (720, 480), fontSize: CGFloat = 30) throws {
        var sub = Data()
        var index = "# VobSub index file, v7\nsize: \(screen.w)x\(screen.h)\n"
        index += "palette: 000000, ffffff, 000000, 808080, 808080, 808080, 808080, 808080, 808080, 808080, 808080, 808080, 808080, 808080, 808080, 808080\n"
        index += "id: en, index: 0\n"
        for cue in cues {
            // DVD subtitles use heavy type so a 2-color image stays readable.
            let img = render(cue.text, fontSize: fontSize, bold: true)
            let x = (screen.w - img.width) / 2, y = screen.h - img.height - 30
            let ms = Int((cue.start * 1000).rounded())
            index += String(format: "timestamp: %02d:%02d:%02d:%03d, filepos: %09x\n", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000, sub.count)
            let spu = makeSPU(img, x: x, y: y, duration: cue.end - cue.start)
            // Split across PES packets the way DVDs do, each in its own pack.
            var rest = spu[...]
            var first = true
            while !rest.isEmpty {
                let chunk = rest.prefix(2000)
                rest = rest.dropFirst(chunk.count)
                let header: [UInt8] = first ? [0x81, 0x80, 5, 0x21, 0, 1, 0, 1] : [0x81, 0, 0]
                let payload = header + [0x20] + chunk
                sub += [0, 0, 1, 0xBA, 0x44, 0, 4, 0, 4, 1, 1, 0x89, 0xC3, 0xF8]
                sub += [0, 0, 1, 0xBD] + be16(payload.count) + payload
                first = false
            }
        }
        try index.write(to: idx, atomically: true, encoding: .utf8)
        try sub.write(to: idx.deletingPathExtension().appendingPathExtension("sub"))
    }

    static func makeSPU(_ img: (width: Int, height: Int, pixels: [UInt8]), x: Int, y: Int, duration: Double) -> [UInt8] {
        // Pixel values 0 background, 1 pattern (text), 2 emphasis 1 (outline).
        let top = nibbleRLE(img, rows: stride(from: 0, to: img.height, by: 2))
        let bottom = nibbleRLE(img, rows: stride(from: 1, to: img.height, by: 2))
        let topOffset = 4, bottomOffset = 4 + top.count
        let ctrl = bottomOffset + bottom.count
        let x2 = x + img.width - 1, y2 = y + img.height - 1
        var seq1: [UInt8] = [0x03, 0x00, 0x10, 0x04, 0x0F, 0xF0]   // colors: e2 0, e1 0, pattern 1, background 0; alpha: background 0
        seq1 += [0x05, UInt8(x >> 4), UInt8((x & 0xF) << 4 | x2 >> 8), UInt8(x2 & 0xFF),
                 UInt8(y >> 4), UInt8((y & 0xF) << 4 | y2 >> 8), UInt8(y2 & 0xFF)]
        seq1 += [0x06] + be16(topOffset) + be16(bottomOffset) + [0x01, 0xFF]
        let seq2Offset = ctrl + 4 + seq1.count
        let stop = Int((duration * 90_000 / 1024).rounded())
        let control = be16(0) + be16(seq2Offset) + seq1 + be16(stop) + be16(seq2Offset) + [0x02, 0xFF]
        let body = top + bottom + control
        return be16(body.count + 4) + be16(ctrl) + body
    }

    static func nibbleRLE(_ img: (width: Int, height: Int, pixels: [UInt8]), rows: StrideTo<Int>) -> [UInt8] {
        var nibbles: [UInt8] = []
        for y in rows {
            var x = 0
            while x < img.width {
                let c = img.pixels[y * img.width + x]
                var run = 1
                while x + run < img.width, img.pixels[y * img.width + x + run] == c, run < 255 { run += 1 }
                let v = run << 2 | Int(c)
                let count = run < 4 ? 1 : run < 16 ? 2 : run < 64 ? 3 : 4
                for k in (0..<count).reversed() { nibbles.append(UInt8(v >> (k * 4) & 0xF)) }
                x += run
            }
            if nibbles.count % 2 == 1 { nibbles.append(0) }
        }
        return stride(from: 0, to: nibbles.count, by: 2).map { nibbles[$0] << 4 | nibbles[$0 + 1] }
    }

    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func be24(_ v: Int) -> [UInt8] { [UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
}
