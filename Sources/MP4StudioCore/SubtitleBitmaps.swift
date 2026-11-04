import Foundation

/// One image subtitle, flattened to "ink": how strongly each pixel reads as text.
/// Each pixel is its brightness composited over black, so the usual white or yellow text stays and its dark outline drops out.
public struct SubtitleImage: Sendable {
    public var start: Double
    public var end: Double
    public var width: Int
    public var height: Int
    /// Row-major, 0 = nothing, 255 = full-strength text.
    public var ink: [UInt8]
    public var isForced: Bool

    public init(start: Double, end: Double, width: Int, height: Int, ink: [UInt8], isForced: Bool = false) {
        self.start = start
        self.end = end
        self.width = width
        self.height = height
        self.ink = ink
        self.isForced = isForced
    }
}

/// How long a subtitle stays up when the stream doesn't say.
let defaultSubtitleDuration = 5.0

// MARK: - PGS (.sup)

/// Reads Blu-ray PGS subtitles from a .sup file: "PG" segments holding palettes, RLE objects and compositions.
public enum PGSReader {
    public static func read(_ url: URL) throws -> [SubtitleImage] {
        try read(Data(contentsOf: url))
    }

    struct Placement { var objectID: Int; var x: Int; var y: Int; var crop: (x: Int, y: Int, w: Int, h: Int)?; var forced: Bool }
    struct Object { var width = 0; var height = 0; var data: [UInt8] = [] }

    public static func read(_ data: Data) throws -> [SubtitleImage] {
        let d = [UInt8](data)
        var images: [SubtitleImage] = []
        var palettes: [Int: [UInt8]] = [:]   // palette ID -> ink per color index
        var objects: [Int: Object] = [:]
        var pending: (pts: Double, paletteID: Int, placements: [Placement])?
        var open: SubtitleImage?

        var i = 0
        while i + 13 <= d.count {
            guard d[i] == 0x50, d[i + 1] == 0x47 else {
                throw ToolError.invalid("This isn't a PGS (.sup) subtitle file, or it's damaged near byte \(i).")
            }
            let pts = Double(u32(d, i + 2)) / 90_000
            let type = d[i + 10]
            let size = u16(d, i + 11)
            let p = i + 13
            i = p + size
            guard i <= d.count else { break }
            let seg = d[p..<i]

            switch type {
            case 0x16 where seg.count >= 11:   // Presentation composition
                let state = seg[p + 7]
                if state & 0x80 != 0 { objects = [:]; palettes = [:] }   // epoch start
                var placements: [Placement] = []
                var q = p + 11
                for _ in 0..<Int(seg[p + 10]) {
                    guard q + 8 <= i else { break }
                    let flags = d[q + 3]
                    var placement = Placement(objectID: u16(d, q), x: u16(d, q + 4), y: u16(d, q + 6), crop: nil, forced: flags & 0x40 != 0)
                    q += 8
                    if flags & 0x80 != 0, q + 8 <= i {
                        placement.crop = (u16(d, q), u16(d, q + 2), u16(d, q + 4), u16(d, q + 6))
                        q += 8
                    }
                    placements.append(placement)
                }
                pending = (pts, Int(seg[p + 9]), placements)
            case 0x14 where seg.count >= 2:    // Palette definition: id, version, then (index, Y, Cr, Cb, A)
                var ink = palettes[Int(seg[p])] ?? [UInt8](repeating: 0, count: 256)
                var q = p + 2
                while q + 5 <= i {
                    let y = Double(d[q + 1]), a = Double(d[q + 4])
                    let luma = min(1, max(0, (y - 16) / 219))
                    ink[Int(d[q])] = UInt8((luma * a).rounded())
                    q += 5
                }
                palettes[Int(seg[p])] = ink
            case 0x15 where seg.count >= 4:    // Object definition, possibly in fragments
                let id = u16(d, p)
                let sequence = d[p + 3]
                if sequence & 0x80 != 0, seg.count >= 11 {
                    objects[id] = Object(width: u16(d, p + 7), height: u16(d, p + 9), data: Array(d[(p + 11)..<i]))
                } else {
                    objects[id]?.data += d[(p + 4)..<i]
                }
            case 0x80:                         // End of display set
                guard let set = pending else { break }
                pending = nil
                if var shown = open {
                    shown.end = set.pts
                    images.append(shown)
                    open = nil
                }
                guard !set.placements.isEmpty else { break }
                open = render(set.placements, objects: objects, ink: palettes[set.paletteID] ?? [UInt8](repeating: 0, count: 256), at: set.pts)
            default:
                break
            }
        }
        if var shown = open {
            shown.end = shown.start + defaultSubtitleDuration
            images.append(shown)
        }
        return images
    }

