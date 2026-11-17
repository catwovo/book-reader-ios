import PDFKit
import SwiftUI
import Translation

struct WordCardData: Equatable {
    let word: String
    let lemma: String
    let phonetic: String
    let translation: String
    var englishTranslation: String
    var englishLoading: Bool
    let lookupCount: Int
    let contextSentence: String
}

struct ReaderView: View {
    @Environment(DatabaseManager.self) private var db
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(SpeechManager.self) private var speech
    @Environment(StepFeedbackPlayer.self) private var feedbackPlayer

    let book: BookItem
    let parsedBook: ParsedBook
    let initialChapter: Int?
    let initialUnit: Int?
    var onBack: () -> Void

    @State private var chapterIndex: Int = 0
    @State private var unitIndex: Int = 0
    @State private var lastInteractionDate = Date()

    @State private var showTocSheet = false
    @State private var showPrefsSheet = false
    @State private var showNoteEditor = false
    @State private var noteDraft = ""

    @State private var pdfOriginalMode = false
    @State private var pdfData: Data? = nil

    @State private var sentenceTranslation = ""
    @State private var translatingSentence = false
    @State private var translationConfig: TranslationSession.Configuration?

    @State private var wordCard: WordCardData?
    @State private var aiResult = ""
    @State private var aiLoading = false

    @State private var stageWidth: CGFloat = 340

    private var settings: ReaderSettings { settingsStore.settings }

    private var units: [ReadingUnit] {
        guard chapterIndex >= 0, chapterIndex < parsedBook.chapters.count else { return [] }
        return BookParser.segmentChapter(
            parsedBook.chapters[chapterIndex],
            mode: settings.stepMode,
            fontSize: settings.fontSize,
            maxWidth: Double(Swift.max(260, stageWidth - 36))
        )
    }

    private var currentUnit: ReadingUnit? {
        guard unitIndex >= 0, unitIndex < units.count else { return nil }
        return units[unitIndex]
    }

    private var currentSentenceNote: SentenceNote? {
        let target = focusSentenceText()
        guard !target.isEmpty else { return nil }
        return db.notes.first(where: { $0.bookId == book.id && $0.sentenceText == target })
    }

