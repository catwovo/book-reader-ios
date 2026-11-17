import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@Observable
final class DatabaseManager {
    private var db: OpaquePointer?

    var folders: [BookFolder] = []
    var books: [BookItem] = []
    var vocabList: [VocabItem] = []
    var notes: [SentenceNote] = []
    var readingLogs: [ReadingLog] = []
    var vocabReviewLogs: [VocabReviewLog] = []
    var dictionaryCount: Int = 0

    init() {
        openDatabase()
        createTables()
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
        sqlite3_open(dbUrl.path, &db)
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func createTables() {
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
            unitIndex INTEGER NOT NULL,
            sentenceText TEXT NOT NULL,
            sentenceTranslation TEXT NOT NULL DEFAULT '',
            noteText TEXT NOT NULL DEFAULT '',
            createdAt INTEGER NOT NULL,
            updatedAt INTEGER NOT NULL,
            UNIQUE(bookId, sentenceText)
        );
        """)
    }

    func reloadAll() {
        folders = fetchFolders()
        books = fetchBooks()
        vocabList = fetchVocab()
        notes = fetchNotes()
        readingLogs = fetchReadingLogs()
        vocabReviewLogs = fetchVocabReviewLogs()
        dictionaryCount = fetchDictionaryCount()
    }

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - Folders & Books
    private func fetchFolders() -> [BookFolder] {
        var list: [BookFolder] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, name, createdAt, updatedAt FROM book_folders ORDER BY updatedAt DESC", -1, &stmt, nil) == SQLITE_OK {
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
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO book_folders (name, createdAt, updatedAt) VALUES (?1, ?2, ?3)", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, trimmed, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, ts)
            sqlite3_bind_int64(stmt, 3, ts)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        folders = fetchFolders()
    }

    func deleteFolder(id: Int64) {
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
        reloadAll()
    }

    private func fetchBooks() -> [BookItem] {
        var list: [BookItem] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id, title, bookmarkData, filePathHint, format, currentChapter, currentIndex, totalItems, readingSeconds, lastReadAt, folderId FROM books ORDER BY lastReadAt DESC, id DESC"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                var bookmark: Data?
                if let blob = sqlite3_column_blob(stmt, 2) {
                    let size = Int(sqlite3_column_bytes(stmt, 2))
                    if size > 0 { bookmark = Data(bytes: blob, count: size) }
                }
                let folderId: Int64? = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 10)
                list.append(BookItem(
                    id: sqlite3_column_int64(stmt, 0),
                    title: String(cString: sqlite3_column_text(stmt, 1)),
                    bookmarkData: bookmark,
                    filePathHint: String(cString: sqlite3_column_text(stmt, 3)),
                    format: String(cString: sqlite3_column_text(stmt, 4)),
                    currentChapter: Int(sqlite3_column_int(stmt, 5)),
                    currentIndex: Int(sqlite3_column_int(stmt, 6)),
                    totalItems: Int(sqlite3_column_int(stmt, 7)),
                    readingSeconds: sqlite3_column_int64(stmt, 8),
                    lastReadAt: sqlite3_column_int64(stmt, 9),
                    folderId: folderId
                ))
            }
        }
        sqlite3_finalize(stmt)
        return list
    }

    func addBook(title: String, bookmarkData: Data?, filePathHint: String, format: String, folderId: Int64? = nil) {
        let ts = nowMs()
        var stmt: OpaquePointer?
        let sql = "INSERT OR IGNORE INTO books (title, bookmarkData, filePathHint, format, lastReadAt, folderId) VALUES (?1, ?2, ?3, ?4, ?5, ?6)"
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
        books = fetchBooks()
    }

    func moveBook(_ bookId: Int64, toFolder folderId: Int64?) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE books SET folderId = ?1 WHERE id = ?2", -1, &stmt, nil) == SQLITE_OK {
            if let fid = folderId { sqlite3_bind_int64(stmt, 1, fid) } else { sqlite3_bind_null(stmt, 1) }
            sqlite3_bind_int64(stmt, 2, bookId)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        books = fetchBooks()
    }

    func deleteBook(id: Int64) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM books WHERE id = ?1", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        books = fetchBooks()
    }

    func updateBookProgress(bookId: Int64, bookTitle: String, chapter: Int, index: Int, total: Int, deltaSeconds: Int64, unitsDelta: Int) {
        let ts = nowMs()
        let safeTotal = max(1, total)
        let safeDelta = max(0, deltaSeconds)
        var stmt: OpaquePointer?
        let sql = "UPDATE books SET currentChapter = ?1, currentIndex = ?2, totalItems = ?3, readingSeconds = readingSeconds + ?4, lastReadAt = ?5 WHERE id = ?6"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(chapter))
            sqlite3_bind_int(stmt, 2, Int32(index))
            sqlite3_bind_int(stmt, 3, Int32(safeTotal))
            sqlite3_bind_int64(stmt, 4, safeDelta)
            sqlite3_bind_int64(stmt, 5, ts)
            sqlite3_bind_int64(stmt, 6, bookId)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

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
        readingLogs = fetchReadingLogs()
    }

    private func fetchReadingLogs() -> [ReadingLog] {
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
    private func fetchDictionaryCount() -> Int {
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

    func lookupDictionary(word: String) -> (lemma: String, phonetic: String, translation: String, found: Bool) {
        let candidates = lemmatizeCandidates(word)
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
        return (word.lowercased(), "/\(word.lowercased())/", "（内置词库暂未收录，可在「设置」一键导入 ECDICT 完整词库或点击下方 AI 语境释义）", false)
    }

    func bulkInsertDictionary(_ entries: [DictionaryEntry]) {
        exec("BEGIN TRANSACTION")
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
        exec("COMMIT")
        dictionaryCount = fetchDictionaryCount()
    }

    func recordVocabLookup(
        word: String,
        lemma: String,
        phonetic: String,
        translation: String,
        contextSentence: String,
        contextTranslation: String,
        bookId: Int64?,
        bookTitle: String
    ) -> VocabItem {
        let ts = nowMs()
        let clean = word.lowercased()
        let existing = vocabList.first(where: { $0.word == clean })
        let newCount = (existing?.lookupCount ?? 0) + 1

        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO vocab (word, lemma, phonetic, translation, lookupCount, contextSentence, contextTranslation, bookId, bookTitle, familiarity, createdAt, updatedAt)
        VALUES (?1, ?2, ?3, ?4, 1, ?5, ?6, ?7, ?8, 0, ?9, ?10)
        ON CONFLICT(word) DO UPDATE SET
            lookupCount = lookupCount + 1,
            contextSentence = CASE WHEN ?5 != '' THEN ?5 ELSE contextSentence END,
            contextTranslation = CASE WHEN ?6 != '' THEN ?6 ELSE contextTranslation END,
            bookId = COALESCE(?7, bookId),
            bookTitle = CASE WHEN ?8 != '' THEN ?8 ELSE bookTitle END,
            updatedAt = ?10
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, clean, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, lemma, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, phonetic, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, translation, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, contextSentence, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, contextTranslation, -1, SQLITE_TRANSIENT)
            if let bid = bookId { sqlite3_bind_int64(stmt, 7, bid) } else { sqlite3_bind_null(stmt, 7) }
            sqlite3_bind_text(stmt, 8, bookTitle, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 9, existing?.createdAt ?? ts)
            sqlite3_bind_int64(stmt, 10, ts)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

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
            englishTranslation: "",
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

    private func fetchVocab() -> [VocabItem] {
        var list: [VocabItem] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id, word, lemma, phonetic, translation, lookupCount, contextSentence, contextTranslation, bookId, bookTitle, familiarity, createdAt, updatedAt FROM vocab ORDER BY lookupCount DESC, updatedAt DESC"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let bid: Int64? = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 8)
                list.append(VocabItem(
                    id: sqlite3_column_int64(stmt, 0),
                    word: String(cString: sqlite3_column_text(stmt, 1)),
                    lemma: String(cString: sqlite3_column_text(stmt, 2)),
                    phonetic: String(cString: sqlite3_column_text(stmt, 3)),
                    translation: String(cString: sqlite3_column_text(stmt, 4)),
                    englishTranslation: "",
                    lookupCount: Int(sqlite3_column_int(stmt, 5)),
                    contextSentence: String(cString: sqlite3_column_text(stmt, 6)),
                    contextTranslation: String(cString: sqlite3_column_text(stmt, 7)),
                    bookId: bid,
                    bookTitle: String(cString: sqlite3_column_text(stmt, 9)),
                    familiarity: Int(sqlite3_column_int(stmt, 10)),
                    createdAt: sqlite3_column_int64(stmt, 11),
                    updatedAt: sqlite3_column_int64(stmt, 12)
                ))
            }
        }
        sqlite3_finalize(stmt)
        return list
    }

    func updateVocabFamiliarity(id: Int64, familiarity: Int) {
        let ts = nowMs()
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
        vocabList = fetchVocab()
        vocabReviewLogs = fetchVocabReviewLogs()
    }

    func deleteVocab(id: Int64) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM vocab WHERE id = ?1", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        vocabList = fetchVocab()
    }

    func resetKnownVocab(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let ts = nowMs()
        exec("BEGIN TRANSACTION")
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE vocab SET familiarity = 0, updatedAt = ?1 WHERE id = ?2", -1, &stmt, nil) == SQLITE_OK {
            for id in ids {
                sqlite3_reset(stmt)
                sqlite3_bind_int64(stmt, 1, ts)
                sqlite3_bind_int64(stmt, 2, id)
                sqlite3_step(stmt)
            }
        }
        sqlite3_finalize(stmt)
        exec("COMMIT")
        vocabList = fetchVocab()
    }

    // MARK: - Sentence Notes
    func saveSentenceNote(
        bookId: Int64,
        bookTitle: String,
        chapterIndex: Int,
        unitIndex: Int,
        sentenceText: String,
        sentenceTranslation: String,
        noteText: String
    ) {
        let ts = nowMs()
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO sentence_notes (bookId, bookTitle, chapterIndex, unitIndex, sentenceText, sentenceTranslation, noteText, createdAt, updatedAt)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
        ON CONFLICT(bookId, sentenceText) DO UPDATE SET
            sentenceTranslation = CASE WHEN ?6 != '' THEN ?6 ELSE sentenceTranslation END,
            noteText = ?7,
            chapterIndex = ?3,
            unitIndex = ?4,
            updatedAt = ?9
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, bookId)
            sqlite3_bind_text(stmt, 2, bookTitle, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(chapterIndex))
            sqlite3_bind_int(stmt, 4, Int32(unitIndex))
            sqlite3_bind_text(stmt, 5, sentenceText, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, sentenceTranslation, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, noteText, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 8, ts)
            sqlite3_bind_int64(stmt, 9, ts)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        notes = fetchNotes()
    }

    func updateNoteText(id: Int64, noteText: String) {
        let ts = nowMs()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE sentence_notes SET noteText = ?1, updatedAt = ?2 WHERE id = ?3", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, noteText, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, ts)
            sqlite3_bind_int64(stmt, 3, id)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        notes = fetchNotes()
    }

    func deleteNote(id: Int64) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM sentence_notes WHERE id = ?1", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        notes = fetchNotes()
    }

    private func fetchNotes() -> [SentenceNote] {
        var list: [SentenceNote] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id, bookId, bookTitle, chapterIndex, unitIndex, sentenceText, sentenceTranslation, noteText, createdAt, updatedAt FROM sentence_notes ORDER BY updatedAt DESC"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                list.append(SentenceNote(
                    id: sqlite3_column_int64(stmt, 0),
                    bookId: sqlite3_column_int64(stmt, 1),
                    bookTitle: String(cString: sqlite3_column_text(stmt, 2)),
                    chapterIndex: Int(sqlite3_column_int(stmt, 3)),
                    unitIndex: Int(sqlite3_column_int(stmt, 4)),
                    sentenceText: String(cString: sqlite3_column_text(stmt, 5)),
                    sentenceTranslation: String(cString: sqlite3_column_text(stmt, 6)),
                    noteText: String(cString: sqlite3_column_text(stmt, 7)),
                    createdAt: sqlite3_column_int64(stmt, 8),
                    updatedAt: sqlite3_column_int64(stmt, 9)
                ))
            }
        }
        sqlite3_finalize(stmt)
        return list
    }

    // MARK: - Translation Cache
    func getCachedTranslation(_ source: String) -> String? {
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
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO translation_cache (sourceText, translatedText) VALUES (?1, ?2)", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, source.trimmingCharacters(in: .whitespacesAndNewlines), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, translated, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
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
        guard fetchDictionaryCount() == 0 else { return }
        let seed: [DictionaryEntry] = [
            DictionaryEntry(word: "abandon", phonetic: "/əˈbændən/", translation: "v. 放弃，遗弃；n. 放任"),
            DictionaryEntry(word: "ability", phonetic: "/əˈbɪləti/", translation: "n. 能力，才能"),
            DictionaryEntry(word: "absorb", phonetic: "/əbˈzɔːrb/", translation: "v. 吸收；使全神贯注"),
            DictionaryEntry(word: "abstract", phonetic: "/ˈæbstrækt/", translation: "adj. 抽象的；n. 摘要"),
            DictionaryEntry(word: "abundant", phonetic: "/əˈbʌndənt/", translation: "adj. 丰富的，充裕的"),
            DictionaryEntry(word: "achieve", phonetic: "/əˈtʃiːv/", translation: "v. 达到，完成，取得"),
            DictionaryEntry(word: "acquire", phonetic: "/əˈkwaɪər/", translation: "v. 获得，学到"),
            DictionaryEntry(word: "anchor", phonetic: "/ˈæŋkər/", translation: "n. 锚；v. 扎根，固定"),
            DictionaryEntry(word: "appreciate", phonetic: "/əˈpriːʃieɪt/", translation: "v. 欣赏，感激，领会"),
            DictionaryEntry(word: "approach", phonetic: "/əˈproʊtʃ/", translation: "v. 靠近；n. 方法，途径"),
            DictionaryEntry(word: "argument", phonetic: "/ˈɑːrɡjumənt/", translation: "n. 争论，论点"),
            DictionaryEntry(word: "attention", phonetic: "/əˈtenʃn/", translation: "n. 注意，关注"),
            DictionaryEntry(word: "capture", phonetic: "/ˈkæptʃər/", translation: "v./n. 捕获，记录"),
            DictionaryEntry(word: "concentrate", phonetic: "/ˈkɑːnsntreɪt/", translation: "v. 集中，全神贯注"),
            DictionaryEntry(word: "concept", phonetic: "/ˈkɑːnsept/", translation: "n. 概念，观念"),
            DictionaryEntry(word: "context", phonetic: "/ˈkɑːntekst/", translation: "n. 上下文，语境，背景"),
            DictionaryEntry(word: "discover", phonetic: "/dɪˈskʌvər/", translation: "v. 发现，发觉"),
            DictionaryEntry(word: "discovery", phonetic: "/dɪˈskʌvəri/", translation: "n. 发现，被发现的事物"),
            DictionaryEntry(word: "distraction", phonetic: "/dɪˈstrækʃn/", translation: "n. 分心，干扰，消遣"),
            DictionaryEntry(word: "effortless", phonetic: "/ˈefərtləs/", translation: "adj. 毫不费力的，轻松的"),
            DictionaryEntry(word: "emotion", phonetic: "/ɪˈmoʊʃn/", translation: "n. 情感，情绪"),
            DictionaryEntry(word: "encounter", phonetic: "/ɪnˈkaʊntər/", translation: "v./n. 遭遇，邂逅"),
            DictionaryEntry(word: "ephemeral", phonetic: "/ɪˈfemərəl/", translation: "adj. 短暂的，转瞬即逝的"),
            DictionaryEntry(word: "era", phonetic: "/ˈɪrə/", translation: "n. 时代，纪元"),
            DictionaryEntry(word: "examine", phonetic: "/ɪɡˈzæmɪn/", translation: "v. 检查，审视，考核"),
            DictionaryEntry(word: "expand", phonetic: "/ɪkˈspænd/", translation: "v. 扩大，扩展"),
            DictionaryEntry(word: "expression", phonetic: "/ɪkˈspreʃn/", translation: "n. 表达，措辞，表情"),
            DictionaryEntry(word: "gentle", phonetic: "/ˈdʒentl/", translation: "adj. 温和的，轻柔的"),
            DictionaryEntry(word: "glimpse", phonetic: "/ɡlɪmps/", translation: "n./v. 一瞥，短暂感受"),
            DictionaryEntry(word: "habit", phonetic: "/ˈhæbɪt/", translation: "n. 习惯，习性"),
            DictionaryEntry(word: "impression", phonetic: "/ɪmˈpreʃn/", translation: "n. 印象，感想"),
            DictionaryEntry(word: "isolation", phonetic: "/ˌaɪsəˈleɪʃn/", translation: "n. 孤立，隔离"),
            DictionaryEntry(word: "journey", phonetic: "/ˈdʒɜːrni/", translation: "n./v. 旅行，历程"),
            DictionaryEntry(word: "landscape", phonetic: "/ˈlændskeɪp/", translation: "n. 风景，格局"),
            DictionaryEntry(word: "lasting", phonetic: "/ˈlæstɪŋ/", translation: "adj. 持久的，永恒的"),
            DictionaryEntry(word: "literature", phonetic: "/ˈlɪtrətʃər/", translation: "n. 文学，文献"),
            DictionaryEntry(word: "lucid", phonetic: "/ˈluːsɪd/", translation: "adj. 清晰易懂的，神志清醒的"),
            DictionaryEntry(word: "memory", phonetic: "/ˈmeməri/", translation: "n. 记忆，回忆"),
            DictionaryEntry(word: "merely", phonetic: "/ˈmɪrli/", translation: "adv. 仅仅，只不过"),
            DictionaryEntry(word: "nuance", phonetic: "/ˈnuːɑːns/", translation: "n. 细微差别，微妙之处"),
            DictionaryEntry(word: "opportunity", phonetic: "/ˌɑːpərˈtuːnəti/", translation: "n. 机会，时机"),
            DictionaryEntry(word: "overwhelm", phonetic: "/ˌoʊvərˈwelm/", translation: "v. 淹没，使不知所措"),
            DictionaryEntry(word: "perspective", phonetic: "/pərˈspektɪv/", translation: "n. 视角，观点"),
            DictionaryEntry(word: "philosophical", phonetic: "/ˌfɪləˈsɑːfɪkl/", translation: "adj. 哲学的，达观的"),
            DictionaryEntry(word: "precious", phonetic: "/ˈpreʃəs/", translation: "adj. 珍贵的，宝贵的"),
            DictionaryEntry(word: "profound", phonetic: "/prəˈfaʊnd/", translation: "adj. 深远的，深刻的"),
            DictionaryEntry(word: "progressive", phonetic: "/prəˈɡresɪv/", translation: "adj. 渐进的，进步的"),
            DictionaryEntry(word: "rare", phonetic: "/rer/", translation: "adj. 罕见的，珍贵的"),
            DictionaryEntry(word: "resonance", phonetic: "/ˈrezənəns/", translation: "n. 共鸣，回响"),
            DictionaryEntry(word: "reveal", phonetic: "/rɪˈviːl/", translation: "v. 揭示，透露，展现"),
            DictionaryEntry(word: "rhythm", phonetic: "/ˈrɪðəm/", translation: "n. 节奏，韵律"),
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
        bulkInsertDictionary(seed)
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
