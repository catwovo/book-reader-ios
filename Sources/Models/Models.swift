import Foundation

struct BookFolder: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    var createdAt: Int64
    var updatedAt: Int64
}

struct BookItem: Identifiable, Hashable, Sendable {
    var id: Int64
    var title: String
    var bookmarkData: Data?
    var filePathHint: String
    var format: String
    var currentChapter: Int
    var currentIndex: Int
    var totalItems: Int
    var overallProgress: Float
    var readingSeconds: Int64
    var lastReadAt: Int64
    var folderId: Int64?

    var progressRatio: Double {
        if overallProgress >= 0 {
            return min(1.0, max(0.0, Double(overallProgress)))
        }
        guard totalItems > 0 else { return 0 }
        return min(1.0, max(0.0, Double(currentIndex + 1) / Double(totalItems)))
    }

    var hasStartedReading: Bool {
        readingSeconds > 0 || currentChapter > 0 || currentIndex > 0 || overallProgress > 0
    }
}

struct VocabItem: Identifiable, Hashable, Sendable {
    var id: Int64
    var word: String
    var lemma: String
    var phonetic: String
    var translation: String
    var englishTranslation: String
    var lookupCount: Int
    var contextSentence: String
    var contextTranslation: String
    var bookId: Int64?
    var bookTitle: String
    var familiarity: Int // 0 = 生疏, 1 = 模糊, 2 = 掌握
    var createdAt: Int64
    var updatedAt: Int64
}

struct SentenceNote: Identifiable, Hashable, Sendable {
    var id: Int64
    var bookId: Int64
    var bookTitle: String
    var chapterIndex: Int
    var chapterTitle: String
    var unitIndex: Int
    var sentenceText: String
    var sentenceTranslation: String
    var aiAnalysis: String
    var noteText: String
    var createdAt: Int64
    var updatedAt: Int64
}

struct ReadingLog: Identifiable, Hashable, Sendable {
    var id: Int64
    var dateKey: String
    var year: Int
    var yearMonth: String
    var dayOfMonth: Int
    var bookId: Int64
    var bookTitle: String
    var readingSeconds: Int64
    var unitsRead: Int
    var lookupsCount: Int
    var lastReadAt: Int64
}

struct VocabReviewLog: Identifiable, Hashable, Sendable {
    var id: String { dateKey }
    var dateKey: String
    var year: Int
    var yearMonth: String
    var dayOfMonth: Int
    var unknownCount: Int
    var fuzzyCount: Int
    var knownCount: Int
    var updatedAt: Int64

    var total: Int { unknownCount + fuzzyCount + knownCount }
}

struct DictionaryEntry: Hashable, Sendable {
    var word: String
    var phonetic: String
    var translation: String
}

struct CacheStats: Hashable, Sendable {
    var bookCacheBytes: Int64 = 0
    var coverCacheBytes: Int64 = 0
    var tempBytes: Int64 = 0

    var totalBytes: Int64 {
        bookCacheBytes + coverCacheBytes + tempBytes
    }
}

struct ManagedBooksCleanupReport: Hashable, Sendable {
    var totalFiles: Int = 0
    var totalBytes: Int64 = 0
    var orphanFiles: Int = 0
    var orphanBytes: Int64 = 0
}

enum StepMode: String, Codable, CaseIterable, Sendable {
    case sentence
    case line

    var displayName: String {
        switch self {
        case .sentence: return "按自然句"
        case .line: return "按视觉行"
        }
    }
}

enum AppThemeMode: String, Codable, CaseIterable, Sendable {
    case dynamic
    case light
    case dark
    case sepia
    case sage
    case slate
    case amoled

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "system", "dynamic": self = .dynamic
        case "light": self = .light
        case "dark": self = .dark
        case "sepia": self = .sepia
        case "sage": self = .sage
        case "slate": self = .slate
        case "amoled": self = .amoled
        default: self = .dynamic
        }
    }

    var displayName: String {
        switch self {
        case .dynamic: return "随系统"
        case .light: return "素净白"
        case .dark: return "经典黑"
        case .sepia: return "暖羊皮"
        case .sage: return "护眼青"
        case .slate: return "深海蓝"
        case .amoled: return "纯黑夜"
        }
    }

    var isDark: Bool {
        switch self {
        case .dark, .slate, .amoled: return true
        case .dynamic, .light, .sepia, .sage: return false
        }
    }
}

