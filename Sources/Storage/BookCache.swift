import CryptoKit
import Foundation
import UIKit

@Observable
final class BookCache: @unchecked Sendable {
    static let shared = BookCache()

    private(set) var cachingHints: Set<String> = []
    private var memoryCache: [String: ParsedBook] = [:]
    private let coverNSCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 250
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private var noCoverSet: Set<String> = []
    private let lock = NSLock()

    // Dedicated GCD queues completely outside Swift Concurrency's cooperative thread pool
    private let coverDiskQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.tin.bookreader.coverDisk"
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()

    private let coverExtractQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.tin.bookreader.coverExtract"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()

    private let precacheQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.tin.bookreader.precache"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .background
        return q
    }()

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
            _ = shared.cachingHints.insert(book.filePathHint)
        }
        defer {
            Task { @MainActor in
                _ = shared.cachingHints.remove(book.filePathHint)
            }
        }
        let parsed = try await Task.detached(priority: .userInitiated) {
            try BookParser.parseBook(book: book)
        }.value
        save(parsed, for: book)
        return parsed
    }

    /// Gentle, serialized background precaching (e.g. for newly downloaded single OPDS/WebDAV book).
    /// Never floods Swift Concurrency's cooperative thread pool or mutates UI `@Observable` hints.
    static func precacheMissingSequentially(books: [BookItem], db: DatabaseManager) {
        for book in books {
            if book.filePathHint.hasPrefix("sample://") || isCached(for: book) { continue }
            shared.precacheQueue.addOperation {
                if isCached(for: book) { return }
                guard let parsed = try? BookParser.parseBook(book: book), !parsed.isErrorPlaceholder else {
                    return
                }
                save(parsed, for: book)
                if book.overallProgress < 0 {
                    let chap = min(max(0, book.currentChapter), max(0, parsed.chapters.count - 1))
                    let unitsCount = parsed.chapters.isEmpty ? 1 : max(1, parsed.chapters[chap].paragraphs.count)
                    let overall = BookParser.computeOverallProgress(
                        parsedBook: parsed,
                        chapterIndex: chap,
                        unitIndex: book.currentIndex,
                        chapterUnitCount: unitsCount
                    )
                    DispatchQueue.main.async {
                        db.updateOverallProgress(bookId: book.id, overallProgress: overall)
                    }
                }
            }
        }
    }

    private func lookupCoverState(_ hint: String) -> (hit: UIImage?, noCover: Bool) {
        if let mem = coverNSCache.object(forKey: hint as NSString) {
            return (mem, false)
        }
        lock.lock()
        let noCov = noCoverSet.contains(hint)
        lock.unlock()
        return (nil, noCov)
    }

    private func saveCoverState(_ hint: String, image: UIImage?) {
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            coverNSCache.setObject(image, forKey: hint as NSString, cost: max(1, cost))
        } else {
            lock.lock()
            noCoverSet.insert(hint)
            lock.unlock()
        }
    }

    static func cachedCoverIfReady(for book: BookItem) -> UIImage? {
        guard !book.filePathHint.isEmpty, !book.filePathHint.hasPrefix("sample://") else { return nil }
        return shared.lookupCoverState(book.filePathHint).hit
    }

    private final class ResumeOnceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private let cont: CheckedContinuation<(image: UIImage?, wasCancelled: Bool), Never>

        init(_ cont: CheckedContinuation<(image: UIImage?, wasCancelled: Bool), Never>) {
            self.cont = cont
        }

        func finish(image: UIImage?, wasCancelled: Bool) {
            lock.lock()
            let shouldResume = !resumed
            resumed = true
            lock.unlock()
            if shouldResume {
                cont.resume(returning: (image, wasCancelled))
            }
        }
    }

    private static func runOperation(_ queue: OperationQueue, work: @escaping () -> UIImage?) async -> (image: UIImage?, wasCancelled: Bool) {
        let op = BlockOperation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                let box = ResumeOnceBox(cont)
                op.addExecutionBlock { [weak op] in
                    if op?.isCancelled == true {
                        box.finish(image: nil, wasCancelled: true)
                        return
                    }
                    let result = work()
                    let wasCancelled = (op?.isCancelled == true)
                    box.finish(image: result, wasCancelled: wasCancelled)
                }
                op.completionBlock = {
                    box.finish(image: nil, wasCancelled: true)
                }
                queue.addOperation(op)
            }
        } onCancel: {
            op.cancel()
        }
    }

    static func getCoverImage(for book: BookItem) async -> UIImage? {
        if book.filePathHint.isEmpty || book.filePathHint.hasPrefix("sample://") { return nil }
        let cached = shared.lookupCoverState(book.filePathHint)
        if let mem = cached.hit { return mem }
        if cached.noCover { return nil }

        let coverUrl = coverFileUrl(for: book)
        let markerUrl = noCoverMarkerUrl(for: book)

        // Phase 1: Fast disk cache read (never waits behind heavy raw-book extraction)
        enum DiskProbe {
            case hit(UIImage)
            case noCover
            case needsExtraction
        }
        let diskProbe: DiskProbe = await withCheckedContinuation { cont in
            shared.coverDiskQueue.addOperation {
                if FileManager.default.fileExists(atPath: coverUrl.path),
                   let data = try? Data(contentsOf: coverUrl),
                   let img = UIImage(data: data) {
                    cont.resume(returning: .hit(img))
                    return
                }
                if FileManager.default.fileExists(atPath: markerUrl.path) {
                    cont.resume(returning: .noCover)
                    return
                }
                cont.resume(returning: .needsExtraction)
            }
        }

        switch diskProbe {
        case .hit(let img):
            shared.saveCoverState(book.filePathHint, image: img)
            return img
        case .noCover:
            shared.saveCoverState(book.filePathHint, image: nil)
            return nil
        case .needsExtraction:
            break
        }

        if Task.isCancelled { return nil }

        // Phase 2: Serialized extraction on dedicated GCD queue (1 at a time, cancellable before start)
        let outcome = await runOperation(shared.coverExtractQueue) {
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
        }

        if outcome.wasCancelled && outcome.image == nil {
            return nil
        }
        shared.saveCoverState(book.filePathHint, image: outcome.image)
        return outcome.image
    }

    static func invalidate(for book: BookItem) {
        shared.coverNSCache.removeObject(forKey: book.filePathHint as NSString)
        shared.lock.lock()
        shared.memoryCache.removeValue(forKey: book.filePathHint)
        shared.noCoverSet.remove(book.filePathHint)
        shared.lock.unlock()
        try? FileManager.default.removeItem(at: cacheFileUrl(for: book))
        try? FileManager.default.removeItem(at: coverFileUrl(for: book))
        try? FileManager.default.removeItem(at: noCoverMarkerUrl(for: book))
    }

    static func deleteLocalBookFileIfManaged(_ book: BookItem) {
        invalidate(for: book)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let managedBooksDir = docs.appendingPathComponent("Books", isDirectory: true).standardizedFileURL.path
        let legacyBooksDir = docs.appendingPathComponent("DownloadedBooks", isDirectory: true).standardizedFileURL.path

        if let resolved = BookParser.resolveReadableUrl(for: book) {
            defer {
                if resolved.stopSecurityScope {
                    resolved.url.stopAccessingSecurityScopedResource()
                }
            }
            let parent = resolved.url.deletingLastPathComponent().standardizedFileURL.path
            if parent == managedBooksDir || parent == legacyBooksDir {
                try? FileManager.default.removeItem(at: resolved.url)
                return
            }
        }

        if let url = URL(string: book.filePathHint), url.isFileURL {
            let parent = url.deletingLastPathComponent().standardizedFileURL.path
            if parent == managedBooksDir || parent == legacyBooksDir {
                try? FileManager.default.removeItem(at: url)
            }
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

    private static func managedBookFilesAndReferenced(activeBooks: [BookItem]) -> (allFiles: [(url: URL, size: Int64)], orphans: [(url: URL, size: Int64)]) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dirs = [
            docs.appendingPathComponent("Books", isDirectory: true),
            docs.appendingPathComponent("DownloadedBooks", isDirectory: true)
        ]

        var referenced = Set<String>()
        for book in activeBooks where !book.filePathHint.hasPrefix("sample://") {
            if let resolved = BookParser.resolveReadableUrl(for: book) {
                referenced.insert(resolved.url.standardizedFileURL.path)
                if resolved.stopSecurityScope {
                    resolved.url.stopAccessingSecurityScopedResource()
                }
            }
            if let url = URL(string: book.filePathHint), url.isFileURL {
                referenced.insert(url.standardizedFileURL.path)
            }
        }

        var allFiles: [(url: URL, size: Int64)] = []
        var orphans: [(url: URL, size: Int64)] = []
        for dir in dirs where fm.fileExists(atPath: dir.path) {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in items {
                let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard vals?.isRegularFile != false else { continue }
                let size = Int64(vals?.fileSize ?? 0)
                allFiles.append((url, size))
                if !referenced.contains(url.standardizedFileURL.path) {
                    orphans.append((url, size))
                }
            }
        }
        return (allFiles, orphans)
    }

    static func inspectManagedBooks(activeBooks: [BookItem]) -> ManagedBooksCleanupReport {
        let scan = managedBookFilesAndReferenced(activeBooks: activeBooks)
        return ManagedBooksCleanupReport(
            totalFiles: scan.allFiles.count,
            totalBytes: scan.allFiles.reduce(0) { $0 + $1.size },
            orphanFiles: scan.orphans.count,
            orphanBytes: scan.orphans.reduce(0) { $0 + $1.size }
        )
    }

    static func cleanOrphanedManagedBooks(activeBooks: [BookItem]) -> (removedFiles: Int, freedBytes: Int64) {
        let scan = managedBookFilesAndReferenced(activeBooks: activeBooks)
        var removed = 0
        var freed: Int64 = 0
        for item in scan.orphans {
            if (try? FileManager.default.removeItem(at: item.url)) != nil {
                removed += 1
                freed += item.size
            }
        }
        return (removed, freed)
    }

    static func clearAll() {
        shared.coverNSCache.removeAllObjects()
        shared.lock.lock()
        shared.memoryCache.removeAll()
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