    static func render(_ placements: [Placement], objects: [Int: Object], ink: [UInt8], at pts: Double) -> SubtitleImage? {
        // Each placement covers the object, or its cropped part, at (x, y) on screen.
        var parts: [(rect: (x: Int, y: Int, w: Int, h: Int), src: (x: Int, y: Int), pixels: [UInt8], stride: Int)] = []
        for pl in placements {
            guard let obj = objects[pl.objectID], obj.width > 0, obj.height > 0 else { continue }
            let pixels = decodeRLE(obj.data, width: obj.width, height: obj.height)
            let c = pl.crop ?? (0, 0, obj.width, obj.height)
            let w = min(c.w, obj.width - c.x), h = min(c.h, obj.height - c.y)
            guard w > 0, h > 0 else { continue }
            parts.append(((pl.x, pl.y, w, h), (c.x, c.y), pixels, obj.width))
        }
        guard !parts.isEmpty else { return nil }
        let minX = parts.map(\.rect.x).min()!, minY = parts.map(\.rect.y).min()!
        let maxX = parts.map { $0.rect.x + $0.rect.w }.max()!, maxY = parts.map { $0.rect.y + $0.rect.h }.max()!
        let width = maxX - minX, height = maxY - minY
        var out = [UInt8](repeating: 0, count: width * height)
        for part in parts {
            for row in 0..<part.rect.h {
                let src = (part.src.y + row) * part.stride + part.src.x
                let dst = (part.rect.y - minY + row) * width + (part.rect.x - minX)
                for col in 0..<part.rect.w {
                    out[dst + col] = max(out[dst + col], ink[Int(part.pixels[src + col])])
                }
            }
        }
        return SubtitleImage(start: pts, end: pts, width: width, height: height, ink: out,
                             isForced: placements.contains { $0.forced })
    }

    /// PGS run-length coding: a non-zero byte is one pixel; 0 starts a run, and 0 0 ends the line.
    static func decodeRLE(_ data: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        var x = 0, y = 0, i = 0
        func put(_ color: UInt8, _ count: Int) {
            guard y < height else { return }
            let n = min(count, width - x)
            if n > 0, color != 0 { for k in 0..<n { out[y * width + x + k] = color } }
            x += max(n, 0)
        }
        while i < data.count, y < height {
            let b = data[i]; i += 1
            if b != 0 { put(b, 1); continue }
            guard i < data.count else { break }
            let f = data[i]; i += 1
            if f == 0 { x = 0; y += 1; continue }
            var length = Int(f & 0x3F)
            if f & 0x40 != 0 { guard i < data.count else { break }; length = length << 8 | Int(data[i]); i += 1 }
            var color: UInt8 = 0
            if f & 0x80 != 0 { guard i < data.count else { break }; color = data[i]; i += 1 }
            put(color, length)
        }
        return out
    }
}

// MARK: - VobSub (.idx + .sub)

/// Reads DVD VobSub subtitles: the .idx gives the palette and each subtitle's time and offset into the .sub.
public enum VobSubReader {
    public static func read(idx: URL) throws -> [SubtitleImage] {
        let sub = idx.deletingPathExtension().appendingPathExtension("sub")
        guard FileManager.default.fileExists(atPath: sub.path) else {
            throw ToolError.invalid("\(sub.lastPathComponent) is missing. VobSub needs the .sub next to the .idx.")
        }
        return try read(idx: String(decoding: Data(contentsOf: idx), as: UTF8.self), sub: [UInt8](Data(contentsOf: sub)))
    }