enum StepSoundTrack: String, Codable, CaseIterable, Sendable {
    case off
    case canon
    case twinkle
    case fur_elise
    case ode_to_joy

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "off": self = .off
        case "canon", "piano": self = .canon
        case "twinkle", "marimba": self = .twinkle
        case "fur_elise", "chime": self = .fur_elise
        case "ode_to_joy": self = .ode_to_joy
        default: self = .canon
        }
    }

    var displayName: String {
        switch self {
        case .off: return "关闭"
        case .canon: return "卡农"
        case .twinkle: return "小星星"
        case .fur_elise: return "致爱丽丝"
        case .ode_to_joy: return "欢乐颂"
        }
    }
}

enum StepHapticMode: String, Codable, CaseIterable, Sendable {
    case single
    case line

    var displayName: String {
        switch self {
        case .single: return "单次"
        case .line: return "随行数"
        }
    }
}

struct OpdsSource: Identifiable, Codable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var url: String
    var username: String = ""
    var password: String = ""

    enum CodingKeys: String, CodingKey {
        case id, name, url, username, password
    }

    init(id: String = UUID().uuidString, name: String, url: String, username: String = "", password: String = "") {
        self.id = id
        self.name = name
        self.url = url
        self.username = username
        self.password = password
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let strId = try? c.decode(String.self, forKey: .id) {
            self.id = strId
        } else if let uuidId = try? c.decode(UUID.self, forKey: .id) {
            self.id = uuidId.uuidString
        } else {
            self.id = UUID().uuidString
        }
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        self.password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
    }
}

struct ReaderSettings: Codable, Equatable, Sendable {
    var visibleCount: Int = 3
    var stepMode: StepMode = .sentence
    var autoTranslateSentence: Bool = true
    var sentenceTranslateEngine: String = "auto" // "auto" | "ai" | "online" | "apple"
    var autoAiAnalyze: Bool = false
    var underlineLookedUpWords: Bool = true

    // Layout & Typography
    var fontSize: Double = 20
    var lineSpacingMultiplier: Double = 1.2
    var readingPositionBias: Double = 0.0
    var readingZoneRatio: Double = 0.45

    // Step Feedback
    var stepSoundTrack: StepSoundTrack = .canon
    var stepNoteIntervalMs: Int = 240
    var stepHapticLevel: Int = 1 // 0=off, 1=soft, 2=medium, 3=strong
    var stepHapticMode: StepHapticMode = .single

    // Theme & 5 Custom Reader Colors (-1 = default Liquid Glass / theme)
    var themeMode: AppThemeMode = .dynamic
    var readerBgColorHex: Int64 = -1
    var readerFocusColorHex: Int64 = -1
    var readerBottomBgColorHex: Int64 = -1
    var readerSentenceCardColorHex: Int64 = -1
    var readerWordCardColorHex: Int64 = -1

    // AI
    var aiBaseUrl: String = "https://api.openai.com/v1"
    var aiApiKey: String = ""
    var aiModel: String = "gpt-4o-mini"
    var aiSystemPrompt: String = "你是一个专业的英语精读助手。请用简洁清晰的中文，分析所给句子或词汇在当前语境中的含义、语法结构与核心用法。"

    // WebDAV
    var webdavUrl: String = ""
    var webdavUsername: String = ""
    var webdavPassword: String = ""

    init() {}

