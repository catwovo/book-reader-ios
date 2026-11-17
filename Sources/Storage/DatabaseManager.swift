import Foundation
import NaturalLanguage
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct TextToken: Hashable, Sendable {
    let text: String
    let isLookupable: Bool
    let isCjk: Bool
}

enum TextTokenizer {
    static func isReadingWhitespace(_ ch: Character) -> Bool {
        if ch.isWhitespace { return true }
        switch ch {
        case "\u{00A0}", "\u{2007}", "\u{202F}", "\u{3000}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}":
            return true
        default:
            return false
        }
    }

    static func isChineseChar(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            if (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3400 && v <= 0x4DBF) {
                return true
            }
        }
        return false
    }

    static func isPredominantlyChinese(_ text: String) -> Bool {
        var cjk = 0
        var latin = 0
        for ch in text {
            if isChineseChar(ch) {
                cjk += 1
            } else if (ch >= "A" && ch <= "Z") || (ch >= "a" && ch <= "z") {
                latin += 1
            }
        }
        return (cjk >= 2 && cjk >= latin) || (cjk >= 1 && latin == 0)
    }

    static func isAsciiWordStart(_ ch: Character) -> Bool {
        (ch >= "A" && ch <= "Z") || (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9")
    }

    static func tokenizeMixedText(_ text: String) -> [TextToken] {
        guard !text.isEmpty else { return [] }
        let chars = Array(text)
        var tokens: [TextToken] = []
        tokens.reserveCapacity(max(8, chars.count / 2))

        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if isReadingWhitespace(ch) {
                i += 1
            } else if isChineseChar(ch) {
                var end = i
                while end < chars.count && isChineseChar(chars[end]) {
                    end += 1
                }
                let run = String(chars[i..<end])
                segmentCjkRun(run, into: &tokens)
                i = end
            } else if isAsciiWordStart(ch) {
                var end = i + 1
                while end < chars.count {
                    let c = chars[end]
                    if isAsciiWordStart(c) {
                        end += 1
                    } else if (c == "'" || c == "’" || c == "-") && end + 1 < chars.count && isAsciiWordStart(chars[end + 1]) {
                        end += 1
                    } else {
                        break
                    }
                }
                tokens.append(TextToken(text: String(chars[i..<end]), isLookupable: true, isCjk: false))
                i = end
            } else {
                var end = i + 1
                while end < chars.count {
                    let c = chars[end]
                    if isReadingWhitespace(c) || isChineseChar(c) || isAsciiWordStart(c) {
                        break
                    }
                    end += 1
                }
                tokens.append(TextToken(text: String(chars[i..<end]), isLookupable: false, isCjk: false))
                i = end
            }
        }
        return tokens
    }

    private static func segmentCjkRun(_ run: String, into out: inout [TextToken]) {
        if run.count <= 1 {
            if !run.isEmpty {
                out.append(TextToken(text: run, isLookupable: true, isCjk: true))
            }
            return
        }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = run
        tokenizer.setLanguage(.simplifiedChinese)
        var cursor = run.startIndex
        var emitted = false
        tokenizer.enumerateTokens(in: run.startIndex..<run.endIndex) { range, _ in
            if cursor < range.lowerBound {
                let gap = String(run[cursor..<range.lowerBound])
                for ch in gap {
                    out.append(TextToken(text: String(ch), isLookupable: true, isCjk: true))
                }
            }
            let piece = String(run[range])
            if !piece.isEmpty {
                out.append(TextToken(text: piece, isLookupable: true, isCjk: true))
                emitted = true
            }
            cursor = range.upperBound
            return true
        }
        if cursor < run.endIndex {
            let tail = String(run[cursor..<run.endIndex])
            for ch in tail {
                out.append(TextToken(text: String(ch), isLookupable: true, isCjk: true))
                emitted = true
            }
        }
        if !emitted {
            for ch in run {
                out.append(TextToken(text: String(ch), isLookupable: true, isCjk: true))
            }
        }
    }
}

@Observable
final class DatabaseManager: @unchecked Sendable {
    private var db: OpaquePointer?
    private let dbLock = NSRecursiveLock()

    var folders: [BookFolder] = []
    var books: [BookItem] = []
    var vocabList: [VocabItem] = []
    var notes: [SentenceNote] = []
    var readingLogs: [ReadingLog] = []
    var vocabReviewLogs: [VocabReviewLog] = []
    var dictionaryCount: Int = 0
    var chineseDictionaryCount: Int = 0

