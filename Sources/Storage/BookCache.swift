import CryptoKit
import Foundation
import UIKit

@Observable
final class BookCache {
    static let shared = BookCache()

    private(set) var cachingHints: Set<String> = []
    private var memoryCache: [String: ParsedBook] = [:]
    private var coverMemoryCache: [String: UIImage] = [:]
    private var noCoverSet: Set<String> = []
    private let lock = NSLock()

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ParsedBookCacheV2", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var coverDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("BookCoverCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func hashKey(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func cacheFileUrl(for book: BookItem) -> URL {
        cacheDirectory.appendingPathComponent("\(hashKey(book.filePathHint)).json")
    }

    private static func coverFileUrl(for book: BookItem) -> URL {
        coverDirectory.appendingPathComponent("\(hashKey(book.filePathHint)).jpg")
    }

    private static func noCoverMarkerUrl(for book: BookItem) -> URL {
        coverDirectory.appendingPathComponent("\(hashKey(book.filePathHint)).nocover")
    }

    static func isCached(for book: BookItem) -> Bool {
        if book.filePathHint.hasPrefix("sample://") { return true }
        if shared.memoryCached(book.filePathHint) != nil { return true }
        return FileManager.default.fileExists(atPath: cacheFileUrl(for: book).path)
    }

    private func memoryCached(_ hint: String) -> ParsedBook? {
        lock.lock()
        defer { lock.unlock() }
        return memoryCache[hint]
    }

    private func putMemoryCache(_ hint: String, _ parsed: ParsedBook) {
        lock.lock()
        if memoryCache.count > 12 {
            memoryCache.removeAll()
        }
        memoryCache[hint] = parsed
        lock.unlock()
    }

    static func load(for book: BookItem) -> ParsedBook? {
        if let mem = shared.memoryCached(book.filePathHint) {
            return mem
        }
        let url = cacheFileUrl(for: book)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ParsedBook.self, from: data) else {
            return nil
        }
        shared.putMemoryCache(book.filePathHint, decoded)
        return decoded
    }

    static func save(_ parsed: ParsedBook, for book: BookItem) {
        guard !parsed.isErrorPlaceholder else { return }
        shared.putMemoryCache(book.filePathHint, parsed)
        let url = cacheFileUrl(for: book)
        if let data = try? JSONEncoder().encode(parsed) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func getOrParse(for book: BookItem) async throws -> ParsedBook {
        if let hit = load(for: book) {
            return hit
        }
        await MainActor.run {
            shared.cachingHints.insert(book.filePathHint)
        }
        defer {
            Task { @MainActor in
                shared.cachingHints.remove(book.filePathHint)
            }
        }
        let parsed = try await Task.detached(priority: .userInitiated) {
            try BookParser.parseBook(book: book)
        }.value
        save(parsed, for: book)
        return parsed
    }

    static func precacheMissingSequentially(books: [BookItem], db: DatabaseManager) {
        Task.detached(priority: .utility) {
            for book in books {
                if book.filePathHint.hasPrefix("sample://") { continue }
                if !isCached(for: book) {
                    if let parsed = try? await getOrParse(for: book), !parsed.isErrorPlaceholder, book.overallProgress < 0 {
                        let chap = min(max(0, book.currentChapter), max(0, parsed.chapters.count - 1))
                        let unitsCount = parsed.chapters.isEmpty ? 1 : max(1, parsed.chapters[chap].paragraphs.count)
                        let overall = BookParser.computeOverallProgress(
                            parsedBook: parsed,
                            chapterIndex: chap,
                            unitIndex: book.currentIndex,
                            chapterUnitCount: unitsCount
                        )
                        await MainActor.run {
                            db.updateOverallProgress(bookId: book.id, overallProgress: overall)
                        }
                    }
                }
            }
        }
    }

    static func getCoverImage(for book: BookItem) async -> UIImage? {
        if book.filePathHint.isEmpty || book.filePathHint.hasPrefix("sample://") { return nil }
        shared.lock.lock()
        if let mem = shared.coverMemoryCache[book.filePathHint] {
            shared.lock.unlock()
            return mem
        }
        if shared.noCoverSet.contains(book.filePathHint) {
            shared.lock.unlock()
            return nil
        }
        shared.lock.unlock()

        let coverUrl = coverFileUrl(for: book)
        let markerUrl = noCoverMarkerUrl(for: book)

        let diskImage: UIImage? = await Task.detached(priority: .utility) {
            if FileManager.default.fileExists(atPath: coverUrl.path),
               let data = try? Data(contentsOf: coverUrl),
               let img = UIImage(data: data) {
                return img
            }
            if FileManager.default.fileExists(atPath: markerUrl.path) {
                return nil
            }
            if let extracted = BookParser.extractCoverThumbnailBytes(for: book),
               let img = UIImage(data: extracted) {
                try? extracted.write(to: coverUrl, options: .atomic)
                return img
            }
            FileManager.default.createFile(atPath: markerUrl.path, contents: Data())
            return nil
        }.value

        shared.lock.lock()
        if let diskImage {
            if shared.coverMemoryCache.count > 48 { shared.coverMemoryCache.removeAll() }
            shared.coverMemoryCache[book.filePathHint] = diskImage
        } else {
            shared.noCoverSet.insert(book.filePathHint)
        }
        shared.lock.unlock()
        return diskImage
    }

    static func invalidate(for book: BookItem) {
        shared.lock.lock()
        shared.memoryCache.removeValue(forKey: book.filePathHint)
        shared.coverMemoryCache.removeValue(forKey: book.filePathHint)
        shared.noCoverSet.remove(book.filePathHint)
        shared.lock.unlock()
        try? FileManager.default.removeItem(at: cacheFileUrl(for: book))
        try? FileManager.default.removeItem(at: coverFileUrl(for: book))
        try? FileManager.default.removeItem(at: noCoverMarkerUrl(for: book))
    }

    static func deleteLocalBookFileIfManaged(_ book: BookItem) {
        invalidate(for: book)
        guard let url = URL(string: book.filePathHint), url.isFileURL else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let managedBooksDir = docs.appendingPathComponent("Books", isDirectory: true).standardizedFileURL.path
        let legacyBooksDir = docs.appendingPathComponent("DownloadedBooks", isDirectory: true).standardizedFileURL.path
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        if parent == managedBooksDir || parent == legacyBooksDir {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func getCacheStats() -> CacheStats {
        func dirSize(_ dir: URL) -> Int64 {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
            return files.reduce(0) { sum, url in
                sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        let tmpDir = FileManager.default.temporaryDirectory
        return CacheStats(
            bookCacheBytes: dirSize(cacheDirectory),
            coverCacheBytes: dirSize(coverDirectory),
            tempBytes: dirSize(tmpDir)
        )
    }

    static func clearAll() {
        shared.lock.lock()
        shared.memoryCache.removeAll()
        shared.coverMemoryCache.removeAll()
        shared.noCoverSet.removeAll()
        shared.lock.unlock()

        for dir in [cacheDirectory, coverDirectory] {
            if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for url in files { try? FileManager.default.removeItem(at: url) }
            }
        }
        let legacyDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ParsedBookCache", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil) {
            for url in files { try? FileManager.default.removeItem(at: url) }
        }
    }
}