    enum CodingKeys: String, CodingKey {
        case visibleCount, stepMode, autoTranslateSentence, sentenceTranslateEngine
        case autoAiAnalyze, underlineLookedUpWords
        case fontSize, lineSpacingMultiplier, readingPositionBias, readingZoneRatio
        case stepSoundTrack, stepNoteIntervalMs, stepHapticLevel, stepHapticMode
        case themeMode
        case readerBgColorHex, readerFocusColorHex, readerBottomBgColorHex
        case readerSentenceCardColorHex, readerWordCardColorHex
        case aiBaseUrl, aiApiKey, aiModel, aiSystemPrompt
        case webdavUrl, webdavUsername, webdavPassword
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReaderSettings()
        visibleCount = try c.decodeIfPresent(Int.self, forKey: .visibleCount) ?? d.visibleCount
        stepMode = try c.decodeIfPresent(StepMode.self, forKey: .stepMode) ?? d.stepMode
        autoTranslateSentence = try c.decodeIfPresent(Bool.self, forKey: .autoTranslateSentence) ?? d.autoTranslateSentence
        let rawEngine = try c.decodeIfPresent(String.self, forKey: .sentenceTranslateEngine) ?? d.sentenceTranslateEngine
        sentenceTranslateEngine = (rawEngine == "offline") ? "apple" : rawEngine
        autoAiAnalyze = try c.decodeIfPresent(Bool.self, forKey: .autoAiAnalyze) ?? d.autoAiAnalyze
        underlineLookedUpWords = try c.decodeIfPresent(Bool.self, forKey: .underlineLookedUpWords) ?? d.underlineLookedUpWords

        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        lineSpacingMultiplier = min(1.8, max(1.0, try c.decodeIfPresent(Double.self, forKey: .lineSpacingMultiplier) ?? d.lineSpacingMultiplier))
        readingPositionBias = min(1.0, max(0.0, try c.decodeIfPresent(Double.self, forKey: .readingPositionBias) ?? d.readingPositionBias))
        readingZoneRatio = min(0.75, max(0.25, try c.decodeIfPresent(Double.self, forKey: .readingZoneRatio) ?? d.readingZoneRatio))

        stepSoundTrack = try c.decodeIfPresent(StepSoundTrack.self, forKey: .stepSoundTrack) ?? d.stepSoundTrack
        stepNoteIntervalMs = min(700, max(180, try c.decodeIfPresent(Int.self, forKey: .stepNoteIntervalMs) ?? d.stepNoteIntervalMs))
        stepHapticLevel = min(3, max(0, try c.decodeIfPresent(Int.self, forKey: .stepHapticLevel) ?? d.stepHapticLevel))
        stepHapticMode = try c.decodeIfPresent(StepHapticMode.self, forKey: .stepHapticMode) ?? d.stepHapticMode

        themeMode = try c.decodeIfPresent(AppThemeMode.self, forKey: .themeMode) ?? d.themeMode
        readerBgColorHex = try c.decodeIfPresent(Int64.self, forKey: .readerBgColorHex) ?? d.readerBgColorHex
        readerFocusColorHex = try c.decodeIfPresent(Int64.self, forKey: .readerFocusColorHex) ?? d.readerFocusColorHex
        readerBottomBgColorHex = try c.decodeIfPresent(Int64.self, forKey: .readerBottomBgColorHex) ?? d.readerBottomBgColorHex
        readerSentenceCardColorHex = try c.decodeIfPresent(Int64.self, forKey: .readerSentenceCardColorHex) ?? d.readerSentenceCardColorHex
        readerWordCardColorHex = try c.decodeIfPresent(Int64.self, forKey: .readerWordCardColorHex) ?? d.readerWordCardColorHex

        aiBaseUrl = try c.decodeIfPresent(String.self, forKey: .aiBaseUrl) ?? d.aiBaseUrl
        aiApiKey = try c.decodeIfPresent(String.self, forKey: .aiApiKey) ?? d.aiApiKey
        aiModel = try c.decodeIfPresent(String.self, forKey: .aiModel) ?? d.aiModel
        aiSystemPrompt = try c.decodeIfPresent(String.self, forKey: .aiSystemPrompt) ?? d.aiSystemPrompt

        webdavUrl = try c.decodeIfPresent(String.self, forKey: .webdavUrl) ?? d.webdavUrl
        webdavUsername = try c.decodeIfPresent(String.self, forKey: .webdavUsername) ?? d.webdavUsername
        webdavPassword = try c.decodeIfPresent(String.self, forKey: .webdavPassword) ?? d.webdavPassword
    }
}