    public static func read(idx text: String, sub: [UInt8]) throws -> [SubtitleImage] {
        var palette: [Double] = (0..<16).map { Double($0) / 15 }   // brightness 0...1 per palette entry
        var entries: [(time: Double, pos: Int)] = []
        var ids = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("palette:") {
                let colors = line.dropFirst(8).split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces), radix: 16) }
                if colors.count == 16 {
                    palette = colors.map { c in
                        (0.299 * Double(c >> 16 & 0xFF) + 0.587 * Double(c >> 8 & 0xFF) + 0.114 * Double(c & 0xFF)) / 255
                    }
                }
            } else if line.hasPrefix("id:") {
                ids += 1
            } else if line.hasPrefix("timestamp:"), ids <= 1 {
                // timestamp: 00:01:02:345, filepos: 00000a000
                let parts = line.split(separator: ",")
                guard parts.count >= 2 else { continue }
                let t = parts[0].dropFirst(10).trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Double($0) }
                let pos = parts[1].split(separator: ":").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces), radix: 16) }
                guard t.count == 4, let pos else { continue }
                entries.append((t[0] * 3600 + t[1] * 60 + t[2] + t[3] / 1000, pos))
            }
        }

        var images: [SubtitleImage] = []
        for (n, entry) in entries.enumerated() {
            guard let spu = readSPU(sub, at: entry.pos), var image = decodeSPU(spu, palette: palette) else { continue }
            let next = n + 1 < entries.count ? entries[n + 1].time : nil
            image.start += entry.time
            image.end = image.end > 0 ? entry.time + image.end : min(next ?? .infinity, image.start + defaultSubtitleDuration)
            images.append(image)
        }
        return images
    }

    /// Collects one subtitle packet from the MPEG program stream, which may span several PES packets.
    static func readSPU(_ d: [UInt8], at start: Int) -> [UInt8]? {
        var spu: [UInt8] = []
        var expected: Int?
        var i = start
        while i + 6 <= d.count, d[i] == 0, d[i + 1] == 0, d[i + 2] == 1 {
            let code = d[i + 3]
            if code == 0xBA {   // pack header: MPEG-2 is 14 bytes plus stuffing, MPEG-1 is 12
                i += d[i + 4] & 0xC0 == 0x40 ? 14 + Int(d[i + 13] & 7) : 12
                continue
            }
            let next = i + 6 + u16(d, i + 4)
            if code == 0xBD, i + 9 <= d.count {   // private stream 1: PES header, substream byte, then data
                let p = i + 9 + Int(d[i + 8]) + 1
                if p < next, next <= d.count { spu += d[p..<next] }
                if expected == nil, spu.count >= 2 { expected = u16(spu, 0) }
                if let e = expected, spu.count >= e { return Array(spu[0..<e]) }
            }
            i = next
        }
        return spu.count > 4 ? spu : nil
    }

    /// Decodes a DVD subpicture unit. Start and end are seconds after the .idx timestamp; end is 0 when the stream doesn't say.
    static func decodeSPU(_ d: [UInt8], palette: [Double]) -> SubtitleImage? {
        guard d.count >= 4 else { return nil }
        let size = min(u16(d, 0), d.count)
        var colors = [0, 1, 2, 3], alpha = [0, 15, 15, 15]
        var x1 = 0, x2 = -1, y1 = 0, y2 = -1, top = 0, bottom = 0
        var startDelay = 0.0, stopDelay = 0.0, forced = false
        var off = u16(d, 2)
        var seen = Set<Int>()
        while off + 4 <= size, seen.insert(off).inserted {
            let delay = Double(u16(d, off)) * 1024 / 90_000
            let next = u16(d, off + 2)
            var p = off + 4
            commands: while p < size {
                let cmd = d[p]; p += 1
                switch cmd {
                case 0x00: forced = true; startDelay = delay
                case 0x01: startDelay = delay
                case 0x02: stopDelay = delay
                case 0x03, 0x04:
                    guard p + 2 <= size else { break commands }
                    let values = [Int(d[p + 1] & 0xF), Int(d[p + 1] >> 4), Int(d[p] & 0xF), Int(d[p] >> 4)]
                    if cmd == 0x03 { colors = values } else { alpha = values }
                    p += 2
                case 0x05:
                    guard p + 6 <= size else { break commands }
                    x1 = Int(d[p]) << 4 | Int(d[p + 1]) >> 4
                    x2 = Int(d[p + 1] & 0xF) << 8 | Int(d[p + 2])
                    y1 = Int(d[p + 3]) << 4 | Int(d[p + 4]) >> 4
                    y2 = Int(d[p + 4] & 0xF) << 8 | Int(d[p + 5])
                    p += 6
                case 0x06:
                    guard p + 4 <= size else { break commands }
                    top = u16(d, p); bottom = u16(d, p + 2)
                    p += 4
                default:
                    break commands   // 0xFF ends the sequence
                }
            }
            if next == off { break }
            off = next
        }
        let width = x2 - x1 + 1, height = y2 - y1 + 1
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }

        let ink = (0..<4).map { UInt8((palette[colors[$0]] * Double(alpha[$0]) / 15 * 255).rounded()) }
        var out = [UInt8](repeating: 0, count: width * height)
        // Interlaced: even lines from the top field, odd lines from the bottom field.
        for (field, start) in [(0, top), (1, bottom)] {
            var nib = start * 2
            func nibble() -> Int {
                guard nib / 2 < size else { return 0 }
                let byte = d[nib / 2]
                defer { nib += 1 }
                return Int(nib % 2 == 0 ? byte >> 4 : byte & 0xF)
            }
            var y = field
            while y < height, nib / 2 < size {
                var x = 0
                while x < width {
                    var v = nibble()
                    if v < 0x4 { v = v << 4 | nibble(); if v < 0x10 { v = v << 4 | nibble(); if v < 0x40 { v = v << 4 | nibble() } } }
                    let run = v >> 2 == 0 ? width - x : min(v >> 2, width - x)
                    let value = ink[v & 3]
                    if value != 0 { for k in 0..<run { out[y * width + x + k] = value } }
                    x += run
                }
                nib += nib % 2   // lines start on a byte boundary
                y += 2
            }
        }
        return SubtitleImage(start: startDelay, end: stopDelay, width: width, height: height, ink: out, isForced: forced)
    }
}

private func u16(_ d: [UInt8], _ i: Int) -> Int { Int(d[i]) << 8 | Int(d[i + 1]) }
private func u16(_ d: ArraySlice<UInt8>, _ i: Int) -> Int { Int(d[i]) << 8 | Int(d[i + 1]) }
private func u32(_ d: [UInt8], _ i: Int) -> UInt32 {
    UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
}
