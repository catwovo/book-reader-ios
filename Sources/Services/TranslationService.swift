import AVFoundation
import Foundation

@Observable
final class SpeechManager {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.48
        synthesizer.speak(utterance)
    }
}

enum TranslationService {
    static func analyzeWithAi(
        settings: ReaderSettings,
        sentence: String,
        targetWord: String? = nil
    ) async -> String {
        if settings.aiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !settings.aiBaseUrl.contains("localhost"),
           !settings.aiBaseUrl.contains("127.0.0.1"),
           !settings.aiBaseUrl.contains("192.168.") {
            return "⚠️ 尚未配置 AI API Key。请前往「设置」填写你的 AI 接口信息（Base URL / API Key / Model）。"
        }

        let base = settings.aiBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = base.hasSuffix("/chat/completions") ? base : "\(base)/chat/completions"
        guard let url = URL(string: endpoint) else {
            return "AI Base URL 格式无效"
        }

        let userPrompt: String
        if let word = targetWord, !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userPrompt = """
            原句："\(sentence)"
            目标单词："\(word)"
            请结合该原句语境，简明扼要地给出：
            1. 「\(word)」在句中的确切词义与词性；
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
            "model": settings.aiModel,
            "messages": [
                ["role": "system", "content": settings.aiSystemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.3
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if !settings.aiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(settings.aiApiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
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

    static func downloadEcdictMini(into db: DatabaseManager) async throws -> Int {
        let urls = [
            "https://ghfast.top/https://raw.githubusercontent.com/skywind3000/ECDICT/master/ecdict.mini.csv",
            "https://raw.githubusercontent.com/skywind3000/ECDICT/master/ecdict.mini.csv"
        ]

        var csvText = ""
        var lastError: Error?
        for urlStr in urls {
            guard let url = URL(string: urlStr) else { continue }
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 45
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode), data.count > 10_000 {
                    csvText = String(decoding: data, as: UTF8.self)
                    break
                }
            } catch {
                lastError = error
            }
        }

        guard !csvText.isEmpty else {
            throw lastError ?? NSError(domain: "ECDICT", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载词库失败，请检查网络连接"])
        }

        var entries: [DictionaryEntry] = []
        entries.reserveCapacity(15000)
        for (idx, line) in csvText.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let lineStr = String(line)
            if idx == 0 && lineStr.lowercased().hasPrefix("word,") { continue }
            let cols = parseCsvCols(lineStr)
            if cols.count >= 4 {
                let w = cols[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !w.isEmpty, !w.contains(" ") else { continue }
                let rawP = cols[1].trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                let p = rawP.isEmpty ? "" : "/\(rawP)/"
                let t = cols[3].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\n", with: "；")
                if !t.isEmpty {
                    entries.append(DictionaryEntry(word: w, phonetic: p, translation: t))
                }
            }
        }
        db.bulkInsertDictionary(entries)
        return entries.count
    }

    private static func parseCsvCols(_ line: String) -> [String] {
        var cols: [String] = []
        var cur = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == "," && !inQuotes {
                cols.append(cur)
                cur = ""
                if cols.count >= 4 { return cols }
            } else {
                cur.append(ch)
            }
        }
        if cols.count < 4 { cols.append(cur) }
        return cols
    }
}
