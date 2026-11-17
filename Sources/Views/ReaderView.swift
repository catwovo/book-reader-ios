import SwiftUI
import Translation

struct WordCardData: Equatable {
    let word: String
    let lemma: String
    let phonetic: String
    let translation: String
    let lookupCount: Int
    let contextSentence: String
}

struct ReaderView: View {
    @Environment(DatabaseManager.self) private var db
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(SpeechManager.self) private var speech

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

    @State private var sentenceTranslation = ""
    @State private var translatingSentence = false
    @State private var translationConfig: TranslationSession.Configuration?

    @State private var wordCard: WordCardData?
    @State private var aiResult = ""
    @State private var aiLoading = false

    @State private var stageWidth: CGFloat = 340
    @State private var stepTrigger = 0

    private var settings: ReaderSettings { settingsStore.settings }

    private var units: [ReadingUnit] {
        guard chapterIndex >= 0, chapterIndex < parsedBook.chapters.count else { return [] }
        return BookParser.segmentChapter(
            parsedBook.chapters[chapterIndex],
            mode: settings.stepMode,
            fontSize: settings.fontSize,
            maxWidth: Double(max(260, stageWidth - 36))
        )
    }

    private var currentUnit: ReadingUnit? {
        guard unitIndex >= 0, unitIndex < units.count else { return nil }
        return units[unitIndex]
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
        NavigationStack {
            VStack(spacing: 0) {
                let progress = units.isEmpty ? 0.0 : Double(unitIndex + 1) / Double(units.count)
                ProgressView(value: progress)
                    .tint(.accentColor)

                // TOP HALF: Progressive Reading Zone
                GeometryReader { geo in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(unitIndex > 0 ? "↑ 已读滚出：\(units[unitIndex - 1].text)" : "轻触单词查词 · 轻点下半屏推进")
                                .font(.caption2)
                                .foregroundStyle(.secondary.opacity(0.65))
                                .lineLimit(1)

                            let endIdx = min(units.count, unitIndex + 1 + settings.visibleCount)
                            let slice = unitIndex < endIdx ? Array(units[unitIndex..<endIdx]) : []

                            ForEach(Array(slice.enumerated()), id: \.element.id) { idx, unit in
                                let isFocus = idx == 0
                                let rowOpacity = isFocus ? 1.0 : max(0.35, 0.85 - Double(idx - 1) * 0.18)

                                TokenizedLineView(
                                    unit: unit,
                                    fontSize: settings.fontSize,
                                    isFocus: isFocus,
                                    underlineEnabled: settings.underlineLookedUpWords,
                                    lookedUpMap: lookedUpMap,
                                    selectedWord: wordCard?.word,
                                    onWordTap: { token in
                                        lookupWord(token: token, in: unit)
                                    }
                                )
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(isFocus ? Color.accentColor.opacity(0.12) : Color.clear)
                                )
                                .opacity(rowOpacity)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                    }
                    .onAppear { stageWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, newW in stageWidth = newW }
                }
                .frame(maxHeight: .infinity)

                Divider()

                // BOTTOM HALF: Translation / Word / AI Cards + Tap-to-Advance
                ScrollView {
                    VStack(spacing: 12) {
                        // Sentence Translation Card
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("当前句离线翻译", systemImage: "translate")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                Spacer()
                                Button {
                                    noteDraft = ""
                                    showNoteEditor = true
                                } label: {
                                    Label("记笔记", systemImage: "bookmark")
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
                                    Text("Apple 离线翻译中...").font(.footnote).foregroundStyle(.secondary)
                                }
                            } else {
                                Text(sentenceTranslation.isEmpty ? "（已关闭自动翻译，点击「AI 精讲」或开启自动翻译）" : sentenceTranslation)
                                    .font(.subheadline)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        // Word Definition Card
                        if let card = wordCard {
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
                                        .background(Color.accentColor.opacity(0.15))
                                        .clipShape(Capsule())
                                }

                                Text(card.translation)
                                    .font(.subheadline)
                                    .textSelection(.enabled)

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
                            .background(Color.accentColor.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }

                        // AI Explanation Card
                        if aiLoading || !aiResult.isEmpty {
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
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }

                        // Tap Blank Area to Advance
                        VStack(spacing: 4) {
                            Text("轻点此处推进下一\(settings.stepMode == .sentence ? "句" : "行")")
                                .font(.footnote.weight(.medium))
                            Text("向上轻扫退回上一\(settings.stepMode == .sentence ? "句" : "行")")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .frame(height: 110)
                        .contentShape(Rectangle())
                        .onTapGesture { stepNext() }
                    }
                    .padding(16)
                }
                .background(Color(.systemGroupedBackground))
                .contentShape(Rectangle())
                .onTapGesture { stepNext() }
                .gesture(
                    DragGesture(minimumDistance: 36)
                        .onEnded { value in
                            if value.translation.height < -50 {
                                stepPrev()
                            }
                        }
                )
                .frame(maxHeight: .infinity)
            }
            .navigationTitle(book.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onBack()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showTocSheet = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    Button {
                        showPrefsSheet = true
                    } label: {
                        Image(systemName: "textformat.size")
                    }
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: stepTrigger)
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
                chapterIndex = (initialChapter ?? book.currentChapter).clamped(to: 0...max(0, parsedBook.chapters.count - 1))
                unitIndex = max(0, initialUnit ?? book.currentIndex)
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
                            total: max(1, units.count),
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
                                db.updateBookProgress(bookId: book.id, bookTitle: book.title, chapter: idx, index: 0, total: max(1, units.count), deltaSeconds: 0, unitsDelta: 0)
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
                NavigationStack {
                    Form {
                        Section("推进与显示") {
                            Picker("推进粒度", selection: Binding(
                                get: { settings.stepMode },
                                set: { settingsStore.settings.stepMode = $0 }
                            )) {
                                ForEach(StepMode.allCases, id: \.self) { m in
                                    Text(m.displayName).tag(m)
                                }
                            }
                            Stepper("后续显示：+\(settings.visibleCount)", value: Binding(
                                get: { settings.visibleCount },
                                set: { settingsStore.settings.visibleCount = $0 }
                            ), in: 1...8)
                            VStack(alignment: .leading) {
                                Text("正文字号：\(Int(settings.fontSize)) pt")
                                Slider(value: Binding(
                                    get: { settings.fontSize },
                                    set: { settingsStore.settings.fontSize = $0 }
                                ), in: 16...28, step: 1)
                            }
                            Toggle("自动翻译当前焦点句", isOn: Binding(
                                get: { settings.autoTranslateSentence },
                                set: { settingsStore.settings.autoTranslateSentence = $0 }
                            ))
                        }
                    }
                    .navigationTitle("阅读调节")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { showPrefsSheet = false }
                        }
                    }
                }
                .presentationDetents([.medium])
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
    }

    private func focusSentenceText() -> String {
        guard let unit = currentUnit else { return "" }
        return settings.stepMode == .sentence ? unit.text : unit.parentSentence
    }

    private func triggerAutoTranslation() {
        let target = focusSentenceText()
        guard settings.autoTranslateSentence, !target.isEmpty else {
            sentenceTranslation = ""
            return
        }
        if let cached = db.getCachedTranslation(target) {
            sentenceTranslation = cached
            translatingSentence = false
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
        stepTrigger += 1
        wordCard = nil
        aiResult = ""
        if unitIndex + 1 < units.count {
            unitIndex += 1
            db.updateBookProgress(bookId: book.id, bookTitle: book.title, chapter: chapterIndex, index: unitIndex, total: units.count, deltaSeconds: 0, unitsDelta: 1)
        } else if chapterIndex + 1 < parsedBook.chapters.count {
            chapterIndex += 1
            unitIndex = 0
            db.updateBookProgress(bookId: book.id, bookTitle: book.title, chapter: chapterIndex, index: 0, total: max(1, units.count), deltaSeconds: 0, unitsDelta: 1)
        }
    }

    private func stepPrev() {
        guard !units.isEmpty else { return }
        lastInteractionDate = Date()
        stepTrigger += 1
        wordCard = nil
        aiResult = ""
        if unitIndex > 0 {
            unitIndex -= 1
            db.updateBookProgress(bookId: book.id, bookTitle: book.title, chapter: chapterIndex, index: unitIndex, total: units.count, deltaSeconds: 0, unitsDelta: 0)
        } else if chapterIndex > 0 {
            chapterIndex -= 1
            unitIndex = 0
            db.updateBookProgress(bookId: book.id, bookTitle: book.title, chapter: chapterIndex, index: 0, total: max(1, units.count), deltaSeconds: 0, unitsDelta: 0)
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
            lookupCount: saved.lookupCount,
            contextSentence: contextSent
        )
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

private struct TokenizedLineView: View {
    let unit: ReadingUnit
    let fontSize: Double
    let isFocus: Bool
    let underlineEnabled: Bool
    let lookedUpMap: [String: Int]
    let selectedWord: String?
    var onWordTap: (String) -> Void

    var body: some View {
        let tokens = unit.text.components(separatedBy: " ").filter { !$0.isEmpty }
        WordFlowLayout(horizontalSpacing: 5, verticalSpacing: 4) {
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
            rowHeight = max(rowHeight, size.height)
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
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
