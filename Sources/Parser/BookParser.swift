import Foundation
import PDFKit
import UIKit
import zlib

struct TocEntry: Codable, Hashable, Sendable {
    var title: String
    var chapterIndex: Int
    var paragraphIndex: Int = 0
    var level: Int = 0
}

struct BookChapter: Codable, Hashable, Sendable {
    var title: String
    var paragraphs: [String]
    var charWeight: Int64 = -1
    var isLoaded: Bool = true

    init(title: String, paragraphs: [String], charWeight: Int64 = -1, isLoaded: Bool = true) {
        self.title = title
        self.paragraphs = paragraphs
        self.charWeight = charWeight >= 0 ? charWeight : paragraphs.reduce(0) { $0 + Int64($1.trimmingCharacters(in: .whitespacesAndNewlines).count) }
        self.isLoaded = isLoaded
    }

    enum CodingKeys: String, CodingKey {
        case title, paragraphs, charWeight, isLoaded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        paragraphs = try c.decode([String].self, forKey: .paragraphs)
        let savedWeight = try c.decodeIfPresent(Int64.self, forKey: .charWeight) ?? -1
        charWeight = savedWeight >= 0 ? savedWeight : paragraphs.reduce(0) { $0 + Int64($1.trimmingCharacters(in: .whitespacesAndNewlines).count) }
        isLoaded = try c.decodeIfPresent(Bool.self, forKey: .isLoaded) ?? true
    }
}

struct ParsedBook: Codable, Hashable, Sendable {
    var title: String
    var chapters: [BookChapter]
    var tocEntries: [TocEntry] = []
    var isImageOnlyPdf: Bool = false
    var pageCount: Int = 0
    var isErrorPlaceholder: Bool = false
    var sourceHint: String = ""

    enum CodingKeys: String, CodingKey {
        case title, chapters, tocEntries, isImageOnlyPdf, pageCount, isErrorPlaceholder, sourceHint
    }

    init(
        title: String,
        chapters: [BookChapter],
        tocEntries: [TocEntry] = [],
        isImageOnlyPdf: Bool = false,
        pageCount: Int = 0,
        isErrorPlaceholder: Bool = false,
        sourceHint: String = ""
    ) {
        self.title = title
        self.chapters = chapters
        self.tocEntries = tocEntries
        self.isImageOnlyPdf = isImageOnlyPdf
        self.pageCount = pageCount
        self.isErrorPlaceholder = isErrorPlaceholder
        self.sourceHint = sourceHint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        chapters = try c.decode([BookChapter].self, forKey: .chapters)
        tocEntries = try c.decodeIfPresent([TocEntry].self, forKey: .tocEntries) ?? []
        isImageOnlyPdf = try c.decodeIfPresent(Bool.self, forKey: .isImageOnlyPdf) ?? false
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
        isErrorPlaceholder = try c.decodeIfPresent(Bool.self, forKey: .isErrorPlaceholder) ?? false
        sourceHint = try c.decodeIfPresent(String.self, forKey: .sourceHint) ?? ""
    }
}

struct ReadingUnit: Identifiable, Hashable, Sendable {
    var id: Int { index }
    var index: Int
    var text: String
    var parentSentence: String
    var paragraphIndex: Int
}

enum BookParser {
    static let sampleBookText = """
    Chapter 1: The Art of Slow Reading

    In an era of ubiquitous digital distractions, the ability to concentrate deeply on a single page has become a rare and precious skill. When we read too quickly, our eyes merely skim the surface of the text, and the subtle nuances of language vanish before we can appreciate them.

    Progressive reading transforms this habit by revealing only a few lines at a time. Instead of feeling overwhelmed by a dense wall of words, your attention remains anchored to the current sentence while keeping a gentle glimpse of the upcoming context.

    Every unfamiliar word is an opportunity to expand your perspective. When you encounter an ephemeral expression or a profound philosophical concept, pausing to examine its meaning within the original sentence creates a lasting impression in your memory.

    Chapter 2: Building a Living Vocabulary

    Words do not exist in isolation; they thrive within the vivid landscape of stories and arguments. Traditional vocabulary lists often fail because they strip words of their natural rhythm and emotional resonance.

    By automatically capturing the exact sentence in which you first discovered a word, review becomes an effortless journey back to the moment of discovery. Over time, even the most complex literature becomes lucid and approachable.
    """

    private static let closingQuotes: Set<Character> = ["\"", "”", "'", "’", "」", "』"]
    private static let openingQuotes: Set<Character> = ["\"", "“", "'", "‘", "「", "『"]
    private static let closingBrackets: Set<Character> = [")", "）", "]", "】", "〉", "》"]
    private static let openingBrackets: Set<Character> = ["(", "（", "[", "【", "〈", "《"]
    private static let sentenceEndPunct: Set<Character> = [".", "!", "?", "。", "！", "？"]
    private static let continuationPunct: Set<Character> = [",", ";", ":", "，", "；", "：", "、", "—", "–", "-", "…"]

    private static let nonTerminalAbbrs: Set<String> = [
        "mr", "mrs", "ms", "miss", "dr", "prof", "rev", "hon", "pres", "gov",
        "sen", "rep", "gen", "col", "maj", "capt", "lt", "sgt", "cpl", "pvt",
        "adm", "cmdr", "supt", "det", "insp", "fr", "br", "mgr", "dir", "esq",
        "messrs", "mme", "mlle", "mt", "ft", "vs", "cf", "viz", "ca", "approx",
        "esp", "no", "nos", "vol", "vols", "ch", "chap", "sec", "sect", "art",
        "pt", "fig", "figs", "eq", "eqs", "ref", "refs", "tab", "p", "pp", "ll",
        "v", "vv", "ff", "ed", "eds", "trans", "est", "min", "max", "avg",
        "tel", "ext", "dept", "univ", "assoc",
        "jan", "feb", "mar", "apr", "aug", "sep", "sept", "oct", "nov", "dec",
        "mon", "tue", "tues", "wed", "thu", "thurs", "fri", "sat", "sun"
    ]

    private static let terminalCapableAbbrs: Set<String> = [
        "etc", "jr", "sr", "st", "inc", "ltd", "corp", "co", "llc", "bros",
        "u.s", "u.s.a", "u.k", "a.m", "p.m", "ph.d", "m.d", "b.a", "m.a",
        "b.s", "m.s", "b.c", "a.d", "b.c.e", "c.e", "e.g", "i.e", "op.cit", "loc.cit"
    ]

    private static let englishSentenceStarters: Set<String> = [
        "the", "a", "an", "he", "she", "it", "they", "we", "you", "i",
        "there", "here", "this", "that", "these", "those", "then", "when",
        "while", "after", "before", "however", "meanwhile", "later", "next",
        "finally", "soon", "suddenly", "fortunately", "unfortunately",
        "but", "and", "or", "so", "yet", "for", "in", "on", "at", "by",
        "from", "to", "with", "as", "if", "although", "though", "because",
        "since", "until", "unless", "wait", "well", "yes", "no", "now", "once"
    ]