struct OpdsAcquisitionLink: Hashable, Sendable {
    let url: String
    let format: String
    let mimeType: String
    let title: String
}

struct OpdsEntry: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let author: String
    let summary: String
    let navigationUrl: String?
    let coverUrl: String?
    let acquisitions: [OpdsAcquisitionLink]
    let updated: String

    var isCategory: Bool { navigationUrl != nil && acquisitions.isEmpty }

    var subtitle: String { author }
    var linkUrl: String { navigationUrl ?? acquisitions.first?.url ?? "" }
    var isAcquisition: Bool { !acquisitions.isEmpty }
    var formatHint: String { acquisitions.first?.format ?? "" }
}

struct OpdsFeed: Sendable {
    let title: String
    let entries: [OpdsEntry]
    let nextPageUrl: String?
    let searchUrlTemplate: String?
}

struct OpdsDownloadResult: Sendable {
    let uriString: String
    let title: String
    let format: String
}

struct WebDavEntry: Identifiable, Hashable, Sendable {
    var id: String { url }
    let name: String
    let url: String
    let isDirectory: Bool
    let sizeBytes: Int64
    let lastModified: String
    let format: String?

    var href: String { url }
}

struct WebDavDownloadResult: Sendable {
    let uriString: String
    let title: String
    let format: String
}

// MARK: - Persistent External Backup Models

struct BackupFolderRecord: Codable, Hashable, Sendable {
    var oldId: Int64
    var name: String
    var createdAt: Int64
    var updatedAt: Int64
}

struct BackupBookRecord: Codable, Hashable, Sendable {
    var oldId: Int64
    var title: String
    var fileName: String
    var filePathHint: String
    var format: String
    var currentChapter: Int
    var currentIndex: Int
    var totalItems: Int
    var overallProgress: Float
    var readingSeconds: Int64
    var lastReadAt: Int64
    var oldFolderId: Int64?
}

struct BackupVocabRecord: Codable, Hashable, Sendable {
    var word: String
    var lemma: String
    var phonetic: String
    var translation: String
    var englishTranslation: String
    var lookupCount: Int
    var contextSentence: String
    var contextTranslation: String
    var oldBookId: Int64?
    var bookTitle: String
    var familiarity: Int
    var createdAt: Int64
    var updatedAt: Int64
}

struct BackupNoteRecord: Codable, Hashable, Sendable {
    var oldBookId: Int64
    var bookTitle: String
    var chapterIndex: Int
    var chapterTitle: String
    var unitIndex: Int
    var sentenceText: String
    var sentenceTranslation: String
    var aiAnalysis: String
    var noteText: String
    var createdAt: Int64
    var updatedAt: Int64
}

struct BackupReadingLogRecord: Codable, Hashable, Sendable {
    var dateKey: String
    var year: Int
    var yearMonth: String
    var dayOfMonth: Int
    var oldBookId: Int64
    var bookTitle: String
    var readingSeconds: Int64
    var unitsRead: Int
    var lookupsCount: Int
    var lastReadAt: Int64
}

struct BackupVocabReviewLogRecord: Codable, Hashable, Sendable {
    var dateKey: String
    var year: Int
    var yearMonth: String
    var dayOfMonth: Int
    var unknownCount: Int
    var fuzzyCount: Int
    var knownCount: Int
    var updatedAt: Int64
}

struct AppBackupManifest: Codable, Sendable {
    var version: Int = 1
    var exportedAtMs: Int64
    var deviceName: String
    var folders: [BackupFolderRecord]
    var books: [BackupBookRecord]
    var vocabList: [BackupVocabRecord]
    var notes: [BackupNoteRecord]
    var readingLogs: [BackupReadingLogRecord]
    var vocabReviewLogs: [BackupVocabReviewLogRecord]
    var settings: ReaderSettings
    var opdsSources: [OpdsSource]
    var selectedOpdsSourceId: String?
}

