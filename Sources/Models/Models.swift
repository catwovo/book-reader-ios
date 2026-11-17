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
    var readingSeconds: Int64
    var lastReadAt: Int64
    var folderId: Int64?

    var progressRatio: Double {
        guard totalItems > 0 else { return 0 }
        return min(1.0, max(0.0, Double(currentIndex + 1) / Double(totalItems)))
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
    var familiarity: Int
    var createdAt: Int64
    var updatedAt: Int64
}

struct SentenceNote: Identifiable, Hashable, Sendable {
    var id: Int64
    var bookId: Int64
    var bookTitle: String
    var chapterIndex: Int
    var unitIndex: Int
    var sentenceText: String
    var sentenceTranslation: String
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
    case system
    case light
    case dark
    case sepia

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        case .sepia: return "羊皮纸"
        }
    }
}

enum StepSoundTrack: String, Codable, CaseIterable, Sendable {
    case off
    case piano
    case marimba
    case chime

    var displayName: String {
        switch self {
        case .off: return "关闭"
        case .piano: return "轻柔钢琴"
        case .marimba: return "清脆木琴"
        case .chime: return "空灵风铃"
        }
    }
}

struct OpdsSource: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var url: String
    var username: String = ""
    var password: String = ""
}

struct ReaderSettings: Codable, Equatable, Sendable {
    var visibleCount: Int = 3
    var stepMode: StepMode = .sentence
    var autoTranslateSentence: Bool = true
    var sentenceTranslateEngine: String = "apple" // "apple" | "ai"
    var autoAiAnalyze: Bool = false
    var underlineLookedUpWords: Bool = true

    // Layout & Typography
    var fontSize: Double = 20
    var lineSpacingMultiplier: Double = 1.35
    var readingPositionBias: Double = 0.0
    var readingZoneRatio: Double = 0.45

    // Step Feedback
    var stepSoundTrack: StepSoundTrack = .off
    var stepHapticLevel: Int = 1 // 0=off, 1=light, 2=medium, 3=heavy

    // Theme & 5 Custom Reader Colors (-1 = default glass)
    var themeMode: AppThemeMode = .system
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

    // OPDS & WebDAV
    var opdsSources: [OpdsSource] = []
    var activeOpdsSourceId: UUID? = nil
    var opdsUrl: String = ""
    var opdsUsername: String = ""
    var opdsPassword: String = ""
    var webdavUrl: String = ""
    var webdavUsername: String = ""
    var webdavPassword: String = ""
}

struct OpdsEntry: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let linkUrl: String
    let isAcquisition: Bool
    let formatHint: String
}

struct WebDavEntry: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let href: String
    let isDirectory: Bool
    let sizeBytes: Int64
}
