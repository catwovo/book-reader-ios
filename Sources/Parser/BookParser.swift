import Foundation
import PDFKit
import UIKit
import zlib

struct BookChapter: Codable, Hashable, Sendable {
    var title: String
    var paragraphs: [String]
}

struct ParsedBook: Codable, Hashable, Sendable {
    var title: String
    var chapters: [BookChapter]
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

    static func loadRawData(for book: BookItem) throws -> Data {
        if let bookmark = book.bookmarkData {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            return try Data(contentsOf: url)
        } else if let url = URL(string: book.filePathHint), url.isFileURL {
            return try Data(contentsOf: url)
        } else if FileManager.default.fileExists(atPath: book.filePathHint) {
            return try Data(contentsOf: URL(fileURLWithPath: book.filePathHint))
        } else {
            throw NSError(domain: "BookParser", code: 404, userInfo: [NSLocalizedDescriptionKey: "找不到原图书文件，请重新关联"])
        }
    }

    static func parseBook(book: BookItem) throws -> ParsedBook {
        if book.filePathHint == "sample://art_of_slow_reading" {
            return parseTxtContent(title: book.title, text: sampleBookText)
        }

        let data = try loadRawData(for: book)

        switch book.format.uppercased() {
        case "TXT":
            return parseTxtData(title: book.title, data: data)
        case "EPUB":
            return parseEpubData(title: book.title, data: data)
        case "PDF":
            return parsePdfData(title: book.title, data: data)
        case "MOBI", "AZW3":
            return parseMobiOrAzw3Data(title: book.title, data: data)
        default:
            return parseTxtData(title: book.title, data: data)
        }
    }

    static func parseTxtData(title: String, data: Data) -> ParsedBook {
        if let utf8 = String(data: data, encoding: .utf8) {
            return parseTxtContent(title: title, text: utf8)
        }
        let cfEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let gbEncoding = String.Encoding(rawValue: cfEnc)
        let text = String(data: data, encoding: gbEncoding) ?? String(decoding: data, as: UTF8.self)
        return parseTxtContent(title: title, text: text)
    }

