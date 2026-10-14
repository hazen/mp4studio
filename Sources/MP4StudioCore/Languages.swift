import Foundation

public struct Language: Hashable, Sendable, Identifiable {
    public let code: String      // ISO 639-2/B, as used by MKV and MP4
    public let name: String
    public let alpha2: String?

    public var id: String { code }
}

public enum Languages {
    public static let all: [Language] = [
        ("und", "Undetermined", nil), ("eng", "English", "en"), ("fre", "French", "fr"), ("ger", "German", "de"),
        ("spa", "Spanish", "es"), ("ita", "Italian", "it"), ("por", "Portuguese", "pt"), ("dut", "Dutch", "nl"),
        ("swe", "Swedish", "sv"), ("nor", "Norwegian", "no"), ("dan", "Danish", "da"), ("fin", "Finnish", "fi"),
        ("ice", "Icelandic", "is"), ("pol", "Polish", "pl"), ("cze", "Czech", "cs"), ("slo", "Slovak", "sk"),
        ("hun", "Hungarian", "hu"), ("rum", "Romanian", "ro"), ("bul", "Bulgarian", "bg"), ("gre", "Greek", "el"),
        ("tur", "Turkish", "tr"), ("rus", "Russian", "ru"), ("ukr", "Ukrainian", "uk"), ("srp", "Serbian", "sr"),
        ("hrv", "Croatian", "hr"), ("slv", "Slovenian", "sl"), ("est", "Estonian", "et"), ("lav", "Latvian", "lv"),
        ("lit", "Lithuanian", "lt"), ("heb", "Hebrew", "he"), ("ara", "Arabic", "ar"), ("per", "Persian", "fa"),
        ("hin", "Hindi", "hi"), ("ben", "Bengali", "bn"), ("tam", "Tamil", "ta"), ("tel", "Telugu", "te"),
        ("tha", "Thai", "th"), ("vie", "Vietnamese", "vi"), ("ind", "Indonesian", "id"), ("may", "Malay", "ms"),
        ("fil", "Filipino", "tl"), ("chi", "Chinese", "zh"), ("jpn", "Japanese", "ja"), ("kor", "Korean", "ko"),
        ("cat", "Catalan", "ca"), ("baq", "Basque", "eu"), ("glg", "Galician", "gl"), ("wel", "Welsh", "cy"),
        ("gle", "Irish", "ga"), ("afr", "Afrikaans", "af"), ("zxx", "No linguistic content", nil),
    ].map { Language(code: $0.0, name: $0.1, alpha2: $0.2) }

    /// ISO 639-2/T ("terminology") codes mapped to the /B codes used above.
    static let terminologyToBibliographic: [String: String] = [
        "fra": "fre", "deu": "ger", "nld": "dut", "ces": "cze", "slk": "slo", "ron": "rum", "ell": "gre",
        "fas": "per", "zho": "chi", "msa": "may", "isl": "ice", "eus": "baq", "cym": "wel", "hye": "arm",
        "sqi": "alb", "mkd": "mac", "kat": "geo", "mya": "bur", "bod": "tib",
    ]

    /// Normalizes "fra", "fr", "FR" or "fr-CA" to "fre". Unknown codes pass through lowercased.
    public static func normalize(_ raw: String?) -> String {
        guard var code = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !code.isEmpty else { return "und" }
        if let dash = code.firstIndex(where: { $0 == "-" || $0 == "_" }) { code = String(code[..<dash]) }
        if let b = terminologyToBibliographic[code] { return b }
        if code.count == 2, let match = all.first(where: { $0.alpha2 == code }) { return match.code }
        return code
    }

    public static func name(for code: String) -> String {
        all.first(where: { $0.code == code })?.name ?? code
    }

    /// Recognizes language tokens in names like "Movie.en.forced.srt" or "Movie.fre.srt".
    public static func guess(fromFileName url: URL) -> (language: String?, forced: Bool) {
        let tokens = url.deletingPathExtension().lastPathComponent
            .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == " " })
            .map { $0.lowercased() }
        let forced = tokens.contains("forced")
        for token in tokens.dropFirst().reversed() where token.count == 2 || token.count == 3 {
            let code = normalize(token)
            if code != "und", all.contains(where: { $0.code == code }) { return (code, forced) }
        }
        return (nil, forced)
    }
}