    private var lookedUpMap: [String: Int] {
        var map: [String: Int] = [:]
        for v in db.vocabList {
            map[v.word.lowercased()] = v.lookupCount
            if !v.lemma.isEmpty { map[v.lemma.lowercased()] = v.lookupCount }
        }
        return map
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            AmbientGlassBackdrop()

            if pdfOriginalMode, let data = pdfData {
                PdfOriginalPageView(data: data)
                    .ignoresSafeArea()
            } else {
                GeometryReader { totalGeo in
                    let topHeight = totalGeo.size.height * settings.readingZoneRatio
                    let bottomHeight = Swift.max(180, totalGeo.size.height - topHeight)

                    VStack(spacing: 0) {
                        let progress = units.isEmpty ? 0.0 : Double(unitIndex + 1) / Double(units.count)
                        ProgressView(value: progress)
                            .tint(.accentColor)

                        // TOP HALF: Progressive Reading Zone
                        GeometryReader { geo in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 10) {
                                    if settings.readingPositionBias > 0.05 {
                                        Spacer()
                                            .frame(height: Swift.max(0, (topHeight - 160) * settings.readingPositionBias))
                                    }

                                    Text(unitIndex > 0 ? "↑ 已读滚出：\(units[unitIndex - 1].text)" : "轻触单词查词 · 轻点下半屏推进")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary.opacity(0.65))
                                        .lineLimit(1)

                                    let endIdx = Swift.min(units.count, unitIndex + 1 + settings.visibleCount)
                                    let slice = unitIndex < endIdx ? Array(units[unitIndex..<endIdx]) : []

                                    ForEach(Array(slice.enumerated()), id: \.element.id) { idx, unit in
                                        let isFocus = idx == 0
                                        let rowOpacity = isFocus ? 1.0 : Swift.max(0.35, 0.85 - Double(idx - 1) * 0.18)
                                        let focusBg = Color(hexInt64: settings.readerFocusColorHex)
                                            ?? Color.accentColor.opacity(0.14)

                                        TokenizedLineView(
                                            unit: unit,
                                            fontSize: settings.fontSize,
                                            lineSpacing: CGFloat((settings.lineSpacingMultiplier - 1.0) * settings.fontSize),
                                            isFocus: isFocus,
                                            underlineEnabled: settings.underlineLookedUpWords,
                                            lookedUpMap: lookedUpMap,
                                            selectedWord: wordCard?.word,
                                            onWordTap: { token in
                                                lookupWord(token: token, in: unit)
                                            }
                                        )
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background {
                                            if isFocus {
                                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                    .fill(.ultraThinMaterial)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                            .fill(focusBg)
                                                    )
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                            .strokeBorder(.white.opacity(0.35), lineWidth: 0.7)
                                                    )
                                            }
                                        }
                                        .opacity(rowOpacity)
                                    }
                                }
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                            }
                            .onAppear { stageWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, newW in stageWidth = newW }
                        }
                        .frame(height: topHeight)
                        .background(Color(hexInt64: settings.readerBgColorHex) ?? Color.clear)

                        // Glass Divider Pill
                        Capsule()
                            .fill(.secondary.opacity(0.35))
                            .frame(width: 40, height: 4)
                            .padding(.vertical, 4)

                        // BOTTOM HALF: Glass Cards + Tap-to-Advance
                        ScrollView {
                            VStack(spacing: 12) {
                                // Sentence Translation + Inline Note Glass Card
                                GlassCard(
                                    cornerRadius: 18,
                                    tintColor: Color(hexInt64: settings.readerSentenceCardColorHex)
                                ) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Label(
                                                settings.sentenceTranslateEngine == "ai" ? "AI 整句翻译" : "Apple 离线翻译",
                                                systemImage: "translate"
                                            )
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Color.accentColor)
                                            Spacer()
                                            Button {
                                                noteDraft = currentSentenceNote?.noteText ?? ""
                                                showNoteEditor = true
                                            } label: {
                                                Label(currentSentenceNote == nil ? "记笔记" : "已记笔记", systemImage: currentSentenceNote == nil ? "bookmark" : "bookmark.fill")
                                                    .font(.caption)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.mini)

                                            Button {
                                                triggerAiAnalysis(sentence: focusSentenceText(), word: nil)
                                            } label: {
                                                Label("AI 精讲", systemImage: "sparkles")
                                                    .font(.caption)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.mini)
                                        }

                                        if translatingSentence {
                                            HStack(spacing: 8) {
                                                ProgressView().controlSize(.small)
                                                Text("正在翻译...").font(.footnote).foregroundStyle(.secondary)
                                            }
                                        } else {
                                            Text(sentenceTranslation.isEmpty ? "（已关闭自动翻译，点击「AI 精讲」或开启自动翻译）" : sentenceTranslation)
                                                .font(.subheadline)
                                                .textSelection(.enabled)
                                        }

                                        if let savedNote = currentSentenceNote, !savedNote.noteText.isEmpty {
                                            Text("笔记：\(savedNote.noteText)")
                                                .font(.caption)
                                                .padding(8)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(Color.accentColor.opacity(0.10))
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                                .onTapGesture {
                                                    noteDraft = savedNote.noteText
                                                    showNoteEditor = true
                                                }
                                        }
                                    }
                                    .padding(14)
                                }

                                // Word Definition Glass Card (ZH + EN Bilingual)
                                if let card = wordCard {
                                    GlassCard(
                                        cornerRadius: 18,
                                        tintColor: Color(hexInt64: settings.readerWordCardColorHex) ?? Color.accentColor.opacity(0.08)
                                    ) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack {
                                                Text(card.word)
                                                    .font(.title3.bold())
                                                    .foregroundStyle(Color.accentColor)
                                                Text(card.phonetic)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                Button {
                                                    speech.speak(card.word)
                                                } label: {
                                                    Image(systemName: "speaker.wave.2.fill")
                                                        .font(.caption)
                                                }
                                                Spacer()
                                                Text("已查 \(card.lookupCount) 次")
                                                    .font(.caption2.weight(.semibold))
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 3)
                                                    .background(Color.accentColor.opacity(0.16))
                                                    .clipShape(Capsule())
                                            }

                                            Text(card.translation)
                                                .font(.subheadline)
                                                .textSelection(.enabled)

                                            if card.englishLoading {
                                                HStack(spacing: 6) {
                                                    ProgressView().controlSize(.mini)
                                                    Text("获取英文释义...").font(.caption2).foregroundStyle(.secondary)
                                                }
                                            } else if !card.englishTranslation.isEmpty {
                                                Text(card.englishTranslation)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .padding(8)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .background(Color.secondary.opacity(0.08))
                                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                            }

                                            Button {
                                                triggerAiAnalysis(sentence: card.contextSentence, word: card.word)
                                            } label: {
                                                Label("AI 语境释义", systemImage: "sparkles")
                                                    .font(.caption)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
                                        .padding(14)
                                    }
                                }

                                // AI Explanation Glass Card
                                if aiLoading || !aiResult.isEmpty {
                                    GlassCard(cornerRadius: 18) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack {
                                                Label("AI 深度解析", systemImage: "sparkles")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(Color.accentColor)
                                                Spacer()
                                                Button("收起") { aiResult = "" }
                                                    .font(.caption)
                                            }
                                            if aiLoading {
                                                ProgressView().controlSize(.small)
                                            } else {
                                                Text(aiResult)
                                                    .font(.footnote)
                                                    .textSelection(.enabled)
                                            }
                                        }
                                        .padding(14)
                                    }
                                }

                                // Tap Blank Area Left=Prev / Right=Next
                                HStack {
                                    Label("上一\(settings.stepMode == .sentence ? "句" : "行")", systemImage: "chevron.left")
                                    Spacer()
                                    Text("轻点左半屏退回 · 右半屏推进")
                                    Spacer()
                                    Label("下一\(settings.stepMode == .sentence ? "句" : "行")", systemImage: "chevron.right")
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary.opacity(0.65))
                                .padding(.horizontal, 12)
                                .frame(maxWidth: .infinity)
                                .frame(height: 150)
                                .contentShape(Rectangle())
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 76)
                        }
                        .frame(height: bottomHeight)
                        .background(Color(hexInt64: settings.readerBottomBgColorHex) ?? Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { location in
                            if location.x < totalGeo.size.width / 2.0 {
                                stepPrev()
                            } else {
                                stepNext()
                            }
                        }
                    }
                }
            }

            // Floating Apple Liquid Glass Bottom TOC Pill
            HStack(spacing: 16) {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                }

                Divider().frame(height: 16)

                Button {
                    showTocSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet")
                        Text(parsedBook.chapters.getOrNil(chapterIndex)?.title ?? book.title)
                            .lineLimit(1)
                            .frame(maxWidth: 130, alignment: .leading)
                        Text("\(unitIndex + 1)/\(Swift.max(1, units.count))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption.weight(.medium))
                }

                Divider().frame(height: 16)

                if book.format.uppercased() == "PDF" {
                    Button {
                        togglePdfOriginalMode()
                    } label: {
                        Image(systemName: pdfOriginalMode ? "text.alignleft" : "doc.richtext")
                            .font(.subheadline)
                    }
                }

                Button {
                    showPrefsSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.subheadline)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.55), .white.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            }
            .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
            .padding(.bottom, 10)
        }
        .translationTask(translationConfig) { session in
            let target = focusSentenceText()
            guard !target.isEmpty else { return }
            if let cached = db.getCachedTranslation(target) {
                sentenceTranslation = cached
                translatingSentence = false
                return
            }
            do {
                let response = try await session.translate(target)
                db.saveCachedTranslation(source: target, translated: response.targetText)
                sentenceTranslation = response.targetText
            } catch {
                sentenceTranslation = "（请联网首次下载 Apple 英文→中文离线翻译包，或点击「AI 精讲」）"
            }
            translatingSentence = false
        }
        .onAppear {
            chapterIndex = (initialChapter ?? book.currentChapter).clamped(to: 0...Swift.max(0, parsedBook.chapters.count - 1))
            unitIndex = Swift.max(0, initialUnit ?? book.currentIndex)
            triggerAutoTranslation()
        }
        .onChange(of: unitIndex) { _, _ in triggerAutoTranslation() }
        .onChange(of: chapterIndex) { _, _ in triggerAutoTranslation() }
        .task(id: book.id) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Date().timeIntervalSince(lastInteractionDate) <= 60 {
                    db.updateBookProgress(
                        bookId: book.id,
                        bookTitle: book.title,
                        chapter: chapterIndex,
                        index: unitIndex,
                        total: Swift.max(1, units.count),
                        deltaSeconds: 5,
                        unitsDelta: 0
                    )
                }
            }
        }
        .sheet(isPresented: $showTocSheet) {
            NavigationStack {
                List {
                    ForEach(Array(parsedBook.chapters.enumerated()), id: \.offset) { idx, chap in
                        Button {
                            chapterIndex = idx
                            unitIndex = 0
                            db.updateBookProgress(bookId: book.id, bookTitle: book.title, chapter: idx, index: 0, total: Swift.max(1, units.count), deltaSeconds: 0, unitsDelta: 0)
                            showTocSheet = false
                        } label: {
                            HStack {
                                Text(chap.title)
                                    .fontWeight(idx == chapterIndex ? .bold : .regular)
                                Spacer()
                                if idx == chapterIndex {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
                .navigationTitle("章节目录")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { showTocSheet = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showPrefsSheet) {
            ReaderPreferencesSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showNoteEditor) {
            NavigationStack {
                Form {
                    Section("原句摘录") {
                        Text(focusSentenceText()).font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("批注笔记") {
                        TextEditor(text: $noteDraft)
                            .frame(minHeight: 120)
                    }
                }
                .navigationTitle("保存句子笔记")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") { showNoteEditor = false }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") {
                            db.saveSentenceNote(
                                bookId: book.id,
                                bookTitle: book.title,
                                chapterIndex: chapterIndex,
                                unitIndex: unitIndex,
                                sentenceText: focusSentenceText(),
                                sentenceTranslation: sentenceTranslation,
                                noteText: noteDraft
                            )
                            showNoteEditor = false
                        }
                        .bold()
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func togglePdfOriginalMode() {
        if pdfOriginalMode {
            pdfOriginalMode = false
        } else {
            if pdfData == nil {
                pdfData = try? BookParser.loadRawData(for: book)
            }
            if pdfData != nil {
                pdfOriginalMode = true
            }
        }
    }

    private func focusSentenceText() -> String {
        guard let unit = currentUnit else { return "" }
        return settings.stepMode == .sentence ? unit.text : unit.parentSentence
    }

    private func triggerAutoTranslation() {
        let target = focusSentenceText()
        guard !target.isEmpty else { return }

        guard settings.autoTranslateSentence else {
            sentenceTranslation = ""
            return
        }

        if let cached = db.getCachedTranslation(target) {
            sentenceTranslation = cached
            translatingSentence = false
            return
        }

        if settings.sentenceTranslateEngine == "ai" {
            translatingSentence = true
            Task {
                let res = await TranslationService.analyzeWithAi(settings: settings, sentence: target, targetWord: nil)
                db.saveCachedTranslation(source: target, translated: res)
                sentenceTranslation = res
                translatingSentence = false
            }
            return
        }

        translatingSentence = true
        if translationConfig == nil {
            translationConfig = TranslationSession.Configuration(
                source: Locale.Language(identifier: "en"),
                target: Locale.Language(identifier: "zh-Hans")
            )
        } else {
            translationConfig?.invalidate()
        }
    }

    private func stepNext() {
        guard !units.isEmpty else { return }
        lastInteractionDate = Date()
        feedbackPlayer.triggerFeedback(soundTrack: settings.stepSoundTrack, hapticLevel: settings.stepHapticLevel)
        wordCard = nil
        aiResult = ""
        if unitIndex + 1 < units.count {
            unitIndex += 1
            db.updateBookProgress(bookId: book.id, bookTitle: book.title, chapter: chapterIndex, index: unitIndex, total: units.count, deltaSeconds: 0, unitsDelta: 1)
        } else if chapterIndex + 1 < parsedBook.chapters.count {
            chapterIndex += 1
            unitIndex = 0
            db.updateBookProgress(bookId: book.id, bookTitle: book.title, chapter: chapterIndex, index: 0, total: Swift.max(1, units.count), deltaSeconds: 0, unitsDelta: 1)
        }
    }

    private func stepPrev() {
        guard !units.isEmpty else { return }
        lastInteractionDate = Date()
        feedbackPlayer.triggerFeedback(soundTrack: settings.stepSoundTrack, hapticLevel: settings.stepHapticLevel)
        wordCard = nil
        aiResult = ""
        if unitIndex > 0 {
            unitIndex -= 1
            db.updateBookProgress(bookId: book.id, bookTitle: book.title, chapter: chapterIndex, index: unitIndex, total: units.count, deltaSeconds: 0, unitsDelta: 0)
        } else if chapterIndex > 0 {
            chapterIndex -= 1
            unitIndex = 0
            db.updateBookProgress(bookId: book.id, bookTitle: book.title, chapter: chapterIndex, index: 0, total: Swift.max(1, units.count), deltaSeconds: 0, unitsDelta: 0)
        }
    }

    private func lookupWord(token: String, in unit: ReadingUnit) {
        let clean = token.trimmingCharacters(in: CharacterSet.letters.inverted).lowercased()
        guard !clean.isEmpty else { return }
        lastInteractionDate = Date()
        let hit = db.lookupDictionary(word: clean)
        let contextSent = unit.parentSentence.isEmpty ? unit.text : unit.parentSentence
        let saved = db.recordVocabLookup(
            word: clean,
            lemma: hit.lemma,
            phonetic: hit.phonetic,
            translation: hit.translation,
            contextSentence: contextSent,
            contextTranslation: sentenceTranslation,
            bookId: book.id,
            bookTitle: book.title
        )
        wordCard = WordCardData(
            word: saved.word,
            lemma: saved.lemma,
            phonetic: saved.phonetic,
            translation: saved.translation,
            englishTranslation: "",
            englishLoading: true,
            lookupCount: saved.lookupCount,
            contextSentence: contextSent
        )

        Task {
            let enDef = await TranslationService.fetchEnglishDefinition(for: hit.lemma)
            if wordCard?.word == clean {
                wordCard?.englishTranslation = enDef ?? ""
                wordCard?.englishLoading = false
            }
        }

        if settings.autoAiAnalyze {
            triggerAiAnalysis(sentence: contextSent, word: clean)
        }
    }

    private func triggerAiAnalysis(sentence: String, word: String?) {
        lastInteractionDate = Date()
        aiLoading = true
        aiResult = ""
        Task {
            aiResult = await TranslationService.analyzeWithAi(settings: settings, sentence: sentence, targetWord: word)
            aiLoading = false
        }
    }
}

private struct ReaderPreferencesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        @Bindable var store = settingsStore
        NavigationStack {
            Form {
                Section("推进与排版") {
                    Picker("推进粒度", selection: $store.settings.stepMode) {
                        ForEach(StepMode.allCases, id: \.self) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    Stepper("后续显示：+\(store.settings.visibleCount)", value: $store.settings.visibleCount, in: 1...8)
                    VStack(alignment: .leading) {
                        Text("正文字号：\(Int(store.settings.fontSize)) pt")
                        Slider(value: $store.settings.fontSize, in: 16...28, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("行间距倍数：\(String(format: "%.2fx", store.settings.lineSpacingMultiplier))")
                        Slider(value: $store.settings.lineSpacingMultiplier, in: 1.0...1.8, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text("阅读区高度占比：\(Int(store.settings.readingZoneRatio * 100))%")
                        Slider(value: $store.settings.readingZoneRatio, in: 0.25...0.75, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text("焦点垂直位置偏移：\(Int(store.settings.readingPositionBias * 100))%")
                        Slider(value: $store.settings.readingPositionBias, in: 0.0...0.7, step: 0.05)
                    }
                }

                Section("翻译与 AI") {
                    Toggle("自动翻译当前句", isOn: $store.settings.autoTranslateSentence)
                    Picker("整句翻译引擎", selection: $store.settings.sentenceTranslateEngine) {
                        Text("Apple 系统离线").tag("apple")
                        Text("自定义 AI").tag("ai")
                    }
                    Toggle("点词自动 AI 语境解析", isOn: $store.settings.autoAiAnalyze)
                }

                Section("步进音效与震动反馈") {
                    Picker("翻句音效", selection: $store.settings.stepSoundTrack) {
                        ForEach(StepSoundTrack.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    Picker("震动强度", selection: $store.settings.stepHapticLevel) {
                        Text("关闭").tag(0)
                        Text("轻柔").tag(1)
                        Text("适中").tag(2)
                        Text("强烈").tag(3)
                    }
                }
            }
            .navigationTitle("阅读调节")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct PdfOriginalPageView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}

private struct TokenizedLineView: View {
    let unit: ReadingUnit
    let fontSize: Double
    let lineSpacing: CGFloat
    let isFocus: Bool
    let underlineEnabled: Bool
    let lookedUpMap: [String: Int]
    let selectedWord: String?
    var onWordTap: (String) -> Void

    var body: some View {
        let tokens = unit.text.components(separatedBy: " ").filter { !$0.isEmpty }
        WordFlowLayout(horizontalSpacing: 5, verticalSpacing: Swift.max(4, lineSpacing)) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, tok in
                let clean = tok.trimmingCharacters(in: CharacterSet.letters.inverted).lowercased()
                let isKnown = underlineEnabled && (lookedUpMap[clean] ?? 0) > 0
                let isSelected = selectedWord == clean && !clean.isEmpty

                Text(tok)
                    .font(.system(size: fontSize, weight: isFocus ? .medium : .regular, design: .serif))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1)
                    .background(isSelected ? Color.accentColor : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(alignment: .bottom) {
                        if isKnown && !isSelected {
                            Rectangle()
                                .fill(Color.orange.opacity(0.65))
                                .frame(height: 1.5)
                        }
                    }
                    .onTapGesture {
                        onWordTap(tok)
                    }
            }
        }
    }
}

private struct WordFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 4
    var verticalSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            x += size.width + horizontalSpacing
            rowHeight = Swift.max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + horizontalSpacing
            rowHeight = Swift.max(rowHeight, size.height)
        }
    }
}

private extension Array {
    func getOrNil(_ index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
