import AVFoundation
import Foundation
import SwiftUI
#if canImport(Translation)
import Translation
#endif

// MARK: - Speech Manager (Auto CN / EN)

@Observable
final class SpeechManager {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: trimmed)
        let lang = TextTokenizer.isPredominantlyChinese(trimmed) ? "zh-CN" : "en-US"
        utterance.voice = AVSpeechSynthesisVoice(language: lang)
        utterance.rate = 0.48
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}

// MARK: - Download State

struct DictDownloadState: Sendable {
    var isDownloading: Bool = false
    var message: String? = nil
    var importedCount: Int = 0
    var isError: Bool = false
    var progress: Double? = nil
}

// MARK: - Apple System Offline Translation Bridge (iOS 18+)

@Observable
@MainActor
final class AppleTranslationBridge {
#if canImport(Translation)
    var configuration: TranslationSession.Configuration?
#endif
    private struct QueuedRequest {
        let text: String
        let toEnglish: Bool
        let isPrepareOnly: Bool
        let continuation: CheckedContinuation<String, Error>
    }

    private var queue: [QueuedRequest] = []
    private var activeRequest: QueuedRequest?

    func translate(_ text: String, toEnglish: Bool) async throws -> String {
#if canImport(Translation)
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }
        return try await withCheckedThrowingContinuation { cont in
            queue.append(QueuedRequest(text: clean, toEnglish: toEnglish, isPrepareOnly: false, continuation: cont))
            pumpNextIfIdle()
        }
#else
        throw NSError(domain: "AppleTranslation", code: -1, userInfo: [NSLocalizedDescriptionKey: "当前系统不支持 Apple 原生离线翻译"])
#endif
    }

    func prepareLanguagePack(toEnglish: Bool) async throws {
#if canImport(Translation)
        _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            queue.append(QueuedRequest(text: "", toEnglish: toEnglish, isPrepareOnly: true, continuation: cont))
            pumpNextIfIdle()
        }
#else
        throw NSError(domain: "AppleTranslation", code: -1, userInfo: [NSLocalizedDescriptionKey: "当前系统不支持 Apple 原生离线翻译"])
#endif
    }

    private func pumpNextIfIdle() {
#if canImport(Translation)
        guard activeRequest == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        activeRequest = next

        let src = Locale.Language(identifier: next.toEnglish ? "zh-Hans" : "en")
        let dst = Locale.Language(identifier: next.toEnglish ? "en" : "zh-Hans")

        if var current = configuration, current.source == src, current.target == dst {
            current.invalidate()
            configuration = current
        } else {
            configuration = TranslationSession.Configuration(source: src, target: dst)
        }
#endif
    }