    static func parseTxtContent(title: String, text: String) -> ParsedBook {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var chapters: [BookChapter] = []
        var currentTitle = "正文"
        var currentParagraphs: [String] = []
        let chapterPattern = #"^(?:chapter\s+[0-9ivxlcdm]+|part\s+[0-9ivxlcdm]+|第[零一二三四五六七八九十百千万0-9]+[章节回卷部篇]).*$"#
        let chapterRegex = try? NSRegularExpression(pattern: chapterPattern, options: [.caseInsensitive])

        var buffer = ""
        func flushBuffer() {
            let joined = buffer.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                currentParagraphs.append(joined)
            }
            buffer = ""
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                flushBuffer()
                continue
            }
            let nsRange = NSRange(line.startIndex..., in: line)
            let isChapter = line.count < 80 && (chapterRegex?.firstMatch(in: line, range: nsRange) != nil)
            if isChapter {
                flushBuffer()
                if !currentParagraphs.isEmpty {
                    chapters.append(BookChapter(title: currentTitle, paragraphs: currentParagraphs))
                }
                currentTitle = line
                currentParagraphs = []
            } else {
                if !buffer.isEmpty { buffer.append(" ") }
                buffer.append(line)
                if let last = line.last, [".", "!", "?", "。", "！", "？", "\"", "”"].contains(last), buffer.count > 120 {
                    flushBuffer()
                }
            }
        }
        flushBuffer()

        if !currentParagraphs.isEmpty || chapters.isEmpty {
            if currentParagraphs.isEmpty { currentParagraphs.append("（本书暂无可读文本内容）") }
            chapters.append(BookChapter(title: currentTitle, paragraphs: currentParagraphs))
        }
        return ParsedBook(title: title, chapters: chapters)
    }

    // MARK: - PDFKit
    static func parsePdfData(title: String, data: Data) -> ParsedBook {
        guard let pdf = PDFDocument(data: data) else {
            return BookChapter(title: "正文", paragraphs: ["无法解析该 PDF 文件。"]).asBook(title: title)
        }
        var chapters: [BookChapter] = []
        let pageCount = pdf.pageCount
        let pagesPerChapter = 10
        var start = 0
        while start < pageCount {
            let end = min(start + pagesPerChapter - 1, pageCount - 1)
            var combined = ""
            for i in start...end {
                if let pageText = pdf.page(at: i)?.string {
                    combined += " " + pageText
                }
            }
            let cleaned = combined.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                let sentences = splitIntoSentences(cleaned)
                var paras: [String] = []
                var i = 0
                while i < sentences.count {
                    let chunk = sentences[i..<min(i + 4, sentences.count)].joined(separator: " ")
                    paras.append(chunk)
                    i += 4
                }
                chapters.append(BookChapter(title: "第 \(start + 1) - \(end + 1) 页", paragraphs: paras))
            }
            start = end + 1
        }
        if chapters.isEmpty {
            return BookChapter(title: "正文", paragraphs: ["未能提取该 PDF 的文本层（可能是扫描图片版 PDF）。"]).asBook(title: title)
        }
        return ParsedBook(title: title, chapters: chapters)
    }

    // MARK: - EPUB (Zero-dependency ZIP + zlib)
    static func parseEpubData(title: String, data: Data) -> ParsedBook {
        let entries = extractZipEntries(from: data)
        let htmlEntries = entries
            .filter { $0.name.lowercased().hasSuffix(".xhtml") || $0.name.lowercased().hasSuffix(".html") || $0.name.lowercased().hasSuffix(".htm") }
            .sorted { $0.name < $1.name }

        var chapters: [BookChapter] = []
        for (idx, item) in htmlEntries.enumerated() {
            let html = String(decoding: item.data, as: UTF8.self)
            let paras = cleanHtmlToParagraphs(html)
            if !paras.isEmpty {
                let heading = paras[0].count < 70 ? paras[0] : "第 \(idx + 1) 节"
                chapters.append(BookChapter(title: heading, paragraphs: paras))
            }
        }
        if chapters.isEmpty {
            return BookChapter(title: "正文", paragraphs: ["未能从该 EPUB 文件中提取到有效文本。"]).asBook(title: title)
        }
        return ParsedBook(title: title, chapters: chapters)
    }

    private struct ZipEntry {
        let name: String
        let data: Data
    }

    private static func extractZipEntries(from data: Data) -> [ZipEntry] {
        var result: [ZipEntry] = []
        let bytes = [UInt8](data)
        var offset = 0
        while offset + 30 <= bytes.count {
            // Local file header signature 0x04034b50
            if bytes[offset] == 0x50, bytes[offset + 1] == 0x4b, bytes[offset + 2] == 0x03, bytes[offset + 3] == 0x04 {
                let compression = UInt16(bytes[offset + 8]) | (UInt16(bytes[offset + 9]) << 8)
                let compSize = Int(UInt32(bytes[offset + 18]) | (UInt32(bytes[offset + 19]) << 8) | (UInt32(bytes[offset + 20]) << 16) | (UInt32(bytes[offset + 21]) << 24))
                let uncompSize = Int(UInt32(bytes[offset + 22]) | (UInt32(bytes[offset + 23]) << 8) | (UInt32(bytes[offset + 24]) << 16) | (UInt32(bytes[offset + 25]) << 24))
                let nameLen = Int(UInt16(bytes[offset + 26]) | (UInt16(bytes[offset + 27]) << 8))
                let extraLen = Int(UInt16(bytes[offset + 28]) | (UInt16(bytes[offset + 29]) << 8))

                let nameStart = offset + 30
                let dataStart = nameStart + nameLen + extraLen
                guard dataStart + compSize <= bytes.count else { break }

                let name = String(bytes: bytes[nameStart..<(nameStart + nameLen)], encoding: .utf8) ?? ""
                let rawSlice = Data(bytes[dataStart..<(dataStart + compSize)])

                if compSize > 0 {
                    if compression == 0 {
                        result.append(ZipEntry(name: name, data: rawSlice))
                    } else if compression == 8, let inflated = inflateDeflate(rawSlice, expectedSize: max(uncompSize, compSize * 4)) {
                        result.append(ZipEntry(name: name, data: inflated))
                    }
                }
                offset = dataStart + compSize
            } else {
                offset += 1
            }
        }
        return result
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
        guard status == Z_STREAM_END else { return nil }
        output.count = Int(stream.total_out)
        return output
    }

    // MARK: - MOBI / AZW3
    static func parseMobiOrAzw3Data(title: String, data: Data) -> ParsedBook {
        let bytes = [UInt8](data)
        guard bytes.count >= 78 else { return parseTxtData(title: title, data: data) }
        let numRecords = Int(UInt16(bytes[76]) << 8 | UInt16(bytes[77]))
        var offsets: [Int] = []
        for i in 0..<numRecords {
            let pos = 78 + i * 8
            if pos + 4 <= bytes.count {
                let off = Int(UInt32(bytes[pos]) << 24 | UInt32(bytes[pos + 1]) << 16 | UInt32(bytes[pos + 2]) << 8 | UInt32(bytes[pos + 3]))
                offsets.append(off)
            }
        }
        guard offsets.count >= 2 else { return parseTxtData(title: title, data: data) }
        let rec0 = offsets[0]
        guard rec0 + 10 <= bytes.count else { return parseTxtData(title: title, data: data) }
        let compression = Int(UInt16(bytes[rec0]) << 8 | UInt16(bytes[rec0 + 1]))
        let textRecCount = Int(UInt16(bytes[rec0 + 8]) << 8 | UInt16(bytes[rec0 + 9]))
        let maxRec = min(offsets.count - 1, textRecCount)

        var out: [UInt8] = []
        for i in 1...max(1, maxRec) {
            let start = offsets[i]
            let end = i + 1 < offsets.count ? offsets[i + 1] : bytes.count
            guard start < end, start < bytes.count else { continue }
            let slice = Array(bytes[start..<min(end, bytes.count)])
            if compression == 2 {
                decompressPalmDocLz77(slice, into: &out)
            } else {
                out.append(contentsOf: slice)
            }
        }
        let html = String(decoding: out, as: UTF8.self)
        let paragraphs = cleanHtmlToParagraphs(html)
        if paragraphs.isEmpty {
            return BookChapter(title: "正文", paragraphs: ["未能从该 MOBI/AZW3 文件中提取到有效文本。"]).asBook(title: title)
        }
        var chapters: [BookChapter] = []
        var i = 0
        var cIdx = 1
        while i < paragraphs.count {
            let slice = Array(paragraphs[i..<min(i + 60, paragraphs.count)])
            chapters.append(BookChapter(title: "第 \(cIdx) 节", paragraphs: slice))
            cIdx += 1
            i += 60
        }
        return ParsedBook(title: title, chapters: chapters)
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
                    for _ in 0..<len {
                        out.append(out[out.count - dist])
                    }
                }
            }
        }
    }

    private static func cleanHtmlToParagraphs(_ html: String) -> [String] {
        var text = html
        text = text.replacingOccurrences(of: #"<script[^>]*>[\s\S]*?</script>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<style[^>]*>[\s\S]*?</style>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"</?(p|div|h1|h2|h3|h4|li|blockquote|br)[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        return text
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Sentence & Line Segmentation
    static func splitIntoSentences(_ paragraph: String) -> [String] {
        let protected = paragraph.replacingOccurrences(
            of: #"\b(Mr|Mrs|Ms|Dr|Prof|Sr|Jr|St|Mt|vs|etc|e\.g|i\.e|U\.S|U\.K)\."#,
            with: "$1\u{0000}",
            options: [.regularExpression, .caseInsensitive]
        )
        let pattern = #"(?:(?<=[.!?]["”'’)\]]*)\s+|(?<=[。！？]["”'’）」』】]*))"#
        let replaced = protected.replacingOccurrences(of: pattern, with: "\u{0001}", options: .regularExpression)
        let list = replaced
            .components(separatedBy: "\u{0001}")
            .map { $0.replacingOccurrences(of: "\u{0000}", with: ".").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return list.isEmpty ? [paragraph] : list
    }

    static func segmentChapter(_ chapter: BookChapter, mode: StepMode, fontSize: Double, maxWidth: Double) -> [ReadingUnit] {
        var units: [ReadingUnit] = []
        var idx = 0

        if mode == .sentence {
            for (pIdx, para) in chapter.paragraphs.enumerated() {
                for s in splitIntoSentences(para) {
                    units.append(ReadingUnit(index: idx, text: s, parentSentence: s, paragraphIndex: pIdx))
                    idx += 1
                }
            }
            return units
        }

        let font = UIFont(name: "Georgia", size: fontSize) ?? UIFont.systemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let safeWidth = max(240, maxWidth)

        for (pIdx, para) in chapter.paragraphs.enumerated() {
            for sentence in splitIntoSentences(para) {
                let words = sentence.components(separatedBy: " ").filter { !$0.isEmpty }
                var currentLine = ""
                for w in words {
                    let candidate = currentLine.isEmpty ? w : "\(currentLine) \(w)"
                    let width = (candidate as NSString).size(withAttributes: attrs).width
                    if width > safeWidth && !currentLine.isEmpty {
                        units.append(ReadingUnit(index: idx, text: currentLine, parentSentence: sentence, paragraphIndex: pIdx))
                        idx += 1
                        currentLine = w
                    } else {
                        currentLine = candidate
                    }
                }
                if !currentLine.isEmpty {
                    units.append(ReadingUnit(index: idx, text: currentLine, parentSentence: sentence, paragraphIndex: pIdx))
                    idx += 1
                }
            }
        }
        return units
    }
}

private extension BookChapter {
    func asBook(title: String) -> ParsedBook {
        ParsedBook(title: title, chapters: [self])
    }
}
