import CryptoKit
import Foundation

enum NetworkBookService {
    static let formatPriority = ["EPUB", "PDF", "TXT", "MOBI", "AZW3"]
    static let supportedFormats = Set(formatPriority)

    // MARK: - Common Helpers

    static func normalizeUrl(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    private static func basicAuthHeader(user: String, pass: String) -> String? {
        guard !user.isEmpty || !pass.isEmpty else { return nil }
        let raw = "\(user):\(pass)"
        guard let data = raw.data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }

    private static func sha256Prefix16(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static var managedBooksDirectory: URL {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docsDir.appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func formatFileSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        let kb = 1024.0
        let mb = kb * 1024.0
        let gb = mb * 1024.0
        let b = Double(bytes)
        if b >= gb { return String(format: "%.2f GB", b / gb) }
        if b >= mb { return String(format: "%.1f MB", b / mb) }
        if b >= kb { return String(format: "%.0f KB", b / kb) }
        return "\(bytes) B"
    }

    // MARK: - OPDS 1.2 Client

    static func pickPreferredAcquisition(_ acquisitions: [OpdsAcquisitionLink]) -> OpdsAcquisitionLink? {
        guard !acquisitions.isEmpty else { return nil }
        for fmt in formatPriority {
            if let hit = acquisitions.first(where: { $0.format == fmt }) {
                return hit
            }
        }
        return acquisitions.first
    }

    static func localUriForOpdsBook(acquisitionUrl: String, format: String) -> String {
        let hash = sha256Prefix16(acquisitionUrl)
        let ext = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let finalExt = ext.isEmpty ? "epub" : ext
        return managedBooksDirectory.appendingPathComponent("opds_\(hash).\(finalExt)").absoluteString
    }

    static func testOpdsConnection(source: OpdsSource) async -> Result<String, Error> {
        let res = await fetchOpdsFeed(urlString: source.url, username: source.username, password: source.password)
        return res.map { feed in
            let titlePart = feed.title.isEmpty ? "OPDS 书源" : feed.title
            return "连接成功 · \(titlePart)（\(feed.entries.count) 项）"
        }
    }

    static func buildSearchUrl(template: String, query: String) -> String {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))
        let encoded = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        var url = template.replacingOccurrences(of: "{searchTerms}", with: encoded)
        url = url.replacingOccurrences(of: #"\{[a-zA-Z0-9_:]+\?\}"#, with: "", options: .regularExpression)
        return url
    }

    static func fetchOpdsFeed(urlString: String, username: String = "", password: String = "") async -> Result<OpdsFeed, Error> {
        let normalized = normalizeUrl(urlString)
        guard let url = URL(string: normalized) else {
            return .failure(NSError(domain: "OPDS", code: -1, userInfo: [NSLocalizedDescriptionKey: "OPDS 地址格式无效"]))
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("application/atom+xml, application/xml, text/xml;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("MiaoReader/1.0 (iOS; OPDS 1.2)", forHTTPHeaderField: "User-Agent")
        if let auth = basicAuthHeader(user: username, pass: password) {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return .failure(NSError(domain: "OPDS", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效响应"]))
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .failure(NSError(domain: "OPDS", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "需要账号密码或认证失败（HTTP \(http.statusCode)）"]))
            }
            if !(200...299).contains(http.statusCode) {
                return .failure(NSError(domain: "OPDS", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "请求失败（HTTP \(http.statusCode)）"]))
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard !data.isEmpty else {
                return .failure(NSError(domain: "OPDS", code: -2, userInfo: [NSLocalizedDescriptionKey: "服务器返回空内容"]))
            }
            let prefixStr = String(decoding: data.prefix(128), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if contentType.lowercased().contains("text/html") || prefixStr.hasPrefix("<!doctype html") || prefixStr.hasPrefix("<html") {
                return .failure(NSError(domain: "OPDS", code: -3, userInfo: [NSLocalizedDescriptionKey: "返回内容是网页而非 OPDS XML（请确认填的是 OPDS 订阅地址）"]))
            }

            let effectiveBase = http.url ?? url
            let parser = OpdsXmlFeedParser(baseUrl: effectiveBase)
            let parsed = parser.parse(data: data)

            var searchTemplate = parsed.directSearchTemplate
            if searchTemplate == nil, let descUrl = parsed.openSearchDescUrl {
                searchTemplate = await fetchOpenSearchTemplate(descUrl: descUrl, username: username, password: password)
            }

            return .success(OpdsFeed(
                title: parsed.title,
                entries: parsed.entries,
                nextPageUrl: parsed.nextPageUrl,
                searchUrlTemplate: searchTemplate
            ))
        } catch {
            return .failure(error)
        }
    }

    private static func fetchOpenSearchTemplate(descUrl: String, username: String, password: String) async -> String? {
        guard let url = URL(string: descUrl) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        if let auth = basicAuthHeader(user: username, pass: password) {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }
        let parser = OpenSearchParser(baseUrl: http.url ?? url)
        return parser.parse(data: data)
    }

    static func downloadOpdsBook(
        title: String,
        acquisition: OpdsAcquisitionLink,
        username: String = "",
        password: String = "",
        onProgress: @Sendable (Int64, Int64) async -> Void = { _, _ in }
    ) async -> Result<OpdsDownloadResult, Error> {
        let normalized = normalizeUrl(acquisition.url)
        guard let url = URL(string: normalized) else {
            return .failure(NSError(domain: "OPDS", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载地址无效"]))
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 180
        req.setValue("MiaoReader/1.0 (iOS; OPDS 1.2)", forHTTPHeaderField: "User-Agent")
        if let auth = basicAuthHeader(user: username, pass: password) {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return .failure(NSError(domain: "OPDS", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载响应无效"]))
            }
            if http.statusCode == 202 {
                return .failure(NSError(domain: "OPDS", code: 202, userInfo: [NSLocalizedDescriptionKey: "服务器正在打包生成电子书（HTTP 202），请约 1 分钟后重试"]))
            }
            if !(200...299).contains(http.statusCode) {
                return .failure(NSError(domain: "OPDS", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "下载失败（HTTP \(http.statusCode)）"]))
            }
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if contentType.contains("text/html") {
                return .failure(NSError(domain: "OPDS", code: -3, userInfo: [NSLocalizedDescriptionKey: "下载链接返回了网页（可能需要登录或跳转验证）"]))
            }

            let disposition = http.value(forHTTPHeaderField: "Content-Disposition") ?? ""
            let finalUrl = http.url?.absoluteString ?? normalized
            guard let finalFormat = resolveDownloadFormat(
                preferred: acquisition.format,
                contentType: contentType,
                disposition: disposition,
                finalUrl: finalUrl
            ) else {
                return .failure(NSError(domain: "OPDS", code: -4, userInfo: [NSLocalizedDescriptionKey: "暂不支持该电子书格式（\(acquisition.format.isEmpty ? contentType : acquisition.format)）"]))
            }

            let hash = sha256Prefix16(acquisition.url)
            let ext = finalFormat.lowercased()
            let targetUrl = managedBooksDirectory.appendingPathComponent("opds_\(hash).\(ext)")
            let tempUrl = managedBooksDirectory.appendingPathComponent("opds_\(hash).\(ext).tmp")

            var data = Data()
            let expected = http.expectedContentLength
            if expected > 0 { data.reserveCapacity(Int(min(expected, 64_000_000))) }
            var readTotal: Int64 = 0
            var lastReported: Int64 = 0

            for try await byte in bytes {
                data.append(byte)
                readTotal += 1
                if readTotal - lastReported >= 32_768 {
                    lastReported = readTotal
                    await onProgress(readTotal, expected)
                }
            }
            await onProgress(readTotal, expected)

            guard !data.isEmpty else {
                return .failure(NSError(domain: "OPDS", code: -5, userInfo: [NSLocalizedDescriptionKey: "下载文件为空"]))
            }
            let headAscii = String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if headAscii.hasPrefix("<!doc") || headAscii.hasPrefix("<html") {
                return .failure(NSError(domain: "OPDS", code: -6, userInfo: [NSLocalizedDescriptionKey: "下载内容是 HTML 错误页而非电子书"]))
            }
            if finalFormat == "EPUB" {
                let bytesArr = [UInt8](data.prefix(2))
                if bytesArr.count < 2 || bytesArr[0] != 0x50 || bytesArr[1] != 0x4B {
                    return .failure(NSError(domain: "OPDS", code: -7, userInfo: [NSLocalizedDescriptionKey: "下载的文件不是有效的 EPUB 包"]))
                }
            }
            if finalFormat == "PDF", !headAscii.hasPrefix("%pdf") {
                return .failure(NSError(domain: "OPDS", code: -8, userInfo: [NSLocalizedDescriptionKey: "下载的文件不是有效的 PDF 文档"]))
            }

            try data.write(to: tempUrl, options: .atomic)
            if FileManager.default.fileExists(atPath: targetUrl.path) {
                try? FileManager.default.removeItem(at: targetUrl)
            }
            try FileManager.default.moveItem(at: tempUrl, to: targetUrl)

            let cleanTitle: String
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                cleanTitle = t
            } else {
                let name = extractFileName(disposition: disposition, url: finalUrl)
                let stripped = (name as NSString).deletingPathExtension
                cleanTitle = stripped.isEmpty ? "在线图书" : stripped
            }

            return .success(OpdsDownloadResult(
                uriString: targetUrl.absoluteString,
                title: cleanTitle,
                format: finalFormat
            ))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - WebDAV Client

    static func detectBookFormat(_ fileName: String) -> String? {
        let ext = (fileName as NSString).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return supportedFormats.contains(ext) ? ext : nil
    }

    static func localUriForWebDavUrl(_ remoteUrl: String, format: String) -> String {
        let hash = sha256Prefix16(remoteUrl)
        let ext = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let finalExt = ext.isEmpty ? "bin" : ext
        return managedBooksDirectory.appendingPathComponent("webdav_\(hash).\(finalExt)").absoluteString
    }

    private static func ensureDirectoryUrl(_ url: String) -> String {
        url.hasSuffix("/") ? url : "\(url)/"
    }

    private static let propfindBodyData: Data? = """
    <?xml version="1.0" encoding="utf-8" ?>
    <d:propfind xmlns:d="DAV:">
      <d:prop>
        <d:displayname/>
        <d:getcontentlength/>
        <d:getlastmodified/>
        <d:resourcetype/>
      </d:prop>
    </d:propfind>
    """.data(using: .utf8)

    static func testWebDavConnection(urlString: String, username: String, password: String) async -> Result<String, Error> {
        let normalized = ensureDirectoryUrl(normalizeUrl(urlString))
        guard let url = URL(string: normalized) else {
            return .failure(NSError(domain: "WebDAV", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebDAV 地址格式无效"]))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PROPFIND"
        req.timeoutInterval = 18
        req.setValue("0", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let auth = basicAuthHeader(user: username, pass: password) {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        req.httpBody = propfindBodyData

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return .failure(NSError(domain: "WebDAV", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务器响应无效"]))
            }
            if http.statusCode == 207 || (200...299).contains(http.statusCode) {
                return .success("连接成功（HTTP \(http.statusCode)）")
            } else if http.statusCode == 401 || http.statusCode == 403 {
                return .failure(NSError(domain: "WebDAV", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "账号或密码校验失败（HTTP \(http.statusCode)）"]))
            } else if http.statusCode == 404 {
                return .failure(NSError(domain: "WebDAV", code: 404, userInfo: [NSLocalizedDescriptionKey: "路径不存在（HTTP 404），请检查地址路径"]))
            } else {
                return .failure(NSError(domain: "WebDAV", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "服务器返回异常（HTTP \(http.statusCode)）"]))
            }
        } catch {
            return .failure(NSError(domain: "WebDAV", code: -2, userInfo: [NSLocalizedDescriptionKey: "连接失败：\(error.localizedDescription)"]))
        }
    }

    static func listWebDav(urlString: String, username: String, password: String) async -> Result<[WebDavEntry], Error> {
        let normalized = ensureDirectoryUrl(normalizeUrl(urlString))
        guard let url = URL(string: normalized) else {
            return .failure(NSError(domain: "WebDAV", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebDAV 地址格式无效"]))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PROPFIND"
        req.timeoutInterval = 25
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let auth = basicAuthHeader(user: username, pass: password) {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        req.httpBody = propfindBodyData

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return .failure(NSError(domain: "WebDAV", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务器响应无效"]))
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .failure(NSError(domain: "WebDAV", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "账号或密码校验失败（HTTP \(http.statusCode)）"]))
            }
            if http.statusCode == 404 {
                return .failure(NSError(domain: "WebDAV", code: 404, userInfo: [NSLocalizedDescriptionKey: "目录不存在（HTTP 404）"]))
            }
            if http.statusCode != 207 && !(200...299).contains(http.statusCode) {
                return .failure(NSError(domain: "WebDAV", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "读取目录失败（HTTP \(http.statusCode)）"]))
            }
            guard !data.isEmpty else { return .success([]) }
            let parser = WebDavPropfindParser(baseUrl: http.url ?? url)
            return .success(parser.parse(data: data))
        } catch {
            return .failure(NSError(domain: "WebDAV", code: -2, userInfo: [NSLocalizedDescriptionKey: "读取目录失败：\(error.localizedDescription)"]))
        }
    }

    static func downloadWebDavBook(
        remoteUrl: String,
        fileName: String,
        format: String,
        username: String,
        password: String,
        onProgress: @Sendable (Int64, Int64) async -> Void = { _, _ in }
    ) async -> Result<WebDavDownloadResult, Error> {
        guard let url = URL(string: normalizeUrl(remoteUrl)) else {
            return .failure(NSError(domain: "WebDAV", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的文件地址"]))
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 180
        if let auth = basicAuthHeader(user: username, pass: password) {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let hash = sha256Prefix16(remoteUrl)
        let ext = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let finalExt = ext.isEmpty ? "bin" : ext
        let finalUrl = managedBooksDirectory.appendingPathComponent("webdav_\(hash).\(finalExt)")
        let tmpUrl = managedBooksDirectory.appendingPathComponent("webdav_\(hash).\(finalExt).tmp")

        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return .failure(NSError(domain: "WebDAV", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务器响应无效"]))
            }
            guard (200...299).contains(http.statusCode) else {
                return .failure(NSError(domain: "WebDAV", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "下载失败（HTTP \(http.statusCode)）"]))
            }

            var data = Data()
            let total = http.expectedContentLength
            if total > 0 { data.reserveCapacity(Int(min(total, 64_000_000))) }
            var downloaded: Int64 = 0
            var lastReported: Int64 = 0

            for try await byte in bytes {
                data.append(byte)
                downloaded += 1
                if downloaded - lastReported >= 32_768 {
                    lastReported = downloaded
                    await onProgress(downloaded, total)
                }
            }
            await onProgress(downloaded, total)

            try data.write(to: tmpUrl, options: .atomic)
            if FileManager.default.fileExists(atPath: finalUrl.path) {
                try? FileManager.default.removeItem(at: finalUrl)
            }
            try FileManager.default.moveItem(at: tmpUrl, to: finalUrl)

            let stripped = (fileName as NSString).deletingPathExtension
            let cleanTitle = stripped.isEmpty ? fileName : stripped
            return .success(WebDavDownloadResult(uriString: finalUrl.absoluteString, title: cleanTitle, format: format))
        } catch {
            try? FileManager.default.removeItem(at: tmpUrl)
            return .failure(NSError(domain: "WebDAV", code: -2, userInfo: [NSLocalizedDescriptionKey: "下载失败：\(error.localizedDescription)"]))
        }
    }

    // MARK: - Format & String Helpers

    fileprivate static func detectFormat(mimeType: String, url: String) -> String? {
        let m = mimeType.lowercased()
        if m.contains("epub") { return "EPUB" }
        if m.contains("pdf") { return "PDF" }
        if m.contains("mobipocket") || m.contains("x-mobi") { return "MOBI" }
        if m.contains("amazon.ebook") || m.contains("azw3") || m.contains("kf8") { return "AZW3" }
        if m.hasPrefix("text/plain") { return "TXT" }

        let base = url.components(separatedBy: "?").first?.components(separatedBy: "#").first?.lowercased() ?? ""
        let ext = (base as NSString).pathExtension.uppercased()
        if supportedFormats.contains(ext) { return ext }
        if m.contains("octet-stream") || m.isEmpty {
            for fmt in supportedFormats where base.contains(".\(fmt.lowercased())") {
                return fmt
            }
        }
        return nil
    }

    private static func resolveDownloadFormat(preferred: String, contentType: String, disposition: String, finalUrl: String) -> String? {
        if let hit = detectFormat(mimeType: contentType, url: finalUrl) { return hit }
        let fileName = extractFileName(disposition: disposition, url: finalUrl)
        let dispExt = (fileName as NSString).pathExtension.uppercased()
        if supportedFormats.contains(dispExt) { return dispExt }
        let up = preferred.uppercased()
        return supportedFormats.contains(up) ? up : nil
    }

    private static func extractFileName(disposition: String, url: String) -> String {
        if let regex = try? NSRegularExpression(pattern: #"filename\*?=(?:UTF-8''|"?)([^";]+)"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: disposition, range: NSRange(disposition.startIndex..., in: disposition)),
           match.numberOfRanges >= 2,
           let r = Range(match.range(at: 1), in: disposition) {
            let raw = String(disposition[r]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            return raw.removingPercentEncoding ?? raw
        }
        let pathPart = url.components(separatedBy: "?").first ?? url
        let last = (pathPart as NSString).lastPathComponent
        return last.removingPercentEncoding ?? last
    }

    fileprivate static func stripHtml(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var s = trimmed.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"),
            ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")
        ]
        for (k, v) in entities {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - OPDS XML Parser

private final class OpdsXmlFeedParser: NSObject, XMLParserDelegate {
    struct ParsedResult {
        let title: String
        let entries: [OpdsEntry]
        let nextPageUrl: String?
        let directSearchTemplate: String?
        let openSearchDescUrl: String?
    }

    private let baseUrl: URL
    private var feedTitle = ""
    private var nextPageUrl: String?
    private var directSearchTemplate: String?
    private var openSearchDescUrl: String?
    private var entries: [OpdsEntry] = []

    private var inEntry = false
    private var inAuthor = false
    private var entryId = ""
    private var entryTitle = ""
    private var entryAuthors: [String] = []
    private var entrySummary = ""
    private var entryContent = ""
    private var entryUpdated = ""
    private var entryNavUrl: String?
    private var entryNavPriority = -1
    private var entryCoverUrl: String?
    private var entryThumbUrl: String?
    private var entryAcquisitions: [OpdsAcquisitionLink] = []

    private var currentTag = ""
    private var textBuffer = ""

    init(baseUrl: URL) {
        self.baseUrl = baseUrl
    }

    func parse(data: Data) -> ParsedResult {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        parser.parse()
        return ParsedResult(
            title: feedTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            entries: entries,
            nextPageUrl: nextPageUrl,
            directSearchTemplate: directSearchTemplate,
            openSearchDescUrl: openSearchDescUrl
        )
    }

    private func localName(_ elementName: String) -> String {
        let lower = elementName.lowercased()
        if let idx = lower.lastIndex(of: ":") {
            return String(lower[lower.index(after: idx)...])
        }
        return lower
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let tag = localName(elementName)
        textBuffer = ""
        currentTag = tag

        switch tag {
        case "entry":
            inEntry = true
            inAuthor = false
            entryId = ""
            entryTitle = ""
            entryAuthors = []
            entrySummary = ""
            entryContent = ""
            entryUpdated = ""
            entryNavUrl = nil
            entryNavPriority = -1
            entryCoverUrl = nil
            entryThumbUrl = nil
            entryAcquisitions = []
        case "author":
            if inEntry { inAuthor = true }
        case "link":
            let rel = (attributeDict["rel"] ?? "").lowercased()
            let href = (attributeDict["href"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let type = (attributeDict["type"] ?? "").lowercased()
            let linkTitle = (attributeDict["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty else { return }
            let resolved = URL(string: href, relativeTo: baseUrl)?.absoluteString ?? href

            if !inEntry {
                if rel == "next" {
                    nextPageUrl = resolved
                } else if rel == "search" {
                    if resolved.contains("{searchTerms}") || type.contains("atom+xml") {
                        if directSearchTemplate == nil { directSearchTemplate = resolved }
                    } else if type.contains("opensearchdescription") {
                        if openSearchDescUrl == nil { openSearchDescUrl = resolved }
                    }
                }
            } else {
                let isAcquisition = rel.contains("opds-spec.org/acquisition") || rel == "acquisition"
                let isImage = rel.contains("opds-spec.org/image") || rel == "thumbnail" || rel == "cover" || type.hasPrefix("image/")

                if isAcquisition {
                    if let fmt = NetworkBookService.detectFormat(mimeType: type, url: resolved),
                       !entryAcquisitions.contains(where: { $0.url == resolved }) {
                        entryAcquisitions.append(OpdsAcquisitionLink(
                            url: resolved,
                            format: fmt,
                            mimeType: type,
                            title: linkTitle
                        ))
                    }
                } else if isImage {
                    if rel.contains("thumbnail") {
                        if entryThumbUrl == nil { entryThumbUrl = resolved }
                    } else if entryCoverUrl == nil {
                        entryCoverUrl = resolved
                    }
                } else if rel == "subsection" ||
                            rel.contains("opds-spec.org/sort") ||
                            rel.contains("opds-spec.org/featured") ||
                            rel == "start" ||
                            (type.contains("application/atom+xml") && rel != "self" && rel != "alternate") {
                    let priority: Int
                    if rel == "subsection" { priority = 3 }
                    else if type.contains("profile=opds-catalog") { priority = 2 }
                    else { priority = 1 }
                    if priority > entryNavPriority {
                        entryNavUrl = resolved
                        entryNavPriority = priority
                    }
                } else if type.contains("application/atom+xml") && rel == "alternate" && entryNavUrl == nil {
                    entryNavUrl = resolved
                    entryNavPriority = 0
                }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let tag = localName(elementName)
        let text = textBuffer

        if !inEntry {
            if tag == "title" && feedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                feedTitle += text
            }
        } else {
            switch tag {
            case "id": entryId += text
            case "title": entryTitle += text
            case "name":
                if inAuthor {
                    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty && !entryAuthors.contains(clean) {
                        entryAuthors.append(clean)
                    }
                }
            case "summary": entrySummary += text
            case "content": entryContent += text
            case "updated": entryUpdated += text
            case "author": inAuthor = false
            case "entry":
                let cleanTitle = entryTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanTitle.isEmpty && (!entryAcquisitions.isEmpty || entryNavUrl != nil) {
                    let rawSummary = entrySummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? entryContent : entrySummary
                    let cleanSummary = NetworkBookService.stripHtml(rawSummary)
                    let sortedAcquisitions = entryAcquisitions.sorted { a, b in
                        let ia = NetworkBookService.formatPriority.firstIndex(of: a.format) ?? Int.max
                        let ib = NetworkBookService.formatPriority.firstIndex(of: b.format) ?? Int.max
                        return ia < ib
                    }
                    let cleanId = entryId.trimmingCharacters(in: .whitespacesAndNewlines)
                    entries.append(OpdsEntry(
                        id: cleanId.isEmpty ? (entryNavUrl ?? sortedAcquisitions.first?.url ?? cleanTitle) : cleanId,
                        title: cleanTitle,
                        author: entryAuthors.joined(separator: ", "),
                        summary: cleanSummary,
                        navigationUrl: entryNavUrl,
                        coverUrl: entryThumbUrl ?? entryCoverUrl,
                        acquisitions: sortedAcquisitions,
                        updated: entryUpdated.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
                inEntry = false
            default:
                break
            }
        }
        if currentTag == tag { currentTag = "" }
        textBuffer = ""
    }
}

private final class OpenSearchParser: NSObject, XMLParserDelegate {
    private let baseUrl: URL
    private var preferredTemplate: String?
    private var fallbackTemplate: String?

    init(baseUrl: URL) {
        self.baseUrl = baseUrl
    }

    func parse(data: Data) -> String? {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        parser.parse()
        return preferredTemplate ?? fallbackTemplate
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let lower = elementName.lowercased()
        let local = lower.components(separatedBy: ":").last ?? lower
        guard local == "url" else { return }
        let type = (attributeDict["type"] ?? "").lowercased()
        let template = attributeDict["template"] ?? ""
        let resolved = URL(string: template, relativeTo: baseUrl)?.absoluteString ?? template
        guard resolved.contains("{searchTerms}") else { return }
        if type.contains("atom+xml") || type.contains("opds") {
            if preferredTemplate == nil { preferredTemplate = resolved }
        } else if fallbackTemplate == nil {
            fallbackTemplate = resolved
        }
    }
}

// MARK: - WebDAV PROPFIND Parser

private final class WebDavPropfindParser: NSObject, XMLParserDelegate {
    private let baseUrl: URL
    private let baseCanonicalPath: String
    private var entries: [WebDavEntry] = []

    private var inResponse = false
    private var inPropStat = false
    private var inResourceType = false

    private var href = ""
    private var displayName = ""
    private var contentLength: Int64 = 0
    private var lastModified = ""
    private var isCollection = false

    private var propStatStatus = 200
    private var psDisplayName = ""
    private var psContentLength: Int64 = 0
    private var psLastModified = ""
    private var psIsCollection = false

    private var textBuffer = ""

    init(baseUrl: URL) {
        self.baseUrl = baseUrl
        self.baseCanonicalPath = Self.canonicalPath(baseUrl.path)
    }

    func parse(data: Data) -> [WebDavEntry] {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        parser.parse()
        return entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private static func canonicalPath(_ path: String) -> String {
        let decoded = path.removingPercentEncoding ?? path
        let trimmed = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "/" : "/\(trimmed)"
    }

    private func localName(_ name: String) -> String {
        let lower = name.lowercased()
        if let idx = lower.lastIndex(of: ":") {
            return String(lower[lower.index(after: idx)...])
        }
        return lower
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let tag = localName(elementName)
        textBuffer = ""
        switch tag {
        case "response":
            inResponse = true
            inPropStat = false
            inResourceType = false
            href = ""
            displayName = ""
            contentLength = 0
            lastModified = ""
            isCollection = false
        case "propstat":
            if inResponse {
                inPropStat = true
                propStatStatus = 200
                psDisplayName = ""
                psContentLength = 0
                psLastModified = ""
                psIsCollection = false
            }
        case "resourcetype":
            if inPropStat { inResourceType = true }
        case "collection":
            if inResourceType { psIsCollection = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let tag = localName(elementName)
        let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { textBuffer = "" }
        guard inResponse else { return }

        switch tag {
        case "href":
            if !inPropStat && !value.isEmpty { href = value }
        case "status":
            if inPropStat && !value.isEmpty {
                let parts = value.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 2, let code = Int(parts[1]) {
                    propStatStatus = code
                }
            }
        case "displayname":
            if inPropStat && !value.isEmpty { psDisplayName = value }
        case "getcontentlength":
            if inPropStat, let len = Int64(value) { psContentLength = len }
        case "getlastmodified":
            if inPropStat && !value.isEmpty { psLastModified = value }
        case "resourcetype":
            inResourceType = false
        case "propstat":
            if inPropStat && (200...299).contains(propStatStatus) {
                if !psDisplayName.isEmpty { displayName = psDisplayName }
                if psContentLength > 0 { contentLength = psContentLength }
                if !psLastModified.isEmpty { lastModified = psLastModified }
                if psIsCollection { isCollection = true }
            }
            inPropStat = false
        case "response":
            inResponse = false
            guard !href.isEmpty, let resolved = URL(string: href, relativeTo: baseUrl) ?? URL(string: href) else { return }
            let entryPath = Self.canonicalPath(resolved.path)
            guard entryPath != baseCanonicalPath else { return }

            let isDir = isCollection || href.hasSuffix("/")
            let fallbackName = (entryPath as NSString).lastPathComponent
            let finalName = displayName.isEmpty ? (fallbackName.isEmpty ? entryPath : fallbackName) : displayName
            var finalUrl = resolved.absoluteString
            if isDir && !finalUrl.hasSuffix("/") { finalUrl += "/" }
            let fmt = isDir ? nil : NetworkBookService.detectBookFormat(finalName)

            entries.append(WebDavEntry(
                name: finalName,
                url: finalUrl,
                isDirectory: isDir,
                sizeBytes: contentLength,
                lastModified: lastModified,
                format: fmt
            ))
        default:
            break
        }
    }
}
