import Foundation
import UIKit

@Observable
@MainActor
final class BackupService {
    struct BackupPreview: Equatable, Sendable {
        let bookCount: Int
        let folderCount: Int
        let noteCount: Int
        let vocabCount: Int
        let exportedAtMs: Int64
        let manifestPath: String
        let booksDirPath: String
        let backupBooksCount: Int
        let backupBooksBytes: Int64
    }

    private let bookmarkKey = "external_backup_folder_bookmark_v1"
    private let folderNameKey = "external_backup_folder_name_v1"
    private let autoBackupKey = "external_auto_backup_enabled_v1"
    private let recordsOnlyKey = "external_backup_records_only_v1"
    private let lastBackupKey = "external_last_backup_ms_v1"

    var isAuthorized: Bool = false
    var authorizedFolderName: String = ""
    var isSandboxOwnDocumentsWarning: Bool = false
    var autoBackupEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(autoBackupEnabled, forKey: autoBackupKey)
        }
    }
    var recordsOnlyBackupEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(recordsOnlyBackupEnabled, forKey: recordsOnlyKey)
        }
    }
    var isBackingUp: Bool = false
    var isRestoring: Bool = false
    var lastBackupAtMs: Int64 = 0
    var statusMessage: String? = nil
    var statusIsError: Bool = false
    var detectedBackupPreview: BackupPreview? = nil

    private let backupQueue = DispatchQueue(label: "com.tin.bookreader.backup", qos: .utility)

    init() {
        let ud = UserDefaults.standard
        if ud.object(forKey: autoBackupKey) != nil {
            self.autoBackupEnabled = ud.bool(forKey: autoBackupKey)
        }
        if ud.object(forKey: recordsOnlyKey) != nil {
            self.recordsOnlyBackupEnabled = ud.bool(forKey: recordsOnlyKey)
        }
        self.lastBackupAtMs = Int64(ud.double(forKey: lastBackupKey))
        self.authorizedFolderName = ud.string(forKey: folderNameKey) ?? ""
        self.isAuthorized = ud.data(forKey: bookmarkKey) != nil
        if isAuthorized {
            Task { await refreshAuthorizedFolderState() }
        }
    }

    func authorizeBackupFolder(_ url: URL) {
        statusMessage = nil
        statusIsError = false
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            let bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let docsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                .standardizedFileURL.path
            let pickedPath = url.standardizedFileURL.path
            let isInsideOwnSandbox = pickedPath == docsPath || pickedPath.hasPrefix(docsPath + "/")

            let folderName = url.lastPathComponent.isEmpty ? "已选目录" : url.lastPathComponent
            let ud = UserDefaults.standard
            ud.set(bookmark, forKey: bookmarkKey)
            ud.set(folderName, forKey: folderNameKey)

            isAuthorized = true
            authorizedFolderName = folderName
            isSandboxOwnDocumentsWarning = isInsideOwnSandbox

            Task {
                await refreshAuthorizedFolderState()
            }
        } catch {
            statusIsError = true
            statusMessage = "无法获取目录持久权限：\(error.localizedDescription)"
        }
    }

    func revokeBackupFolder() {
        let ud = UserDefaults.standard
        ud.removeObject(forKey: bookmarkKey)
        ud.removeObject(forKey: folderNameKey)
        isAuthorized = false
        authorizedFolderName = ""
        isSandboxOwnDocumentsWarning = false
        detectedBackupPreview = nil
        statusIsError = false
        statusMessage = "已取消外部目录授权（外部目录中的已有备份不会被删除）"
    }

    func refreshAuthorizedFolderState() async {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            isAuthorized = false
            detectedBackupPreview = nil
            return
        }
        let preview = await withCheckedContinuation { (cont: CheckedContinuation<(valid: Bool, inSandbox: Bool, name: String?, preview: BackupPreview?), Never>) in
            backupQueue.async {
                var isStale = false
                guard let rootUrl = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
                    cont.resume(returning: (false, false, nil, nil))
                    return
                }
                let accessed = rootUrl.startAccessingSecurityScopedResource()
                defer { if accessed { rootUrl.stopAccessingSecurityScopedResource() } }

                let docsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    .standardizedFileURL.path
                let pickedPath = rootUrl.standardizedFileURL.path
                let inSandbox = pickedPath == docsPath || pickedPath.hasPrefix(docsPath + "/")
                let preview = Self.probeManifestSync(in: rootUrl)
                cont.resume(returning: (true, inSandbox, rootUrl.lastPathComponent, preview))
            }
        }
        isAuthorized = preview.valid
        isSandboxOwnDocumentsWarning = preview.inSandbox
        if let n = preview.name, !n.isEmpty {
            authorizedFolderName = n
        }
        detectedBackupPreview = preview.preview
    }

    func backupNow(db: DatabaseManager, settingsStore: SettingsStore, silent: Bool = false) async {
        guard !isBackingUp, !isRestoring else { return }
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            if !silent {
                statusIsError = true
                statusMessage = "请先授权外部存储目录（推荐 iCloud 云盘）"
            }
            return
        }

        let recordsOnly = recordsOnlyBackupEnabled
        isBackingUp = true
        if !silent {
            statusIsError = false
            statusMessage = recordsOnly
                ? "正在同步阅读进度、笔记与设置（不复制原书）..."
                : "正在增量同步藏书与阅读数据..."
        }

        let snapshot = db.exportBackupSnapshot()
        let currentSettings = settingsStore.settings
        let currentOpds = settingsStore.opdsSources
        let currentOpdsId = settingsStore.selectedOpdsSourceId
        let deviceName = UIDevice.current.name

        let result: Result<(copiedBooks: Int, totalBooks: Int, exportedAt: Int64, preview: BackupPreview), Error> = await withCheckedContinuation { cont in
            backupQueue.async {
                var isStale = false
                guard let rootUrl = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
                    cont.resume(returning: .failure(NSError(domain: "BackupService", code: 1, userInfo: [NSLocalizedDescriptionKey: "目录权限已失效，请重新授权目录"])))
                    return
                }
                let accessed = rootUrl.startAccessingSecurityScopedResource()
                defer { if accessed { rootUrl.stopAccessingSecurityScopedResource() } }

                do {
                    let fm = FileManager.default
                    let backupRoot = rootUrl.appendingPathComponent("MiaoyueBackup", isDirectory: true)
                    let booksDir = backupRoot.appendingPathComponent("Books", isDirectory: true)
                    try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
                    if !recordsOnly {
                        try fm.createDirectory(at: booksDir, withIntermediateDirectories: true)
                    }

                    var usedNames = Set<String>()
                    var backupBooks: [BackupBookRecord] = []
                    backupBooks.reserveCapacity(snapshot.books.count)
                    var copiedCount = 0

                    for book in snapshot.books {
                        var storedFileName = ""
                        if !book.filePathHint.hasPrefix("sample://") {
                            if recordsOnly {
                                let rawName: String = {
                                    if let parsed = URL(string: book.filePathHint), parsed.isFileURL {
                                        return parsed.lastPathComponent
                                    }
                                    return (book.filePathHint as NSString).lastPathComponent
                                }()
                                let cleanName = BookParser.strippedBookFileName(rawName)
                                storedFileName = cleanName.isEmpty ? "\(book.title).\(book.format.lowercased())" : cleanName
                            } else if let resolved = BookParser.resolveReadableUrl(for: book) {
                                defer {
                                    if resolved.stopSecurityScope {
                                        resolved.url.stopAccessingSecurityScopedResource()
                                    }
                                }
                                let cleanName = BookParser.strippedBookFileName(resolved.url.lastPathComponent)
                                var candidate = cleanName.isEmpty ? "book_\(book.id).\(book.format.lowercased())" : cleanName
                                if usedNames.contains(candidate.lowercased()) {
                                    candidate = "b\(book.id)_\(candidate)"
                                }
                                usedNames.insert(candidate.lowercased())
                                storedFileName = candidate

                                let destUrl = booksDir.appendingPathComponent(candidate)
                                let srcSize = (try? resolved.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                                let dstSize = (try? destUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
                                if !fm.fileExists(atPath: destUrl.path) || srcSize != dstSize || srcSize <= 0 {
                                    if fm.fileExists(atPath: destUrl.path) {
                                        try? fm.removeItem(at: destUrl)
                                    }
                                    try fm.copyItem(at: resolved.url, to: destUrl)
                                    copiedCount += 1
                                }
                            }
                        }

                        backupBooks.append(BackupBookRecord(
                            oldId: book.id,
                            title: book.title,
                            fileName: storedFileName,
                            filePathHint: book.filePathHint,
                            format: book.format,
                            currentChapter: book.currentChapter,
                            currentIndex: book.currentIndex,
                            totalItems: book.totalItems,
                            overallProgress: book.overallProgress,
                            readingSeconds: book.readingSeconds,
                            lastReadAt: book.lastReadAt,
                            oldFolderId: book.folderId
                        ))
                    }

                    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                    let manifest = AppBackupManifest(
                        version: 1,
                        exportedAtMs: nowMs,
                        deviceName: deviceName,
                        folders: snapshot.folders.map {
                            BackupFolderRecord(oldId: $0.id, name: $0.name, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
                        },
                        books: backupBooks,
                        vocabList: snapshot.vocabList.map {
                            BackupVocabRecord(
                                word: $0.word,
                                lemma: $0.lemma,
                                phonetic: $0.phonetic,
                                translation: $0.translation,
                                englishTranslation: $0.englishTranslation,
                                lookupCount: $0.lookupCount,
                                contextSentence: $0.contextSentence,
                                contextTranslation: $0.contextTranslation,
                                oldBookId: $0.bookId,
                                bookTitle: $0.bookTitle,
                                familiarity: $0.familiarity,
                                createdAt: $0.createdAt,
                                updatedAt: $0.updatedAt
                            )
                        },
                        notes: snapshot.notes.map {
                            BackupNoteRecord(
                                oldBookId: $0.bookId,
                                bookTitle: $0.bookTitle,
                                chapterIndex: $0.chapterIndex,
                                chapterTitle: $0.chapterTitle,
                                unitIndex: $0.unitIndex,
                                sentenceText: $0.sentenceText,
                                sentenceTranslation: $0.sentenceTranslation,
                                aiAnalysis: $0.aiAnalysis,
                                noteText: $0.noteText,
                                createdAt: $0.createdAt,
                                updatedAt: $0.updatedAt
                            )
                        },
                        readingLogs: snapshot.readingLogs.map {
                            BackupReadingLogRecord(
                                dateKey: $0.dateKey,
                                year: $0.year,
                                yearMonth: $0.yearMonth,
                                dayOfMonth: $0.dayOfMonth,
                                oldBookId: $0.bookId,
                                bookTitle: $0.bookTitle,
                                readingSeconds: $0.readingSeconds,
                                unitsRead: $0.unitsRead,
                                lookupsCount: $0.lookupsCount,
                                lastReadAt: $0.lastReadAt
                            )
                        },
                        vocabReviewLogs: snapshot.vocabReviewLogs.map {
                            BackupVocabReviewLogRecord(
                                dateKey: $0.dateKey,
                                year: $0.year,
                                yearMonth: $0.yearMonth,
                                dayOfMonth: $0.dayOfMonth,
                                unknownCount: $0.unknownCount,
                                fuzzyCount: $0.fuzzyCount,
                                knownCount: $0.knownCount,
                                updatedAt: $0.updatedAt
                            )
                        },
                        settings: currentSettings,
                        opdsSources: currentOpds,
                        selectedOpdsSourceId: currentOpdsId
                    )

                    let manifestUrl = backupRoot.appendingPathComponent("backup_manifest.json")
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted]
                    let data = try encoder.encode(manifest)
                    try data.write(to: manifestUrl, options: .atomic)

                    let booksStats = Self.dirStats(at: booksDir)
                    let preview = BackupPreview(
                        bookCount: manifest.books.count,
                        folderCount: manifest.folders.count,
                        noteCount: manifest.notes.count,
                        vocabCount: manifest.vocabList.count,
                        exportedAtMs: nowMs,
                        manifestPath: manifestUrl.path,
                        booksDirPath: booksDir.path,
                        backupBooksCount: booksStats.count,
                        backupBooksBytes: booksStats.bytes
                    )
                    cont.resume(returning: .success((copiedCount, manifest.books.count, nowMs, preview)))
                } catch {
                    cont.resume(returning: .failure(error))
                }
            }
        }

        isBackingUp = false
        switch result {
        case .success(let info):
            lastBackupAtMs = info.exportedAt
            UserDefaults.standard.set(Double(info.exportedAt), forKey: lastBackupKey)
            detectedBackupPreview = info.preview
            if !silent {
                statusIsError = false
                if recordsOnly {
                    statusMessage = "同步完成：已备份 \(info.totalBooks) 本图书的阅读进度、笔记、生词与设置（仅阅读记录，未拷贝原书）"
                } else if info.copiedBooks > 0 {
                    statusMessage = "同步完成：共 \(info.totalBooks) 本图书（本次增量拷贝 \(info.copiedBooks) 本）及全部笔记/生词/设置"
                } else {
                    statusMessage = "同步完成：\(info.totalBooks) 本图书均已是最新，已更新阅读进度与笔记设置"
                }
            }
        case .failure(let err):
            if !silent {
                statusIsError = true
                statusMessage = "备份失败：\(err.localizedDescription)"
            }
        }
    }

    func clearBackupBookCopies() async {
        guard !isBackingUp, !isRestoring else { return }
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return }

        isBackingUp = true
        statusIsError = false
        statusMessage = "正在清理备份目录中的原书副本..."

        let result: Result<(removedCount: Int, preview: BackupPreview?), Error> = await withCheckedContinuation { cont in
            backupQueue.async {
                var isStale = false
                guard let rootUrl = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
                    cont.resume(returning: .failure(NSError(domain: "BackupService", code: 3, userInfo: [NSLocalizedDescriptionKey: "目录权限已失效，请重新授权目录"])))
                    return
                }
                let accessed = rootUrl.startAccessingSecurityScopedResource()
                defer { if accessed { rootUrl.stopAccessingSecurityScopedResource() } }

                let fm = FileManager.default
                let booksDirs = [
                    rootUrl.appendingPathComponent("MiaoyueBackup/Books", isDirectory: true),
                    rootUrl.appendingPathComponent("Books", isDirectory: true)
                ]
                var removed = 0
                for dir in booksDirs where fm.fileExists(atPath: dir.path) {
                    if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                        removed += items.count
                    }
                    try? fm.removeItem(at: dir)
                }
                let preview = Self.probeManifestSync(in: rootUrl)
                cont.resume(returning: .success((removed, preview)))
            }
        }

        isBackingUp = false
        switch result {
        case .success(let info):
            detectedBackupPreview = info.preview
            statusIsError = false
            statusMessage = info.removedCount > 0
                ? "已清理备份目录中的 \(info.removedCount) 个原书副本（阅读记录、笔记与生词已保留）"
                : "备份目录中已无原书副本"
        case .failure(let err):
            statusIsError = true
            statusMessage = "清理失败：\(err.localizedDescription)"
        }
    }

    func restoreFromAuthorizedFolder(db: DatabaseManager, settingsStore: SettingsStore) async {
        guard !isBackingUp, !isRestoring else { return }
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            statusIsError = true
            statusMessage = "请先授权包含「MiaoyueBackup」的外部目录"
            return
        }

        isRestoring = true
        statusIsError = false
        statusMessage = "正在从外部目录恢复阅读记录与图书..."

        let loadResult: Result<(manifest: AppBackupManifest, resolvedHints: [Int64: String], copiedFiles: Int), Error> = await withCheckedContinuation { cont in
            backupQueue.async {
                var isStale = false
                guard let rootUrl = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
                    cont.resume(returning: .failure(NSError(domain: "BackupService", code: 2, userInfo: [NSLocalizedDescriptionKey: "目录权限已失效，请重新选择目录"])))
                    return
                }
                let accessed = rootUrl.startAccessingSecurityScopedResource()
                defer { if accessed { rootUrl.stopAccessingSecurityScopedResource() } }

                guard let located = Self.locateManifestUrls(in: rootUrl) else {
                    cont.resume(returning: .failure(NSError(domain: "BackupService", code: 404, userInfo: [NSLocalizedDescriptionKey: "所选目录下未找到 MiaoyueBackup/backup_manifest.json 备份文件"])))
                    return
                }

                do {
                    let data = try Self.coordinatedReadData(at: located.manifestUrl)
                    let manifest = try JSONDecoder().decode(AppBackupManifest.self, from: data)

                    let fm = FileManager.default
                    let sandboxBooksDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
                        .appendingPathComponent("Books", isDirectory: true)
                    try fm.createDirectory(at: sandboxBooksDir, withIntermediateDirectories: true)

                    let existingSandboxFiles = (try? fm.contentsOfDirectory(at: sandboxBooksDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []

                    var resolvedHints: [Int64: String] = [:]
                    var copiedFiles = 0

                    for book in manifest.books {
                        guard !book.fileName.isEmpty else { continue }
                        let cleanName = BookParser.strippedBookFileName(book.fileName)
                        let backupFileUrl = located.booksDirUrl.appendingPathComponent(book.fileName)
                        let backupCleanUrl = located.booksDirUrl.appendingPathComponent(cleanName)
                        let sourceUrl: URL? = fm.fileExists(atPath: backupFileUrl.path)
                            ? backupFileUrl
                            : (fm.fileExists(atPath: backupCleanUrl.path) ? backupCleanUrl : nil)

                        if let src = sourceUrl {
                            let srcSize = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                            if let existingLocal = existingSandboxFiles.first(where: {
                                BookParser.strippedBookFileName($0.lastPathComponent).caseInsensitiveCompare(cleanName) == .orderedSame
                                    && (((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2) == srcSize)
                            }) {
                                resolvedHints[book.oldId] = existingLocal.absoluteString
                                continue
                            }

                            let destUrl = sandboxBooksDir.appendingPathComponent(cleanName)
                            let dstSize = (try? destUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
                            if !fm.fileExists(atPath: destUrl.path) || (srcSize > 0 && srcSize != dstSize) {
                                try Self.coordinatedCopyItem(from: src, to: destUrl)
                                copiedFiles += 1
                            }
                            resolvedHints[book.oldId] = destUrl.absoluteString
                        } else if let existingLocal = existingSandboxFiles.first(where: {
                            BookParser.strippedBookFileName($0.lastPathComponent).caseInsensitiveCompare(cleanName) == .orderedSame
                        }) {
                            resolvedHints[book.oldId] = existingLocal.absoluteString
                        }
                    }

                    cont.resume(returning: .success((manifest, resolvedHints, copiedFiles)))
                } catch {
                    cont.resume(returning: .failure(error))
                }
            }
        }

        switch loadResult {
        case .success(let payload):
            let stats = db.restoreFromBackup(
                manifest: payload.manifest,
                resolvedFileHintByOldBookId: payload.resolvedHints
            )
            settingsStore.restoreFromBackup(
                settings: payload.manifest.settings,
                opdsSources: payload.manifest.opdsSources,
                selectedOpdsSourceId: payload.manifest.selectedOpdsSourceId
            )
            isRestoring = false
            statusIsError = false
            if payload.copiedFiles > 0 {
                statusMessage = "恢复成功：还原 \(stats.restoredBooks) 本图书（同步 \(payload.copiedFiles) 个文件）、\(stats.restoredFolders) 个文件夹、\(stats.restoredNotes) 条笔记、\(stats.restoredVocab) 个生词"
            } else {
                statusMessage = "恢复成功：还原 \(stats.restoredBooks) 本图书阅读记录、\(stats.restoredFolders) 个文件夹、\(stats.restoredNotes) 条笔记、\(stats.restoredVocab) 个生词（重导同名原书可自动接续进度）"
            }
        case .failure(let err):
            isRestoring = false
            statusIsError = true
            statusMessage = "恢复失败：\(err.localizedDescription)"
        }
    }

    // MARK: - Nonisolated File Helpers

    nonisolated private static func dirStats(at dir: URL) -> (count: Int, bytes: Int64) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path),
              let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return (0, 0)
        }
        let totalBytes = files.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (files.count, totalBytes)
    }

    nonisolated private static func locateManifestUrls(in rootUrl: URL) -> (manifestUrl: URL, booksDirUrl: URL)? {
        let fm = FileManager.default
        let nestedDir = rootUrl.appendingPathComponent("MiaoyueBackup", isDirectory: true)
        let nestedManifest = nestedDir.appendingPathComponent("backup_manifest.json")
        if fm.fileExists(atPath: nestedManifest.path) {
            return (nestedManifest, nestedDir.appendingPathComponent("Books", isDirectory: true))
        }
        let directManifest = rootUrl.appendingPathComponent("backup_manifest.json")
        if fm.fileExists(atPath: directManifest.path) {
            return (directManifest, rootUrl.appendingPathComponent("Books", isDirectory: true))
        }
        return nil
    }

    nonisolated private static func probeManifestSync(in rootUrl: URL) -> BackupPreview? {
        guard let located = locateManifestUrls(in: rootUrl),
              let data = try? coordinatedReadData(at: located.manifestUrl),
              let manifest = try? JSONDecoder().decode(AppBackupManifest.self, from: data) else {
            return nil
        }
        let booksStats = dirStats(at: located.booksDirUrl)
        return BackupPreview(
            bookCount: manifest.books.count,
            folderCount: manifest.folders.count,
            noteCount: manifest.notes.count,
            vocabCount: manifest.vocabList.count,
            exportedAtMs: manifest.exportedAtMs,
            manifestPath: located.manifestUrl.path,
            booksDirPath: located.booksDirUrl.path,
            backupBooksCount: booksStats.count,
            backupBooksBytes: booksStats.bytes
        )
    }

    nonisolated private static func coordinatedReadData(at url: URL) throws -> Data {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var coordError: NSError?
        var readResult: Result<Data, Error> = .failure(NSError(domain: "BackupService", code: -1))
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readUrl in
            do {
                readResult = .success(try Data(contentsOf: readUrl))
            } catch {
                readResult = .failure(error)
            }
        }
        if let coordError { throw coordError }
        return try readResult.get()
    }

    nonisolated private static func coordinatedCopyItem(from src: URL, to dst: URL) throws {
        try? FileManager.default.startDownloadingUbiquitousItem(at: src)
        var coordError: NSError?
        var copyError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: src, options: [], error: &coordError) { readUrl in
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: dst.path) {
                    try? fm.removeItem(at: dst)
                }
                try fm.copyItem(at: readUrl, to: dst)
            } catch {
                copyError = error
            }
        }
        if let coordError { throw coordError }
        if let copyError { throw copyError }
    }
}