#if canImport(Translation)
    func handleSession(_ session: TranslationSession) async {
        guard let req = activeRequest else { return }
        do {
            if req.isPrepareOnly {
                try await session.prepareTranslation()
                req.continuation.resume(returning: "")
            } else {
                let response = try await session.translate(req.text)
                req.continuation.resume(returning: response.targetText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } catch {
            req.continuation.resume(throwing: error)
        }
        activeRequest = nil
        pumpNextIfIdle()
    }
#endif

    static func checkAvailability(toEnglish: Bool) async -> String {
#if canImport(Translation)
        let availability = LanguageAvailability()
        let src = Locale.Language(identifier: toEnglish ? "zh-Hans" : "en")
        let dst = Locale.Language(identifier: toEnglish ? "en" : "zh-Hans")
        let status = await availability.status(from: src, to: dst)
        switch status {
        case .installed:
            return "已安装（完全离线可用）"
        case .supported:
            return "支持（点击下方可预下载离线包）"
        case .unsupported:
            return "当前环境不支持"
        @unknown default:
            return "支持"
        }
#else
        return "需要 iOS 18+"
#endif
    }
}

// MARK: - Thread-safe Runtime Cache Store

private final class TranslationCacheStore: @unchecked Sendable {
    static let shared = TranslationCacheStore()

    let lock = NSLock()
    var sentenceMemoryCache: [String: String] = [:]
    var sentenceSourceMemoryCache: [String: String] = [:]
    var wordEnMemoryCache: [String: String] = [:]

    var bingSession: BingWebSession?
    var bingCooldownUntil: Date = .distantPast
    var googleCooldownUntil: Date = .distantPast
    var myMemoryCooldownUntil: Date = .distantPast

    struct BingWebSession: Sendable {
        let host: String
        let ig: String
        let iid: String
        let key: String
        let token: String
        let expiresAt: Date
    }

    let bingSessionUrlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        return URLSession(configuration: config)
    }()

    private init() {}

    func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - Translation Service

@Observable
@MainActor
final class TranslationService {
    static let shared = TranslationService()

    var ecdictState = DictDownloadState()
    var chineseDictState = DictDownloadState()

    private var ecdictTask: Task<Void, Never>?
    private var chineseDictTask: Task<Void, Never>?

    private init() {}

    nonisolated static func clearMemoryCaches() {
        TranslationCacheStore.shared.withLock {
            TranslationCacheStore.shared.sentenceMemoryCache.removeAll()
            TranslationCacheStore.shared.sentenceSourceMemoryCache.removeAll()
            TranslationCacheStore.shared.wordEnMemoryCache.removeAll()
        }
    }

    nonisolated static func isErrorPlaceholder(_ text: String) -> Bool {
        text.hasPrefix("（离线翻译") ||
        text.hasPrefix("（Apple 离线") ||
        text.hasPrefix("（在线翻译失败") ||
        text.hasPrefix("（翻译失败") ||
        text.hasPrefix("（当前系统暂不支持")
    }

    nonisolated static func hasAiConfigured(_ settings: ReaderSettings) -> Bool {
        !settings.aiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        settings.aiBaseUrl.contains("localhost") ||
        settings.aiBaseUrl.contains("127.0.0.1") ||
        settings.aiBaseUrl.contains("192.168.")
    }

    nonisolated static func resolveEffectiveSentenceEngine(_ settings: ReaderSettings) -> String {
        switch settings.sentenceTranslateEngine {
        case "apple", "offline":
            return "apple"
        case "online":
            return "online"
        case "ai":
            return hasAiConfigured(settings) ? "ai" : "online"
        default:
            return hasAiConfigured(settings) ? "ai" : "online"
        }
    }

    nonisolated private static func buildSentenceCacheKey(engine: String, settings: ReaderSettings, cleanText: String) -> String {
        let dir = TextTokenizer.isPredominantlyChinese(cleanText) ? "zh2en" : "en2zh"
        switch engine {
        case "ai":
            return "ai:\(settings.aiModel.trimmingCharacters(in: .whitespacesAndNewlines)):\(dir):\(cleanText)"
        case "online":
            return "online:\(dir):\(cleanText)"
        default:
            return "apple:\(dir):\(cleanText)"
        }
    }

    nonisolated static func getCachedSentenceSource(text: String, settings: ReaderSettings) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let primary = resolveEffectiveSentenceEngine(settings)
        let key = buildSentenceCacheKey(engine: primary, settings: settings, cleanText: clean)
        let store = TranslationCacheStore.shared
        if let hit = store.withLock({ store.sentenceSourceMemoryCache[key] }) { return hit }
        switch primary {
        case "ai": return "AI 精译"
        case "online": return "在线翻译"
        default: return "Apple 离线"
        }
    }

    nonisolated static func getCachedSentenceMemory(text: String, settings: ReaderSettings) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }
        let primary = resolveEffectiveSentenceEngine(settings)
        let key = buildSentenceCacheKey(engine: primary, settings: settings, cleanText: clean)
        let store = TranslationCacheStore.shared
        return store.withLock { store.sentenceMemoryCache[key] }
    }

    nonisolated private static func putMemorySentence(key: String, text: String, source: String) {
        let store = TranslationCacheStore.shared
        store.withLock {
            if store.sentenceMemoryCache.count > 600 { store.sentenceMemoryCache.removeAll() }
            if store.sentenceSourceMemoryCache.count > 600 { store.sentenceSourceMemoryCache.removeAll() }
            store.sentenceMemoryCache[key] = text
            store.sentenceSourceMemoryCache[key] = source
        }
    }

    nonisolated static func getCachedSentenceTranslation(
        text: String,
        db: DatabaseManager,
        settings: ReaderSettings
    ) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }
        let primary = resolveEffectiveSentenceEngine(settings)
        let key = buildSentenceCacheKey(engine: primary, settings: settings, cleanText: clean)
        let store = TranslationCacheStore.shared
        if let memHit = store.withLock({ store.sentenceMemoryCache[key] }) { return memHit }

        if let dbHit = db.getCachedTranslation(key) {
            let label = primary == "ai" ? "AI 精译" : (primary == "online" ? "在线翻译" : "Apple 离线")
            putMemorySentence(key: key, text: dbHit, source: label)
            return dbHit
        }
        return nil
    }

    // MARK: - Word CN -> EN

    nonisolated static func getCachedZhToEnWord(word: String, db: DatabaseManager) -> String? {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let key = "zh2en_w2:\(clean)"
        let store = TranslationCacheStore.shared
        if let mem = store.withLock({ store.wordEnMemoryCache[key] }) { return mem }
        if let hit = db.getCachedTranslation(key) {
            store.withLock {
                if store.wordEnMemoryCache.count > 400 { store.wordEnMemoryCache.removeAll() }
                store.wordEnMemoryCache[key] = hit
            }
            return hit
        }
        return nil
    }

    static func translateWordToEnglishOffline(
        word: String,
        db: DatabaseManager,
        appleTranslator: (@MainActor (String, Bool) async throws -> String)? = nil
    ) async -> String? {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if let cached = getCachedZhToEnWord(word: clean, db: db) {
            return cached
        }

        let store = TranslationCacheStore.shared
        if let onlineHit = await translateWithOnlineEngines(cleanText: clean, toEnglish: true)?.1, !onlineHit.isEmpty {
            let key = "zh2en_w2:\(clean)"
            store.withLock {
                if store.wordEnMemoryCache.count > 400 { store.wordEnMemoryCache.removeAll() }
                store.wordEnMemoryCache[key] = onlineHit
            }
            db.saveCachedTranslation(source: key, translated: onlineHit)
            return onlineHit
        }

        if let appleTranslator, let appleHit = try? await appleTranslator(clean, true), !appleHit.isEmpty {
            let key = "zh2en_w2:\(clean)"
            store.withLock {
                if store.wordEnMemoryCache.count > 400 { store.wordEnMemoryCache.removeAll() }
                store.wordEnMemoryCache[key] = appleHit
            }
            db.saveCachedTranslation(source: key, translated: appleHit)
            return appleHit
        }
        return nil
    }

    // MARK: - Progressive Sentence Translation

    static func translateSentenceProgressive(
        text: String,
        settings: ReaderSettings,
        db: DatabaseManager,
        prevSentence: String? = nil,
        nextSentence: String? = nil,
        bookTitle: String? = nil,
        forceRefresh: Bool = false,
        allowOfflineFallback: Bool = true,
        appleTranslator: (@MainActor (String, Bool) async throws -> String)? = nil,
        onFastPreview: ((String) -> Void)? = nil
    ) async -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }
        let toEnglish = TextTokenizer.isPredominantlyChinese(clean)
        let effectiveEngine = resolveEffectiveSentenceEngine(settings)
        let store = TranslationCacheStore.shared

        func runOnline() async -> String? {
            let key = buildSentenceCacheKey(engine: "online", settings: settings, cleanText: clean)
            if !forceRefresh {
                if let mem = store.withLock({ store.sentenceMemoryCache[key] }) { return mem }
                if let hit = db.getCachedTranslation(key) {
                    putMemorySentence(key: key, text: hit, source: "在线翻译")
                    return hit
                }
            }
            if let hit = await translateWithOnlineEngines(cleanText: clean, toEnglish: toEnglish), !hit.1.isEmpty {
                putMemorySentence(key: key, text: hit.1, source: hit.0)
                db.saveCachedTranslation(source: key, translated: hit.1)
                return hit.1
            }
            return nil
        }

        func runAi() async -> String? {
            let key = buildSentenceCacheKey(engine: "ai", settings: settings, cleanText: clean)
            if !forceRefresh {
                if let mem = store.withLock({ store.sentenceMemoryCache[key] }) { return mem }
                if let hit = db.getCachedTranslation(key) {
                    putMemorySentence(key: key, text: hit, source: "AI 精译")
                    return hit
                }
            }
            if let translated = await translateSentenceWithAiDirect(
                settings: settings,
                cleanText: clean,
                toEnglish: toEnglish,
                prevSentence: prevSentence,
                nextSentence: nextSentence,
                bookTitle: bookTitle
            ), !translated.isEmpty {
                putMemorySentence(key: key, text: translated, source: "AI 精译")
                db.saveCachedTranslation(source: key, translated: translated)
                return translated
            }
            return nil
        }

        func runAppleOffline() async -> String {
            let key = buildSentenceCacheKey(engine: "apple", settings: settings, cleanText: clean)
            if !forceRefresh {
                if let mem = store.withLock({ store.sentenceMemoryCache[key] }) { return mem }
                if let hit = db.getCachedTranslation(key) {
                    putMemorySentence(key: key, text: hit, source: "Apple 离线")
                    return hit
                }
            }
            guard let appleTranslator else {
                return "（Apple 离线翻译需要在阅读界面内触发，请稍后重试）"
            }
            do {
                let translated = try await appleTranslator(clean, toEnglish)
                let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    putMemorySentence(key: key, text: trimmed, source: "Apple 离线")
                    db.saveCachedTranslation(source: key, translated: trimmed)
                    return trimmed
                }
                return "（Apple 离线翻译未返回结果）"
            } catch {
                return "（Apple 离线翻译准备中或需下载语言包：\(error.localizedDescription)）"
            }
        }

        switch effectiveEngine {
        case "ai":
            let aiKey = buildSentenceCacheKey(engine: "ai", settings: settings, cleanText: clean)
            if !forceRefresh {
                if let cached = getCachedSentenceTranslation(text: clean, db: db, settings: settings) {
                    return cached
                }
            }

            if let onFastPreview {
                let previewTask = Task { () -> String? in
                    let fast = await runOnline()
                    if let fast, !fast.isEmpty, !Task.isCancelled {
                        let onlineKey = buildSentenceCacheKey(engine: "online", settings: settings, cleanText: clean)
                        store.withLock {
                            let src = store.sentenceSourceMemoryCache[onlineKey] ?? "在线翻译"
                            store.sentenceSourceMemoryCache[aiKey] = src
                        }
                        onFastPreview(fast)
                    }
                    return fast
                }

                if let aiHit = await runAi(), !aiHit.isEmpty {
                    previewTask.cancel()
                    putMemorySentence(key: aiKey, text: aiHit, source: "AI 精译")
                    return aiHit
                }

                if let fastHit = await previewTask.value, !fastHit.isEmpty {
                    return fastHit
                }
            } else {
                if let aiHit = await runAi(), !aiHit.isEmpty { return aiHit }
                if let onlineHit = await runOnline(), !onlineHit.isEmpty {
                    let onlineKey = buildSentenceCacheKey(engine: "online", settings: settings, cleanText: clean)
                    store.withLock {
                        let src = store.sentenceSourceMemoryCache[onlineKey] ?? "在线翻译"
                        store.sentenceSourceMemoryCache[aiKey] = src
                    }
                    return onlineHit
                }
            }

            guard allowOfflineFallback else { return "" }
            let off = await runAppleOffline()
            putMemorySentence(
                key: aiKey,
                text: off,
                source: isErrorPlaceholder(off) ? "翻译失败" : "回退 Apple 离线"
            )
            return off

        case "online":
            let onlineKey = buildSentenceCacheKey(engine: "online", settings: settings, cleanText: clean)
            if let onlineHit = await runOnline(), !onlineHit.isEmpty {
                return onlineHit
            }
            guard allowOfflineFallback else { return "" }
            let off = await runAppleOffline()
            if isErrorPlaceholder(off) {
                store.withLock {
                    store.sentenceSourceMemoryCache[onlineKey] = "在线翻译失败"
                }
                return "（在线翻译失败，请检查网络连接后点击右侧刷新重试）"
            }
            putMemorySentence(key: onlineKey, text: off, source: "在线失败·已回退 Apple 离线")
            return off

        default:
            let appleKey = buildSentenceCacheKey(engine: "apple", settings: settings, cleanText: clean)
            let off = await runAppleOffline()
            store.withLock {
                store.sentenceSourceMemoryCache[appleKey] = isErrorPlaceholder(off) ? "离线未就绪" : "Apple 离线"
            }
            return off
        }
    }

    // MARK: - Online Engines (Bing Web / Google Free / MyMemory)

    nonisolated private static func getBingWebSession(forceRefresh: Bool) async -> TranslationCacheStore.BingWebSession? {
        let store = TranslationCacheStore.shared
        if !forceRefresh {
            if let existing = store.withLock({ store.bingSession }), Date() < existing.expiresAt {
                return existing
            }
        } else {
            store.withLock { store.bingSession = nil }
        }

        let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        for entryUrlStr in ["https://cn.bing.com/translator", "https://www.bing.com/translator"] {
            guard let url = URL(string: entryUrlStr) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

            guard let (data, resp) = try? await store.bingSessionUrlSession.data(for: req),
                  let http = resp as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8),
                  !html.isEmpty else {
                continue
            }

            let finalHost = http.url?.host ?? "cn.bing.com"
            guard let ig = firstRegexGroup(#"IG\s*:\s*"([A-Za-z0-9]+)""#, in: html) else { continue }
            let iid = firstRegexGroup(#"data-iid="([^"]+)""#, in: html) ?? "translator.5028"
            guard let abuseRegex = try? NSRegularExpression(pattern: #"params_AbusePreventionHelper\s*=\s*\[\s*(\d+)\s*,\s*"([^"]+)"\s*,\s*(\d+)\s*\]"#),
                  let match = abuseRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  match.numberOfRanges >= 4,
                  let r1 = Range(match.range(at: 1), in: html),
                  let r2 = Range(match.range(at: 2), in: html),
                  let r3 = Range(match.range(at: 3), in: html) else {
                continue
            }

            let key = String(html[r1])
            let token = String(html[r2])
            let ttlMs = Double(html[r3]) ?? 3_600_000.0
            let safeTtlSec = min(max(60.0, (ttlMs - 120_000.0) / 1000.0), 25.0 * 60.0)
            let created = TranslationCacheStore.BingWebSession(
                host: finalHost,
                ig: ig,
                iid: iid,
                key: key,
                token: token,
                expiresAt: Date().addingTimeInterval(safeTtlSec)
            )
            store.withLock { store.bingSession = created }
            return created
        }
        return nil
    }

    nonisolated private static func translateViaBingWeb(text: String, toEnglish: Bool) async -> String? {
        let store = TranslationCacheStore.shared
        let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        let fromLang = toEnglish ? "zh-Hans" : "en"
        let toLang = toEnglish ? "en" : "zh-Hans"
        let clipped = String(text.prefix(950))

        for attempt in 0...1 {
            guard let session = await getBingWebSession(forceRefresh: attempt > 0),
                  let url = URL(string: "https://\(session.host)/ttranslatev3?isVertical=1&IG=\(session.ig)&IID=\(session.iid)") else {
                return nil
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 10
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            req.setValue("https://\(session.host)/translator", forHTTPHeaderField: "Referer")
            req.setValue("https://\(session.host)", forHTTPHeaderField: "Origin")
            req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")

            var comps = URLComponents()
            comps.queryItems = [
                URLQueryItem(name: "fromLang", value: fromLang),
                URLQueryItem(name: "to", value: toLang),
                URLQueryItem(name: "text", value: clipped),
                URLQueryItem(name: "token", value: session.token),
                URLQueryItem(name: "key", value: session.key),
                URLQueryItem(name: "tryFetchingGenderDebiasedTranslations", value: "true")
            ]
            req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

            guard let (data, resp) = try? await store.bingSessionUrlSession.data(for: req),
                  let http = resp as? HTTPURLResponse else {
                return nil
            }
            if [400, 401, 403, 429].contains(http.statusCode) {
                store.withLock { store.bingSession = nil }
                continue
            }
            guard (200...299).contains(http.statusCode) else { return nil }
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let translations = arr.first?["translations"] as? [[String: Any]],
               let text = translations.first?["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            } else {
                store.withLock { store.bingSession = nil }
            }
        }
        return nil
    }

    nonisolated private static func translateViaGoogleFree(text: String, toEnglish: Bool) async -> String? {
        let sl = toEnglish ? "zh-CN" : "en"
        let tl = toEnglish ? "en" : "zh-CN"
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=\(sl)&tl=\(tl)&dt=t&q=\(encoded)") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4.5
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segs = root.first as? [Any] else {
            return nil
        }
        var out = ""
        for item in segs {
            if let arr = item as? [Any], let piece = arr.first as? String {
                out += piece
            }
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func translateViaMyMemory(text: String, toEnglish: Bool) async -> String? {
        guard text.count <= 450 else { return nil }
        let langPair = toEnglish ? "zh-CN|en" : "en|zh-CN"
        var comps = URLComponents(string: "https://api.mymemory.translated.net/get")
        comps?.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: langPair)
        ]
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("LocalBookReader-iOS/1.0", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["responseStatus"] as? Int) == 200,
              (obj["quotaFinished"] as? Bool) != true,
              let responseData = obj["responseData"] as? [String: Any],
              let translated = responseData["translatedText"] as? String else {
            return nil
        }
        let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.uppercased().hasPrefix("MYMEMORY WARNING") {
            return nil
        }
        return trimmed
    }

    nonisolated private static func translateWithOnlineEngines(cleanText: String, toEnglish: Bool) async -> (String, String)? {
        let store = TranslationCacheStore.shared
        let now = Date()
        let (bingReady, googleReady, myMemReady) = store.withLock {
            (
                now >= store.bingCooldownUntil,
                now >= store.googleCooldownUntil,
                now >= store.myMemoryCooldownUntil
            )
        }

        var engines: [(String, String, Bool)] = [] // id, label, delayed
        if bingReady { engines.append(("bing", "必应在线", false)) }
        if googleReady { engines.append(("google", "Google", false)) }
        if myMemReady { engines.append(("mymemory", "MyMemory", bingReady)) }
        if engines.isEmpty {
            store.withLock {
                store.bingCooldownUntil = .distantPast
                store.myMemoryCooldownUntil = .distantPast
            }
            engines = [("bing", "必应在线", false), ("mymemory", "MyMemory", true)]
        }

        return await withTaskGroup(of: (String, String, String?)?.self) { group in
            for (id, label, delayed) in engines {
                group.addTask {
                    if delayed {
                        try? await Task.sleep(nanoseconds: 1_100_000_000)
                        if Task.isCancelled { return nil }
                    }
                    let res: String?
                    switch id {
                    case "bing": res = await translateViaBingWeb(text: cleanText, toEnglish: toEnglish)
                    case "google": res = await translateViaGoogleFree(text: cleanText, toEnglish: toEnglish)
                    default: res = await translateViaMyMemory(text: cleanText, toEnglish: toEnglish)
                    }
                    return (id, label, res)
                }
            }

            while let item = await group.next() {
                guard let (id, label, res) = item else { continue }
                if let res, !res.isEmpty {
                    store.withLock {
                        switch id {
                        case "bing": store.bingCooldownUntil = .distantPast
                        case "google": store.googleCooldownUntil = .distantPast
                        default: store.myMemoryCooldownUntil = .distantPast
                        }
                    }
                    group.cancelAll()
                    return (label, res)
                } else {
                    let failSec: TimeInterval = (id == "google") ? 600 : (id == "bing" ? 90 : 180)
                    store.withLock {
                        switch id {
                        case "bing": store.bingCooldownUntil = Date().addingTimeInterval(failSec)
                        case "google": store.googleCooldownUntil = Date().addingTimeInterval(failSec)
                        default: store.myMemoryCooldownUntil = Date().addingTimeInterval(failSec)
                        }
                    }
                }
            }
            return nil
        }
    }

    // MARK: - AI Translation & Context Analysis

    nonisolated private static func buildAiTranslateRequest(
        settings: ReaderSettings,
        cleanText: String,
        toEnglish: Bool,
        prevSentence: String?,
        nextSentence: String?,
        bookTitle: String?
    ) -> URLRequest? {
        guard hasAiConfigured(settings) else { return nil }
        let base = settings.aiBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = base.hasSuffix("/chat/completions") ? base : "\(base)/chat/completions"
        guard let url = URL(string: endpoint) else { return nil }

        let model = settings.aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any]
        if model.lowercased().hasPrefix("qwen-mt") {
            body = [
                "model": model,
                "messages": [["role": "user", "content": cleanText]],
                "translation_options": [
                    "source_lang": toEnglish ? "Chinese" : "English",
                    "target_lang": toEnglish ? "English" : "Chinese"
                ]
            ]
        } else {
            let systemPrompt = toEnglish
                ? "你是精通文学与中英互译的专业译者。请结合语境，将给出的中文句子翻译为自然、地道、忠实原意的英文。只输出译文句子本身，不要添加引号、解释、编号或多余说明。"
                : "你是精通英美文学与双语精读的专业译者。请结合语境，将给出的英文句子翻译为信达雅、自然流畅的简体中文。只输出译文句子本身，不要添加引号、注释或多余说明。"

            var userPrompt = ""
            if let bookTitle, !bookTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                userPrompt += "书名：\(bookTitle.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            }
            let prev = prevSentence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let next = nextSentence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !prev.isEmpty || !next.isEmpty {
                userPrompt += "上下文参考（请勿翻译，仅用于理解人称代词、语气与指代）：\n"
                if !prev.isEmpty { userPrompt += "上句：\(prev)\n" }
                if !next.isEmpty { userPrompt += "下句：\(next)\n" }
            }
            userPrompt += "请仅翻译下面这一句：\n\(cleanText)"

            body = [
                "model": model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ],
                "temperature": 0.2,
                "max_tokens": 512
            ]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let key = settings.aiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    nonisolated private static func translateSentenceWithAiDirect(
        settings: ReaderSettings,
        cleanText: String,
        toEnglish: Bool,
        prevSentence: String?,
        nextSentence: String?,
        bookTitle: String?
    ) async -> String? {
        guard let req = buildAiTranslateRequest(
            settings: settings,
            cleanText: cleanText,
            toEnglish: toEnglish,
            prevSentence: prevSentence,
            nextSentence: nextSentence,
            bookTitle: bookTitle
        ) else { return nil }

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }

        var cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("“") && cleaned.hasSuffix("”") && cleaned.count >= 2 {
            cleaned = String(cleaned.dropFirst().dropLast())
        } else if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") && cleaned.count >= 2 {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    nonisolated static func testAiTranslationSpeed(settings: ReaderSettings) async -> Result<(Int64, String), Error> {
        guard hasAiConfigured(settings) else {
            return .failure(NSError(domain: "AI", code: -1, userInfo: [NSLocalizedDescriptionKey: "请先填写 API Key（或本地服务地址）"]))
        }
        let sample = "The quick brown fox jumps over the lazy dog."
        guard let req = buildAiTranslateRequest(
            settings: settings,
            cleanText: sample,
            toEnglish: false,
            prevSentence: nil,
            nextSentence: nil,
            bookTitle: nil
        ) else {
            return .failure(NSError(domain: "AI", code: -1, userInfo: [NSLocalizedDescriptionKey: "AI 配置无效"]))
        }
        let t0 = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let raw = String(decoding: data.prefix(200), as: UTF8.self)
                return .failure(NSError(domain: "AI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(raw)"]))
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                let elapsed = Int64(Date().timeIntervalSince(t0) * 1000)
                return .success((elapsed, content.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            return .failure(NSError(domain: "AI", code: -1, userInfo: [NSLocalizedDescriptionKey: "返回数据解析失败"]))
        } catch {
            return .failure(error)
        }
    }

    nonisolated static func analyzeWithAi(
        settings: ReaderSettings,
        sentence: String,
        targetWord: String? = nil
    ) async -> String {
        if !hasAiConfigured(settings) {
            return "⚠️ 尚未配置 AI API Key。请前往「设置」填写你的 AI 接口信息（Base URL / API Key / Model）。"
        }

        let base = settings.aiBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = base.hasSuffix("/chat/completions") ? base : "\(base)/chat/completions"
        guard let url = URL(string: endpoint) else {
            return "AI Base URL 格式无效"
        }

        let cleanTarget = targetWord?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isChineseContext = TextTokenizer.isPredominantlyChinese(sentence) ||
            (!cleanTarget.isEmpty && TextTokenizer.isPredominantlyChinese(cleanTarget))

        let systemPrompt = isChineseContext
            ? "你是一个博学的中文精读与中英双语辞书助手。请用清晰简洁的中文结合地道英文对照来解析所给词语或句段。"
            : settings.aiSystemPrompt

        let userPrompt: String
        if isChineseContext {
            if !cleanTarget.isEmpty {
                userPrompt = """
                原句："\(sentence)"
                目标词句："\(cleanTarget)"
                请结合原句语境，简明扼要地给出：
                1. 「\(cleanTarget)」的读音、中文含义及对应的地道英文翻译（含词性与常见英文表达）；
                2. 词源、典故或近义辨析（如有）；
                3. 整句的自然英文翻译与白话梳理。
                """
            } else {
                userPrompt = """
                请解读以下中文句段：
                "\(sentence)"
                请简明扼要地给出：
                1. 自然流畅的英文翻译（附 1~3 个句中关键表达的英文对照）；
                2. 核心意思与白话疏解；
                3. 重点字词、修辞或语境意蕴。
                """
            }
        } else if !cleanTarget.isEmpty {
            userPrompt = """
            原句："\(sentence)"
            目标单词："\(cleanTarget)"
            请结合该原句语境，简明扼要地给出：
            1. 「\(cleanTarget)」在句中的确切词义与词性；
            2. 词根词缀或固定搭配；
            3. 整句的自然中文翻译。
            """
        } else {
            userPrompt = """
            请分析以下英文句子：
            "\(sentence)"
            请简明扼要地给出：
            1. 自然流畅的中文翻译；
            2. 句子主干与语法结构拆解；
            3. 句中 1~3 个重点词汇解析。
            """
        }

        let body: [String: Any] = [
            "model": settings.aiModel.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.3
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let key = settings.aiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let raw = String(decoding: data, as: UTF8.self)
                return "AI 接口返回错误 (\(http.statusCode)): \(raw)"
            }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return "未获取到有效回复"
        } catch {
            return "AI 请求失败: \(error.localizedDescription)"
        }
    }

    // MARK: - Online English Definition

    nonisolated static func fetchEnglishDefinition(for word: String) async -> String? {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty,
              let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(encoded)") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = arr.first,
                  let meanings = first["meanings"] as? [[String: Any]] else {
                return nil
            }
            var lines: [String] = []
            for m in meanings.prefix(2) {
                let pos = m["partOfSpeech"] as? String ?? ""
                if let defs = m["definitions"] as? [[String: Any]],
                   let defText = defs.first?["definition"] as? String {
                    lines.append(pos.isEmpty ? defText : "[\(pos)] \(defText)")
                }
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        } catch {
            return nil
        }
    }

    // MARK: - ECDICT & Chinese Dictionary Downloaders

    func startEcdictDownload(db: DatabaseManager) {
        if ecdictState.isDownloading { return }
        ecdictTask?.cancel()
        ecdictState = DictDownloadState(isDownloading: true, message: "正在连接词库镜像源...")
        ecdictTask = Task.detached(priority: .userInitiated) {
            let mirrors: [(String, String)] = [
                ("Statically CDN", "https://cdn.statically.io/gh/skywind3000/ECDICT/master/ecdict.csv"),
                ("GitHub 加速(gh-proxy)", "https://gh-proxy.com/https://raw.githubusercontent.com/skywind3000/ECDICT/master/ecdict.csv"),
                ("GitHub 加速(ghproxy.net)", "https://ghproxy.net/https://raw.githubusercontent.com/skywind3000/ECDICT/master/ecdict.csv"),
                ("GitHub 加速(ghfast)", "https://ghfast.top/https://raw.githubusercontent.com/skywind3000/ECDICT/master/ecdict.csv"),
                ("GitHub Raw", "https://raw.githubusercontent.com/skywind3000/ECDICT/master/ecdict.csv")
            ]

            var errors: [String] = []
            for (name, urlStr) in mirrors {
                if Task.isCancelled { return }
                guard let url = URL(string: urlStr) else { continue }
                await MainActor.run {
                    self.ecdictState = DictDownloadState(
                        isDownloading: true,
                        message: "正在从 \(name) 下载完整 ECDICT 词库（约 63MB）..."
                    )
                }
                do {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 60
                    req.setValue("LocalBookReader-iOS/1.0", forHTTPHeaderField: "User-Agent")
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                        throw NSError(domain: "ECDICT", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
                    }

                    var batch: [DictionaryEntry] = []
                    batch.reserveCapacity(5000)
                    var total = 0
                    var checkedHeader = false

                    for try await line in bytes.lines {
                        if Task.isCancelled { return }
                        if !checkedHeader {
                            checkedHeader = true
                            if !line.lowercased().hasPrefix("word,") {
                                throw NSError(domain: "ECDICT", code: -2, userInfo: [NSLocalizedDescriptionKey: "返回内容非有效 CSV 格式"])
                            }
                            continue
                        }
                        let cols = Self.parseCsvCols(line, maxCols: 4)
                        if cols.count >= 4 {
                            let w = cols[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                            if !w.isEmpty && !w.contains(" ") {
                                let rawP = cols[1].trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                                let p = rawP.isEmpty ? "" : "/\(rawP)/"
                                let t = cols[3].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\n", with: "；")
                                if !t.isEmpty {
                                    batch.append(DictionaryEntry(word: w, phonetic: p, translation: t))
                                    total += 1
                                    if batch.count >= 5000 {
                                        db.bulkInsertDictionary(batch, refreshCounts: false)
                                        batch.removeAll(keepingCapacity: true)
                                        let snap = total
                                        await MainActor.run {
                                            self.ecdictState = DictDownloadState(
                                                isDownloading: true,
                                                message: "正在从 \(name) 导入词库：已写入 \(snap) 词...",
                                                importedCount: snap
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if !batch.isEmpty {
                        db.bulkInsertDictionary(batch, refreshCounts: false)
                    }
                    guard total > 0 else {
                        throw NSError(domain: "ECDICT", code: -3, userInfo: [NSLocalizedDescriptionKey: "未解析到有效词条"])
                    }
                    db.refreshDictionaryCounts()
                    let finalTotal = db.fetchDictionaryCount()
                    let importedSnap = total
                    await MainActor.run {
                        self.ecdictState = DictDownloadState(
                            isDownloading: false,
                            message: "导入成功！本次导入 \(importedSnap) 词，本地词库共 \(finalTotal) 词",
                            importedCount: importedSnap,
                            isError: false
                        )
                    }
                    return
                } catch {
                    errors.append("\(name)(\(error.localizedDescription))")
                }
            }

            let errStr = errors.joined(separator: "；")
            await MainActor.run {
                self.ecdictState = DictDownloadState(
                    isDownloading: false,
                    message: "下载失败：\(errStr)",
                    isError: true
                )
            }
        }
    }

    func deleteEnglishDict(db: DatabaseManager) {
        ecdictTask?.cancel()
        ecdictTask = nil
        Task.detached(priority: .userInitiated) {
            db.deleteEnglishDictionary()
            await MainActor.run {
                self.ecdictState = DictDownloadState(
                    isDownloading: false,
                    message: "已删除完整英文词库并释放空间",
                    importedCount: 0,
                    isError: false
                )
            }
        }
    }

    func startChineseDictDownload(db: DatabaseManager) {
        if chineseDictState.isDownloading { return }
        chineseDictTask?.cancel()
        chineseDictState = DictDownloadState(isDownloading: true, message: "正在连接中文词典镜像源...")
        chineseDictTask = Task.detached(priority: .userInitiated) {
            var totalImported = 0
            var errors: [String] = []

            // 1. ci.csv
            let ciMirrors: [(String, String)] = [
                ("jsDelivr CDN", "https://cdn.jsdelivr.net/gh/pwxcoo/chinese-xinhua@master/data/ci.csv"),
                ("Fastly CDN", "https://fastly.jsdelivr.net/gh/pwxcoo/chinese-xinhua@master/data/ci.csv"),
                ("Statically CDN", "https://cdn.statically.io/gh/pwxcoo/chinese-xinhua/master/data/ci.csv"),
                ("GitHub 加速(gh-proxy)", "https://gh-proxy.com/https://raw.githubusercontent.com/pwxcoo/chinese-xinhua/master/data/ci.csv"),
                ("GitHub Raw", "https://raw.githubusercontent.com/pwxcoo/chinese-xinhua/master/data/ci.csv")
            ]

            do {
                let ciCount = try await Self.downloadCiFromMirrors(ciMirrors, baseCount: totalImported) { batch in
                    db.bulkInsertDictionary(batch, refreshCounts: false)
                } onProgress: { count, msg in
                    await MainActor.run {
                        self.chineseDictState = DictDownloadState(isDownloading: true, message: msg, importedCount: count)
                    }
                }
                totalImported += ciCount
            } catch {
                errors.append("词语库:\(error.localizedDescription)")
            }

            // 2. idiom.json
            let idiomMirrors: [(String, String)] = [
                ("Statically CDN", "https://cdn.statically.io/gh/pwxcoo/chinese-xinhua/master/data/idiom.json"),
                ("GitHub 加速(gh-proxy)", "https://gh-proxy.com/https://raw.githubusercontent.com/pwxcoo/chinese-xinhua/master/data/idiom.json"),
                ("GitHub 加速(ghfast)", "https://ghfast.top/https://raw.githubusercontent.com/pwxcoo/chinese-xinhua/master/data/idiom.json"),
                ("GitHub Raw", "https://raw.githubusercontent.com/pwxcoo/chinese-xinhua/master/data/idiom.json")
            ]

            do {
                let idiomCount = try await Self.downloadIdiomsFromMirrors(idiomMirrors, baseCount: totalImported, db: db) { count, msg in
                    await MainActor.run {
                        self.chineseDictState = DictDownloadState(isDownloading: true, message: msg, importedCount: count)
                    }
                }
                totalImported += idiomCount
            } catch {
                errors.append("成语库:\(error.localizedDescription)")
            }

            // 3. word.json
            let wordMirrors: [(String, String)] = [
                ("Statically CDN", "https://cdn.statically.io/gh/pwxcoo/chinese-xinhua/master/data/word.json"),
                ("GitHub 加速(gh-proxy)", "https://gh-proxy.com/https://raw.githubusercontent.com/pwxcoo/chinese-xinhua/master/data/word.json"),
                ("GitHub 加速(ghfast)", "https://ghfast.top/https://raw.githubusercontent.com/pwxcoo/chinese-xinhua/master/data/word.json"),
                ("GitHub Raw", "https://raw.githubusercontent.com/pwxcoo/chinese-xinhua/master/data/word.json")
            ]

            do {
                let wordCount = try await Self.downloadWordsFromMirrors(wordMirrors, baseCount: totalImported, db: db) { count, msg in
                    await MainActor.run {
                        self.chineseDictState = DictDownloadState(isDownloading: true, message: msg, importedCount: count)
                    }
                }
                totalImported += wordCount
            } catch {
                errors.append("汉字库:\(error.localizedDescription)")
            }

            db.refreshDictionaryCounts()
            let zhTotal = db.fetchChineseDictionaryCount()
            let finalImported = totalImported
            let errStr = errors.joined(separator: "；")
            await MainActor.run {
                if finalImported > 0 {
                    self.chineseDictState = DictDownloadState(
                        isDownloading: false,
                        message: "中文词典导入成功！本次写入 \(finalImported) 条，本地中文词库共 \(zhTotal) 词",
                        importedCount: finalImported,
                        isError: false
                    )
                } else {
                    self.chineseDictState = DictDownloadState(
                        isDownloading: false,
                        message: "下载失败：\(errStr.isEmpty ? "所有中文词典镜像均不可用" : errStr)",
                        isError: true
                    )
                }
            }
        }
    }

    func deleteChineseDict(db: DatabaseManager) {
        chineseDictTask?.cancel()
        chineseDictTask = nil
        Task.detached(priority: .userInitiated) {
            db.deleteChineseDictionary()
            await MainActor.run {
                self.chineseDictState = DictDownloadState(
                    isDownloading: false,
                    message: "已删除完整中文词典并释放空间",
                    importedCount: 0,
                    isError: false
                )
            }
        }
    }

    // MARK: - Private Chinese Dict Helpers

    private struct RawIdiom: Decodable {
        let word: String?
        let pinyin: String?
        let explanation: String?
        let derivation: String?
        let example: String?
    }

    private struct RawHanzi: Decodable {
        let word: String?
        let pinyin: String?
        let radicals: String?
        let strokes: String?
        let explanation: String?
    }

    nonisolated private static func downloadCiFromMirrors(
        _ mirrors: [(String, String)],
        baseCount: Int,
        insertBatch: ([DictionaryEntry]) -> Void,
        onProgress: @Sendable (Int, String) async -> Void
    ) async throws -> Int {
        var errors: [String] = []
        for (name, urlStr) in mirrors {
            guard let url = URL(string: urlStr) else { continue }
            await onProgress(baseCount, "正在从 \(name) 下载 词语库(ci.csv)...")
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 60
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw NSError(domain: "CNDict", code: -1, userInfo: [NSLocalizedDescriptionKey: "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"])
                }
                var batch: [DictionaryEntry] = []
                batch.reserveCapacity(5000)
                var count = 0
                var firstChecked = false

                for try await line in bytes.lines {
                    if !firstChecked {
                        firstChecked = true
                        let low = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if low.hasPrefix("<!doctype") || low.hasPrefix("<html") {
                            throw NSError(domain: "CNDict", code: -2, userInfo: [NSLocalizedDescriptionKey: "返回非 CSV"])
                        }
                        if low == "ci,explanation" || low == "\"ci\",\"explanation\"" { continue }
                    }
                    let cols = parseCsvCols(line, maxCols: 2)
                    if cols.count >= 2 {
                        let w = cols[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        let exp = cols[1].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\n", with: "\n")
                        if !w.isEmpty && !exp.isEmpty && !w.hasPrefix("<") {
                            batch.append(DictionaryEntry(word: w, phonetic: "", translation: exp))
                            count += 1
                            if batch.count >= 5000 {
                                insertBatch(batch)
                                batch.removeAll(keepingCapacity: true)
                                await onProgress(baseCount + count, "正在从 \(name) 导入中文词语：已写入 \(baseCount + count) 词...")
                            }
                        }
                    }
                }
                if !batch.isEmpty { insertBatch(batch) }
                if count > 0 { return count }
            } catch {
                errors.append("\(name)(\(error.localizedDescription))")
            }
        }
        throw NSError(domain: "CNDict", code: -1, userInfo: [NSLocalizedDescriptionKey: errors.joined(separator: "/")])
    }

    nonisolated private static func downloadIdiomsFromMirrors(
        _ mirrors: [(String, String)],
        baseCount: Int,
        db: DatabaseManager,
        onProgress: @Sendable (Int, String) async -> Void
    ) async throws -> Int {
        var errors: [String] = []
        for (name, urlStr) in mirrors {
            guard let url = URL(string: urlStr) else { continue }
            await onProgress(baseCount, "正在从 \(name) 下载 成语库(idiom.json)...")
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 60
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw NSError(domain: "CNDict", code: -1, userInfo: [NSLocalizedDescriptionKey: "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"])
                }
                let items = try JSONDecoder().decode([RawIdiom].self, from: data)
                var batch: [DictionaryEntry] = []
                batch.reserveCapacity(3000)
                var count = 0
                for item in items {
                    let word = (item.word ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let explanation = (item.explanation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !word.isEmpty, !explanation.isEmpty else { continue }
                    var details = explanation
                    if let deriv = item.derivation?.trimmingCharacters(in: .whitespacesAndNewlines), !deriv.isEmpty {
                        details += "\n【出处】\(deriv)"
                    }
                    if let ex = item.example?.trimmingCharacters(in: .whitespacesAndNewlines), !ex.isEmpty {
                        details += "\n【例句】\(ex)"
                    }
                    batch.append(DictionaryEntry(
                        word: word,
                        phonetic: (item.pinyin ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                        translation: details
                    ))
                    count += 1
                    if batch.count >= 3000 {
                        db.bulkInsertDictionary(batch, refreshCounts: false)
                        batch.removeAll(keepingCapacity: true)
                        await onProgress(baseCount + count, "正在从 \(name) 导入成语：已写入 \(baseCount + count) 词...")
                    }
                }
                if !batch.isEmpty { db.bulkInsertDictionary(batch, refreshCounts: false) }
                if count > 0 { return count }
            } catch {
                errors.append("\(name)(\(error.localizedDescription))")
            }
        }
        throw NSError(domain: "CNDict", code: -1, userInfo: [NSLocalizedDescriptionKey: errors.joined(separator: "/")])
    }

    nonisolated private static func downloadWordsFromMirrors(
        _ mirrors: [(String, String)],
        baseCount: Int,
        db: DatabaseManager,
        onProgress: @Sendable (Int, String) async -> Void
    ) async throws -> Int {
        var errors: [String] = []
        for (name, urlStr) in mirrors {
            guard let url = URL(string: urlStr) else { continue }
            await onProgress(baseCount, "正在从 \(name) 下载 汉字库(word.json)...")
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 60
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw NSError(domain: "CNDict", code: -1, userInfo: [NSLocalizedDescriptionKey: "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"])
                }
                let items = try JSONDecoder().decode([RawHanzi].self, from: data)
                var batch: [DictionaryEntry] = []
                batch.reserveCapacity(2000)
                var count = 0
                for item in items {
                    let word = (item.word ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let explanation = (item.explanation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !word.isEmpty, !explanation.isEmpty else { continue }
                    var meta: [String] = []
                    if let p = item.pinyin?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { meta.append(p) }
                    if let r = item.radicals?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty { meta.append("部首:\(r)") }
                    if let s = item.strokes?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { meta.append("\(s)画") }
                    batch.append(DictionaryEntry(
                        word: word,
                        phonetic: meta.joined(separator: " · "),
                        translation: explanation
                    ))
                    count += 1
                    if batch.count >= 2000 {
                        db.bulkInsertDictionary(batch, refreshCounts: false)
                        batch.removeAll(keepingCapacity: true)
                        await onProgress(baseCount + count, "正在从 \(name) 导入汉字：已写入 \(baseCount + count) 词...")
                    }
                }
                if !batch.isEmpty { db.bulkInsertDictionary(batch, refreshCounts: false) }
                if count > 0 { return count }
            } catch {
                errors.append("\(name)(\(error.localizedDescription))")
            }
        }
        throw NSError(domain: "CNDict", code: -1, userInfo: [NSLocalizedDescriptionKey: errors.joined(separator: "/")])
    }

    nonisolated private static func parseCsvCols(_ line: String, maxCols: Int) -> [String] {
        var cols: [String] = []
        cols.reserveCapacity(maxCols)
        var cur = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\"" {
                if inQuotes && i + 1 < chars.count && chars[i + 1] == "\"" {
                    cur.append("\"")
                    i += 1
                } else {
                    inQuotes.toggle()
                }
            } else if ch == "," && !inQuotes {
                cols.append(cur)
                cur = ""
                if cols.count >= maxCols { return cols }
            } else {
                cur.append(ch)
            }
            i += 1
        }
        if cols.count < maxCols { cols.append(cur) }
        return cols
    }

    nonisolated private static func firstRegexGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[r])
    }
}
