import Foundation

enum NetworkBookService {
    private static func basicAuthHeader(user: String, pass: String) -> String? {
        guard !user.isEmpty || !pass.isEmpty else { return nil }
        let raw = "\(user):\(pass)"
        guard let data = raw.data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }

    // MARK: - OPDS Catalog
    static func fetchOpdsFeed(urlString: String, username: String, password: String) async throws -> [OpdsEntry] {
        guard let baseUrl = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "OPDS", code: -1, userInfo: [NSLocalizedDescriptionKey: "OPDS 地址无效"])
        }
        var req = URLRequest(url: baseUrl)
        req.timeoutInterval = 20
        if let auth = basicAuthHeader(user: username, pass: password) {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let (data, _) = try await URLSession.shared.data(for: req)
        let parser = OpdsXmlParser(baseUrl: baseUrl)
        return parser.parse(data: data)
    }

    // MARK: - WebDAV List & Download
    static func listWebDav(urlString: String, username: String, password: String) async throws -> [WebDavEntry] {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "WebDAV", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebDAV 地址无效"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PROPFIND"
        req.timeoutInterval = 20
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let auth = basicAuthHeader(user: username, pass: password) {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        req.httpBody = """
        <?xml version="1.0" encoding="utf-8" ?>
        <D:propfind xmlns:D="DAV:"><D:prop><D:displayname/><D:getcontentlength/><D:resourcetype/></D:prop></D:propfind>
        """.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "WebDAV", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "WebDAV 返回状态码 \(http.statusCode)"])
        }

        let xml = String(decoding: data, as: UTF8.self)
        return parseWebDavResponse(xml: xml, requestUrl: url)
    }

    static func downloadBookToLocal(urlString: String, suggestedName: String, username: String, password: String) async throws -> URL {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "Download", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载地址无效"])
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        if let auth = basicAuthHeader(user: username, pass: password) {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let (data, _) = try await URLSession.shared.data(for: req)
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let booksDir = docsDir.appendingPathComponent("DownloadedBooks", isDirectory: true)
        try FileManager.default.createDirectory(at: booksDir, withIntermediateDirectories: true)
        let safeName = suggestedName.replacingOccurrences(of: "/", with: "_")
        let destUrl = booksDir.appendingPathComponent(safeName)
        try data.write(to: destUrl)
        return destUrl
    }

    private static func parseWebDavResponse(xml: String, requestUrl: URL) -> [WebDavEntry] {
        var items: [WebDavEntry] = []
        let responses = xml.components(separatedBy: "<D:response>").dropFirst()
        let fallbackResponses = responses.isEmpty ? xml.components(separatedBy: "<d:response>").dropFirst() : responses
        let finalBlocks = fallbackResponses.isEmpty ? xml.components(separatedBy: "<response>").dropFirst() : fallbackResponses

        for block in finalBlocks {
            let href = extractTag("href", in: block) ?? ""
            guard !href.isEmpty else { continue }
            let decodedHref = href.removingPercentEncoding ?? href
            let reqPath = requestUrl.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let hrefPath = decodedHref.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if hrefPath == reqPath { continue }

            let isDir = block.contains("collection")
            let name = extractTag("displayname", in: block)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? (URL(string: href)?.lastPathComponent.removingPercentEncoding ?? href)
            let size = Int64(extractTag("getcontentlength", in: block) ?? "0") ?? 0

            let fullUrl: String
            if href.hasPrefix("http") {
                fullUrl = href
            } else if let resolved = URL(string: href, relativeTo: requestUrl) {
                fullUrl = resolved.absoluteString
            } else {
                fullUrl = href
            }

            let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
            if isDir || ["epub", "txt", "pdf", "mobi", "azw3"].contains(ext) {
                items.append(WebDavEntry(id: fullUrl, name: name.isEmpty ? "未命名" : name, href: fullUrl, isDirectory: isDir, sizeBytes: size))
            }
        }
        return items
    }

    private static func extractTag(_ tag: String, in text: String) -> String? {
        let pattern = "<(?:[a-zA-Z0-9]+:)?\(tag)[^>]*>([\\s\\S]*?)</(?:[a-zA-Z0-9]+:)?\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}

private final class OpdsXmlParser: NSObject, XMLParserDelegate {
    private let baseUrl: URL
    private var entries: [OpdsEntry] = []
    private var inEntry = false
    private var currentTag = ""
    private var title = ""
    private var author = ""
    private var bestLink = ""
    private var isAcquisition = false
    private var formatHint = "EPUB"

    init(baseUrl: URL) {
        self.baseUrl = baseUrl
    }

    func parse(data: Data) -> [OpdsEntry] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentTag = elementName.lowercased()
        if currentTag == "entry" {
            inEntry = true
            title = ""
            author = ""
            bestLink = ""
            isAcquisition = false
            formatHint = "EPUB"
        } else if inEntry && currentTag == "link" {
            let rel = (attributeDict["rel"] ?? "").lowercased()
            let type = (attributeDict["type"] ?? "").lowercased()
            let href = attributeDict["href"] ?? ""
            guard !href.isEmpty else { return }

            let resolved = URL(string: href, relativeTo: baseUrl)?.absoluteString ?? href
            if rel.contains("acquisition") || type.contains("epub") || type.contains("pdf") || type.contains("mobipocket") {
                isAcquisition = true
                bestLink = resolved
                if type.contains("pdf") { formatHint = "PDF" }
                else if type.contains("mobi") { formatHint = "MOBI" }
                else if type.contains("text/plain") { formatHint = "TXT" }
                else { formatHint = "EPUB" }
            } else if bestLink.isEmpty {
                bestLink = resolved
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inEntry else { return }
        if currentTag == "title" { title += string }
        else if currentTag == "name" { author += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.lowercased() == "entry", inEntry {
            inEntry = false
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanTitle.isEmpty && !bestLink.isEmpty {
                entries.append(OpdsEntry(
                    id: bestLink,
                    title: cleanTitle,
                    subtitle: author.trimmingCharacters(in: .whitespacesAndNewlines),
                    linkUrl: bestLink,
                    isAcquisition: isAcquisition,
                    formatHint: formatHint
                ))
            }
        }
    }
}