    // MARK: - File Loading & Format Detection
    static func resolveReadableUrl(for book: BookItem) -> (url: URL, stopSecurityScope: Bool)? {
        if let bookmark = book.bookmarkData {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                let accessed = url.startAccessingSecurityScopedResource()
                return (url, accessed)
            }
        }
        if let url = URL(string: book.filePathHint), url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
            return (url, false)
        }
        if FileManager.default.fileExists(atPath: book.filePathHint) {
            return (URL(fileURLWithPath: book.filePathHint), false)
        }
        return nil
    }

    static func loadRawData(for book: BookItem) throws -> Data {
        guard let resolved = resolveReadableUrl(for: book) else {
            throw NSError(domain: "BookParser", code: 404, userInfo: [NSLocalizedDescriptionKey: "找不到原图书文件，请重新导入"])
        }
        defer {
            if resolved.stopSecurityScope {
                resolved.url.stopAccessingSecurityScopedResource()
            }
        }
        return try Data(contentsOf: resolved.url)
    }

    static func detectActualFormat(data: Data, declaredFormat: String) -> String {
        let headCount = min(data.count, 1024)
        if headCount >= 5 {
            let headStr = String(data: data.prefix(headCount), encoding: .isoLatin1) ?? String(decoding: data.prefix(headCount), as: UTF8.self)
            if headStr.contains("%PDF-") { return "PDF" }
        }
        if headCount >= 68 {
            let bytes = [UInt8](data.prefix(68))
            if String(bytes: bytes[60..<68], encoding: .ascii) == "BOOKMOBI" {
                return "MOBI"
            }
        }
        if headCount >= 4 {
            let b = [UInt8](data.prefix(4))
            if b[0] == 0x50 && b[1] == 0x4B && b[2] == 0x03 && b[3] == 0x04 {
                return "EPUB"
            }
        }
        return declaredFormat.uppercased()
    }

    static func parseBook(book: BookItem) throws -> ParsedBook {
        if book.filePathHint == "sample://art_of_slow_reading" {
            var parsed = parseTxtContent(title: book.title, text: sampleBookText)
            parsed.sourceHint = book.filePathHint
            return parsed
        }
        let data = try loadRawData(for: book)
        if data.isEmpty {
            throw NSError(domain: "BookParser", code: 400, userInfo: [NSLocalizedDescriptionKey: "文件内容为空"])
        }
        let actualFormat = detectActualFormat(data: data, declaredFormat: book.format)
        var parsed: ParsedBook
        switch actualFormat {
        case "TXT":
            parsed = parseTxtData(title: book.title, data: data)
        case "EPUB":
            parsed = parseEpubData(title: book.title, data: data)
        case "PDF":
            parsed = parsePdfData(title: book.title, data: data)
        case "MOBI", "AZW3":
            parsed = parseMobiOrAzw3Data(title: book.title, data: data)
        default:
            parsed = parseTxtData(title: book.title, data: data)
        }
        parsed.sourceHint = book.filePathHint
        return parsed
    }

    // MARK: - Cover Thumbnail Extraction
    static func extractCoverThumbnailBytes(for book: BookItem) -> Data? {
        if book.filePathHint.isEmpty || book.filePathHint.hasPrefix("sample://") { return nil }
        guard let data = try? loadRawData(for: book), !data.isEmpty else { return nil }
        let actualFormat = detectActualFormat(data: data, declaredFormat: book.format)
        switch actualFormat {
        case "EPUB":
            if let rawImg = extractEpubCoverImageBytes(data: data) {
                return encodeThumbnailJpeg(rawImg)
            }
            return nil
        case "MOBI", "AZW3":
            if let rawImg = extractMobiCoverImageBytes(data: data) {
                return encodeThumbnailJpeg(rawImg)
            }
            return nil
        case "PDF":
            return extractPdfCoverThumbnailBytes(data: data)
        default:
            return nil
        }
    }

    private static func encodeThumbnailJpeg(_ rawImageData: Data) -> Data? {
        guard rawImageData.count >= 32, let image = UIImage(data: rawImageData) else { return nil }
        let srcW = image.size.width
        let srcH = image.size.height
        guard srcW > 0, srcH > 0 else { return nil }
        let maxW: CGFloat = 280
        let maxH: CGFloat = 400
        let scale = min(maxW / srcW, maxH / srcH, 1.0)
        let dstSize = CGSize(width: max(1, (srcW * scale).rounded()), height: max(1, (srcH * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: dstSize, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: dstSize))
            image.draw(in: CGRect(origin: .zero, size: dstSize))
        }
        return rendered.jpegData(compressionQuality: 0.86)
    }

    private static func extractPdfCoverThumbnailBytes(data: Data) -> Data? {
        guard let pdf = PDFDocument(data: data), pdf.pageCount > 0, let page = pdf.page(at: 0) else {
            return nil
        }
        let thumb = page.thumbnail(of: CGSize(width: 260, height: 380), for: .mediaBox)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: thumb.size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: thumb.size))
            thumb.draw(in: CGRect(origin: .zero, size: thumb.size))
        }
        return rendered.jpegData(compressionQuality: 0.86)
    }

    // MARK: - Text Normalization Helpers
    private static func isCjkScalar(_ ch: Character) -> Bool {
        for s in ch.unicodeScalars {
            let v = s.value
            if (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3400 && v <= 0x4DBF) || (v >= 0x3000 && v <= 0x303F) || (v >= 0xFF00 && v <= 0xFFEF) {
                return true
            }
        }
        return false
    }

    private static func normalizeParagraphLine(_ input: String) -> String {
        var s = input
        s = s.replacingOccurrences(of: "[\u{200B}-\u{200F}\u{202A}-\u{202E}\u{2060}\u{FEFF}\u{00AD}]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t\\r\\u{00A0}\\u{1680}\\u{2000}-\\u{200A}\\u{2028}\\u{2029}\\u{202F}\\u{205F}\\u{3000}]+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appendLineSmart(_ buffer: inout String, _ line: String) {
        if buffer.isEmpty {
            buffer = line
            return
        }
        guard let lastChar = buffer.last, let firstChar = line.first else { return }
        if lastChar == "-" && buffer.count >= 2 {
            let beforeHyphen = buffer[buffer.index(buffer.endIndex, offsetBy: -2)]
            if beforeHyphen.isLetter && firstChar >= "a" && firstChar <= "z" {
                buffer.removeLast()
                buffer.append(line)
                return
            }
        }
        if isCjkScalar(lastChar) || isCjkScalar(firstChar) {
            buffer.append(line)
        } else {
            buffer.append(" ")
            buffer.append(line)
        }
    }

    // MARK: - TXT Parser
    static func parseTxtData(title: String, data: Data) -> ParsedBook {
        if let utf8 = String(data: data, encoding: .utf8), utf8.filter({ $0 == "\u{FFFD}" }).count <= 3 {
            return parseTxtContent(title: title, text: utf8)
        }
        let cfEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let gbEncoding = String.Encoding(rawValue: cfEnc)
        let text = String(data: data, encoding: gbEncoding) ?? String(decoding: data, as: UTF8.self)
        return parseTxtContent(title: title, text: text)
    }

    private static let txtChapterRegex: NSRegularExpression? = {
        let pattern = "^(?:" +
            "chapter\\s+(?:[0-9ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\\b.*|" +
            "part\\s+(?:[0-9ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten)\\b.*|" +
            "book\\s+[0-9ivxlcdm]+\\b.*|" +
            "section\\s+[0-9ivxlcdm]+\\b.*|" +
            "(?:prologue|epilogue|foreword|afterword|appendix)(?:[\\s:：—\\-].*)?|" +
            "(?:preface|introduction)(?:[\\s:：—\\-].{0,32})?|" +
            "第[零一二三四五六七八九十百千万两〇0-9]+[章节回卷部篇集幕季话].*|" +
            "(?:序章|序言|序幕|自序|序|前言|引子|楔子|内容简介|作者的话|尾声|后记|跋|终章|番外(?:篇|[^，。！？]{0,20})?|外传(?:[^，。！？]{0,20})?)(?:[\\s:：—\\-].*)?|" +
            "[卷篇部][零一二三四五六七八九十百千万0-9]+(?:[\\s:：—\\-].*)?|" +
            "[一二三四五六七八九十百]+[、.．]\\s*\\S.{0,40}|" +
            "(?:[0-9]{1,3}|[IVXLCDM]{1,6})[.、]\\s*\\S.{0,42}" +
            ")$"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func isTxtHeadingLine(_ line: String) -> Bool {
        guard !line.isEmpty, line.count < 75 else { return false }
        if line.hasSuffix(",") || line.hasSuffix("，") || line.hasSuffix("；") || line.hasSuffix(";") { return false }
        if line.hasSuffix("。") && !line.hasPrefix("第") { return false }
        let nsRange = NSRange(line.startIndex..., in: line)
        guard txtChapterRegex?.firstMatch(in: line, range: nsRange) != nil else { return false }
        if let first = line.first, first.isNumber && line.hasSuffix(".") { return false }
        return true
    }

    private static func isVolumeOrPartHeading(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^(?:第[零一二三四五六七八九十百千万两〇0-9]+[卷部篇]|[卷篇部][零一二三四五六七八九十百千万0-9]+|(?:part|book)\\s+[0-9ivxlcdm]+).*"
        return t.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isSubSectionHeading(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^(?:第[零一二三四五六七八九十百千万两〇0-9]+节|section\\s+[0-9ivxlcdm]+).*"
        return t.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func parseTxtContent(title: String, text: String) -> ParsedBook {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var chapters: [BookChapter] = []
        var pendingEmptyTitles: [String] = []
        var tocEntries: [TocEntry] = []
        var currentTitle = "正文"
        var hasExplicitChapter = false
        var hasVolume = false
        var hasChapter = false
        var currentParagraphs: [String] = []
        var buffer = ""

        func resolveTxtLevel(_ heading: String, isExplicit: Bool) -> Int {
            guard isExplicit else { return 0 }
            if isVolumeOrPartHeading(heading) {
                hasVolume = true
                hasChapter = false
                return 0
            } else if isSubSectionHeading(heading) {
                if hasVolume && hasChapter { return 2 }
                if hasVolume || hasChapter { return 1 }
                return 0
            } else {
                hasChapter = true
                return hasVolume ? 1 : 0
            }
        }

        func flushBuffer() {
            let joined = buffer.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                currentParagraphs.append(joined)
            }
            buffer = ""
        }

        for idx in lines.indices {
            let line = normalizeParagraphLine(lines[idx])
            if line.isEmpty {
                flushBuffer()
                continue
            }
            if isTxtHeadingLine(line) {
                flushBuffer()
                if !currentParagraphs.isEmpty {
                    let chapIdx = chapters.count
                    chapters.append(BookChapter(title: currentTitle, paragraphs: currentParagraphs))
                    for emptyTitle in pendingEmptyTitles {
                        tocEntries.append(TocEntry(title: emptyTitle, chapterIndex: chapIdx, level: resolveTxtLevel(emptyTitle, isExplicit: true)))
                    }
                    pendingEmptyTitles.removeAll()
                    tocEntries.append(TocEntry(title: currentTitle, chapterIndex: chapIdx, level: resolveTxtLevel(currentTitle, isExplicit: hasExplicitChapter)))
                } else if hasExplicitChapter {
                    pendingEmptyTitles.append(currentTitle)
                }
                currentTitle = line
                hasExplicitChapter = true
                currentParagraphs = []
            } else {
                appendLineSmart(&buffer, line)
                let nextNonEmpty = findNextNonEmptyLine(lines, startIdx: idx + 1)
                if shouldFlushWrappedLine(line, nextNonEmpty: nextNonEmpty, bufferLength: buffer.count) {
                    flushBuffer()
                }
            }
        }
        flushBuffer()

        if !currentParagraphs.isEmpty || chapters.isEmpty {
            if currentParagraphs.isEmpty {
                currentParagraphs.append("（本书暂无可读文本内容）")
            }
            if chapters.isEmpty && currentParagraphs.count > 150 {
                var i = 0
                var secIdx = 1
                while i < currentParagraphs.count {
                    let chunk = Array(currentParagraphs[i..<min(i + 80, currentParagraphs.count)])
                    let secTitle = "第 \(secIdx) 节"
                    let chapIdx = chapters.count
                    chapters.append(BookChapter(title: secTitle, paragraphs: chunk))
                    tocEntries.append(TocEntry(title: secTitle, chapterIndex: chapIdx, level: 0))
                    secIdx += 1
                    i += 80
                }
            } else {
                let chapIdx = chapters.count
                chapters.append(BookChapter(title: currentTitle, paragraphs: currentParagraphs))
                for emptyTitle in pendingEmptyTitles {
                    tocEntries.append(TocEntry(title: emptyTitle, chapterIndex: chapIdx, level: resolveTxtLevel(emptyTitle, isExplicit: true)))
                }
                pendingEmptyTitles.removeAll()
                tocEntries.append(TocEntry(title: currentTitle, chapterIndex: chapIdx, level: resolveTxtLevel(currentTitle, isExplicit: hasExplicitChapter)))
            }
        }
        return ParsedBook(title: title, chapters: chapters, tocEntries: tocEntries)
    }

    // MARK: - PDFKit Parser with Outline TOC & Image-Only Detection
    private struct RawPdfOutline {
        let title: String
        let pageIdx: Int
        let level: Int
    }

    private static func collectPdfOutline(pdf: PDFDocument, item: PDFOutline?, level: Int, out: inout [RawPdfOutline]) {
        guard let item else { return }
        for i in 0..<item.numberOfChildren {
            guard let child = item.child(at: i) else { continue }
            if let page = child.destination?.page {
                let pageIdx = pdf.index(for: page)
                let cleanTitle = normalizeParagraphLine(child.label ?? "")
                if pageIdx != NSNotFound && pageIdx >= 0 && !cleanTitle.isEmpty {
                    out.append(RawPdfOutline(title: cleanTitle, pageIdx: pageIdx, level: level))
                }
            }
            collectPdfOutline(pdf: pdf, item: child, level: level + 1, out: &out)
        }
    }

    private static func extractPdfParagraphs(_ rawPageText: String) -> [String] {
        let lines = rawPageText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var paragraphs: [String] = []
        var buffer = ""

        func flush() {
            let cleaned = normalizeParagraphLine(buffer)
            if !cleaned.isEmpty {
                paragraphs.append(cleaned)
            }
            buffer = ""
        }

        for idx in lines.indices {
            let line = normalizeParagraphLine(lines[idx])
            if line.isEmpty {
                flush()
                continue
            }
            appendLineSmart(&buffer, line)
            let nextNonEmpty = findNextNonEmptyLine(lines, startIdx: idx + 1)
            if shouldFlushWrappedLine(line, nextNonEmpty: nextNonEmpty, bufferLength: buffer.count) {
                flush()
            }
        }
        flush()
        return paragraphs
    }

    static func parsePdfData(title: String, data: Data) -> ParsedBook {
        guard let pdf = PDFDocument(data: data) else {
            return ParsedBook(
                title: title,
                chapters: [BookChapter(title: "正文", paragraphs: ["无法解析该 PDF 文件。"])],
                isErrorPlaceholder: true
            )
        }
        if pdf.isLocked && !pdf.unlock(withPassword: "") {
            return ParsedBook(
                title: title,
                chapters: [BookChapter(title: "正文", paragraphs: ["该 PDF 已设置打开密码，暂不支持加密文档。"])],
                isErrorPlaceholder: true
            )
        }
        let totalPages = pdf.pageCount
        if totalPages <= 0 {
            return ParsedBook(
                title: title,
                chapters: [BookChapter(title: "正文", paragraphs: ["该 PDF 文件不包含任何页面。"])],
                isErrorPlaceholder: true
            )
        }

        var outlineItems: [RawPdfOutline] = []
        if let root = pdf.outlineRoot {
            collectPdfOutline(pdf: pdf, item: root, level: 0, out: &outlineItems)
        }

        var firstHeadingByPage: [Int: String] = [:]
        for item in outlineItems {
            if firstHeadingByPage[item.pageIdx] == nil {
                firstHeadingByPage[item.pageIdx] = item.title
            }
        }

        var chapters: [BookChapter] = []
        var tocEntries: [TocEntry] = []

        let useOutline = firstHeadingByPage.count >= 2 || (!outlineItems.isEmpty && totalPages > 1)
        if useOutline {
            var currentTitle = firstHeadingByPage[0] ?? "第 1 页"
            var currentParas: [String] = []
            var currentPageStart = 0
            var pageToChapIdx: [Int: Int] = [:]
            var pageToParaIdx: [Int: Int] = [:]

            for pageIdx in 0..<totalPages {
                if let newHeading = firstHeadingByPage[pageIdx] {
                    if !currentParas.isEmpty {
                        let chapIdx = chapters.count
                        chapters.append(BookChapter(title: currentTitle, paragraphs: currentParas))
                        for p in currentPageStart..<pageIdx {
                            pageToChapIdx[p] = chapIdx
                        }
                        currentTitle = newHeading
                        currentParas = []
                        currentPageStart = pageIdx
                    } else if pageIdx == 0 {
                        currentTitle = newHeading
                    }
                }
                pageToParaIdx[pageIdx] = currentParas.count
                let pageText = pdf.page(at: pageIdx)?.string ?? ""
                currentParas.append(contentsOf: extractPdfParagraphs(pageText))
            }
            if !currentParas.isEmpty {
                let chapIdx = chapters.count
                chapters.append(BookChapter(title: currentTitle, paragraphs: currentParas))
                for p in currentPageStart..<totalPages {
                    pageToChapIdx[p] = chapIdx
                }
            }

            for item in outlineItems {
                guard let mappedChap = pageToChapIdx[item.pageIdx] else { continue }
                let mappedPara: Int
                if chapters[mappedChap].title == item.title {
                    mappedPara = 0
                } else {
                    mappedPara = min(pageToParaIdx[item.pageIdx] ?? 0, max(0, chapters[mappedChap].paragraphs.count - 1))
                }
                tocEntries.append(TocEntry(title: item.title, chapterIndex: mappedChap, paragraphIndex: mappedPara, level: item.level))
            }
        } else {
            let pagesPerChapter = 10
            var startPage = 0
            while startPage < totalPages {
                let endPage = min(startPage + pagesPerChapter - 1, totalPages - 1)
                var chunkParas: [String] = []
                for pageIdx in startPage...endPage {
                    let pageText = pdf.page(at: pageIdx)?.string ?? ""
                    chunkParas.append(contentsOf: extractPdfParagraphs(pageText))
                }
                if !chunkParas.isEmpty {
                    let chapTitle = "第 \(startPage + 1) - \(endPage + 1) 页"
                    let chapIdx = chapters.count
                    chapters.append(BookChapter(title: chapTitle, paragraphs: chunkParas))
                    tocEntries.append(TocEntry(title: chapTitle, chapterIndex: chapIdx, level: 0))
                }
                startPage = endPage + 1
            }
        }

        if chapters.isEmpty {
            let imageToc = outlineItems.map {
                TocEntry(
                    title: $0.title,
                    chapterIndex: 0,
                    paragraphIndex: min(max(0, $0.pageIdx), max(0, totalPages - 1)),
                    level: $0.level
                )
            }
            return ParsedBook(
                title: title,
                chapters: [
                    BookChapter(
                        title: "PDF 页面 (共 \(totalPages) 页)",
                        paragraphs: ["该 PDF 共 \(totalPages) 页，未能提取到可复制文本层（可能是纯图片扫描版 PDF）。"]
                    )
                ],
                tocEntries: imageToc,
                isImageOnlyPdf: true,
                pageCount: totalPages
            )
        }

        return ParsedBook(title: title, chapters: chapters, tocEntries: tocEntries, pageCount: totalPages)
    }

    // MARK: - ZIP Central Directory & zlib EPUB Parser
    private struct ZipCentralEntry {
        let name: String
        let compression: UInt16
        let compSize: Int
        let uncompSize: Int
        let localHeaderOffset: Int
    }

    private static func readUInt16LE(_ bytes: [UInt8], _ off: Int) -> UInt16 {
        UInt16(bytes[off]) | (UInt16(bytes[off + 1]) << 8)
    }

    private static func readUInt32LE(_ bytes: [UInt8], _ off: Int) -> UInt32 {
        UInt32(bytes[off]) |
        (UInt32(bytes[off + 1]) << 8) |
        (UInt32(bytes[off + 2]) << 16) |
        (UInt32(bytes[off + 3]) << 24)
    }

    private static func indexZipEntries(in data: Data) -> [String: ZipCentralEntry] {
        let bytes = [UInt8](data)
        var map: [String: ZipCentralEntry] = [:]

        // 1. Locate End of Central Directory (0x06054b50) from end
        let minSearch = max(0, bytes.count - 65557)
        var eocdOffset = -1
        if bytes.count >= 22 {
            var pos = bytes.count - 22
            while pos >= minSearch {
                if bytes[pos] == 0x50 && bytes[pos + 1] == 0x4B && bytes[pos + 2] == 0x05 && bytes[pos + 3] == 0x06 {
                    eocdOffset = pos
                    break
                }
                pos -= 1
            }
        }

        if eocdOffset >= 0 {
            let cdSize = Int(readUInt32LE(bytes, eocdOffset + 12))
            let cdOffset = Int(readUInt32LE(bytes, eocdOffset + 16))
            if cdOffset >= 0 && cdOffset < bytes.count {
                var pos = cdOffset
                let limit = min(bytes.count, cdOffset + cdSize)
                while pos + 46 <= limit {
                    guard bytes[pos] == 0x50, bytes[pos + 1] == 0x4B, bytes[pos + 2] == 0x01, bytes[pos + 3] == 0x02 else {
                        break
                    }
                    let compression = readUInt16LE(bytes, pos + 10)
                    let compSize = Int(readUInt32LE(bytes, pos + 20))
                    let uncompSize = Int(readUInt32LE(bytes, pos + 24))
                    let nameLen = Int(readUInt16LE(bytes, pos + 28))
                    let extraLen = Int(readUInt16LE(bytes, pos + 30))
                    let commentLen = Int(readUInt16LE(bytes, pos + 32))
                    let localOff = Int(readUInt32LE(bytes, pos + 42))
                    let nameStart = pos + 46
                    if nameStart + nameLen <= bytes.count {
                        let name = String(bytes: bytes[nameStart..<(nameStart + nameLen)], encoding: .utf8)
                            ?? String(bytes: bytes[nameStart..<(nameStart + nameLen)], encoding: .isoLatin1)
                            ?? ""
                        let norm = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        if !norm.hasSuffix("/") && !norm.isEmpty {
                            map[norm] = ZipCentralEntry(
                                name: norm,
                                compression: compression,
                                compSize: compSize,
                                uncompSize: uncompSize,
                                localHeaderOffset: localOff
                            )
                        }
                    }
                    pos += 46 + nameLen + extraLen + commentLen
                }
            }
        }

        if !map.isEmpty { return map }

        // Fallback: local file headers
        var offset = 0
        while offset + 30 <= bytes.count {
            if bytes[offset] == 0x50, bytes[offset + 1] == 0x4B, bytes[offset + 2] == 0x03, bytes[offset + 3] == 0x04 {
                let compression = readUInt16LE(bytes, offset + 8)
                let compSize = Int(readUInt32LE(bytes, offset + 18))
                let uncompSize = Int(readUInt32LE(bytes, offset + 22))
                let nameLen = Int(readUInt16LE(bytes, offset + 26))
                let extraLen = Int(readUInt16LE(bytes, offset + 28))
                let nameStart = offset + 30
                let dataStart = nameStart + nameLen + extraLen
                guard dataStart + compSize <= bytes.count else { break }
                let name = (String(bytes: bytes[nameStart..<(nameStart + nameLen)], encoding: .utf8) ?? "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !name.isEmpty && compSize > 0 {
                    map[name] = ZipCentralEntry(
                        name: name,
                        compression: compression,
                        compSize: compSize,
                        uncompSize: uncompSize,
                        localHeaderOffset: offset
                    )
                }
                offset = dataStart + max(1, compSize)
            } else {
                offset += 1
            }
        }
        return map
    }

    private static func readZipEntryData(_ entry: ZipCentralEntry, from bytes: [UInt8]) -> Data? {
        let off = entry.localHeaderOffset
        guard off >= 0, off + 30 <= bytes.count else { return nil }
        guard bytes[off] == 0x50, bytes[off + 1] == 0x4B, bytes[off + 2] == 0x03, bytes[off + 3] == 0x04 else { return nil }
        let nameLen = Int(readUInt16LE(bytes, off + 26))
        let extraLen = Int(readUInt16LE(bytes, off + 28))
        let dataStart = off + 30 + nameLen + extraLen
        guard dataStart >= 0, entry.compSize >= 0, dataStart + entry.compSize <= bytes.count else { return nil }
        if entry.compSize == 0 { return Data() }
        let slice = Data(bytes[dataStart..<(dataStart + entry.compSize)])
        if entry.compression == 0 {
            return slice
        } else if entry.compression == 8 {
            return inflateDeflate(slice, expectedSize: max(entry.uncompSize, entry.compSize * 4))
        }
        return nil
    }

    private static func inflateDeflate(_ data: Data, expectedSize: Int) -> Data? {
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var output = Data(count: max(1024, expectedSize))
        var status: Int32 = Z_OK
        data.withUnsafeBytes { rawIn in
            guard let inBase = rawIn.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: inBase)
            stream.avail_in = uInt(data.count)

            repeat {
                if Int(stream.total_out) >= output.count {
                    output.count += max(4096, expectedSize / 2)
                }
                let outCount = output.count
                output.withUnsafeMutableBytes { rawOut in
                    guard let outBase = rawOut.bindMemory(to: Bytef.self).baseAddress else { return }
                    stream.next_out = outBase.advanced(by: Int(stream.total_out))
                    stream.avail_out = uInt(outCount - Int(stream.total_out))
                    status = inflate(&stream, Z_NO_FLUSH)
                }
            } while status == Z_OK
        }
        guard status == Z_STREAM_END || status == Z_OK else { return nil }
        output.count = Int(stream.total_out)
        return output
    }

    private struct RawEpubTocItem {
        let title: String
        let path: String
        let fragment: String
        let level: Int
    }

    private static func isImageEntryPath(_ path: String, mediaType: String = "") -> Bool {
        if mediaType.lowercased().hasPrefix("image/") && !mediaType.lowercased().contains("svg") {
            return true
        }
        let lower = path.components(separatedBy: "?").first?.components(separatedBy: "#").first?.lowercased() ?? ""
        return lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") ||
            lower.hasSuffix(".webp") || lower.hasSuffix(".gif") || lower.hasSuffix(".bmp")
    }

    private static func isHtmlEntryPath(_ path: String, mediaType: String = "") -> Bool {
        let lower = path.components(separatedBy: "?").first?.components(separatedBy: "#").first?.lowercased() ?? ""
        return mediaType.lowercased().contains("html") ||
            lower.hasSuffix(".xhtml") || lower.hasSuffix(".html") || lower.hasSuffix(".htm")
    }

    private static func extractEpubCoverImageBytes(data: Data) -> Data? {
        let bytes = [UInt8](data)
        let entries = indexZipEntries(in: data)
        if entries.isEmpty { return nil }
        var byLower: [String: ZipCentralEntry] = [:]
        for (k, v) in entries { byLower[k.lowercased()] = v }

        func findEntry(_ path: String) -> ZipCentralEntry? {
            let norm = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return entries[norm] ?? byLower[norm.lowercased()]
        }
        func readBytes(_ path: String) -> Data? {
            guard let e = findEntry(path), e.uncompSize < 24 * 1024 * 1024 else { return nil }
            return readZipEntryData(e, from: bytes)
        }
        func readText(_ path: String) -> String? {
            readBytes(path).map { decodeXmlBytes($0) }
        }
        func extractImageFromHtmlWrapper(_ htmlPath: String) -> Data? {
            guard let htmlText = readText(htmlPath) else { return nil }
            let htmlDir = (htmlPath as NSString).deletingLastPathComponent
            let matches = regexMatches(#"<(?:img|image)\b[^>]*>"#, in: htmlText, caseInsensitive: true)
            for m in matches {
                let attrs = parseAttributes(m)
                guard let src = attrs["src"] ?? attrs["xlink:href"] ?? attrs["href"] else { continue }
                let resolved = normalizeZipPath(baseDir: htmlDir, href: src)
                if isImageEntryPath(resolved), let imgBytes = readBytes(resolved), imgBytes.count > 256 {
                    return imgBytes
                }
            }
            return nil
        }

        var opfPath: String?
        if let containerXml = readText("META-INF/container.xml"),
           let rf = regexMatches(#"<(?:[A-Za-z0-9_-]+:)?rootfile\b[^>]*>"#, in: containerXml, caseInsensitive: true).first {
            opfPath = parseAttributes(rf)["full-path"]
        }
        if opfPath == nil || opfPath?.isEmpty == true {
            opfPath = entries.keys.first(where: { $0.lowercased().hasSuffix(".opf") })
        }

        var candidates: [(String, String)] = []
        if let resolvedOpf = opfPath, let opfText = readText(resolvedOpf) {
            let opfDir = (resolvedOpf as NSString).deletingLastPathComponent
            struct OpfItem { let id: String; let path: String; let mediaType: String; let properties: String }
            var items: [OpfItem] = []
            var byId: [String: OpfItem] = [:]

            for tag in regexMatches(#"<(?:[A-Za-z0-9_-]+:)?item\b[^>]*>"#, in: opfText, caseInsensitive: true) {
                let attrs = parseAttributes(tag)
                guard let id = attrs["id"], let href = attrs["href"] else { continue }
                let resolved = normalizeZipPath(baseDir: opfDir, href: href)
                let mt = (attrs["media-type"] ?? "").lowercased()
                let props = (attrs["properties"] ?? "").lowercased()
                let item = OpfItem(id: id, path: resolved, mediaType: mt, properties: props)
                items.append(item)
                byId[id] = item
            }

            for item in items where item.properties.split(whereSeparator: { $0.isWhitespace }).contains("cover-image") {
                candidates.append((item.path, item.mediaType))
            }

            for tag in regexMatches(#"<(?:[A-Za-z0-9_-]+:)?meta\b[^>]*>"#, in: opfText, caseInsensitive: true) {
                let attrs = parseAttributes(tag)
                if attrs["name"]?.lowercased() == "cover" {
                    let coverVal = (attrs["content"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !coverVal.isEmpty {
                        if let byIdItem = byId[coverVal] {
                            candidates.append((byIdItem.path, byIdItem.mediaType))
                        } else {
                            candidates.append((normalizeZipPath(baseDir: opfDir, href: coverVal), ""))
                        }
                    }
                }
            }

            for tag in regexMatches(#"<(?:[A-Za-z0-9_-]+:)?reference\b[^>]*>"#, in: opfText, caseInsensitive: true) {
                let attrs = parseAttributes(tag)
                let type = (attrs["type"] ?? "").lowercased()
                if (type == "cover" || type == "cover-image"), let href = attrs["href"] {
                    candidates.append((normalizeZipPath(baseDir: opfDir, href: href), ""))
                }
            }

            items.filter {
                isImageEntryPath($0.path, mediaType: $0.mediaType) &&
                ($0.id.lowercased().contains("cover") || ($0.path as NSString).lastPathComponent.lowercased().contains("cover"))
            }.sorted { a, b in
                let la = (a.path as NSString).lastPathComponent.lowercased()
                let lb = (b.path as NSString).lastPathComponent.lowercased()
                let pa = (la.contains("thumb") || la.contains("icon")) ? 1 : 0
                let pb = (lb.contains("thumb") || lb.contains("icon")) ? 1 : 0
                return pa < pb
            }.forEach {
                candidates.append(($0.path, $0.mediaType))
            }
        }

        entries.keys.filter {
            isImageEntryPath($0) && ($0 as NSString).lastPathComponent.lowercased().contains("cover")
        }.sorted { a, b in
            let la = (a as NSString).lastPathComponent.lowercased()
            let lb = (b as NSString).lastPathComponent.lowercased()
            let pa = (la.contains("thumb") || la.contains("icon")) ? 1 : 0
            let pb = (lb.contains("thumb") || lb.contains("icon")) ? 1 : 0
            return pa < pb
        }.forEach {
            candidates.append(($0, ""))
        }

        var seen = Set<String>()
        for (path, mt) in candidates {
            guard seen.insert(path.lowercased()).inserted else { continue }
            if isImageEntryPath(path, mediaType: mt) {
                if let imgBytes = readBytes(path), imgBytes.count > 256 { return imgBytes }
            } else if isHtmlEntryPath(path, mediaType: mt) {
                if let imgBytes = extractImageFromHtmlWrapper(path) { return imgBytes }
            }
        }
        return nil
    }

    static func parseEpubData(title: String, data: Data) -> ParsedBook {
        let bytes = [UInt8](data)
        let entries = indexZipEntries(in: data)
        var byLower: [String: ZipCentralEntry] = [:]
        for (k, v) in entries { byLower[k.lowercased()] = v }

        func findEntry(_ path: String) -> ZipCentralEntry? {
            let norm = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return entries[norm] ?? byLower[norm.lowercased()]
        }
        func readText(_ path: String) -> String? {
            guard let e = findEntry(path), let d = readZipEntryData(e, from: bytes) else { return nil }
            return decodeXmlBytes(d)
        }

        var opfPath: String?
        if let containerXml = readText("META-INF/container.xml"),
           let rf = regexMatches(#"<(?:[A-Za-z0-9_-]+:)?rootfile\b[^>]*>"#, in: containerXml, caseInsensitive: true).first {
            opfPath = parseAttributes(rf)["full-path"]
        }
        if opfPath == nil || opfPath?.isEmpty == true {
            opfPath = entries.keys.first(where: { $0.lowercased().hasSuffix(".opf") })
        }

        var spinePaths: [String] = []
        var ncxItems: [RawEpubTocItem] = []
        var navItems: [RawEpubTocItem] = []
        var navFilePath: String?

        if let resolvedOpf = opfPath, let opfText = readText(resolvedOpf) {
            let opfDir = (resolvedOpf as NSString).deletingLastPathComponent
            var manifestById: [String: String] = [:]
            var ncxPath: String?
            var spineTocId: String?

            if let spineTag = regexMatches(#"<(?:[A-Za-z0-9_-]+:)?spine\b[^>]*>"#, in: opfText, caseInsensitive: true).first {
                spineTocId = parseAttributes(spineTag)["toc"]
            }

            for itemTag in regexMatches(#"<(?:[A-Za-z0-9_-]+:)?item\b[^>]*>"#, in: opfText, caseInsensitive: true) {
                let attrs = parseAttributes(itemTag)
                guard let id = attrs["id"], let href = attrs["href"] else { continue }
                let resolved = normalizeZipPath(baseDir: opfDir, href: href)
                manifestById[id] = resolved
                let mt = (attrs["media-type"] ?? "").lowercased()
                let props = (attrs["properties"] ?? "").lowercased()
                if mt == "application/x-dtbncx+xml" || id == spineTocId || resolved.lowercased().hasSuffix(".ncx") {
                    ncxPath = resolved
                }
                if props.split(whereSeparator: { $0.isWhitespace }).contains("nav") {
                    navFilePath = resolved
                }
            }

            for itemrefTag in regexMatches(#"<(?:[A-Za-z0-9_-]+:)?itemref\b[^>]*>"#, in: opfText, caseInsensitive: true) {
                let attrs = parseAttributes(itemrefTag)
                if let idref = attrs["idref"], let path = manifestById[idref] {
                    spinePaths.append(path)
                }
            }

            if let ncxPath, let ncxXml = readText(ncxPath) {
                ncxItems = parseNcxToc(ncxXml, ncxDir: (ncxPath as NSString).deletingLastPathComponent)
            }
            if let navFilePath, let navHtml = readText(navFilePath) {
                navItems = parseNavXhtmlToc(navHtml, navDir: (navFilePath as NSString).deletingLastPathComponent)
            }
        }

        let rawTocItems: [RawEpubTocItem]
        if !navItems.isEmpty && navItems.count >= ncxItems.count {
            rawTocItems = navItems
        } else if !ncxItems.isEmpty {
            rawTocItems = ncxItems
        } else {
            rawTocItems = navItems
        }

        let orderedPaths: [String]
        if !spinePaths.isEmpty {
            var seen = Set<String>()
            orderedPaths = spinePaths.filter { seen.insert($0).inserted }
        } else {
            orderedPaths = entries.keys
                .filter {
                    let l = $0.lowercased()
                    return l.hasSuffix(".xhtml") || l.hasSuffix(".html") || l.hasSuffix(".htm")
                }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }

        var chapters: [BookChapter] = []
        var resolvedTocMap: [Int: Int] = [:] // index in rawTocItems -> chapterIndex
        var pendingUnmappedIndices: [Int] = []
        let tocIndexLookup: [(idx: Int, item: RawEpubTocItem)] = rawTocItems.enumerated().map { ($0.offset, $0.element) }

        for path in orderedPaths {
            let lowerPath = path.lowercased()
            if let navFilePath, lowerPath == navFilePath.lowercased(), orderedPaths.count > 2 {
                continue
            }
            guard let html = readText(path) else { continue }
            let itemsForFile = tocIndexLookup.filter { $0.item.path.lowercased() == lowerPath }

            let locatedAnchors: [(tocIdx: Int, item: RawEpubTocItem, offset: Int)] = itemsForFile.compactMap { pair in
                let off: Int? = pair.item.fragment.isEmpty ? 0 : findAnchorOffsetInHtml(html, fragment: pair.item.fragment)
                if let off { return (pair.idx, pair.item, off) }
                return nil
            }

            let distinctOffsets = Array(Set(locatedAnchors.map { $0.offset })).sorted()
            if distinctOffsets.count >= 2 {
                var allSlices: [(Int, Int)] = []
                if distinctOffsets[0] > 0 {
                    allSlices.append((0, distinctOffsets[0]))
                }
                for i in distinctOffsets.indices {
                    let start = distinctOffsets[i]
                    let end = (i + 1 < distinctOffsets.count) ? distinctOffsets[i + 1] : html.count
                    allSlices.append((start, end))
                }

                var offsetToChapIdx: [Int: Int] = [:]
                var firstCreatedChap: Int?
                var danglingOffsets: [Int] = []

                for (start, end) in allSlices {
                    let sIdx = html.index(html.startIndex, offsetBy: start)
                    let eIdx = html.index(html.startIndex, offsetBy: end)
                    let sliceHtml = String(html[sIdx..<eIdx])
                    let sliceParas = cleanHtmlToParagraphs(sliceHtml)
                    let itemsAtOffset = locatedAnchors.filter { $0.offset == start }
                    if sliceParas.isEmpty {
                        danglingOffsets.append(start)
                        continue
                    }
                    let chapIdx = chapters.count
                    let sliceTitle = itemsAtOffset.first?.item.title
                        ?? extractFirstHeading(sliceHtml)
                        ?? itemsForFile.first?.item.title
                        ?? "第 \(chapIdx + 1) 节"
                    chapters.append(BookChapter(title: sliceTitle, paragraphs: sliceParas))
                    if firstCreatedChap == nil { firstCreatedChap = chapIdx }
                    offsetToChapIdx[start] = chapIdx
                    for d in danglingOffsets { offsetToChapIdx[d] = chapIdx }
                    danglingOffsets.removeAll()
                }

                if let fallbackChap = firstCreatedChap {
                    for d in danglingOffsets { offsetToChapIdx[d] = fallbackChap }
                    for pair in itemsForFile {
                        let off = locatedAnchors.first(where: { $0.tocIdx == pair.idx })?.offset
                        let mapped = off.flatMap { offsetToChapIdx[$0] } ?? fallbackChap
                        resolvedTocMap[pair.idx] = mapped
                    }
                    for pIdx in pendingUnmappedIndices { resolvedTocMap[pIdx] = fallbackChap }
                    pendingUnmappedIndices.removeAll()
                } else {
                    pendingUnmappedIndices.append(contentsOf: itemsForFile.map { $0.idx })
                }
                continue
            }

            let paragraphs = cleanHtmlToParagraphs(html)
            if paragraphs.isEmpty {
                pendingUnmappedIndices.append(contentsOf: itemsForFile.map { $0.idx })
                continue
            }

            let tocTitle = itemsForFile.first?.item.title
            let heading = tocTitle ?? extractFirstHeading(html) ?? (paragraphs[0].count < 50 ? paragraphs[0] : nil)

            if itemsForFile.count <= 1 && paragraphs.count > 140 {
                let headingRanges = regexMatchRanges(#"<h[1-3][^>]*>([\s\S]*?)</h[1-3]>"#, in: html, caseInsensitive: true)
                if headingRanges.count >= 3 {
                    var cursor = html.startIndex
                    var firstSubChap: Int?
                    for (hIdx, match) in headingRanges.enumerated() {
                        if hIdx == 0, cursor < match.full.lowerBound {
                            let preHtml = String(html[cursor..<match.full.lowerBound])
                            let preParas = cleanHtmlToParagraphs(preHtml)
                            if !preParas.isEmpty {
                                let cIdx = chapters.count
                                if firstSubChap == nil { firstSubChap = cIdx }
                                chapters.append(BookChapter(title: heading ?? "前言", paragraphs: preParas))
                            }
                        }
                        let secEnd = (hIdx + 1 < headingRanges.count) ? headingRanges[hIdx + 1].full.lowerBound : html.endIndex
                        let secHtml = String(html[match.full.lowerBound..<secEnd])
                        let rawHead = match.groups.first ?? ""
                        let secTitle = normalizeParagraphLine(decodeHtmlEntities(stripHtmlTags(rawHead)))
                        let finalSecTitle = secTitle.isEmpty ? "第 \(chapters.count + 1) 节" : secTitle
                        let secParas = cleanHtmlToParagraphs(secHtml)
                        if !secParas.isEmpty {
                            let cIdx = chapters.count
                            if firstSubChap == nil { firstSubChap = cIdx }
                            chapters.append(BookChapter(title: finalSecTitle, paragraphs: secParas))
                        }
                        cursor = secEnd
                    }
                    if let mappedIdx = firstSubChap {
                        for pair in itemsForFile { resolvedTocMap[pair.idx] = mappedIdx }
                        for pIdx in pendingUnmappedIndices { resolvedTocMap[pIdx] = mappedIdx }
                        pendingUnmappedIndices.removeAll()
                    }
                    continue
                }
            }

            let chapIdx = chapters.count
            chapters.append(BookChapter(title: heading ?? "第 \(chapIdx + 1) 节", paragraphs: paragraphs))
            for pair in itemsForFile { resolvedTocMap[pair.idx] = chapIdx }
            for pIdx in pendingUnmappedIndices { resolvedTocMap[pIdx] = chapIdx }
            pendingUnmappedIndices.removeAll()
        }

        if !pendingUnmappedIndices.isEmpty && !chapters.isEmpty {
            let lastIdx = chapters.count - 1
            for pIdx in pendingUnmappedIndices { resolvedTocMap[pIdx] = lastIdx }
        }

        var tocEntries: [TocEntry] = []
        for (idx, item) in rawTocItems.enumerated() {
            if let mapped = resolvedTocMap[idx] {
                tocEntries.append(TocEntry(title: item.title, chapterIndex: mapped, paragraphIndex: 0, level: item.level))
            }
        }

        if chapters.isEmpty {
            return ParsedBook(
                title: title,
                chapters: [BookChapter(title: "正文", paragraphs: ["未能从该 EPUB 文件中提取到有效文本。"])],
                isErrorPlaceholder: true
            )
        }
        return ParsedBook(title: title, chapters: chapters, tocEntries: tocEntries)
    }

    private static func parseNcxToc(_ ncxXml: String, ncxDir: String) -> [RawEpubTocItem] {
        var out: [RawEpubTocItem] = []
        let blockRegex = #"<(?:[A-Za-z0-9_-]+:)?navPoint\b[^>]*>([\s\S]*?)(?=<(?:[A-Za-z0-9_-]+:)?navPoint\b|</(?:[A-Za-z0-9_-]+:)?navPoint)"#
        let textRegex = #"<(?:[A-Za-z0-9_-]+:)?text>([\s\S]*?)</(?:[A-Za-z0-9_-]+:)?text>"#
        let contentRegex = #"<(?:[A-Za-z0-9_-]+:)?content\b([^>]*)/?>"#

        // Track nesting depth using XMLParser first
        let delegate = NcxTocXmlDelegate(ncxDir: ncxDir)
        if let data = ncxXml.data(using: .utf8) {
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            if parser.parse(), !delegate.items.isEmpty {
                return delegate.items
            }
        }

        // Regex fallback
        for match in regexMatchRanges(blockRegex, in: ncxXml, caseInsensitive: true) {
            let seg = match.groups.first ?? ""
            guard let labelMatch = regexMatchRanges(textRegex, in: seg, caseInsensitive: true).first?.groups.first,
                  let contentAttrs = regexMatchRanges(contentRegex, in: seg, caseInsensitive: true).first?.groups.first,
                  let src = parseAttributes(contentAttrs)["src"] else { continue }
            let label = normalizeParagraphLine(decodeHtmlEntities(stripHtmlTags(labelMatch)))
            if !label.isEmpty {
                let (path, frag) = normalizeZipPathWithFragment(baseDir: ncxDir, href: src)
                out.append(RawEpubTocItem(title: label, path: path, fragment: frag, level: 0))
            }
        }
        return out
    }

    private final class NcxTocXmlDelegate: NSObject, XMLParserDelegate {
        let ncxDir: String
        var items: [RawEpubTocItem] = []
        private struct Frame {
            let level: Int
            var label: String = ""
            var src: String?
            var emitted: Bool = false
        }
        private var stack: [Frame] = []
        private var inNavLabel = false
        private var inText = false

        init(ncxDir: String) {
            self.ncxDir = ncxDir
        }

        private func emitIfReady(_ idx: Int) {
            guard idx < stack.count, !stack[idx].emitted else { return }
            let src = (stack[idx].src ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let label = BookParser.normalizeParagraphLine(stack[idx].label)
            if !src.isEmpty && !label.isEmpty {
                let (path, frag) = BookParser.normalizeZipPathWithFragment(baseDir: ncxDir, href: src)
                items.append(RawEpubTocItem(title: label, path: path, fragment: frag, level: stack[idx].level))
                stack[idx].emitted = true
            }
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let tag = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
            switch tag {
            case "navpoint":
                if !stack.isEmpty { emitIfReady(stack.count - 1) }
                stack.append(Frame(level: stack.count))
            case "navlabel":
                if !stack.isEmpty { inNavLabel = true }
            case "text":
                if inNavLabel && !stack.isEmpty { inText = true }
            case "content":
                if !stack.isEmpty {
                    for (k, v) in attributeDict where (k.components(separatedBy: ":").last?.lowercased() ?? k.lowercased()) == "src" {
                        stack[stack.count - 1].src = v
                        break
                    }
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText && !stack.isEmpty {
                stack[stack.count - 1].label.append(string)
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let tag = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
            switch tag {
            case "text": inText = false
            case "navlabel": inNavLabel = false
            case "navpoint":
                if !stack.isEmpty {
                    emitIfReady(stack.count - 1)
                    stack.removeLast()
                }
            default: break
            }
        }
    }

    private static func parseNavXhtmlToc(_ navHtml: String, navDir: String) -> [RawEpubTocItem] {
        let navBlocks = regexMatchRanges(#"<nav\b([^>]*)>([\s\S]*?)</nav>"#, in: navHtml, caseInsensitive: true)
        let chosenBody = navBlocks.first(where: { ($0.groups.first ?? "").lowercased().contains("toc") })?.groups.last
            ?? navBlocks.first(where: { ($0.groups.last ?? "").lowercased().contains("<a") })?.groups.last
            ?? navHtml

        let tokenRegex = #"<(/?)(ol|ul)\b[^>]*>|<a\b([^>]*)>([\s\S]*?)</a>"#
        var out: [RawEpubTocItem] = []
        var depth = 0
        for match in regexMatchRanges(tokenRegex, in: chosenBody, caseInsensitive: true) {
            let fullLower = String(chosenBody[match.full]).lowercased()
            if fullLower.hasPrefix("<ol") || fullLower.hasPrefix("<ul") {
                depth += 1
            } else if fullLower.hasPrefix("</ol") || fullLower.hasPrefix("</ul") {
                depth = max(0, depth - 1)
            } else if match.groups.count >= 4 {
                let attrs = parseAttributes(match.groups[2])
                guard let href = attrs["href"] else { continue }
                let label = normalizeParagraphLine(decodeHtmlEntities(stripHtmlTags(match.groups[3])))
                if !label.isEmpty {
                    let (path, frag) = normalizeZipPathWithFragment(baseDir: navDir, href: href)
                    out.append(RawEpubTocItem(title: label, path: path, fragment: frag, level: max(0, depth - 1)))
                }
            }
        }
        return out
    }

    private static func findAnchorOffsetInHtml(_ html: String, fragment: String) -> Int? {
        guard !fragment.isEmpty else { return nil }
        let esc = NSRegularExpression.escapedPattern(for: fragment)
        let pattern = "(?:id|name)\\s*=\\s*(?:\"\(esc)\"|'\(esc)'|\(esc)(?=[\\s/>]))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsRange = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: nsRange),
              let range = Range(match.range, in: html) else { return nil }
        let prefix = html[..<range.lowerBound]
        if let tagStart = prefix.lastIndex(of: "<") {
            return html.distance(from: html.startIndex, to: tagStart)
        }
        return html.distance(from: html.startIndex, to: range.lowerBound)
    }

    // MARK: - MOBI / AZW3 Parser (with EXTH, FDST, INDX TOC, filepos, headings, LZ77)
    private struct MobiHeaderInfo {
        let headerRecIdx: Int
        let compression: Int
        let textLength: UInt32
        let textRecCount: Int
        let encryptionType: Int
        let encoding: String.Encoding
        let mobiVersion: Int
        let extraFlags: Int
        let ncxIdx: Int
        let fdstIdx: Int
        let fdstCount: Int
        let fragIdx: Int
        let skelIdx: Int
        let kf8BoundaryRecIdx: Int
    }

    private struct MobiTocPoint {
        let title: String
        let rawOffset: Int
        let level: Int
    }

    private struct IndxTagDef {
        let tag: Int
        let numValues: Int
        let bitmask: Int
        let eof: Int
    }

    private struct IndxRecordEntry {
        let key: String
        let tags: [Int: [Int]]
    }

    private struct IndxTable {
        let encoding: String.Encoding
        let cncxBytes: [UInt8]
        let entries: [IndxRecordEntry]
    }

    private static func readUInt16BE(_ bytes: [UInt8], _ off: Int) -> UInt16 {
        (UInt16(bytes[off]) << 8) | UInt16(bytes[off + 1])
    }

    private static func readUInt32BE(_ bytes: [UInt8], _ off: Int) -> UInt32 {
        (UInt32(bytes[off]) << 24) | (UInt32(bytes[off + 1]) << 16) | (UInt32(bytes[off + 2]) << 8) | UInt32(bytes[off + 3])
    }

    private static func readInt32BE(_ bytes: [UInt8], _ off: Int) -> Int {
        Int(Int32(bitPattern: readUInt32BE(bytes, off)))
    }

    private static func parseMobiHeaderAt(_ bytes: [UInt8], offsets: [Int], recIdx: Int) -> MobiHeaderInfo? {
        guard recIdx >= 0 && recIdx < offsets.count else { return nil }
        let hdrOff = offsets[recIdx]
        let recEnd = (recIdx + 1 < offsets.count) ? offsets[recIdx + 1] : bytes.count
        let headerLimit = min(recEnd, bytes.count)
        guard hdrOff >= 0 && hdrOff + 32 <= headerLimit else { return nil }

        let compression = Int(readUInt16BE(bytes, hdrOff))
        let textLength = readUInt32BE(bytes, hdrOff + 4)
        let textRecCount = Int(readUInt16BE(bytes, hdrOff + 8))
        let encryptionType = Int(readUInt16BE(bytes, hdrOff + 12))

        let hasMobi = hdrOff + 40 <= headerLimit &&
            bytes[hdrOff + 16] == 0x4D && bytes[hdrOff + 17] == 0x4F &&
            bytes[hdrOff + 18] == 0x42 && bytes[hdrOff + 19] == 0x49 // "MOBI"

        if !hasMobi {
            return MobiHeaderInfo(
                headerRecIdx: recIdx, compression: compression, textLength: textLength,
                textRecCount: textRecCount, encryptionType: encryptionType, encoding: .utf8,
                mobiVersion: 0, extraFlags: 0, ncxIdx: -1, fdstIdx: -1, fdstCount: 0,
                fragIdx: -1, skelIdx: -1, kf8BoundaryRecIdx: -1
            )
        }

        let mobiHeaderLen = readInt32BE(bytes, hdrOff + 20)
        let encodingCode = readInt32BE(bytes, hdrOff + 28)
        let encoding: String.Encoding = (encodingCode == 1252) ? .windowsCP1252 : .utf8
        let mobiVersion = readInt32BE(bytes, hdrOff + 36)
        let exthFlags = (mobiHeaderLen >= 116 && hdrOff + 132 <= headerLimit) ? readInt32BE(bytes, hdrOff + 128) : 0
        let fdstIdx = (mobiVersion >= 8 && mobiHeaderLen >= 184 && hdrOff + 200 <= headerLimit) ? readInt32BE(bytes, hdrOff + 192) : -1
        let fdstCount = (mobiVersion >= 8 && mobiHeaderLen >= 184 && hdrOff + 200 <= headerLimit) ? readInt32BE(bytes, hdrOff + 196) : 0
        let extraFlags = (mobiHeaderLen >= 228 && hdrOff + 244 <= headerLimit) ? Int(readUInt16BE(bytes, hdrOff + 242)) : 0
        let ncxIdx = (mobiHeaderLen >= 232 && hdrOff + 248 <= headerLimit) ? readInt32BE(bytes, hdrOff + 244) : -1
        let fragIdx = (mobiVersion >= 8 && mobiHeaderLen >= 236 && hdrOff + 252 <= headerLimit) ? readInt32BE(bytes, hdrOff + 248) : -1
        let skelIdx = (mobiVersion >= 8 && mobiHeaderLen >= 240 && hdrOff + 256 <= headerLimit) ? readInt32BE(bytes, hdrOff + 252) : -1

        var kf8BoundaryRecIdx = -1
        if (exthFlags & 0x40) != 0 && mobiHeaderLen > 0 {
            let exthStart = hdrOff + 16 + mobiHeaderLen
            if exthStart + 12 <= headerLimit &&
                bytes[exthStart] == 0x45 && bytes[exthStart + 1] == 0x58 &&
                bytes[exthStart + 2] == 0x54 && bytes[exthStart + 3] == 0x48 { // "EXTH"
                let exthCount = min(512, max(0, readInt32BE(bytes, exthStart + 8)))
                var pos = exthStart + 12
                for _ in 0..<exthCount {
                    guard pos + 8 <= headerLimit else { break }
                    let tag = readInt32BE(bytes, pos)
                    let len = readInt32BE(bytes, pos + 4)
                    guard len >= 8 && pos + len <= headerLimit else { break }
                    if tag == 121 && len >= 12 {
                        kf8BoundaryRecIdx = readInt32BE(bytes, pos + 8)
                    }
                    pos += len
                }
            }
        }

        return MobiHeaderInfo(
            headerRecIdx: recIdx, compression: compression, textLength: textLength,
            textRecCount: textRecCount, encryptionType: encryptionType, encoding: encoding,
            mobiVersion: mobiVersion, extraFlags: extraFlags, ncxIdx: ncxIdx,
            fdstIdx: fdstIdx, fdstCount: fdstCount, fragIdx: fragIdx,
            skelIdx: skelIdx, kf8BoundaryRecIdx: kf8BoundaryRecIdx
        )
    }

    private static func resolveMobiRecordIndex(_ bytes: [UInt8], offsets: [Int], baseRecIdx: Int, rawIdx: Int, expectedMagic: String) -> Int? {
        guard rawIdx >= 0 else { return nil }
        let candidates = baseRecIdx > 0 ? [baseRecIdx + rawIdx, rawIdx] : [rawIdx]
        let magicBytes = Array(expectedMagic.utf8)
        for cand in candidates where cand >= 0 && cand < offsets.count {
            let off = offsets[cand]
            if off >= 0 && off + magicBytes.count <= bytes.count {
                if Array(bytes[off..<(off + magicBytes.count)]) == magicBytes {
                    return cand
                }
            }
        }
        return nil
    }

    private static func readForwardVwi(_ bytes: [UInt8], start: Int, limit: Int) -> (Int, Int) {
        var pos = start
        var value = 0
        var count = 0
        while pos < limit && count < 5 {
            let b = Int(bytes[pos])
            pos += 1
            value = (value << 7) | (b & 0x7F)
            count += 1
            if (b & 0x80) != 0 { break }
        }
        return (value, pos)
    }

    private static func readIndxTable(_ bytes: [UInt8], offsets: [Int], indxRecIdx: Int) -> IndxTable? {
        guard indxRecIdx >= 0 && indxRecIdx < offsets.count else { return nil }
        let hdrOff = offsets[indxRecIdx]
        let hdrEnd = min((indxRecIdx + 1 < offsets.count) ? offsets[indxRecIdx + 1] : bytes.count, bytes.count)
        guard hdrOff + 56 <= hdrEnd else { return nil }
        guard bytes[hdrOff] == 0x49, bytes[hdrOff + 1] == 0x4E, bytes[hdrOff + 2] == 0x44, bytes[hdrOff + 3] == 0x58 else { return nil }

        let indxHeaderLen = readInt32BE(bytes, hdrOff + 4)
        let numIdxRecs = min(1024, max(0, readInt32BE(bytes, hdrOff + 24)))
        let idxEncoding = readInt32BE(bytes, hdrOff + 28)
        let numCncx = indxHeaderLen >= 56 ? min(1024, max(0, readInt32BE(bytes, hdrOff + 52))) : 0
        let idxEncodingObj: String.Encoding = (idxEncoding == 1252) ? .windowsCP1252 : .utf8

        let tagxOff = hdrOff + indxHeaderLen
        var tagDefs: [IndxTagDef] = []
        var numCtrlBytes = 0
        if tagxOff + 12 <= hdrEnd &&
            bytes[tagxOff] == 0x54 && bytes[tagxOff + 1] == 0x41 &&
            bytes[tagxOff + 2] == 0x47 && bytes[tagxOff + 3] == 0x58 {
            let tagxLen = readInt32BE(bytes, tagxOff + 4)
            numCtrlBytes = min(32, max(0, readInt32BE(bytes, tagxOff + 8)))
            let tagxLimit = min(tagxOff + tagxLen, hdrEnd)
            var p = tagxOff + 12
            while p + 4 <= tagxLimit {
                tagDefs.append(IndxTagDef(
                    tag: Int(bytes[p]),
                    numValues: Int(bytes[p + 1]),
                    bitmask: Int(bytes[p + 2]),
                    eof: Int(bytes[p + 3])
                ))
                p += 4
            }
        }

        var cncxBytes: [UInt8] = []
        let cncxStart = indxRecIdx + 1 + numIdxRecs
        for c in 0..<numCncx {
            let rIdx = cncxStart + c
            guard rIdx >= 0 && rIdx < offsets.count else { break }
            let s = offsets[rIdx]
            let e = min((rIdx + 1 < offsets.count) ? offsets[rIdx + 1] : bytes.count, bytes.count)
            if s >= 0 && s < e {
                cncxBytes.append(contentsOf: bytes[s..<e])
            }
        }

        var entries: [IndxRecordEntry] = []
        if numIdxRecs >= 1 {
            for r in 1...numIdxRecs {
                let rIdx = indxRecIdx + r
                guard rIdx >= 0 && rIdx < offsets.count else { break }
                let recStart = offsets[rIdx]
                let recEnd = min((rIdx + 1 < offsets.count) ? offsets[rIdx + 1] : bytes.count, bytes.count)
                guard recStart + 32 <= recEnd else { continue }
                guard bytes[recStart] == 0x49 && bytes[recStart + 1] == 0x4E &&
                        bytes[recStart + 2] == 0x44 && bytes[recStart + 3] == 0x58 else { continue }
                let idxtRel = readInt32BE(bytes, recStart + 20)
                let entryCount = min(50_000, max(0, readInt32BE(bytes, recStart + 24)))
                let idxtAbs = recStart + idxtRel
                guard idxtAbs + 4 <= recEnd &&
                        bytes[idxtAbs] == 0x49 && bytes[idxtAbs + 1] == 0x44 &&
                        bytes[idxtAbs + 2] == 0x58 && bytes[idxtAbs + 3] == 0x54 else { continue }

                let dataLimit = min(idxtAbs, recEnd)
                for e in 0..<entryCount {
                    let offPos = idxtAbs + 4 + e * 2
                    guard offPos + 2 <= recEnd else { break }
                    let entryRel = Int(readUInt16BE(bytes, offPos))
                    let entryAbs = recStart + entryRel
                    guard entryAbs < idxtAbs && entryAbs + 1 <= dataLimit else { continue }
                    let keyLen = Int(bytes[entryAbs])
                    let keyStart = entryAbs + 1
                    guard keyStart + keyLen <= dataLimit else { continue }
                    let keyStr = String(bytes: bytes[keyStart..<(keyStart + keyLen)], encoding: .ascii) ?? ""
                    let ctrlStart = keyStart + keyLen
                    if ctrlStart + numCtrlBytes > dataLimit || numCtrlBytes == 0 || tagDefs.isEmpty {
                        entries.append(IndxRecordEntry(key: keyStr, tags: [:]))
                        continue
                    }

                    var dataPtr = ctrlStart + numCtrlBytes
                    var ctrlIdx = 0
                    var tagMap: [Int: [Int]] = [:]
                    for td in tagDefs {
                        if td.eof == 1 && td.bitmask == 0 {
                            ctrlIdx += 1
                            continue
                        }
                        if ctrlIdx >= numCtrlBytes { break }
                        let ctrlByte = Int(bytes[ctrlStart + ctrlIdx])
                        let masked = ctrlByte & td.bitmask
                        if masked != 0 {
                            var values: [Int] = []
                            if td.bitmask.nonzeroBitCount == 1 {
                                for _ in 0..<max(1, td.numValues) where dataPtr < dataLimit {
                                    let (v, nextPtr) = readForwardVwi(bytes, start: dataPtr, limit: dataLimit)
                                    values.append(v)
                                    dataPtr = nextPtr
                                }
                            } else {
                                let shift = td.bitmask.trailingZeroBitCount
                                let v = masked >> shift
                                let maxV = td.bitmask >> shift
                                if v == maxV {
                                    let (byteLen, nextPtr) = readForwardVwi(bytes, start: dataPtr, limit: dataLimit)
                                    dataPtr = nextPtr
                                    let blockEnd = min(dataPtr + max(0, byteLen), dataLimit)
                                    var ptr = dataPtr
                                    while ptr < blockEnd {
                                        let (itemVal, itemNext) = readForwardVwi(bytes, start: ptr, limit: blockEnd)
                                        values.append(itemVal)
                                        ptr = itemNext
                                    }
                                    dataPtr = blockEnd
                                } else {
                                    let count = v * max(1, td.numValues)
                                    for _ in 0..<count where dataPtr < dataLimit {
                                        let (itemVal, nextPtr) = readForwardVwi(bytes, start: dataPtr, limit: dataLimit)
                                        values.append(itemVal)
                                        dataPtr = nextPtr
                                    }
                                }
                            }
                            if !values.isEmpty { tagMap[td.tag] = values }
                        }
                        if (td.eof & 1) != 0 { ctrlIdx += 1 }
                    }
                    entries.append(IndxRecordEntry(key: keyStr, tags: tagMap))
                }
            }
        }
        return IndxTable(encoding: idxEncodingObj, cncxBytes: cncxBytes, entries: entries)
    }

    private static func readCncxString(_ cncxBytes: [UInt8], offset: Int, encoding: String.Encoding) -> String {
        guard offset >= 0 && offset < cncxBytes.count else { return "" }
        let (strLen, textStart) = readForwardVwi(cncxBytes, start: offset, limit: cncxBytes.count)
        guard strLen > 0 && textStart < cncxBytes.count else { return "" }
        let safeLen = min(strLen, cncxBytes.count - textStart)
        let str = String(bytes: cncxBytes[textStart..<(textStart + safeLen)], encoding: encoding)
            ?? String(decoding: cncxBytes[textStart..<(textStart + safeLen)], as: UTF8.self)
        return normalizeParagraphLine(decodeHtmlEntities(str))
    }

    private static func parseMobiNcxToc(_ bytes: [UInt8], offsets: [Int], info: MobiHeaderInfo, flow0End: Int) -> ([MobiTocPoint], [Int: Int]) {
        var fragStartPositions: [Int: Int] = [:]
        var fragRanges: [Int: (Int, Int)] = [:]

        if let fragRecIdx = resolveMobiRecordIndex(bytes, offsets: offsets, baseRecIdx: info.headerRecIdx, rawIdx: info.fragIdx, expectedMagic: "INDX"),
           let skelRecIdx = resolveMobiRecordIndex(bytes, offsets: offsets, baseRecIdx: info.headerRecIdx, rawIdx: info.skelIdx, expectedMagic: "INDX"),
           let tableA = readIndxTable(bytes, offsets: offsets, indxRecIdx: skelRecIdx),
           let tableB = readIndxTable(bytes, offsets: offsets, indxRecIdx: fragRecIdx) {
            let (skelTable, fragTable) = (tableB.entries.first?.key.hasPrefix("SKEL") == true && tableA.entries.first?.key.hasPrefix("SKEL") != true)
                ? (tableB, tableA) : (tableA, tableB)
            let skelRanges: [(Int, Int)] = skelTable.entries.map { entry in
                let start = entry.tags[6]?[safe: 0] ?? 0
                let len = entry.tags[6]?[safe: 1] ?? 0
                return (start, len)
            }
            let probeEntry = fragTable.entries.first(where: { !($0.tags[6]?.isEmpty ?? true) })
            let probeFileNum = probeEntry?.tags[3]?.first ?? (skelRanges.count == 1 ? 0 : nil)
            let probePos = probeEntry?.tags[6]?.first ?? 0
            let probeSkel = (probeFileNum != nil && probeFileNum! >= 0 && probeFileNum! < skelRanges.count) ? skelRanges[probeFileNum!] : (0, 0)
            let addSkelLen = probePos == 0 && probeSkel.1 > 0 && probeSkel.0 + probeSkel.1 < flow0End

            let multiFileFrags = fragTable.entries.compactMap { e -> (Int, Int)? in
                guard let fn = e.tags[3]?.first, let fp = e.tags[6]?.first, fn > 0 && fn < skelRanges.count else { return nil }
                return (fn, fp)
            }
            let isAbsoluteFragPos = !addSkelLen && !multiFileFrags.isEmpty &&
                multiFileFrags.allSatisfy { (fn, fp) in fp >= skelRanges[fn].0 + skelRanges[fn].1 && fp < flow0End }

            for (fid, entry) in fragTable.entries.enumerated() {
                let fileNum = entry.tags[3]?.first ?? (skelRanges.count == 1 ? 0 : nil)
                let fragPos = entry.tags[6]?[safe: 0] ?? 0
                let fragLen = entry.tags[6]?[safe: 1] ?? 0
                let absStart: Int
                if let fn = fileNum, fn >= 0 && fn < skelRanges.count {
                    let (skelStart, skelLen) = skelRanges[fn]
                    let candidate = addSkelLen ? (skelStart + skelLen + fragPos) : (isAbsoluteFragPos ? fragPos : (skelStart + fragPos))
                    absStart = min(max(0, candidate), max(0, flow0End - 1))
                } else {
                    absStart = fragPos
                }
                if absStart >= 0 && absStart < flow0End {
                    fragStartPositions[fid] = absStart
                    fragRanges[fid] = (absStart, fragLen)
                }
            }
        }

        guard let ncxRecIdx = resolveMobiRecordIndex(bytes, offsets: offsets, baseRecIdx: info.headerRecIdx, rawIdx: info.ncxIdx, expectedMagic: "INDX"),
              let ncxTable = readIndxTable(bytes, offsets: offsets, indxRecIdx: ncxRecIdx),
              !ncxTable.entries.isEmpty else {
            return ([], fragStartPositions)
        }

        let nCount = ncxTable.entries.count
        var parentOf = Array<Int?>(repeating: nil, count: nCount)
        for i in 0..<nCount {
            if let pIdx = ncxTable.entries[i].tags[21]?.first, pIdx >= 0 && pIdx < nCount && pIdx != i {
                parentOf[i] = pIdx
            }
        }
        for p in 0..<nCount {
            if let firstChild = ncxTable.entries[p].tags[22]?.first,
               let lastChild = ncxTable.entries[p].tags[23]?.first,
               firstChild <= lastChild {
                let safeStart = max(0, firstChild)
                let safeEnd = min(nCount - 1, lastChild)
                if safeStart <= safeEnd {
                    for c in safeStart...safeEnd where c != p && parentOf[c] == nil {
                        parentOf[c] = p
                    }
                }
            }
        }

        var childrenByParent: [Int: [Int]] = [:]
        var roots: [Int] = []
        for i in 0..<nCount {
            if let p = parentOf[i] {
                childrenByParent[p, default: []].append(i)
            } else {
                roots.append(i)
            }
        }

        var visited = Array(repeating: false, count: nCount)
        var orderedIndices: [Int] = []
        func dfsVisit(_ idx: Int) {
            guard idx >= 0 && idx < nCount && !visited[idx] else { return }
            visited[idx] = true
            orderedIndices.append(idx)
            for child in childrenByParent[idx] ?? [] { dfsVisit(child) }
        }
        for r in roots { dfsVisit(r) }
        for i in 0..<nCount where !visited[i] { dfsVisit(i) }

        var depthMemo: [Int: Int] = [:]
        var visitingDepth = Array(repeating: false, count: nCount)
        func computeDepth(_ idx: Int) -> Int {
            guard idx >= 0 && idx < nCount else { return 0 }
            if let d = depthMemo[idx] { return d }
            if visitingDepth[idx] { return 0 }
            visitingDepth[idx] = true
            let d = parentOf[idx].map { min(5, max(0, computeDepth($0) + 1)) } ?? 0
            visitingDepth[idx] = false
            depthMemo[idx] = d
            return d
        }

        var fidCandidates = Array(repeating: -1, count: nCount)
        var directCandidates = Array(repeating: -1, count: nCount)
        for i in 0..<nCount {
            let entry = ncxTable.entries[i]
            if let fidOff = entry.tags[6], fidOff.count >= 2, let range = fragRanges[fidOff[0]] {
                let safeOff = range.1 > 0 ? min(max(0, fidOff[1]), range.1) : max(0, fidOff[1])
                let pos = min(max(0, range.0 + safeOff), max(0, flow0End - 1))
                if pos >= 0 && pos < flow0End { fidCandidates[i] = pos }
            }
            if let directPos = entry.tags[1]?.first, directPos >= 0 && directPos < flow0End {
                directCandidates[i] = directPos
            }
        }

        func scoreArray(_ arr: [Int]) -> (score: Int, mono: Int, back: Int) {
            let valid = orderedIndices.compactMap { idx -> Int? in
                let v = arr[idx]
                return (v >= 0 && v < flow0End) ? v : nil
            }
            if Set(valid).count < 2 { return (Int.min, 0, 0) }
            var mono = 0, back = 0
            for k in 1..<valid.count {
                if valid[k] >= valid[k - 1] { mono += 1 } else { back += 1 }
            }
            return (mono * 2 - back * 4, mono, back)
        }

        let fScore = scoreArray(fidCandidates)
        let dScore = scoreArray(directCandidates)
        var resolvedOffsets = Array(repeating: -1, count: nCount)
        if fScore.score > Int.min && fScore.score >= dScore.score {
            if fScore.mono + fScore.back >= 4 && fScore.mono * 2 < fScore.back {
                return ([], fragStartPositions)
            }
            for i in 0..<nCount { resolvedOffsets[i] = fidCandidates[i] >= 0 ? fidCandidates[i] : directCandidates[i] }
        } else if dScore.score > Int.min {
            if dScore.mono + dScore.back >= 4 && dScore.mono * 2 < dScore.back {
                return ([], fragStartPositions)
            }
            for i in 0..<nCount { resolvedOffsets[i] = directCandidates[i] >= 0 ? directCandidates[i] : fidCandidates[i] }
        } else {
            for i in 0..<nCount { resolvedOffsets[i] = fidCandidates[i] >= 0 ? fidCandidates[i] : directCandidates[i] }
        }

        for idx in orderedIndices.reversed() where resolvedOffsets[idx] < 0 {
            if let childOff = childrenByParent[idx]?.first(where: { resolvedOffsets[$0] >= 0 && resolvedOffsets[$0] < flow0End }) {
                resolvedOffsets[idx] = resolvedOffsets[childOff]
            }
        }

        var result: [MobiTocPoint] = []
        for entryIdx in orderedIndices {
            guard let labelOff = ncxTable.entries[entryIdx].tags[3]?.first else { continue }
            let label = readCncxString(ncxTable.cncxBytes, offset: labelOff, encoding: ncxTable.encoding)
            guard !label.isEmpty && label.count <= 140 else { continue }
            let explicitLevel = ncxTable.entries[entryIdx].tags[4]?.first ?? 0
            let level = min(5, max(0, max(explicitLevel, computeDepth(entryIdx))))
            let resolvedOffset = resolvedOffsets[entryIdx]
            if resolvedOffset >= 0 && resolvedOffset < flow0End {
                result.append(MobiTocPoint(title: label, rawOffset: resolvedOffset, level: level))
            }
        }
        return (result, fragStartPositions)
    }

    private static func stripMobiTrailingExtraBytes(_ bytes: [UInt8], recStart: Int, recEnd: Int, extraFlags: Int) -> Int {
        var dataEnd = min(recEnd, bytes.count)
        if extraFlags == 0 || dataEnd <= recStart { return dataEnd }
        var flags = extraFlags >> 1
        while flags != 0 && dataEnd > recStart {
            if (flags & 1) != 0 {
                var size = 0
                var shift = 0
                var ptr = dataEnd - 1
                while ptr >= recStart && shift < 28 {
                    let b = Int(bytes[ptr])
                    ptr -= 1
                    size = size | ((b & 0x7F) << shift)
                    shift += 7
                    if (b & 0x80) != 0 { break }
                }
                if size >= 1 && size <= (dataEnd - recStart) {
                    dataEnd -= size
                } else {
                    break
                }
            }
            flags >>= 1
        }
        if (extraFlags & 1) != 0 && dataEnd > recStart {
            let overlap = (Int(bytes[dataEnd - 1]) & 0x03) + 1
            if overlap <= dataEnd - recStart {
                dataEnd -= overlap
            }
        }
        return dataEnd
    }

    private static func snapMobiOffset(_ bytes: [UInt8], rawOffset: Int, maxOffset: Int) -> Int {
        guard rawOffset > 0 else { return 0 }
        var pos = min(rawOffset, maxOffset)
        if pos < maxOffset && bytes[pos] == 0x3C { return pos } // '<'

        var fwd = pos
        var steps = 0
        while fwd < maxOffset && steps < 12 {
            let ch = bytes[fwd]
            if ch == 0x3C { return fwd }
            if ch != 0x20 && ch != 0x0A && ch != 0x0D && ch != 0x09 { break }
            fwd += 1
            steps += 1
        }

        var back = pos
        var backSteps = 0
        while back > 0 && backSteps < 64 {
            let ch = bytes[back]
            if ch == 0x3C { return back }
            if ch == 0x3E { break }
            back -= 1
            backSteps += 1
        }

        while pos < maxOffset && (bytes[pos] & 0xC0) == 0x80 { pos += 1 }
        return pos
    }

    private static func buildMobiChaptersFromTocPoints(title: String, rawBytes: [UInt8], flow0End: Int, encoding: String.Encoding, tocPoints: [MobiTocPoint]) -> ParsedBook? {
        guard !tocPoints.isEmpty else { return nil }
        let snapped = tocPoints.map { (title: $0.title, offset: snapMobiOffset(rawBytes, rawOffset: $0.rawOffset, maxOffset: flow0End), level: $0.level) }
        let uniqueOffsets = Array(Set(snapped.map { $0.offset })).sorted()
        guard !uniqueOffsets.isEmpty else { return nil }
        if uniqueOffsets.count < 2 && snapped.count >= 2 { return nil }

        var firstTitleAtOffset: [Int: String] = [:]
        for sp in snapped where firstTitleAtOffset[sp.offset] == nil {
            firstTitleAtOffset[sp.offset] = sp.title
        }

        var chapters: [BookChapter] = []
        var offsetToChapIdx: [Int: Int] = [:]

        if uniqueOffsets[0] > 256 {
            let leadHtml = String(bytes: rawBytes[0..<uniqueOffsets[0]], encoding: encoding)
                ?? String(decoding: rawBytes[0..<uniqueOffsets[0]], as: UTF8.self)
            let leadParas = cleanHtmlToParagraphs(leadHtml)
            if !leadParas.isEmpty {
                chapters.append(BookChapter(title: extractFirstHeading(leadHtml) ?? "前言", paragraphs: leadParas))
            }
        }

        for i in uniqueOffsets.indices {
            let startOff = uniqueOffsets[i]
            let endOff = (i + 1 < uniqueOffsets.count) ? uniqueOffsets[i + 1] : flow0End
            guard startOff < endOff else { continue }
            let sliceHtml = String(bytes: rawBytes[startOff..<endOff], encoding: encoding)
                ?? String(decoding: rawBytes[startOff..<endOff], as: UTF8.self)
            let sliceParas = cleanHtmlToParagraphs(sliceHtml)
            if !sliceParas.isEmpty {
                let chapTitle = firstTitleAtOffset[startOff] ?? "第 \(chapters.count + 1) 节"
                offsetToChapIdx[startOff] = chapters.count
                chapters.append(BookChapter(title: chapTitle, paragraphs: sliceParas))
            }
        }
        guard !chapters.isEmpty else { return nil }

        var tocEntries: [TocEntry] = []
        if uniqueOffsets[0] > 256 && chapters.count > offsetToChapIdx.count {
            tocEntries.append(TocEntry(title: chapters[0].title, chapterIndex: 0, paragraphIndex: 0, level: 0))
        }
        let sortedValidOffsets = offsetToChapIdx.keys.sorted()
        for sp in snapped {
            let mappedChap = offsetToChapIdx[sp.offset] ?? {
                let nextOff = sortedValidOffsets.first(where: { $0 >= sp.offset }) ?? sortedValidOffsets.last!
                return offsetToChapIdx[nextOff] ?? 0
            }()
            tocEntries.append(TocEntry(title: sp.title, chapterIndex: mappedChap, paragraphIndex: 0, level: sp.level))
        }
        return ParsedBook(title: title, chapters: chapters, tocEntries: tocEntries)
    }

    private static func isMobiFootnoteLabel(_ label: String) -> Bool {
        let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        let pattern = #"^(?:\[?\d{1,4}\]?|\(\d{1,4}\)|（\d{1,4}）|[①-⑳]|注\s*\d*|注释\s*\d*|返回.*|回到正文|回正文|back|return|top)$"#
        return t.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func parseMobiOrAzw3Data(title: String, data: Data) -> ParsedBook {
        let bytes = [UInt8](data)
        guard bytes.count >= 78 else { return parseTxtData(title: title, data: data) }
        let numRecords = Int(readUInt16BE(bytes, 76))
        var offsets: [Int] = []
        for i in 0..<numRecords {
            let pos = 78 + i * 8
            if pos + 4 <= bytes.count {
                offsets.append(Int(readUInt32BE(bytes, pos)))
            }
        }
        guard offsets.count >= 2, let primaryInfo = parseMobiHeaderAt(bytes, offsets: offsets, recIdx: 0) else {
            return parseTxtData(title: title, data: data)
        }

        var kf8Info: MobiHeaderInfo?
        if primaryInfo.kf8BoundaryRecIdx >= 1 && primaryInfo.kf8BoundaryRecIdx < offsets.count {
            let bOff = offsets[primaryInfo.kf8BoundaryRecIdx]
            let bEnd = (primaryInfo.kf8BoundaryRecIdx + 1 < offsets.count) ? offsets[primaryInfo.kf8BoundaryRecIdx + 1] : bytes.count
            let candidateRecIdx: Int
            if bOff >= 0 && bOff + 8 <= min(bEnd, bytes.count),
               String(bytes: bytes[bOff..<(bOff + 8)], encoding: .ascii) == "BOUNDARY" {
                candidateRecIdx = primaryInfo.kf8BoundaryRecIdx + 1
            } else {
                candidateRecIdx = primaryInfo.kf8BoundaryRecIdx
            }
            if let candidate = parseMobiHeaderAt(bytes, offsets: offsets, recIdx: candidateRecIdx),
               candidate.mobiVersion >= 8 && candidate.encryptionType == 0 && candidate.compression != 17480 && candidate.textRecCount > 0 {
                kf8Info = candidate
            }
        }

        let info = kf8Info ?? primaryInfo
        if info.encryptionType != 0 {
            return ParsedBook(title: title, chapters: [BookChapter(title: "正文", paragraphs: ["该电子书已启用 DRM 加密保护，暂不支持解析。"])], isErrorPlaceholder: true)
        }
        if info.compression == 17480 {
            return ParsedBook(title: title, chapters: [BookChapter(title: "正文", paragraphs: ["该 MOBI 文件使用了暂不支持的 HUFF/CDIC 压缩格式，建议转换为 EPUB 后导入。"])], isErrorPlaceholder: true)
        }

        let maxRec = min(offsets.count - 1, info.headerRecIdx + info.textRecCount)
        var out: [UInt8] = []
        out.reserveCapacity(Int(min(info.textLength, 16_000_000)))
        if info.headerRecIdx + 1 <= maxRec {
            for i in (info.headerRecIdx + 1)...maxRec {
                let start = offsets[i]
                let recEnd = (i + 1 < offsets.count) ? offsets[i + 1] : bytes.count
                let dataEnd = stripMobiTrailingExtraBytes(bytes, recStart: start, recEnd: recEnd, extraFlags: info.extraFlags)
                guard start >= 0 && start < dataEnd && start < bytes.count else { continue }
                let slice = Array(bytes[start..<min(dataEnd, bytes.count)])
                if info.compression == 2 {
                    decompressPalmDocLz77(slice, into: &out)
                } else {
                    out.append(contentsOf: slice)
                }
            }
        }

        let rawBytes: [UInt8] = (info.textLength >= 1 && Int(info.textLength) < out.count)
            ? Array(out[0..<Int(info.textLength)])
            : out

        var flow0End = rawBytes.count
        if let fdstRecIdx = resolveMobiRecordIndex(bytes, offsets: offsets, baseRecIdx: info.headerRecIdx, rawIdx: info.fdstIdx, expectedMagic: "FDST"),
           info.fdstCount > 1 {
            let fOff = offsets[fdstRecIdx]
            let fEnd = (fdstRecIdx + 1 < offsets.count) ? offsets[fdstRecIdx + 1] : bytes.count
            if fOff + 20 <= min(fEnd, bytes.count) {
                let flowTableOffset = readInt32BE(bytes, fOff + 4)
                let flow0Base = fOff + flowTableOffset
                if flowTableOffset >= 12 && flow0Base + 8 <= min(fEnd, bytes.count) {
                    let f0Start = readInt32BE(bytes, flow0Base)
                    let f0End = readInt32BE(bytes, flow0Base + 4)
                    if f0Start == 0 && f0End >= 1 && f0End <= rawBytes.count {
                        flow0End = f0End
                    }
                }
            }
        }

        let html = String(bytes: rawBytes[0..<flow0End], encoding: info.encoding)
            ?? String(decoding: rawBytes[0..<flow0End], as: UTF8.self)

        // Strategy 1: INDX/NCX
        let (ncxPoints, fragStartPositions) = parseMobiNcxToc(bytes, offsets: offsets, info: info, flow0End: flow0End)
        if let built = buildMobiChaptersFromTocPoints(title: title, rawBytes: rawBytes, flow0End: flow0End, encoding: info.encoding, tocPoints: ncxPoints) {
            return built
        }

        // Strategy 2: kindle:pos links
        if !fragStartPositions.isEmpty {
            let kindlePosPattern = #"<a\b[^>]*\bhref\s*=\s*["']kindle:pos:fid:([0-9a-fA-F]+):off:([0-9a-fA-F]+)["'][^>]*>([\s\S]*?)</a>"#
            var kPoints: [MobiTocPoint] = []
            var kSeen = Set<Int>()
            for m in regexMatchRanges(kindlePosPattern, in: html, caseInsensitive: true) where m.groups.count >= 3 {
                guard let fid = Int(m.groups[0], radix: 16), let base = fragStartPositions[fid] else { continue }
                let off = Int(m.groups[1], radix: 16) ?? 0
                let targetOff = min(max(0, base + off), max(0, flow0End - 1))
                let linkTitle = normalizeParagraphLine(decodeHtmlEntities(stripHtmlTags(m.groups[2])))
                if !linkTitle.isEmpty && linkTitle.count <= 120 && !isMobiFootnoteLabel(linkTitle), kSeen.insert(targetOff).inserted {
                    kPoints.append(MobiTocPoint(title: linkTitle, rawOffset: targetOff, level: 0))
                }
            }
            if kPoints.count >= 2, let built = buildMobiChaptersFromTocPoints(title: title, rawBytes: rawBytes, flow0End: flow0End, encoding: info.encoding, tocPoints: kPoints) {
                return built
            }
        }

        // Strategy 3: clustered <a filepos=...>
        let fileposPattern = #"<a\b[^>]*\bfilepos\s*=\s*["']?0*(\d+)["']?[^>]*>([\s\S]*?)</a>"#
        struct RawFileposMatch { let startPos: Int; let endPos: Int; let offset: Int; let title: String }
        var allFilepos: [RawFileposMatch] = []
        for m in regexMatchRanges(fileposPattern, in: html, caseInsensitive: true) where m.groups.count >= 2 {
            guard let rawOff = Int(m.groups[0]), rawOff >= 0 && rawOff < flow0End else { continue }
            let linkTitle = normalizeParagraphLine(decodeHtmlEntities(stripHtmlTags(m.groups[1])))
            guard !linkTitle.isEmpty && linkTitle.count <= 120 else { continue }
            let sPos = html.distance(from: html.startIndex, to: m.full.lowerBound)
            let ePos = html.distance(from: html.startIndex, to: m.full.upperBound)
            allFilepos.append(RawFileposMatch(startPos: sPos, endPos: ePos, offset: rawOff, title: linkTitle))
        }
        if allFilepos.count >= 2 {
            var clusters: [[RawFileposMatch]] = []
            for item in allFilepos {
                if var last = clusters.last, let lastItem = last.last, item.startPos - lastItem.endPos <= 2500 {
                    last.append(item)
                    clusters[clusters.count - 1] = last
                } else {
                    clusters.append([item])
                }
            }
            let bestCluster = clusters
                .map { $0.filter { !isMobiFootnoteLabel($0.title) } }
                .filter { $0.count >= 2 }
                .max { a, b in
                    func score(_ cl: [RawFileposMatch]) -> Int {
                        var mono = 0
                        for i in 1..<cl.count where cl[i].offset >= cl[i - 1].offset { mono += 1 }
                        return mono * 10 + cl.count
                    }
                    return score(a) < score(b)
                }
            if let bestCluster {
                let points = bestCluster.map { MobiTocPoint(title: $0.title, rawOffset: $0.offset, level: 0) }
                if let built = buildMobiChaptersFromTocPoints(title: title, rawBytes: rawBytes, flow0End: flow0End, encoding: info.encoding, tocPoints: points) {
                    return built
                }
            }
        }

        // Strategy 4: HTML headings <h1..h4>
        let headingPattern = #"<h([1-4])\b[^>]*>([\s\S]*?)</h\1>"#
        struct HtmlHeadingMatch { let tagLevel: Int; let index: String.Index; let title: String }
        let headingMatches: [HtmlHeadingMatch] = regexMatchRanges(headingPattern, in: html, caseInsensitive: true).compactMap { m in
            guard m.groups.count >= 2 else { return nil }
            let hLevel = Int(m.groups[0]) ?? 1
            let hTitle = String(normalizeParagraphLine(decodeHtmlEntities(stripHtmlTags(m.groups[1]))).prefix(100))
            return hTitle.isEmpty ? nil : HtmlHeadingMatch(tagLevel: hLevel, index: m.full.lowerBound, title: hTitle)
        }
        if headingMatches.count >= 2 {
            let h1Count = headingMatches.filter { $0.tagLevel == 1 }.count
            let hasLower = headingMatches.contains { $0.tagLevel > 1 }
            let baseTagLevel = (h1Count == 1 && headingMatches[0].tagLevel == 1 && hasLower)
                ? (headingMatches.dropFirst().map { $0.tagLevel }.min() ?? 1)
                : (headingMatches.map { $0.tagLevel }.min() ?? 1)

            var chapters: [BookChapter] = []
            var tocEntries: [TocEntry] = []
            let preParas = cleanHtmlToParagraphs(String(html[..<headingMatches[0].index]))
            if !preParas.isEmpty {
                let chapIdx = chapters.count
                chapters.append(BookChapter(title: "前言", paragraphs: preParas))
                tocEntries.append(TocEntry(title: "前言", chapterIndex: chapIdx, level: 0))
            }
            for i in headingMatches.indices {
                let hm = headingMatches[i]
                let secEnd = (i + 1 < headingMatches.count) ? headingMatches[i + 1].index : html.endIndex
                let secParas = cleanHtmlToParagraphs(String(html[hm.index..<secEnd]))
                if !secParas.isEmpty {
                    let chapIdx = chapters.count
                    chapters.append(BookChapter(title: hm.title, paragraphs: secParas))
                    tocEntries.append(TocEntry(title: hm.title, chapterIndex: chapIdx, level: min(4, max(0, hm.tagLevel - baseTagLevel))))
                }
            }
            if !chapters.isEmpty {
                return ParsedBook(title: title, chapters: chapters, tocEntries: tocEntries)
            }
        }

        // Strategy 5: TXT heading fallback
        let paragraphs = cleanHtmlToParagraphs(html)
        if paragraphs.isEmpty {
            return ParsedBook(title: title, chapters: [BookChapter(title: "正文", paragraphs: ["未能从该 MOBI/AZW3 文件中提取到有效文本。"])], isErrorPlaceholder: true)
        }
        return parseTxtContent(title: title, text: paragraphs.joined(separator: "\n\n"))
    }

    private static func isSupportedMobiImageBytes(_ data: Data) -> Bool {
        guard data.count >= 64 else { return false }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return true }
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return true }
        if b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 { return true }
        if b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
            b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50 { return true }
        return false
    }

    private static func extractMobiCoverImageBytes(data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 86 else { return nil }
        let numRecords = Int(readUInt16BE(bytes, 76))
        guard numRecords >= 2 && 78 + numRecords * 8 <= bytes.count else { return nil }
        var offsets: [Int] = []
        for i in 0..<numRecords {
            offsets.append(Int(readUInt32BE(bytes, 78 + i * 8)))
        }

        func readRecord(_ idx: Int) -> Data? {
            guard idx >= 0 && idx < numRecords else { return nil }
            let start = offsets[idx]
            let end = (idx + 1 < numRecords) ? offsets[idx + 1] : bytes.count
            guard start >= 0 && end > start && end <= bytes.count && (end - start) <= 24 * 1024 * 1024 else { return nil }
            return Data(bytes[start..<end])
        }

        struct CoverMeta { let firstImageRecIdx: Int; let coverOffset: Int; let thumbOffset: Int; let kf8Boundary: Int }
        func parseCoverMeta(_ recData: Data?) -> CoverMeta? {
            guard let recData, recData.count >= 40 else { return nil }
            let rb = [UInt8](recData)
            guard rb[16] == 0x4D && rb[17] == 0x4F && rb[18] == 0x42 && rb[19] == 0x49 else { return nil }
            let mobiHeaderLen = readInt32BE(rb, 20)
            let firstImageRecIdx = (mobiHeaderLen >= 96 && rb.count >= 112) ? readInt32BE(rb, 108) : -1
            let exthFlags = (mobiHeaderLen >= 116 && rb.count >= 132) ? readInt32BE(rb, 128) : 0
            var coverOffset = -1, thumbOffset = -1, kf8Boundary = -1
            if (exthFlags & 0x40) != 0 {
                let exthStart = 16 + mobiHeaderLen
                if exthStart + 12 <= rb.count && rb[exthStart] == 0x45 && rb[exthStart + 1] == 0x58 && rb[exthStart + 2] == 0x54 && rb[exthStart + 3] == 0x48 {
                    let exthCount = min(512, max(0, readInt32BE(rb, exthStart + 8)))
                    var pos = exthStart + 12
                    for _ in 0..<exthCount {
                        guard pos + 8 <= rb.count else { break }
                        let tag = readInt32BE(rb, pos)
                        let len = readInt32BE(rb, pos + 4)
                        guard len >= 8 && pos + len <= rb.count else { break }
                        if len >= 12 {
                            if tag == 121 { kf8Boundary = readInt32BE(rb, pos + 8) }
                            else if tag == 201 { coverOffset = readInt32BE(rb, pos + 8) }
                            else if tag == 202 { thumbOffset = readInt32BE(rb, pos + 8) }
                        }
                        pos += len
                    }
                }
            }
            return CoverMeta(firstImageRecIdx: firstImageRecIdx, coverOffset: coverOffset, thumbOffset: thumbOffset, kf8Boundary: kf8Boundary)
        }

        guard let primary = parseCoverMeta(readRecord(0)) else { return nil }
        var metas = [primary]
        if primary.kf8Boundary >= 1 && primary.kf8Boundary < numRecords {
            let bRec = readRecord(primary.kf8Boundary)
            let isBoundary = bRec.map { $0.count >= 8 && String(decoding: $0.prefix(8), as: UTF8.self) == "BOUNDARY" } ?? false
            let kf8Idx = isBoundary ? primary.kf8Boundary + 1 : primary.kf8Boundary
            if let kf8 = parseCoverMeta(readRecord(kf8Idx)) { metas.append(kf8) }
        }

        for meta in metas where meta.firstImageRecIdx >= 1 && meta.firstImageRecIdx < numRecords {
            if meta.coverOffset >= 0, let d = readRecord(meta.firstImageRecIdx + meta.coverOffset), isSupportedMobiImageBytes(d) {
                return d
            }
            if meta.thumbOffset >= 0, let d = readRecord(meta.firstImageRecIdx + meta.thumbOffset), isSupportedMobiImageBytes(d) {
                return d
            }
        }
        if let start = metas.first(where: { $0.firstImageRecIdx >= 1 && $0.firstImageRecIdx < numRecords })?.firstImageRecIdx {
            let end = min(numRecords, start + 8)
            for idx in start..<end {
                if let d = readRecord(idx), d.count >= 2048 && isSupportedMobiImageBytes(d) { return d }
            }
        }
        return nil
    }

    private static func decompressPalmDocLz77(_ input: [UInt8], into out: inout [UInt8]) {
        var i = 0
        while i < input.count {
            let c = Int(input[i]); i += 1
            if c == 0 {
                out.append(0)
            } else if c >= 1 && c <= 8 {
                for _ in 0..<c where i < input.count {
                    out.append(input[i]); i += 1
                }
            } else if c >= 9 && c <= 0x7F {
                out.append(UInt8(c))
            } else if c >= 0xC0 {
                out.append(0x20)
                out.append(UInt8(c ^ 0x80))
            } else {
                guard i < input.count else { break }
                let next = Int(input[i]); i += 1
                let pair = ((c << 8) | next) & 0x3FFF
                let dist = pair >> 3
                let len = (pair & 0x07) + 3
                if dist > 0 && dist <= out.count {
                    for _ in 0..<len { out.append(out[out.count - dist]) }
                }
            }
        }
    }

    // MARK: - HTML & XML Helpers
    private static func cleanHtmlToParagraphs(_ html: String) -> [String] {
        var text = html
        text = text.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<(head|script|style|svg|rt|rp)\b[^>]*/>"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<(head|script|style|svg|rt|rp)\b[^>]*>[\s\S]*?</\1\s*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"</?(p|pre|div|h1|h2|h3|h4|h5|h6|li|dt|dd|blockquote|section|article|figcaption|caption|tr|br|hr)\b[^>]*>"#, with: "\u{0001}", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"</?(td|th)\b[^>]*>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        text = stripHtmlTags(text)
        text = decodeHtmlEntities(text)
        return text
            .components(separatedBy: "\u{0001}")
            .map { joinHtmlWrappedBlock($0) }
            .filter { !$0.isEmpty }
    }

    private static func joinHtmlWrappedBlock(_ block: String) -> String {
        if !block.contains("\n") && !block.contains("\r") {
            return normalizeParagraphLine(block)
        }
        var sb = ""
        let rawLines = block.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        for rawLine in rawLines {
            let line = normalizeParagraphLine(rawLine)
            if line.isEmpty { continue }
            if sb.isEmpty {
                sb = line
                continue
            }
            guard let lastChar = sb.last, let firstChar = line.first else { continue }
            let noSpace = isCjkScalar(lastChar) || isCjkScalar(firstChar) ||
                lastChar == "-" || lastChar == "—" || lastChar == "–" ||
                openingQuotes.contains(lastChar) || openingBrackets.contains(lastChar) ||
                closingQuotes.contains(firstChar) || closingBrackets.contains(firstChar) ||
                continuationPunct.contains(firstChar) || sentenceEndPunct.contains(firstChar)
            if noSpace {
                sb.append(line)
            } else {
                sb.append(" ")
                sb.append(line)
            }
        }
        return normalizeParagraphLine(sb)
    }

    private static func stripHtmlTags(_ html: String) -> String {
        html.replacingOccurrences(of: #"</?[A-Za-z!?][^>]*>"#, with: "", options: .regularExpression)
    }

    private static func decodeHtmlEntities(_ input: String) -> String {
        var s = input
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&ensp;", with: " ")
            .replacingOccurrences(of: "&emsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&ldquo;", with: "“")
            .replacingOccurrences(of: "&rdquo;", with: "”")
            .replacingOccurrences(of: "&lsquo;", with: "‘")
            .replacingOccurrences(of: "&rsquo;", with: "’")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&hellip;", with: "…")
            .replacingOccurrences(of: "&middot;", with: "·")
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|\d+);"#) {
            let ns = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                let raw = ns.substring(with: m.range(at: 1))
                let code: UInt32? = raw.lowercased().hasPrefix("x") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw, radix: 10)
                if let code, let scalar = UnicodeScalar(code) {
                    s = (s as NSString).replacingCharacters(in: m.range, with: String(scalar))
                }
            }
        }
        return s
    }

    private static func extractFirstHeading(_ html: String) -> String? {
        guard let raw = regexMatchRanges(#"<h[1-3][^>]*>([\s\S]*?)</h[1-3]>"#, in: html, caseInsensitive: true).first?.groups.first else { return nil }
        let cleaned = normalizeParagraphLine(decodeHtmlEntities(stripHtmlTags(raw)))
        return (!cleaned.isEmpty && cleaned.count <= 80) ? cleaned : nil
    }

    private static func decodeXmlBytes(_ data: Data) -> String {
        if data.count >= 2 {
            let b = [UInt8](data.prefix(2))
            if b[0] == 0xFF && b[1] == 0xFE {
                return (String(data: data, encoding: .utf16LittleEndian) ?? "").replacingOccurrences(of: "\u{FEFF}", with: "")
            }
            if b[0] == 0xFE && b[1] == 0xFF {
                return (String(data: data, encoding: .utf16BigEndian) ?? "").replacingOccurrences(of: "\u{FEFF}", with: "")
            }
        }
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{FEFF}", with: "")
    }

    private static func normalizeZipPath(baseDir: String, href: String) -> String {
        let cleanHref = href.components(separatedBy: "#").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let decoded = cleanHref.removingPercentEncoding ?? cleanHref
        let combined = (baseDir.isEmpty || decoded.hasPrefix("/"))
            ? decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : "\(baseDir)/\(decoded)"
        var parts: [String] = []
        for seg in combined.components(separatedBy: "/") {
            if seg.isEmpty || seg == "." { continue }
            else if seg == ".." { if !parts.isEmpty { parts.removeLast() } }
            else { parts.append(seg) }
        }
        return parts.joined(separator: "/")
    }

    private static func normalizeZipPathWithFragment(baseDir: String, href: String) -> (String, String) {
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = parts.first.map(String.init) ?? ""
        let rawFrag = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let decodedFrag = rawFrag.removingPercentEncoding ?? rawFrag
        return (normalizeZipPath(baseDir: baseDir, href: rawPath), decodedFrag)
    }

    private static func parseAttributes(_ tag: String) -> [String: String] {
        var map: [String: String] = [:]
        guard let regex = try? NSRegularExpression(pattern: #"([A-Za-z0-9_:\-]+)\s*=\s*("([^"]*)"|'([^']*)')"#) else { return map }
        let ns = tag as NSString
        for m in regex.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1)).lowercased()
            let value: String
            if m.range(at: 3).location != NSNotFound {
                value = ns.substring(with: m.range(at: 3))
            } else if m.range(at: 4).location != NSNotFound {
                value = ns.substring(with: m.range(at: 4))
            } else {
                value = ""
            }
            map[key] = value
        }
        return map
    }

    private static func regexMatches(_ pattern: String, in text: String, caseInsensitive: Bool = false) -> [String] {
        let opts: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: opts) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func regexMatchRanges(_ pattern: String, in text: String, caseInsensitive: Bool = false) -> [(full: Range<String.Index>, groups: [String])] {
        let opts: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: opts) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { m in
            guard let full = Range(m.range, in: text) else { return nil }
            var groups: [String] = []
            for idx in 1..<m.numberOfRanges {
                if let r = Range(m.range(at: idx), in: text) {
                    groups.append(String(text[r]))
                } else {
                    groups.append("")
                }
            }
            return (full, groups)
        }
    }

    // MARK: - Smart Sentence & Visual Line Segmentation
    private static func findNextNonEmptyLine(_ lines: [String], startIdx: Int) -> String? {
        guard startIdx < lines.count else { return nil }
        for i in startIdx..<lines.count {
            let normalized = normalizeParagraphLine(lines[i])
            if !normalized.isEmpty { return normalized }
        }
        return nil
    }

    private static func isEllipsisDot(_ chars: [Character], dotIdx: Int) -> Bool {
        if dotIdx > 0 && chars[dotIdx - 1] == "." { return true }
        if dotIdx + 1 < chars.count && chars[dotIdx + 1] == "." { return true }
        let prevSpaced = dotIdx >= 2 && chars[dotIdx - 1] == " " && chars[dotIdx - 2] == "."
        let nextSpaced = dotIdx + 2 < chars.count && chars[dotIdx + 1] == " " && chars[dotIdx + 2] == "."
        if prevSpaced && nextSpaced { return true }
        if prevSpaced && dotIdx >= 4 && chars[dotIdx - 3] == " " && chars[dotIdx - 4] == "." { return true }
        if nextSpaced && dotIdx + 4 < chars.count && chars[dotIdx + 3] == " " && chars[dotIdx + 4] == "." { return true }
        return false
    }

    private static func extractTokenBeforePeriod(_ chars: [Character], dotIdx: Int) -> (start: Int, raw: String) {
        var i = dotIdx - 1
        while i >= 0 {
            let ch = chars[i]
            if ch.isLetter || ch.isNumber || ch == "." { i -= 1 } else { break }
        }
        let start = i + 1
        let raw = String(chars[start..<dotIdx]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return (start, raw)
    }

    private static func isLeadingListNumber(_ chars: [Character], tokenStart: Int, token: String, scopeStart: Int = 0) -> Bool {
        guard !token.isEmpty && token.count <= 3 && token.allSatisfy({ $0.isNumber }) else { return false }
        for k in scopeStart..<tokenStart {
            let ch = chars[k]
            if !ch.isWhitespace && !openingBrackets.contains(ch) && !openingQuotes.contains(ch) && ch != "•" && ch != "-" {
                return false
            }
        }
        return true
    }

    private static func extractNextAsciiWord(_ chars: [Character], startIdx: Int) -> String {
        var i = startIdx
        while i < chars.count && openingQuotes.contains(chars[i]) { i += 1 }
        let wordStart = i
        while i < chars.count && (chars[i].isLetter || chars[i] == "'" || chars[i] == "’") { i += 1 }
        return i > wordStart ? String(chars[wordStart..<i]) : ""
    }

    private static func isLikelyCjkAttribution(_ chars: [Character], startIdx: Int) -> Bool {
        let windowEnd = min(chars.count, startIdx + 24)
        guard startIdx < windowEnd else { return false }
        let slice = String(chars[startIdx..<windowEnd])
        let endSet = CharacterSet(charactersIn: "。！？.!?:：\n")
        let endRange = slice.rangeOfCharacter(from: endSet)
        let clause = endRange.map { String(slice[..<$0.lowerBound]) } ?? slice
        let endDist = endRange.map { slice.distance(from: slice.startIndex, to: $0.lowerBound) } ?? -1
        if clause.isEmpty { return false }
        let cjkVerbs = "说道|问道|笑道|叹道|喊道|叫道|答道|回道|心想|心道|自言自语|低声道|轻声道|冷笑道|怒道|哭道|说|道|问|答|喊|叫|笑|叹|想|念叨|嘟囔|低语|喃喃|补充|解释|提醒|感叹|惊呼|抱怨|追问|反问|吼|骂|嘱咐|叮嘱"
        if endDist >= 0 && endDist <= 18 && clause.range(of: cjkVerbs, options: .regularExpression) != nil { return true }
        if endDist >= 0 && endDist <= 8, let first = clause.first, "他她它我你道说问".contains(first) { return true }
        return false
    }

    private static func isLikelyEnglishAttribution(_ chars: [Character], startIdx: Int) -> Bool {
        let windowEnd = min(chars.count, startIdx + 42)
        guard startIdx < windowEnd else { return false }
        let slice = String(chars[startIdx..<windowEnd])
        let endSet = CharacterSet(charactersIn: ".!?,;:\n")
        let clause = slice.rangeOfCharacter(from: endSet).map { String(slice[..<$0.lowerBound]) } ?? slice
        guard clause.count <= 38 else { return false }
        let engVerbs = #"\b(said|says|asked|asks|replied|replies|answered|answers|whispered|whispers|shouted|shouts|cried|cries|muttered|mutters|murmured|murmurs|added|adds|continued|continues|explained|explains|laughed|laughs|sighed|sighs|thought|thinks|wondered|wonders|noted|notes|called|calls|yelled|yells|observed|observes|remarked|remarks|repeated|repeats|demanded|demands|snapped|snaps|groaned|groans|breathed|breathes|went on)\b"#
        return clause.range(of: engVerbs, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func shouldFlushWrappedLine(_ line: String, nextNonEmpty: String?, bufferLength: Int) -> Bool {
        guard bufferLength > 100 && !line.isEmpty else { return false }
        let chars = Array(line)
        var coreEnd = chars.count - 1
        while coreEnd >= 0 && (closingQuotes.contains(chars[coreEnd]) || closingBrackets.contains(chars[coreEnd])) {
            coreEnd -= 1
        }
        guard coreEnd >= 0 else { return false }
        let endChar = chars[coreEnd]
        guard sentenceEndPunct.contains(endChar) else { return false }

        if endChar == "." {
            if isEllipsisDot(chars, dotIdx: coreEnd) { return false }
            let (tokenStart, rawToken) = extractTokenBeforePeriod(chars, dotIdx: coreEnd)
            let lower = rawToken.lowercased()
            if nonTerminalAbbrs.contains(lower) { return false }
            if isLeadingListNumber(chars, tokenStart: tokenStart, token: rawToken) { return false }
            if rawToken.count == 1 && rawToken >= "A" && rawToken <= "Z" { return false }
            if lower == "al" && tokenStart >= 3 && String(chars[(tokenStart - 3)..<tokenStart]).lowercased() == "et " { return false }
            if terminalCapableAbbrs.contains(lower), let nextNonEmpty {
                let nextWord = extractNextAsciiWord(Array(nextNonEmpty), startIdx: 0).lowercased()
                if !nextWord.isEmpty && !englishSentenceStarters.contains(nextWord) { return false }
            }
        }

        if let nextNonEmpty, let nextFirst = nextNonEmpty.first {
            if (nextFirst >= "a" && nextFirst <= "z") || continuationPunct.contains(nextFirst) || closingQuotes.contains(nextFirst) || closingBrackets.contains(nextFirst) {
                return false
            }
            let hadClosingQuote = (coreEnd + 1 < chars.count) && chars[(coreEnd + 1)...].contains { closingQuotes.contains($0) }
            if hadClosingQuote {
                let nextChars = Array(nextNonEmpty)
                if isCjkScalar(nextFirst) && isLikelyCjkAttribution(nextChars, startIdx: 0) { return false }
                if nextFirst >= "A" && nextFirst <= "Z" && isLikelyEnglishAttribution(nextChars, startIdx: 0) { return false }
            }
        }
        return true
    }

    private static func computeBracketMask(_ chars: [Character]) -> [Bool] {
        var protected = Array(repeating: false, count: chars.count)
        var stack: [(Character, Int)] = []
        func matches(_ open: Character, _ close: Character) -> Bool {
            switch (open, close) {
            case ("(", ")"), ("（", "）"), ("[", "]"), ("【", "】"), ("〈", "〉"), ("《", "》"): return true
            default: return false
            }
        }
        for i in chars.indices {
            let ch = chars[i]
            if openingBrackets.contains(ch) {
                stack.append((ch, i))
            } else if closingBrackets.contains(ch) && !stack.isEmpty {
                if let matchIdx = stack.lastIndex(where: { matches($0.0, ch) }) {
                    let openIdx = stack[matchIdx].1
                    stack.removeSubrange(matchIdx..<stack.count)
                    if i - openIdx <= 260 && openIdx + 1 < i {
                        for k in (openIdx + 1)..<i { protected[k] = true }
                    }
                }
            }
        }
        return protected
    }

    private static func isNonBreakingPeriod(_ chars: [Character], dotIdx: Int, sentenceStart: Int, hadClosingQuote: Bool, hasSpace: Bool, nextNonSpace: Int) -> Bool {
        if isEllipsisDot(chars, dotIdx: dotIdx) { return true }
        if dotIdx > 0 && chars[dotIdx - 1].isNumber && dotIdx + 1 < chars.count && chars[dotIdx + 1].isNumber { return true }
        if !hadClosingQuote && !hasSpace { return true }

        let (tokenStart, rawToken) = extractTokenBeforePeriod(chars, dotIdx: dotIdx)
        let lower = rawToken.lowercased()
        if nonTerminalAbbrs.contains(lower) { return true }
        if isLeadingListNumber(chars, tokenStart: tokenStart, token: rawToken, scopeStart: sentenceStart) { return true }
        if lower == "al" && tokenStart >= 3 && String(chars[(tokenStart - 3)..<tokenStart]).lowercased() == "et " { return true }

        let nextWord = nextNonSpace < chars.count ? extractNextAsciiWord(chars, startIdx: nextNonSpace).lowercased() : ""
        if terminalCapableAbbrs.contains(lower) {
            if hadClosingQuote {
                if nextNonSpace < chars.count && !openingQuotes.contains(chars[nextNonSpace]) && !englishSentenceStarters.contains(nextWord) { return true }
            } else if nextWord.isEmpty || !englishSentenceStarters.contains(nextWord) {
                return true
            }
        }
        if rawToken.count == 1 && rawToken >= "A" && rawToken <= "Z" {
            if hadClosingQuote {
                if nextNonSpace < chars.count && !englishSentenceStarters.contains(nextWord) { return true }
            } else {
                let prevIsWord = tokenStart >= 2 && chars[tokenStart - 2].isLetter
                if !prevIsWord || !englishSentenceStarters.contains(nextWord) { return true }
                if nextNonSpace + 1 < chars.count && chars[nextNonSpace + 1] == "." { return true }
            }
        }
        return false
    }

    static func splitIntoSentences(_ paragraph: String) -> [String] {
        let cleanPara = normalizeParagraphLine(paragraph)
        guard !cleanPara.isEmpty else { return [] }
        let chars = Array(cleanPara)
        let bracketProtected = computeBracketMask(chars)
        var list: [String] = []
        var sentenceStart = 0
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            if sentenceEndPunct.contains(ch) {
                let punctStart = i
                var punctEnd = i + 1
                if ch == "." {
                    while punctEnd < chars.count && chars[punctEnd] == "." { punctEnd += 1 }
                } else {
                    while punctEnd < chars.count && ["!", "?", "！", "？"].contains(chars[punctEnd]) { punctEnd += 1 }
                }

                var splitEnd: Int?
                if !bracketProtected[punctStart] && !(ch == "." && punctEnd - punctStart > 1) {
                    var endAfterQuotes = punctEnd
                    var hadClosingQuote = false
                    while endAfterQuotes < chars.count {
                        let c = chars[endAfterQuotes]
                        if closingQuotes.contains(c) { hadClosingQuote = true; endAfterQuotes += 1 }
                        else if closingBrackets.contains(c) { endAfterQuotes += 1 }
                        else { break }
                    }
                    let immediateCont = punctEnd < chars.count && continuationPunct.contains(chars[punctEnd])
                    if !immediateCont {
                        var nextNonSpace = endAfterQuotes
                        while nextNonSpace < chars.count && chars[nextNonSpace].isWhitespace { nextNonSpace += 1 }
                        if nextNonSpace >= chars.count {
                            splitEnd = endAfterQuotes
                        } else {
                            let hasSpace = nextNonSpace > endAfterQuotes
                            let nextChar = chars[nextNonSpace]
                            let blocked = continuationPunct.contains(nextChar) ||
                                closingQuotes.contains(nextChar) ||
                                closingBrackets.contains(nextChar) ||
                                (nextChar >= "a" && nextChar <= "z") ||
                                (ch == "." && isNonBreakingPeriod(chars, dotIdx: punctStart, sentenceStart: sentenceStart, hadClosingQuote: hadClosingQuote, hasSpace: hasSpace, nextNonSpace: nextNonSpace)) ||
                                (hadClosingQuote && ((isCjkScalar(nextChar) && (!hasSpace && [".", "!", "?"].contains(ch) || isLikelyCjkAttribution(chars, startIdx: nextNonSpace))) || (nextChar >= "A" && nextChar <= "Z" && isLikelyEnglishAttribution(chars, startIdx: nextNonSpace)))) ||
                                (!hadClosingQuote && !hasSpace && [".", "!", "?"].contains(ch))
                            if !blocked {
                                splitEnd = nextNonSpace
                            }
                        }
                    }
                }

                if let splitEnd {
                    let sentence = normalizeParagraphLine(String(chars[sentenceStart..<splitEnd]))
                    if !sentence.isEmpty { list.append(contentsOf: splitOversizedSentence(sentence)) }
                    sentenceStart = splitEnd
                    i = splitEnd
                    continue
                }
                i = punctEnd
            } else {
                i += 1
            }
        }

        if sentenceStart < chars.count {
            let tail = normalizeParagraphLine(String(chars[sentenceStart..<chars.count]))
            if !tail.isEmpty { list.append(contentsOf: splitOversizedSentence(tail)) }
        }
        return list.isEmpty ? splitOversizedSentence(cleanPara) : list
    }

    private static func splitOversizedSentence(_ sentence: String) -> [String] {
        guard sentence.count > 450 else { return [sentence] }
        let chars = Array(sentence)
        let bracketProtected = computeBracketMask(chars)
        let major: Set<Character> = [";", "；", ":", "：", "—"]
        let minor: Set<Character> = [",", "，", "、"]
        var result: [String] = []
        var start = 0
        while chars.count - start > 450 {
            let searchFrom = min(chars.count, start + 180)
            let searchTo = min(chars.count, start + 430)
            var splitPos = -1
            if searchTo > searchFrom {
                for k in stride(from: searchTo - 1, through: searchFrom, by: -1) where !bracketProtected[k] && major.contains(chars[k]) {
                    var end = k + 1
                    while end < chars.count && closingQuotes.contains(chars[end]) { end += 1 }
                    while end < chars.count && chars[end].isWhitespace { end += 1 }
                    splitPos = end
                    break
                }
                if splitPos < 0 {
                    for k in stride(from: searchTo - 1, through: searchFrom, by: -1) where !bracketProtected[k] && minor.contains(chars[k]) {
                        var end = k + 1
                        while end < chars.count && closingQuotes.contains(chars[end]) { end += 1 }
                        while end < chars.count && chars[end].isWhitespace { end += 1 }
                        splitPos = end
                        break
                    }
                }
                if splitPos < 0 {
                    for k in stride(from: searchTo - 1, through: searchFrom, by: -1) where chars[k].isWhitespace || isCjkScalar(chars[k]) {
                        splitPos = k + 1
                        break
                    }
                }
            }
            if splitPos <= start { splitPos = min(chars.count, start + 420) }
            let seg = normalizeParagraphLine(String(chars[start..<splitPos]))
            if !seg.isEmpty { result.append(seg) }
            start = splitPos
        }
        let tail = normalizeParagraphLine(String(chars[start..<chars.count]))
        if !tail.isEmpty { result.append(tail) }
        return result.isEmpty ? [sentence] : result
    }

    static func segmentChapter(_ chapter: BookChapter, mode: StepMode, fontSize: Double, maxWidth: Double) -> [ReadingUnit] {
        var units: [ReadingUnit] = []
        var idx = 0

        if mode == .sentence {
            for (pIdx, para) in chapter.paragraphs.enumerated() {
                for s in splitIntoSentences(para) {
                    let clean = normalizeParagraphLine(s)
                    if !clean.isEmpty {
                        units.append(ReadingUnit(index: idx, text: clean, parentSentence: clean, paragraphIndex: pIdx))
                        idx += 1
                    }
                }
            }
            return units
        }

        let font = UIFont(name: "Georgia", size: fontSize * 1.04) ?? UIFont.systemFont(ofSize: fontSize * 1.04)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let safeWidth = max(240, maxWidth) * 0.94

        for (pIdx, para) in chapter.paragraphs.enumerated() {
            for sentence in splitIntoSentences(para) {
                let tokens = TextTokenizer.tokenizeMixedText(sentence)
                var currentLine = ""
                var currentWidth: CGFloat = 0

                for token in tokens {
                    let piece = token.text
                    let pad: CGFloat = token.isLookupable ? (token.isCjk ? 1.5 : 8.0) : 0.0
                    let pieceWidth = (piece as NSString).size(withAttributes: attrs).width + pad
                    if currentWidth + pieceWidth > safeWidth && !currentLine.isEmpty {
                        let cleaned = normalizeParagraphLine(currentLine)
                        if !cleaned.isEmpty {
                            units.append(ReadingUnit(index: idx, text: cleaned, parentSentence: sentence, paragraphIndex: pIdx))
                            idx += 1
                        }
                        currentLine = ""
                        currentWidth = 0
                    }
                    if !currentLine.isEmpty && !token.isCjk && token.isLookupable {
                        currentLine.append(" ")
                    }
                    currentLine.append(piece)
                    currentWidth += pieceWidth
                }
                let tail = normalizeParagraphLine(currentLine)
                if !tail.isEmpty {
                    units.append(ReadingUnit(index: idx, text: tail, parentSentence: sentence, paragraphIndex: pIdx))
                    idx += 1
                }
            }
        }
        return units
    }

    static func computeOverallProgress(
        parsedBook: ParsedBook,
        chapterIndex: Int,
        unitIndex: Int,
        chapterUnitCount: Int
    ) -> Float {
        if parsedBook.isImageOnlyPdf && parsedBook.pageCount > 0 {
            return min(1.0, max(0.0, Float(unitIndex + 1) / Float(parsedBook.pageCount)))
        }
        let chapters = parsedBook.chapters
        guard !chapters.isEmpty else { return 0 }
        var totalWeight: Int64 = 0
        var weights: [Int64] = []
        weights.reserveCapacity(chapters.count)
        for chap in chapters {
            let raw = chap.charWeight >= 0 ? chap.charWeight : chap.paragraphs.reduce(0) { $0 + Int64($1.trimmingCharacters(in: .whitespacesAndNewlines).count) }
            let w = max(1, raw)
            totalWeight += w
            weights.append(w)
        }
        guard totalWeight > 0 else { return 0 }
        let safeChap = min(max(0, chapterIndex), chapters.count - 1)
        var prefixWeight: Int64 = 0
        for i in 0..<safeChap { prefixWeight += weights[i] }
        let frac: Double = chapterUnitCount > 0 ? min(1.0, max(0.0, Double(unitIndex + 1) / Double(chapterUnitCount))) : 0.0
        let progress = (Double(prefixWeight) + Double(weights[safeChap]) * frac) / Double(totalWeight)
        return Float(min(1.0, max(0.0, progress)))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
