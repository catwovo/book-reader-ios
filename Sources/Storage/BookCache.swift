import Foundation

enum BookCache {
    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ParsedBookCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheFileUrl(for book: BookItem) -> URL {
        let key = "\(book.id)_\(book.title.hashValue)_\(book.format)"
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return cacheDirectory.appendingPathComponent("\(safe).json")
    }

    static func load(for book: BookItem) -> ParsedBook? {
        let url = cacheFileUrl(for: book)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ParsedBook.self, from: data) else {
            return nil
        }
        return decoded
    }

    static func save(_ parsed: ParsedBook, for book: BookItem) {
        let url = cacheFileUrl(for: book)
        if let data = try? JSONEncoder().encode(parsed) {
            try? data.write(to: url)
        }
    }

    static func totalCacheBytes() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return files.reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
    }

    static func clearAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in files {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