    init() {
        openDatabase()
        createTablesAndMigrate()
        seedDictionaryIfEmpty()
        seedSampleBookIfEmpty()
        reloadAll()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private func openDatabase() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbUrl = dir.appendingPathComponent("book_reader.sqlite")
        sqlite3_open_v2(dbUrl.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
    }

    private func exec(_ sql: String) {
        dbLock.lock()
        defer { dbLock.unlock() }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func tableColumns(_ table: String) -> Set<String> {
        dbLock.lock()
        defer { dbLock.unlock() }
        var cols = Set<String>()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 1) {
                    cols.insert(String(cString: cStr))
                }
            }
        }
        sqlite3_finalize(stmt)
        return cols
    }

    private func createTablesAndMigrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS book_folders (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            createdAt INTEGER NOT NULL,
            updatedAt INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS books (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            bookmarkData BLOB,
            filePathHint TEXT NOT NULL UNIQUE,
            format TEXT NOT NULL,
            currentChapter INTEGER NOT NULL DEFAULT 0,
            currentIndex INTEGER NOT NULL DEFAULT 0,
            totalItems INTEGER NOT NULL DEFAULT 1,
            overallProgress REAL NOT NULL DEFAULT -1.0,
            readingSeconds INTEGER NOT NULL DEFAULT 0,
            lastReadAt INTEGER NOT NULL,
            folderId INTEGER
        );
        CREATE TABLE IF NOT EXISTS vocab (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            word TEXT NOT NULL UNIQUE,
            lemma TEXT NOT NULL,
            phonetic TEXT NOT NULL,
            translation TEXT NOT NULL,
            englishTranslation TEXT NOT NULL DEFAULT '',
            lookupCount INTEGER NOT NULL DEFAULT 1,
            contextSentence TEXT NOT NULL DEFAULT '',
            contextTranslation TEXT NOT NULL DEFAULT '',
            bookId INTEGER,
            bookTitle TEXT NOT NULL DEFAULT '',
            familiarity INTEGER NOT NULL DEFAULT 0,
            createdAt INTEGER NOT NULL,
            updatedAt INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS dictionary (
            word TEXT PRIMARY KEY,
            phonetic TEXT NOT NULL,
            translation TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS translation_cache (
            sourceText TEXT PRIMARY KEY,
            translatedText TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS reading_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            dateKey TEXT NOT NULL,
            year INTEGER NOT NULL,
            yearMonth TEXT NOT NULL,
            dayOfMonth INTEGER NOT NULL,
            bookId INTEGER NOT NULL,
            bookTitle TEXT NOT NULL,
            readingSeconds INTEGER NOT NULL DEFAULT 0,
            unitsRead INTEGER NOT NULL DEFAULT 0,
            lookupsCount INTEGER NOT NULL DEFAULT 0,
            lastReadAt INTEGER NOT NULL,
            UNIQUE(dateKey, bookId)
        );
        CREATE TABLE IF NOT EXISTS vocab_review_logs (
            dateKey TEXT PRIMARY KEY,
            year INTEGER NOT NULL,
            yearMonth TEXT NOT NULL,
            dayOfMonth INTEGER NOT NULL,
            unknownCount INTEGER NOT NULL DEFAULT 0,
            fuzzyCount INTEGER NOT NULL DEFAULT 0,
            knownCount INTEGER NOT NULL DEFAULT 0,
            updatedAt INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sentence_notes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            bookId INTEGER NOT NULL,
            bookTitle TEXT NOT NULL,
            chapterIndex INTEGER NOT NULL,
            chapterTitle TEXT NOT NULL DEFAULT '',
            unitIndex INTEGER NOT NULL,
            sentenceText TEXT NOT NULL,
            sentenceTranslation TEXT NOT NULL DEFAULT '',
            aiAnalysis TEXT NOT NULL DEFAULT '',
            noteText TEXT NOT NULL DEFAULT '',
            createdAt INTEGER NOT NULL,
            updatedAt INTEGER NOT NULL,
            UNIQUE(bookId, sentenceText)
        );
        """)

        let bookCols = tableColumns("books")
        if !bookCols.contains("overallProgress") {
            exec("ALTER TABLE books ADD COLUMN overallProgress REAL NOT NULL DEFAULT -1.0")
        }

        let vocabCols = tableColumns("vocab")
        if !vocabCols.contains("englishTranslation") {
            exec("ALTER TABLE vocab ADD COLUMN englishTranslation TEXT NOT NULL DEFAULT ''")
        }

        let noteCols = tableColumns("sentence_notes")
        if !noteCols.contains("chapterTitle") {
            exec("ALTER TABLE sentence_notes ADD COLUMN chapterTitle TEXT NOT NULL DEFAULT ''")
        }
        if !noteCols.contains("aiAnalysis") {
            exec("ALTER TABLE sentence_notes ADD COLUMN aiAnalysis TEXT NOT NULL DEFAULT ''")
        }
    }

    func reloadAll() {
        let f = fetchFolders()
        let b = fetchBooks()
        let v = fetchVocab()
        let n = fetchNotes()
        let rl = fetchReadingLogs()
        let vrl = fetchVocabReviewLogs()
        let dc = fetchDictionaryCount()
        let cdc = fetchChineseDictionaryCount()
        folders = f
        books = b
        vocabList = v
        notes = n
        readingLogs = rl
        vocabReviewLogs = vrl
        dictionaryCount = dc
        chineseDictionaryCount = cdc
    }

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - Folders & Books
    private func fetchFolders() -> [BookFolder] {
        dbLock.lock()
        defer { dbLock.unlock() }
        var list: [BookFolder] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, name, createdAt, updatedAt FROM book_folders ORDER BY updatedAt DESC, id DESC", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                list.append(BookFolder(
                    id: sqlite3_column_int64(stmt, 0),
                    name: String(cString: sqlite3_column_text(stmt, 1)),
                    createdAt: sqlite3_column_int64(stmt, 2),
                    updatedAt: sqlite3_column_int64(stmt, 3)
                ))
            }
        }
        sqlite3_finalize(stmt)
        return list
    }

    func createFolder(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ts = nowMs()
        dbLock.lock()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO book_folders (name, createdAt, updatedAt) VALUES (?1, ?2, ?3)", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, trimmed, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, ts)
            sqlite3_bind_int64(stmt, 3, ts)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        dbLock.unlock()
        folders = fetchFolders()
    }

    func renameFolder(id: Int64, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ts = nowMs()
        dbLock.lock()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE book_folders SET name = ?1, updatedAt = ?2 WHERE id = ?3", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, trimmed, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, ts)
            sqlite3_bind_int64(stmt, 3, id)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        dbLock.unlock()
        folders = fetchFolders()
    }

    func deleteFolder(id: Int64) {
        dbLock.lock()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE books SET folderId = NULL WHERE folderId = ?1", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        if sqlite3_prepare_v2(db, "DELETE FROM book_folders WHERE id = ?1", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        dbLock.unlock()
        reloadAll()
    }

    private func fetchBooks() -> [BookItem] {
        dbLock.lock()
        defer { dbLock.unlock() }
        var list: [BookItem] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id, title, bookmarkData, filePathHint, format, currentChapter, currentIndex, totalItems, overallProgress, readingSeconds, lastReadAt, folderId FROM books ORDER BY lastReadAt DESC, id DESC"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                var bookmark: Data?
                if let blob = sqlite3_column_blob(stmt, 2) {
                    let size = Int(sqlite3_column_bytes(stmt, 2))
                    if size > 0 { bookmark = Data(bytes: blob, count: size) }
                }
                let folderId: Int64? = sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 11)
                list.append(BookItem(
                    id: sqlite3_column_int64(stmt, 0),
                    title: String(cString: sqlite3_column_text(stmt, 1)),
                    bookmarkData: bookmark,
                    filePathHint: String(cString: sqlite3_column_text(stmt, 3)),
                    format: String(cString: sqlite3_column_text(stmt, 4)),
                    currentChapter: Int(sqlite3_column_int(stmt, 5)),
                    currentIndex: Int(sqlite3_column_int(stmt, 6)),
                    totalItems: Int(sqlite3_column_int(stmt, 7)),
                    overallProgress: Float(sqlite3_column_double(stmt, 8)),
                    readingSeconds: sqlite3_column_int64(stmt, 9),
                    lastReadAt: sqlite3_column_int64(stmt, 10),
                    folderId: folderId
                ))
            }
        }
        sqlite3_finalize(stmt)
        return list
    }

    func findBookByHint(_ filePathHint: String) -> BookItem? {
        books.first(where: { $0.filePathHint == filePathHint })
    }

    @discardableResult
    func addBook(
        title: String,
        bookmarkData: Data?,
        filePathHint: String,
        format: String,
        folderId: Int64? = nil,
        lastReadAt: Int64? = nil
    ) -> BookItem? {
        let ts = lastReadAt ?? nowMs()
        dbLock.lock()
        var stmt: OpaquePointer?
        let sql = "INSERT OR IGNORE INTO books (title, bookmarkData, filePathHint, format, overallProgress, lastReadAt, folderId) VALUES (?1, ?2, ?3, ?4, -1.0, ?5, ?6)"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, title, -1, SQLITE_TRANSIENT)
            if let data = bookmarkData {
                _ = data.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_text(stmt, 3, filePathHint, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, format.uppercased(), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 5, ts)
            if let fid = folderId { sqlite3_bind_int64(stmt, 6, fid) } else { sqlite3_bind_null(stmt, 6) }
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        dbLock.unlock()
        books = fetchBooks()
        return books.first(where: { $0.filePathHint == filePathHint })
    }

    func moveBook(_ bookId: Int64, toFolder folderId: Int64?) {
        dbLock.lock()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE books SET folderId = ?1 WHERE id = ?2", -1, &stmt, nil) == SQLITE_OK {
            if let fid = folderId { sqlite3_bind_int64(stmt, 1, fid) } else { sqlite3_bind_null(stmt, 1) }
            sqlite3_bind_int64(stmt, 2, bookId)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        dbLock.unlock()
        books = fetchBooks()
    }

    func moveBooks(_ bookIds: [Int64], toFolder folderId: Int64?) {
        guard !bookIds.isEmpty else { return }
        dbLock.lock()
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE books SET folderId = ?1 WHERE id = ?2", -1, &stmt, nil) == SQLITE_OK {
            for id in bookIds {
                sqlite3_reset(stmt)
                if let fid = folderId { sqlite3_bind_int64(stmt, 1, fid) } else { sqlite3_bind_null(stmt, 1) }
                sqlite3_bind_int64(stmt, 2, id)
                sqlite3_step(stmt)
            }
        }
        sqlite3_finalize(stmt)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        dbLock.unlock()
        books = fetchBooks()
    }

    func deleteBook(id: Int64) {
        dbLock.lock()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM books WHERE id = ?1", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        dbLock.unlock()
        books = fetchBooks()
    }

    func updateOverallProgress(bookId: Int64, overallProgress: Float) {
        dbLock.lock()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE books SET overallProgress = ?1 WHERE id = ?2", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, Double(overallProgress))
            sqlite3_bind_int64(stmt, 2, bookId)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        dbLock.unlock()
        books = fetchBooks()
    }

    func updateBookProgress(
        bookId: Int64,
        bookTitle: String,
        chapter: Int,
        index: Int,
        total: Int,
        overallProgress: Float = -1.0,
        deltaSeconds: Int64,
        unitsDelta: Int
    ) {
        let ts = nowMs()
        let safeTotal = max(1, total)
        let safeDelta = max(0, deltaSeconds)
        dbLock.lock()
        var stmt: OpaquePointer?
        let sql = "UPDATE books SET currentChapter = ?1, currentIndex = ?2, totalItems = ?3, overallProgress = CASE WHEN ?4 >= 0 THEN ?4 ELSE overallProgress END, readingSeconds = readingSeconds + ?5, lastReadAt = ?6 WHERE id = ?7"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(chapter))
            sqlite3_bind_int(stmt, 2, Int32(index))
            sqlite3_bind_int(stmt, 3, Int32(safeTotal))
            sqlite3_bind_double(stmt, 4, Double(overallProgress))
            sqlite3_bind_int64(stmt, 5, safeDelta)
            sqlite3_bind_int64(stmt, 6, ts)
            sqlite3_bind_int64(stmt, 7, bookId)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        dbLock.unlock()

        if safeDelta > 0 || unitsDelta > 0 {
            recordReadingLog(bookId: bookId, bookTitle: bookTitle, deltaSeconds: safeDelta, unitsDelta: unitsDelta, lookupsDelta: 0)
        }
        books = fetchBooks()
    }

    // MARK: - Reading Logs & Vocab Review Logs
    private func todayParts() -> (String, Int, String, Int) {
        let now = Date()
        let cal = Calendar.current
        let y = cal.component(.year, from: now)
        let m = cal.component(.month, from: now)
        let d = cal.component(.day, from: now)
        let ym = String(format: "%04d-%02d", y, m)
        let dk = String(format: "%04d-%02d-%02d", y, m, d)
        return (dk, y, ym, d)
    }

    func recordReadingLog(bookId: Int64, bookTitle: String, deltaSeconds: Int64, unitsDelta: Int, lookupsDelta: Int) {
        let (dk, y, ym, d) = todayParts()
        let ts = nowMs()
        dbLock.lock()
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO reading_logs (dateKey, year, yearMonth, dayOfMonth, bookId, bookTitle, readingSeconds, unitsRead, lookupsCount, lastReadAt)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        ON CONFLICT(dateKey, bookId) DO UPDATE SET
            bookTitle = excluded.bookTitle,
            readingSeconds = readingSeconds + excluded.readingSeconds,
            unitsRead = unitsRead + excluded.unitsRead,
            lookupsCount = lookupsCount + excluded.lookupsCount,
            lastReadAt = excluded.lastReadAt
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, dk, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(y))
            sqlite3_bind_text(stmt, 3, ym, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 4, Int32(d))
            sqlite3_bind_int64(stmt, 5, bookId)
            sqlite3_bind_text(stmt, 6, bookTitle, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 7, deltaSeconds)
            sqlite3_bind_int(stmt, 8, Int32(unitsDelta))
            sqlite3_bind_int(stmt, 9, Int32(lookupsDelta))
            sqlite3_bind_int64(stmt, 10, ts)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        dbLock.unlock()
        readingLogs = fetchReadingLogs()
    }

    private func fetchReadingLogs() -> [ReadingLog] {
        dbLock.lock()
        defer { dbLock.unlock() }
        var list: [ReadingLog] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id, dateKey, year, yearMonth, dayOfMonth, bookId, bookTitle, readingSeconds, unitsRead, lookupsCount, lastReadAt FROM reading_logs ORDER BY dateKey DESC, lastReadAt DESC"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                list.append(ReadingLog(
                    id: sqlite3_column_int64(stmt, 0),
                    dateKey: String(cString: sqlite3_column_text(stmt, 1)),
                    year: Int(sqlite3_column_int(stmt, 2)),
                    yearMonth: String(cString: sqlite3_column_text(stmt, 3)),
                    dayOfMonth: Int(sqlite3_column_int(stmt, 4)),
                    bookId: sqlite3_column_int64(stmt, 5),
                    bookTitle: String(cString: sqlite3_column_text(stmt, 6)),
                    readingSeconds: sqlite3_column_int64(stmt, 7),
                    unitsRead: Int(sqlite3_column_int(stmt, 8)),
                    lookupsCount: Int(sqlite3_column_int(stmt, 9)),
                    lastReadAt: sqlite3_column_int64(stmt, 10)
                ))
            }
        }
        sqlite3_finalize(stmt)
        return list
    }

    private func fetchVocabReviewLogs() -> [VocabReviewLog] {
        dbLock.lock()
        defer { dbLock.unlock() }
        var list: [VocabReviewLog] = []
        var stmt: OpaquePointer?
        let sql = "SELECT dateKey, year, yearMonth, dayOfMonth, unknownCount, fuzzyCount, knownCount, updatedAt FROM vocab_review_logs ORDER BY dateKey DESC"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                list.append(VocabReviewLog(
                    dateKey: String(cString: sqlite3_column_text(stmt, 0)),
                    year: Int(sqlite3_column_int(stmt, 1)),
                    yearMonth: String(cString: sqlite3_column_text(stmt, 2)),
                    dayOfMonth: Int(sqlite3_column_int(stmt, 3)),
                    unknownCount: Int(sqlite3_column_int(stmt, 4)),
                    fuzzyCount: Int(sqlite3_column_int(stmt, 5)),
                    knownCount: Int(sqlite3_column_int(stmt, 6)),
                    updatedAt: sqlite3_column_int64(stmt, 7)
                ))
            }
        }
        sqlite3_finalize(stmt)
        return list
    }

    // MARK: - Dictionary & Vocab
    func fetchDictionaryCount() -> Int {
        dbLock.lock()
        defer { dbLock.unlock() }
        var stmt: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM dictionary", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return count
    }

    func fetchChineseDictionaryCount() -> Int {
        dbLock.lock()
        defer { dbLock.unlock() }
        var stmt: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM dictionary WHERE word >= '一' AND word <= '龥'", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return count
    }

    func fetchEnglishDictionaryCount() -> Int {
        dbLock.lock()
        defer { dbLock.unlock() }
        var stmt: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM dictionary WHERE NOT (word >= '一' AND word <= '龥')", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return count
    }

    func refreshDictionaryCounts() {
        let total = fetchDictionaryCount()
        let zh = fetchChineseDictionaryCount()
        DispatchQueue.main.async {
            self.dictionaryCount = total
            self.chineseDictionaryCount = zh
        }
    }

    func deleteEnglishDictionary() {
        exec("DELETE FROM dictionary WHERE NOT (word >= '一' AND word <= '龥')")
        seedEnglishIfEmpty()
        exec("VACUUM")
        refreshDictionaryCounts()
    }

    func deleteChineseDictionary() {
        exec("DELETE FROM dictionary WHERE word >= '一' AND word <= '龥'")
        seedChineseIfEmpty()
        exec("VACUUM")
        refreshDictionaryCounts()
    }

    func lookupDictionary(word: String) -> (lemma: String, phonetic: String, translation: String, found: Bool) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCjk = TextTokenizer.isPredominantlyChinese(trimmed)
        let candidates = isCjk ? [trimmed] : lemmatizeCandidates(trimmed)
        dbLock.lock()
        defer { dbLock.unlock() }
        for cand in candidates {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT phonetic, translation FROM dictionary WHERE word = ?1 LIMIT 1", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, cand, -1, SQLITE_TRANSIENT)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let p = String(cString: sqlite3_column_text(stmt, 0))
                    let t = String(cString: sqlite3_column_text(stmt, 1))
                    sqlite3_finalize(stmt)
                    return (cand, p, t, true)
                }
            }
            sqlite3_finalize(stmt)
        }
        let fallbackMsg = isCjk
            ? "（本地中文词典暂未收录，可在「设置」一键导入完整中文词典或使用上方 AI 解析）"
            : "（内置词库暂未收录，可在「设置」一键导入 ECDICT 完整词库或点击下方 AI 语境释义）"
        return (trimmed.lowercased(), isCjk ? "" : "/\(trimmed.lowercased())/", fallbackMsg, false)
    }

    func findExistingDictionaryWords(_ candidates: [String]) -> Set<String> {
        guard !candidates.isEmpty else { return [] }
        dbLock.lock()
        defer { dbLock.unlock() }
        var found = Set<String>()
        let chunkSize = 400
        var offset = 0
        while offset < candidates.count {
            let chunk = Array(candidates[offset..<min(offset + chunkSize, candidates.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = "SELECT word FROM dictionary WHERE word IN (\(placeholders))"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                for (idx, w) in chunk.enumerated() {
                    sqlite3_bind_text(stmt, Int32(idx + 1), w, -1, SQLITE_TRANSIENT)
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let cStr = sqlite3_column_text(stmt, 0) {
                        found.insert(String(cString: cStr))
                    }
                }
            }
            sqlite3_finalize(stmt)
            offset += chunkSize
        }
        return found
    }

    func bulkInsertDictionary(_ entries: [DictionaryEntry], refreshCounts: Bool = true) {
        guard !entries.isEmpty else { return }
        dbLock.lock()
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO dictionary (word, phonetic, translation) VALUES (?1, ?2, ?3)", -1, &stmt, nil) == SQLITE_OK {
            for e in entries {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, e.word, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, e.phonetic, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, e.translation, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
        }
        sqlite3_finalize(stmt)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        dbLock.unlock()
        if refreshCounts {
            refreshDictionaryCounts()
        }
    }

    func recordVocabLookup(
        word: String,
        lemma: String,
        phonetic: String,
        translation: String,
        englishTranslation: String = "",
        contextSentence: String,
        contextTranslation: String,
        bookId: Int64?,
        bookTitle: String
    ) -> VocabItem {
        let ts = nowMs()
        let isCjk = TextTokenizer.isPredominantlyChinese(word)
        let clean = isCjk ? word.trimmingCharacters(in: .whitespacesAndNewlines) : word.lowercased()
        let existing = vocabList.first(where: { $0.word == clean })
        let newCount = (existing?.lookupCount ?? 0) + 1

        dbLock.lock()
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO vocab (word, lemma, phonetic, translation, englishTranslation, lookupCount, contextSentence, contextTranslation, bookId, bookTitle, familiarity, createdAt, updatedAt)
        VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6, ?7, ?8, ?9, 0, ?10, ?11)
        ON CONFLICT(word) DO UPDATE SET
            lookupCount = lookupCount + 1,
            phonetic = CASE WHEN ?3 != '' THEN ?3 ELSE phonetic END,
            translation = CASE WHEN ?4 != '' THEN ?4 ELSE translation END,
            englishTranslation = CASE WHEN ?5 != '' THEN ?5 ELSE englishTranslation END,
            contextSentence = CASE WHEN ?6 != '' THEN ?6 ELSE contextSentence END,
            contextTranslation = CASE WHEN ?7 != '' THEN ?7 ELSE contextTranslation END,
            bookId = COALESCE(?8, bookId),
            bookTitle = CASE WHEN ?9 != '' THEN ?9 ELSE bookTitle END,
            updatedAt = ?11
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, clean, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, lemma, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, phonetic, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, translation, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, englishTranslation, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, contextSentence, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, contextTranslation, -1, SQLITE_TRANSIENT)
            if let bid = bookId { sqlite3_bind_int64(stmt, 8, bid) } else { sqlite3_bind_null(stmt, 8) }
            sqlite3_bind_text(stmt, 9, bookTitle, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 10, existing?.createdAt ?? ts)
            sqlite3_bind_int64(stmt, 11, ts)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        dbLock.unlock()

        if let bid = bookId {
            recordReadingLog(bookId: bid, bookTitle: bookTitle, deltaSeconds: 0, unitsDelta: 0, lookupsDelta: 1)
        }
        vocabList = fetchVocab()
        return vocabList.first(where: { $0.word == clean }) ?? VocabItem(
            id: existing?.id ?? 0,
            word: clean,
            lemma: lemma,
            phonetic: phonetic,
            translation: translation,
            englishTranslation: englishTranslation,
            lookupCount: newCount,
            contextSentence: contextSentence,
            contextTranslation: contextTranslation,
            bookId: bookId,
            bookTitle: bookTitle,
            familiarity: existing?.familiarity ?? 0,
            createdAt: existing?.createdAt ?? ts,
            updatedAt: ts
        )
    }

    func updateVocabEnglishTranslation(word: String, englishTranslation: String) {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !englishTranslation.isEmpty else { return }
        dbLock.lock()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE vocab SET englishTranslation = ?1 WHERE word = ?2", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, englishTranslation, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, clean, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        dbLock.unlock()
        vocabList = fetchVocab()
    }

    func updateVocabContextTranslation(word: String, contextSentence: String, contextTranslation: String) {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !contextTranslation.isEmpty else { return }
        dbLock.lock()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE vocab SET contextTranslation = ?1 WHERE word = ?2 AND contextSentence = ?3", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, contextTranslation, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, clean, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, contextSentence, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        dbLock.unlock()
        vocabList = fetchVocab()
    }

    private func fetchVocab() -> [VocabItem] {
        dbLock.lock()
        defer { dbLock.unlock() }
        var list: [VocabItem] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id, word, lemma, phonetic, translation, englishTranslation, lookupCount, contextSentence, contextTranslation, bookId, bookTitle, familiarity, createdAt, updatedAt FROM vocab ORDER BY lookupCount DESC, updatedAt DESC"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let bid: Int64? = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 9)
                list.append(VocabItem(
                    id: sqlite3_column_int64(stmt, 0),
                    word: String(cString: sqlite3_column_text(stmt, 1)),
                    lemma: String(cString: sqlite3_column_text(stmt, 2)),
                    phonetic: String(cString: sqlite3_column_text(stmt, 3)),
                    translation: String(cString: sqlite3_column_text(stmt, 4)),
                    englishTranslation: String(cString: sqlite3_column_text(stmt, 5)),
                    lookupCount: Int(sqlite3_column_int(stmt, 6)),
                    contextSentence: String(cString: sqlite3_column_text(stmt, 7)),
                    contextTranslation: String(cString: sqlite3_column_text(stmt, 8)),
                    bookId: bid,
                    bookTitle: String(cString: sqlite3_column_text(stmt, 10)),
                    familiarity: Int(sqlite3_column_int(stmt, 11)),
                    createdAt: sqlite3_column_int64(stmt, 12),
                    updatedAt: sqlite3_column_int64(stmt, 13)
                ))
            }
        }
        sqlite3_finalize(stmt)
        return list
    }

    func updateVocabFamiliarity(id: Int64, familiarity: Int) {
        let ts = nowMs()
        dbLock.lock()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE vocab SET familiarity = ?1, updatedAt = ?2 WHERE id = ?3", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(familiarity))
            sqlite3_bind_int64(stmt, 2, ts)
            sqlite3_bind_int64(stmt, 3, id)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

        let (dk, y, ym, d) = todayParts()
        let unk = familiarity == 0 ? 1 : 0
        let fuz = familiarity == 1 ? 1 : 0
        let knw = familiarity == 2 ? 1 : 0
        let logSql = """
        INSERT INTO vocab_review_logs (dateKey, year, yearMonth, dayOfMonth, unknownCount, fuzzyCount, knownCount, updatedAt)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        ON CONFLICT(dateKey) DO UPDATE SET
            unknownCount = unknownCount + excluded.unknownCount,
            fuzzyCount = fuzzyCount + excluded.fuzzyCount,
            knownCount = knownCount + excluded.knownCount,
            updatedAt = excluded.updatedAt
        """
        if sqlite3_prepare_v2(db, logSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, dk, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(y))
            sqlite3_bind_text(stmt, 3, ym, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 4, Int32(d))
            sqlite3_bind_int(stmt, 5, Int32(unk))
            sqlite3_bind_int(stmt, 6, Int32(fuz))
            sqlite3_bind_int(stmt, 7, Int32(knw))
            sqlite3_bind_int64(stmt, 8, ts)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        dbLock.unlock()
        vocabList = fetchVocab()
        vocabReviewLogs = fetchVocabReviewLogs()
    }

    func deleteVocab(id: Int64) {
        dbLock.lock()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM vocab WHERE id = ?1", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        dbLock.unlock()
        vocabList = fetchVocab()
    }

    func resetKnownVocab(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let ts = nowMs()
        dbLock.lock()
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE vocab SET familiarity = 1, updatedAt = ?1 WHERE id = ?2 AND familiarity = 2", -1, &stmt, nil) == SQLITE_OK {
            for id in ids {
                sqlite3_reset(stmt)
                sqlite3_bind_int64(stmt, 1, ts)
                sqlite3_bind_int64(stmt, 2, id)
                sqlite3_step(stmt)
            }
        }
        sqlite3_finalize(stmt)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        dbLock.unlock()
        vocabList = fetchVocab()
    }

    // MARK: - Sentence Notes
    func saveSentenceNote(
        bookId: Int64,
        bookTitle: String,
        chapterIndex: Int,
        chapterTitle: String = "",
        unitIndex: Int,
        sentenceText: String,
        sentenceTranslation: String,
        aiAnalysis: String = "",
        noteText: String
    ) {
        let ts = nowMs()
        dbLock.lock()
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO sentence_notes (bookId, bookTitle, chapterIndex, chapterTitle, unitIndex, sentenceText, sentenceTranslation, aiAnalysis, noteText, createdAt, updatedAt)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
        ON CONFLICT(bookId, sentenceText) DO UPDATE SET
            chapterTitle = CASE WHEN ?4 != '' THEN ?4 ELSE chapterTitle END,
            sentenceTranslation = CASE WHEN ?7 != '' THEN ?7 ELSE sentenceTranslation END,
            aiAnalysis = CASE WHEN ?8 != '' THEN ?8 ELSE aiAnalysis END,
            noteText = ?9,
            chapterIndex = ?3,
            unitIndex = ?5,
            updatedAt = ?11
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, bookId)
            sqlite3_bind_text(stmt, 2, bookTitle, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(chapterIndex))
            sqlite3_bind_text(stmt, 4, chapterTitle, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 5, Int32(unitIndex))
            sqlite3_bind_text(stmt, 6, sentenceText, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, sentenceTranslation, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 8, aiAnalysis, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 9, noteText, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 10, ts)
            sqlite3_bind_int64(stmt, 11, ts)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        dbLock.unlock()
        notes = fetchNotes()
    }

    func updateNoteText(id: Int64, noteText: String) {
        let ts = nowMs()
        dbLock.lock()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE sentence_notes SET noteText = ?1, updatedAt = ?2 WHERE id = ?3", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, noteText, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, ts)
            sqlite3_bind_int64(stmt, 3, id)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        dbLock.unlock()
        notes = fetchNotes()
    }

    func deleteNote(id: Int64) {
        dbLock.lock()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM sentence_notes WHERE id = ?1", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        dbLock.unlock()
        notes = fetchNotes()
    }

    private func fetchNotes() -> [SentenceNote] {
        dbLock.lock()
        defer { dbLock.unlock() }
        var list: [SentenceNote] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id, bookId, bookTitle, chapterIndex, chapterTitle, unitIndex, sentenceText, sentenceTranslation, aiAnalysis, noteText, createdAt, updatedAt FROM sentence_notes ORDER BY updatedAt DESC, id DESC"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                list.append(SentenceNote(
                    id: sqlite3_column_int64(stmt, 0),
                    bookId: sqlite3_column_int64(stmt, 1),
                    bookTitle: String(cString: sqlite3_column_text(stmt, 2)),
                    chapterIndex: Int(sqlite3_column_int(stmt, 3)),
                    chapterTitle: String(cString: sqlite3_column_text(stmt, 4)),
                    unitIndex: Int(sqlite3_column_int(stmt, 5)),
                    sentenceText: String(cString: sqlite3_column_text(stmt, 6)),
                    sentenceTranslation: String(cString: sqlite3_column_text(stmt, 7)),
                    aiAnalysis: String(cString: sqlite3_column_text(stmt, 8)),
                    noteText: String(cString: sqlite3_column_text(stmt, 9)),
                    createdAt: sqlite3_column_int64(stmt, 10),
                    updatedAt: sqlite3_column_int64(stmt, 11)
                ))
            }
        }
        sqlite3_finalize(stmt)
        return list
    }

    // MARK: - Translation Cache
    func getCachedTranslation(_ source: String) -> String? {
        dbLock.lock()
        defer { dbLock.unlock() }
        var stmt: OpaquePointer?
        var res: String?
        if sqlite3_prepare_v2(db, "SELECT translatedText FROM translation_cache WHERE sourceText = ?1 LIMIT 1", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, source.trimmingCharacters(in: .whitespacesAndNewlines), -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                res = String(cString: sqlite3_column_text(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return res
    }

    func saveCachedTranslation(source: String, translated: String) {
        dbLock.lock()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO translation_cache (sourceText, translatedText) VALUES (?1, ?2)", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, source.trimmingCharacters(in: .whitespacesAndNewlines), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, translated, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        dbLock.unlock()
    }

    func translationCacheCount() -> Int {
        dbLock.lock()
        defer { dbLock.unlock() }
        var stmt: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM translation_cache", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return count
    }

    func clearTranslationCache() {
        exec("DELETE FROM translation_cache")
    }

    // MARK: - Lemmatization & Seeds
    func lemmatizeCandidates(_ raw: String) -> [String] {
        let w = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let irregulars: [String: String] = [
            "went": "go", "gone": "go", "goes": "go", "going": "go",
            "was": "be", "were": "be", "been": "be", "am": "be", "is": "be", "are": "be",
            "had": "have", "has": "have", "having": "have",
            "did": "do", "done": "do", "does": "do",
            "said": "say", "made": "make", "took": "take", "taken": "take",
            "came": "come", "saw": "see", "seen": "see", "knew": "know", "known": "know",
            "got": "get", "gotten": "get", "gave": "give", "given": "give",
            "found": "find", "thought": "think", "told": "tell",
            "became": "become", "left": "leave", "felt": "feel",
            "wrote": "write", "written": "write", "stood": "stand",
            "children": "child", "men": "man", "women": "woman",
            "better": "good", "best": "good", "worse": "bad", "worst": "bad"
        ]
        var result = [w]
        if let base = irregulars[w] { result.append(base) }
        if w.hasSuffix("ies"), w.count > 4 { result.append(String(w.dropLast(3)) + "y") }
        if w.hasSuffix("es"), w.count > 3 {
            result.append(String(w.dropLast(2)))
            result.append(String(w.dropLast(1)))
        }
        if w.hasSuffix("s"), w.count > 2 { result.append(String(w.dropLast(1))) }
        if w.hasSuffix("ied"), w.count > 4 { result.append(String(w.dropLast(3)) + "y") }
        if w.hasSuffix("ed"), w.count > 3 {
            let stem = String(w.dropLast(2))
            result.append(stem)
            result.append(stem + "e")
            if stem.count >= 2, stem.last == stem[stem.index(stem.endIndex, offsetBy: -2)] {
                result.append(String(stem.dropLast()))
            }
        }
        if w.hasSuffix("ing"), w.count > 4 {
            let stem = String(w.dropLast(3))
            result.append(stem)
            result.append(stem + "e")
            if stem.count >= 2, stem.last == stem[stem.index(stem.endIndex, offsetBy: -2)] {
                result.append(String(stem.dropLast()))
            }
        }
        if w.hasSuffix("ly"), w.count > 4 {
            let stem = String(w.dropLast(2))
            result.append(stem)
            if stem.hasSuffix("i") { result.append(String(stem.dropLast()) + "y") }
        }
        var unique: [String] = []
        for item in result where !unique.contains(item) { unique.append(item) }
        return unique
    }

    private func seedDictionaryIfEmpty() {
        seedEnglishIfEmpty()
        seedChineseIfEmpty()
    }

    func seedEnglishIfEmpty() {
        guard fetchEnglishDictionaryCount() == 0 else { return }
        let seed: [DictionaryEntry] = [
            DictionaryEntry(word: "abandon", phonetic: "/əˈbændən/", translation: "v. 放弃，遗弃；n. 放任"),
            DictionaryEntry(word: "ability", phonetic: "/əˈbɪləti/", translation: "n. 能力，才能"),
            DictionaryEntry(word: "absorb", phonetic: "/əbˈzɔːrb/", translation: "v. 吸收；使全神贯注"),
            DictionaryEntry(word: "abstract", phonetic: "/ˈæbstrækt/", translation: "adj. 抽象的；n. 摘要"),
            DictionaryEntry(word: "abundant", phonetic: "/əˈbʌndənt/", translation: "adj. 丰富的，充裕的"),
            DictionaryEntry(word: "achieve", phonetic: "/əˈtʃiːv/", translation: "v. 达到，完成，取得"),
            DictionaryEntry(word: "acquire", phonetic: "/əˈkwaɪər/", translation: "v. 获得，学到"),
            DictionaryEntry(word: "adapt", phonetic: "/əˈdæpt/", translation: "v. 适应，改编"),
            DictionaryEntry(word: "ambiguous", phonetic: "/æmˈbɪɡjuəs/", translation: "adj. 模棱两可的，含糊不清的"),
            DictionaryEntry(word: "anchor", phonetic: "/ˈæŋkər/", translation: "n. 锚；v. 扎根，固定"),
            DictionaryEntry(word: "anticipate", phonetic: "/ænˈtɪsɪpeɪt/", translation: "v. 预期，期盼"),
            DictionaryEntry(word: "appreciate", phonetic: "/əˈpriːʃieɪt/", translation: "v. 欣赏，感激，领会"),
            DictionaryEntry(word: "approach", phonetic: "/əˈproʊtʃ/", translation: "v. 靠近；n. 方法，途径"),
            DictionaryEntry(word: "argument", phonetic: "/ˈɑːrɡjumənt/", translation: "n. 争论，论点"),
            DictionaryEntry(word: "attention", phonetic: "/əˈtenʃn/", translation: "n. 注意，关注"),
            DictionaryEntry(word: "capture", phonetic: "/ˈkæptʃər/", translation: "v./n. 捕获，记录"),
            DictionaryEntry(word: "coherent", phonetic: "/koʊˈhɪrənt/", translation: "adj. 连贯的，条理清楚的"),
            DictionaryEntry(word: "complex", phonetic: "/ˈkɑːmpleks/", translation: "adj. 复杂的；n. 综合体"),
            DictionaryEntry(word: "concentrate", phonetic: "/ˈkɑːnsntreɪt/", translation: "v. 集中，全神贯注"),
            DictionaryEntry(word: "concept", phonetic: "/ˈkɑːnsept/", translation: "n. 概念，观念"),
            DictionaryEntry(word: "context", phonetic: "/ˈkɑːntekst/", translation: "n. 上下文，语境，背景"),
            DictionaryEntry(word: "crucial", phonetic: "/ˈkruːʃl/", translation: "adj. 至关重要的，决定性的"),
            DictionaryEntry(word: "discover", phonetic: "/dɪˈskʌvər/", translation: "v. 发现，发觉"),
            DictionaryEntry(word: "discovery", phonetic: "/dɪˈskʌvəri/", translation: "n. 发现，被发现的事物"),
            DictionaryEntry(word: "distraction", phonetic: "/dɪˈstrækʃn/", translation: "n. 分心，干扰，消遣"),
            DictionaryEntry(word: "effortless", phonetic: "/ˈefərtləs/", translation: "adj. 毫不费力的，轻松的"),
            DictionaryEntry(word: "eloquent", phonetic: "/ˈeləkwənt/", translation: "adj. 雄辩的，有说服力的"),
            DictionaryEntry(word: "emotion", phonetic: "/ɪˈmoʊʃn/", translation: "n. 情感，情绪"),
            DictionaryEntry(word: "encounter", phonetic: "/ɪnˈkaʊntər/", translation: "v./n. 遭遇，邂逅"),
            DictionaryEntry(word: "ephemeral", phonetic: "/ɪˈfemərəl/", translation: "adj. 短暂的，转瞬即逝的"),
            DictionaryEntry(word: "era", phonetic: "/ˈɪrə/", translation: "n. 时代，纪元"),
            DictionaryEntry(word: "examine", phonetic: "/ɪɡˈzæmɪn/", translation: "v. 检查，审视，考核"),
            DictionaryEntry(word: "expand", phonetic: "/ɪkˈspænd/", translation: "v. 扩大，扩展"),
            DictionaryEntry(word: "expression", phonetic: "/ɪkˈspreʃn/", translation: "n. 表达，措辞，表情"),
            DictionaryEntry(word: "fail", phonetic: "/feɪl/", translation: "v. 失败，未能"),
            DictionaryEntry(word: "gentle", phonetic: "/ˈdʒentl/", translation: "adj. 温和的，轻柔的"),
            DictionaryEntry(word: "glimpse", phonetic: "/ɡlɪmps/", translation: "n./v. 一瞥，短暂感受"),
            DictionaryEntry(word: "habit", phonetic: "/ˈhæbɪt/", translation: "n. 习惯，习性"),
            DictionaryEntry(word: "impression", phonetic: "/ɪmˈpreʃn/", translation: "n. 印象，感想"),
            DictionaryEntry(word: "isolation", phonetic: "/ˌaɪsəˈleɪʃn/", translation: "n. 孤立，隔离"),
            DictionaryEntry(word: "journey", phonetic: "/ˈdʒɜːrni/", translation: "n./v. 旅行，历程"),
            DictionaryEntry(word: "landscape", phonetic: "/ˈlændskeɪp/", translation: "n. 风景，格局"),
            DictionaryEntry(word: "language", phonetic: "/ˈlæŋɡwɪdʒ/", translation: "n. 语言"),
            DictionaryEntry(word: "lasting", phonetic: "/ˈlæstɪŋ/", translation: "adj. 持久的，永恒的"),
            DictionaryEntry(word: "literature", phonetic: "/ˈlɪtrətʃər/", translation: "n. 文学，文献"),
            DictionaryEntry(word: "lucid", phonetic: "/ˈluːsɪd/", translation: "adj. 清晰易懂的，神志清醒的"),
            DictionaryEntry(word: "memory", phonetic: "/ˈmeməri/", translation: "n. 记忆，回忆"),
            DictionaryEntry(word: "merely", phonetic: "/ˈmɪrli/", translation: "adv. 仅仅，只不过"),
            DictionaryEntry(word: "moment", phonetic: "/ˈmoʊmənt/", translation: "n. 片刻，瞬间"),
            DictionaryEntry(word: "natural", phonetic: "/ˈnætʃrəl/", translation: "adj. 自然的，天生的"),
            DictionaryEntry(word: "nuance", phonetic: "/ˈnuːɑːns/", translation: "n. 细微差别，微妙之处"),
            DictionaryEntry(word: "opportunity", phonetic: "/ˌɑːpərˈtuːnəti/", translation: "n. 机会，时机"),
            DictionaryEntry(word: "overwhelm", phonetic: "/ˌoʊvərˈwelm/", translation: "v. 淹没，使不知所措"),
            DictionaryEntry(word: "perspective", phonetic: "/pərˈspektɪv/", translation: "n. 视角，观点"),
            DictionaryEntry(word: "philosophical", phonetic: "/ˌfɪləˈsɑːfɪkl/", translation: "adj. 哲学的，达观的"),
            DictionaryEntry(word: "precious", phonetic: "/ˈpreʃəs/", translation: "adj. 珍贵的，宝贵的"),
            DictionaryEntry(word: "profound", phonetic: "/prəˈfaʊnd/", translation: "adj. 深远的，深刻的"),
            DictionaryEntry(word: "progressive", phonetic: "/prəˈɡresɪv/", translation: "adj. 渐进的，进步的"),
            DictionaryEntry(word: "rare", phonetic: "/rer/", translation: "adj. 罕见的，珍贵的"),
            DictionaryEntry(word: "remain", phonetic: "/rɪˈmeɪn/", translation: "v. 保持，留下"),
            DictionaryEntry(word: "resonance", phonetic: "/ˈrezənəns/", translation: "n. 共鸣，回响"),
            DictionaryEntry(word: "reveal", phonetic: "/rɪˈviːl/", translation: "v. 揭示，透露，展现"),
            DictionaryEntry(word: "rhythm", phonetic: "/ˈrɪðəm/", translation: "n. 节奏，韵律"),
            DictionaryEntry(word: "sentence", phonetic: "/ˈsentəns/", translation: "n. 句子，判决"),
            DictionaryEntry(word: "skill", phonetic: "/skɪl/", translation: "n. 技能，技巧"),
            DictionaryEntry(word: "skim", phonetic: "/skɪm/", translation: "v. 浏览，掠过"),
            DictionaryEntry(word: "strip", phonetic: "/strɪp/", translation: "v. 剥去，脱去"),
            DictionaryEntry(word: "subtle", phonetic: "/ˈsʌtl/", translation: "adj. 微妙的，敏锐的"),
            DictionaryEntry(word: "surface", phonetic: "/ˈsɜːrfɪs/", translation: "n. 表面；v. 浮出水面"),
            DictionaryEntry(word: "thrive", phonetic: "/θraɪv/", translation: "v. 茁壮成长，繁荣"),
            DictionaryEntry(word: "traditional", phonetic: "/trəˈdɪʃənl/", translation: "adj. 传统的，惯例的"),
            DictionaryEntry(word: "transform", phonetic: "/trænsˈfɔːrm/", translation: "v. 改变，使改观"),
            DictionaryEntry(word: "ubiquitous", phonetic: "/juːˈbɪkwɪtəs/", translation: "adj. 无处不在的，普遍存在的"),
            DictionaryEntry(word: "unfamiliar", phonetic: "/ˌʌnfəˈmɪliər/", translation: "adj. 不熟悉的，陌生的"),
            DictionaryEntry(word: "vanish", phonetic: "/ˈvænɪʃ/", translation: "v. 消失，突然不见"),
            DictionaryEntry(word: "vivid", phonetic: "/ˈvɪvɪd/", translation: "adj. 生动的，鲜明的"),
            DictionaryEntry(word: "vocabulary", phonetic: "/voʊˈkæbjəleri/", translation: "n. 词汇，词汇量")
        ]
        bulkInsertDictionary(seed, refreshCounts: false)
    }

    func seedChineseIfEmpty() {
        guard fetchChineseDictionaryCount() == 0 else { return }
        let seed: [DictionaryEntry] = [
            DictionaryEntry(word: "阅读", phonetic: "yuè dú", translation: "看（书报等）并领会其内容。"),
            DictionaryEntry(word: "精读", phonetic: "jīng dú", translation: "仔细、深入地阅读，逐字逐句推敲文义与结构。"),
            DictionaryEntry(word: "踌躇", phonetic: "chóu chú", translation: "1. 犹豫不决；2. 停留，徘徊；3. 得意的样子。"),
            DictionaryEntry(word: "徘徊", phonetic: "pái huái", translation: "1. 在一个地方来回地走；2. 比喻犹豫不决；3. 比喻事物在某个范围内浮动。"),
            DictionaryEntry(word: "弥漫", phonetic: "mí màn", translation: "（烟尘、雾气、水等）充满；布满。"),
            DictionaryEntry(word: "落寞", phonetic: "luò mò", translation: "寂寞；冷落凄凉。"),
            DictionaryEntry(word: "羁绊", phonetic: "jī bàn", translation: "缠住不能脱身；束缚。"),
            DictionaryEntry(word: "凛冽", phonetic: "lǐn liè", translation: "刺骨地寒冷。"),
            DictionaryEntry(word: "静谧", phonetic: "jìng mì", translation: "安静；宁静。"),
            DictionaryEntry(word: "琐碎", phonetic: "suǒ suì", translation: "细小而繁多。"),
            DictionaryEntry(word: "沧桑", phonetic: "cāng sāng", translation: "沧海桑田的略语，比喻世事变化很大。"),
            DictionaryEntry(word: "恍惚", phonetic: "huǎng hū", translation: "1. 神志不清，精神不集中；2. （记得、听得、看得）不真切，不清楚。"),
            DictionaryEntry(word: "惬意", phonetic: "qiè yì", translation: "满意；称心；舒服。"),
            DictionaryEntry(word: "沉吟", phonetic: "chén yín", translation: "1. 遇到复杂或疑难的事，迟疑不决，低声自语；2. 低声吟咏。"),
            DictionaryEntry(word: "憧憬", phonetic: "chōng jǐng", translation: "向往；对美好未来的期待与想象。"),
            DictionaryEntry(word: "缄默", phonetic: "jiān mò", translation: "闭口不说话。"),
            DictionaryEntry(word: "执拗", phonetic: "zhí niù", translation: "固执任性，不听人劝。"),
            DictionaryEntry(word: "倏忽", phonetic: "shū hū", translation: "很快地；忽然；转眼间。"),
            DictionaryEntry(word: "寥落", phonetic: "liáo luò", translation: "稀少；冷落；荒凉。"),
            DictionaryEntry(word: "端倪", phonetic: "duān ní", translation: "事情的眉目；头绪；边际。"),
            DictionaryEntry(word: "斟酌", phonetic: "zhēn zhuó", translation: "考虑事情、文字等是否可行或是否恰当。"),
            DictionaryEntry(word: "隽永", phonetic: "juàn yǒng", translation: "（言辞、诗文等）意味深长，耐人寻味。"),
            DictionaryEntry(word: "豁然开朗", phonetic: "huò rán kāi lǎng", translation: "形容由狭窄幽暗突然变得宽阔敞亮；也比喻一下子明白了某种道理，心情顿感舒畅。"),
            DictionaryEntry(word: "潜移默化", phonetic: "qián yí mò huà", translation: "指人的思想或性格不知不觉受到感染、影响而发生了变化。"),
            DictionaryEntry(word: "一蹴而就", phonetic: "yī cù ér jiù", translation: "踏一步就成功，比喻事情轻而易举，一下子就能完成（多用于否定）。"),
            DictionaryEntry(word: "相得益彰", phonetic: "xiāng dé yì zhāng", translation: "指两个人或两件事物互相配合，双方的能力和作用更能显示出来。"),
            DictionaryEntry(word: "微不足道", phonetic: "wēi bù zú dào", translation: "微小得很，不值得一提。"),
            DictionaryEntry(word: "循序渐进", phonetic: "xún xù jiàn jìn", translation: "指学习、工作等按照一定的步骤逐渐深入或提高。"),
            DictionaryEntry(word: "风起云涌", phonetic: "fēng qǐ yún yǒng", translation: "大风刮起，乌云涌现。比喻新事物相继兴起，声势很盛。"),
            DictionaryEntry(word: "水落石出", phonetic: "shuǐ luò shí chū", translation: "水落下去，水底的石头就露出来。比喻事情的真相完全显露出来。"),
            DictionaryEntry(word: "专心致志", phonetic: "zhuān xīn zhì zhì", translation: "把心思全放在上面。形容一心一意，聚精会神。"),
            DictionaryEntry(word: "不言而喻", phonetic: "bù yán ér yù", translation: "不用说话就能明白。形容道理很明显。"),
            DictionaryEntry(word: "迥然不同", phonetic: "jiǒng rán bù tóng", translation: "形容相差得远，很明显不一样。"),
            DictionaryEntry(word: "游刃有余", phonetic: "yóu rèn yǒu yú", translation: "刀刃运转于骨节空隙中，有回旋的余地。比喻工作熟练，有实际经验，解决问题毫不费力。"),
            DictionaryEntry(word: "娓娓道来", phonetic: "wěi wěi dào lái", translation: "连续不断地说、生动地谈论。形容谈论不倦或说话动听。"),
            DictionaryEntry(word: "字斟句酌", phonetic: "zì zhēn jù zhuó", translation: "写文章或说话时慎重细致，一字一句地推敲琢磨。"),
            DictionaryEntry(word: "语境", phonetic: "yǔ jìng", translation: "使用语言的环境，包括上下文语境和情景语境。"),
            DictionaryEntry(word: "意蕴", phonetic: "yì yùn", translation: "事物里面所包含的意义、情趣或道理。"),
            DictionaryEntry(word: "脉络", phonetic: "mài luò", translation: "1. 中医指人体内的血管与经络；2. 比喻事物的条理或头绪。"),
            DictionaryEntry(word: "底蕴", phonetic: "dǐ yùn", translation: "事情的详细内容或内在涵养。"),
            DictionaryEntry(word: "图书馆", phonetic: "tú shū guǎn", translation: "搜集、整理、收藏图书资料以供人阅览、参考的机构。"),
            DictionaryEntry(word: "文学", phonetic: "wén xué", translation: "以语言文字为工具，形象化地反映客观现实、表现作家心灵世界的艺术。")
        ]
        bulkInsertDictionary(seed, refreshCounts: false)
    }

    private func seedSampleBookIfEmpty() {
        if fetchBooks().isEmpty {
            addBook(
                title: "The Art of Slow Reading (示例英文读物)",
                bookmarkData: nil,
                filePathHint: "sample://art_of_slow_reading",
                format: "TXT"
            )
        }
    }
}
