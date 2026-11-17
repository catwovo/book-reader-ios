import PDFKit
import SwiftUI
#if canImport(Translation)
import Translation
#endif

struct WordCardState: Equatable {
    let word: String
    let lemma: String
    let phonetic: String
    let translation: String
    var englishTranslation: String
    var englishLoading: Bool
    var lookupCount: Int
    let contextSentence: String
    var isSaved: Bool
}

struct ReaderView: View {
    @Environment(DatabaseManager.self) private var db
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(SpeechManager.self) private var speech
    @Environment(StepFeedbackPlayer.self) private var feedbackPlayer
    @Environment(\.appPalette) private var palette
    @Environment(\.scenePhase) private var scenePhase

    let book: BookItem
    let parsedBook: ParsedBook
    let initialChapter: Int?
    let initialUnit: Int?
    var onBack: () -> Void

    // Reading position
    @State private var chapterIndex: Int = 0
    @State private var unitIndex: Int = 0
    @State private var pendingJumpToEnd = false
    @State private var pendingTargetParagraph: Int? = nil
    @State private var stageWidth: CGFloat = 340

    // Progress scrubbing
    @State private var isScrubbingProgress = false
    @State private var scrubFraction: Double = 0

    // Translation & AI
    @State private var appleBridge = AppleTranslationBridge()
    @State private var sentenceTranslation = ""
    @State private var sentenceSource = ""
    @State private var translatingSentence = false
    @State private var sentenceTaskId = 0

    @State private var sentenceAiResult = ""
    @State private var sentenceAiLoading = false
    @State private var sentenceAiCache: [String: String] = [:]

    @State private var wordCard: WordCardState? = nil
    @State private var wordAiResult = ""
    @State private var wordAiLoading = false
    @State private var wordAiCache: [String: String] = [:]
    @State private var wordDefExpanded = false

    // Token cache
    @State private var tokenCache: [String: [TextToken]] = [:]

    // Sheets
    @State private var showTocSheet = false
    @State private var showPrefsSheet = false
    @State private var showNoteSheet = false
    @State private var noteDraft = ""

    // PDF original mode
    @State private var pdfOriginalMode = false
    @State private var pdfData: Data? = nil
    @State private var pdfCurrentPage: Int = 0

    // Active timer & flush state
    @State private var lastInteractionDate = Date()
    @State private var pendingDeltaSeconds: Int64 = 0
    @State private var pendingDeltaUnits: Int = 0

    private var settings: ReaderSettings { settingsStore.settings }

    private var units: [ReadingUnit] {
        guard chapterIndex >= 0, chapterIndex < parsedBook.chapters.count else { return [] }
        return BookParser.segmentChapter(
            parsedBook.chapters[chapterIndex],
            mode: settings.stepMode,
            fontSize: settings.fontSize,
            maxWidth: Double(Swift.max(240, stageWidth - 36))
        )
    }

    private var safeIndex: Int {
        units.isEmpty ? 0 : Swift.min(Swift.max(0, unitIndex), units.count - 1)
    }

    private var currentUnit: ReadingUnit? {
        guard !units.isEmpty else { return nil }
        return units[safeIndex]
    }

    private var targetSentence: String {
        guard let unit = currentUnit else { return "" }
        return (settings.stepMode == .sentence ? unit.text : unit.parentSentence)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var contextNeighbors: (prev: String, next1: String, next2: String) {
        guard !units.isEmpty, !targetSentence.isEmpty else { return ("", "", "") }
        func sentenceOf(_ idx: Int) -> String {
            guard idx >= 0, idx < units.count else { return "" }
            let u = units[idx]
            return (settings.stepMode == .sentence ? u.text : u.parentSentence)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var prev = ""
        if safeIndex > 0 {
            for i in stride(from: safeIndex - 1, through: Swift.max(0, safeIndex - 8), by: -1) {
                let s = sentenceOf(i)
                if !s.isEmpty && s != targetSentence {
                    prev = s
                    break
                }
            }
        }
        var next1 = ""
        var next1Idx = -1
        if safeIndex + 1 < units.count {
            for i in (safeIndex + 1)...Swift.min(units.count - 1, safeIndex + 8) {
                let s = sentenceOf(i)
                if !s.isEmpty && s != targetSentence {
                    next1 = s
                    next1Idx = i
                    break
                }
            }
        }
        var next2 = ""
        if next1Idx >= 0 && next1Idx + 1 < units.count {
            for i in (next1Idx + 1)...Swift.min(units.count - 1, next1Idx + 8) {
                let s = sentenceOf(i)
                if !s.isEmpty && s != next1 && s != targetSentence {
                    next2 = s
                    break
                }
            }
        }
        return (prev, next1, next2)
    }

    private var bookNotes: [SentenceNote] {
        db.notes.filter { $0.bookId == book.id }
    }

    private var currentSentenceNote: SentenceNote? {
        guard !targetSentence.isEmpty else { return nil }
        return bookNotes.first(where: { $0.sentenceText == targetSentence })
    }

    private var lookedUpMap: [String: Int] {
        var map: [String: Int] = [:]
        for v in db.vocabList {
            map[v.word.lowercased()] = v.lookupCount
            if !v.lemma.isEmpty { map[v.lemma.lowercased()] = v.lookupCount }
        }
        return map
    }

    // Custom colors with fallback to theme palette / Liquid Glass
    private var customReaderBg: Color? { Color(hexInt64: settings.readerBgColorHex) }
    private var customFocusBg: Color? { Color(hexInt64: settings.readerFocusColorHex) }
    private var customBottomBg: Color? { Color(hexInt64: settings.readerBottomBgColorHex) }
    private var customSentenceCardBg: Color? { Color(hexInt64: settings.readerSentenceCardColorHex) }
    private var customWordCardBg: Color? { Color(hexInt64: settings.readerWordCardColorHex) }

    private var readerTextColor: Color {
        customReaderBg?.contrastingTextColor ?? .primary
    }
    private var readerSecondaryColor: Color {
        customReaderBg?.contrastingSecondaryTextColor ?? .secondary
    }
    private var focusTextColor: Color {
        (customFocusBg ?? customReaderBg)?.contrastingTextColor ?? .primary
    }
    private var focusSecondaryColor: Color {
        (customFocusBg ?? customReaderBg)?.contrastingSecondaryTextColor ?? .secondary
    }
    private var bottomSecondaryColor: Color {
        customBottomBg?.contrastingSecondaryTextColor ?? .secondary
    }
    private var sentenceCardTextColor: Color {
        customSentenceCardBg?.contrastingTextColor ?? .primary
    }
    private var sentenceCardSecondaryColor: Color {
        customSentenceCardBg?.contrastingSecondaryTextColor ?? .secondary
    }
    private var wordCardTextColor: Color {
        customWordCardBg?.contrastingTextColor ?? .primary
    }
    private var wordCardSecondaryColor: Color {
        customWordCardBg?.contrastingSecondaryTextColor ?? .secondary
    }

    var body: some View {
        ZStack {
            AmbientGlassBackdrop(themeMode: settings.themeMode)

            if parsedBook.isImageOnlyPdf && parsedBook.pageCount > 0 {
                pdfImageReaderView(isForcedImageOnly: true)
            } else if pdfOriginalMode, let data = pdfData {
                pdfImageReaderView(isForcedImageOnly: false, preloadedData: data)
            } else {
                reflowableReaderView
            }
        }
        #if canImport(Translation)
        .translationTask(appleBridge.configuration) { session in
            await appleBridge.handleSession(session)
        }
        #endif
        .onAppear {
            syncFeedbackConfig()
            let maxChap = Swift.max(0, parsedBook.chapters.count - 1)
            chapterIndex = Swift.min(Swift.max(0, initialChapter ?? book.currentChapter), maxChap)
            unitIndex = Swift.max(0, initialUnit ?? book.currentIndex)
            pdfCurrentPage = Swift.min(Swift.max(0, book.currentIndex), Swift.max(0, parsedBook.pageCount - 1))
            if parsedBook.isImageOnlyPdf && parsedBook.pageCount > 0 {
                pdfData = try? BookParser.loadRawData(for: book)
            }
            db.recordReadingLog(bookId: book.id, bookTitle: book.title, deltaSeconds: 0, unitsDelta: 0, lookupsDelta: 0)
            pretokenizeAround(index: safeIndex)
        }
        .onDisappear {
            flushProgressNow()
            feedbackPlayer.pauseAll()
            speech.stop()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                flushProgressNow()
                feedbackPlayer.pauseAll()
            }
        }
        .onChange(of: settings.stepSoundTrack) { _, _ in syncFeedbackConfig() }
        .onChange(of: settings.stepNoteIntervalMs) { _, _ in syncFeedbackConfig() }
        .onChange(of: settings.stepHapticLevel) { _, _ in syncFeedbackConfig() }
        .onChange(of: settings.stepHapticMode) { _, _ in syncFeedbackConfig() }
        .onChange(of: chapterIndex) { _, _ in
            resolvePendingUnitAdjustments()
            pretokenizeAround(index: safeIndex)
        }
        .onChange(of: safeIndex) { _, idx in
            pretokenizeAround(index: idx)
        }
        .task(id: "\(book.id)-\(chapterIndex)-\(safeIndex)-\(settings.autoTranslateSentence)-\(settings.sentenceTranslateEngine)-\(settings.aiModel)-\(settings.aiBaseUrl)-\(settings.aiApiKey)-\(sentenceTaskId)") {
            await loadSentenceTranslation(forceRefresh: false)
        }
        .task(id: "\(book.id)-ai-sent-\(settings.autoAiAnalyze)-\(targetSentence)-\(settings.aiModel)") {
            await loadAutoSentenceAi()
        }
        .task(id: "\(book.id)-ai-word-\(settings.autoAiAnalyze)-\(wordCard?.word ?? "")-\(wordCard?.contextSentence ?? "")-\(settings.aiModel)") {
            await loadAutoWordAi()
        }
        .task(id: book.id) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if scenePhase == .active && Date().timeIntervalSince(lastInteractionDate) <= 60 {
                    pendingDeltaSeconds += 5
                    if pendingDeltaSeconds >= 15 {
                        flushProgressNow()
                    }
                }
            }
        }
        .sheet(isPresented: $showTocSheet) {
            ReaderTocAndNotesSheet(
                parsedBook: parsedBook,
                chapterIndex: chapterIndex,
                currentParagraphIndex: currentUnit?.paragraphIndex ?? 0,
                currentPdfPage: pdfCurrentPage,
                isPdfImageMode: parsedBook.isImageOnlyPdf || pdfOriginalMode,
                bookNotes: bookNotes,
                onSelectToc: { entry in
                    if parsedBook.isImageOnlyPdf || pdfOriginalMode {
                        pdfCurrentPage = Swift.min(Swift.max(0, entry.paragraphIndex), Swift.max(0, parsedBook.pageCount - 1))
                        savePdfPageProgress(pdfCurrentPage, immediate: true)
                    } else {
                        let targetChap = Swift.min(Swift.max(0, entry.chapterIndex), Swift.max(0, parsedBook.chapters.count - 1))
                        let targetPara = Swift.max(0, entry.paragraphIndex)
                        if targetChap == chapterIndex && !units.isEmpty {
                            let hit = units.firstIndex(where: { $0.paragraphIndex >= targetPara }) ?? 0
                            pendingTargetParagraph = nil
                            unitIndex = hit
                            queueProgress(chapter: targetChap, index: hit, immediate: true)
                        } else {
                            pendingTargetParagraph = targetPara > 0 ? targetPara : nil
                            chapterIndex = targetChap
                            unitIndex = 0
                            queueProgress(chapter: targetChap, index: 0, immediate: true)
                        }
                        clearWordCard()
                    }
                    showTocSheet = false
                },
                onSelectNote: { note in
                    if pdfOriginalMode { pdfOriginalMode = false }
                    let targetChap = Swift.min(Swift.max(0, note.chapterIndex), Swift.max(0, parsedBook.chapters.count - 1))
                    chapterIndex = targetChap
                    unitIndex = Swift.max(0, note.unitIndex)
                    clearWordCard()
                    queueProgress(chapter: targetChap, index: Swift.max(0, note.unitIndex), immediate: true)
                    showTocSheet = false
                }
            )
        }
        .sheet(isPresented: $showPrefsSheet) {
            ReaderPreferencesSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showNoteSheet) {
            noteEditorSheet
                .presentationDetents([.medium])
        }
    }

    // MARK: - Reflowable Reader View

    private var reflowableReaderView: some View {
        GeometryReader { totalGeo in
            let safeZoneRatio = Swift.min(0.75, Swift.max(0.25, settings.readingZoneRatio))
            let topZoneHeight = totalGeo.size.height * safeZoneRatio

            VStack(spacing: 0) {
                // Top Glass Bar
                readerTopBar
                    .background(customReaderBg ?? Color.clear)

                // Interactive Chapter Scrubber Bar
                chapterScrubberBar
                    .background(customReaderBg ?? Color.clear)

                // TOP HALF: Progressive Reading Zone
                ZStack(alignment: .top) {
                    (customReaderBg ?? Color.clear)

                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            let prevStart = Swift.max(0, safeIndex - Swift.max(settings.visibleCount, 5))
                            let endIdx = Swift.min(units.count, safeIndex + 1 + settings.visibleCount)
                            let windowUnits = prevStart < endIdx ? Array(units[prevStart..<endIdx]) : []
                            let lineGap = CGFloat((settings.lineSpacingMultiplier - 1.0) * 5.0)
                            let unitGap = CGFloat((settings.lineSpacingMultiplier - 1.0) * 14.0 + 6.0)

                            VStack(alignment: .leading, spacing: unitGap) {
                                // Extra vertical spacer padding so ScrollViewReader can center/top/bottom focus smoothly
                                Color.clear
                                    .frame(height: Swift.max(12, topZoneHeight * 0.42 * settings.readingPositionBias))

                                ForEach(windowUnits) { unit in
                                    let dist = abs(unit.index - safeIndex)
                                    let isFocus = dist == 0
                                    let targetAlpha = isFocus ? 1.0 : Swift.max(0.08, 0.34 * pow(0.60, Double(dist - 1)))
                                    let focusFill = customFocusBg ?? palette.accent.opacity(0.14)

                                    TokenizedUnitTextView(
                                        tokens: tokensFor(unit.text),
                                        fontSize: settings.fontSize,
                                        lineSpacing: Swift.max(3, lineGap),
                                        isFocus: isFocus,
                                        underlineEnabled: settings.underlineLookedUpWords,
                                        lookedUpMap: lookedUpMap,
                                        selectedWord: wordCard?.word,
                                        textColor: isFocus ? focusTextColor : readerTextColor,
                                        accentColor: palette.accent,
                                        onWordTap: { token in
                                            lookupWord(rawToken: token, unit: unit)
                                        }
                                    )
                                    .padding(.horizontal, isFocus ? 14 : 8)
                                    .padding(.vertical, isFocus ? 10 : 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background {
                                        if isFocus {
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .fill(.ultraThinMaterial)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                        .fill(focusFill)
                                                )
                                                .overlay(alignment: .leading) {
                                                    Capsule()
                                                        .fill(palette.accent.opacity(0.85))
                                                        .frame(width: 3.5)
                                                        .padding(.vertical, 9)
                                                        .padding(.leading, 5)
                                                }
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                        .strokeBorder(
                                                            customFocusBg != nil ? focusTextColor.opacity(0.15) : palette.accent.opacity(0.28),
                                                            lineWidth: 0.75
                                                        )
                                                )
                                        }
                                    }
                                    .opacity(targetAlpha)
                                    .scaleEffect(isFocus ? 1.0 : 0.99, anchor: .leading)
                                    .id(unit.index)
                                }

                                Color.clear
                                    .frame(height: Swift.max(24, topZoneHeight * 0.45))
                            }
                            .padding(.horizontal, 16)
                        }
                        .onAppear {
                            stageWidth = totalGeo.size.width
                            scrollToFocus(proxy: proxy, animated: false)
                        }
                        .onChange(of: totalGeo.size.width) { _, newW in
                            stageWidth = newW
                        }
                        .onChange(of: safeIndex) { _, _ in
                            scrollToFocus(proxy: proxy, animated: true)
                        }
                        .onChange(of: chapterIndex) { _, _ in
                            scrollToFocus(proxy: proxy, animated: false)
                        }
                        .onChange(of: settings.readingPositionBias) { _, _ in
                            scrollToFocus(proxy: proxy, animated: true)
                        }
                    }

                    // Scrubbing floating preview capsule
                    if isScrubbingProgress && !units.isEmpty {
                        let targetIdx = scrubTargetIndex()
                        let pct = Int(((Double(targetIdx + 1) / Double(units.count)) * 100.0).rounded())
                        let snippet = units[targetIdx].text
                        GlassCard(cornerRadius: 16) {
                            VStack(spacing: 2) {
                                Text("第 \(targetIdx + 1) / \(units.count) · \(pct)%")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(palette.accent)
                                if !snippet.isEmpty {
                                    Text(snippet)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        .transition(.opacity)
                    }
                }
                .frame(height: topZoneHeight)
                .clipped()

                Divider()
                    .opacity(0.35)

                // BOTTOM HALF: Translation + Word Card + Tap-to-Step + Floating TOC Dock
                ZStack(alignment: .bottom) {
                    (customBottomBg ?? Color.clear)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 8) {
                            sentenceTranslationCard

                            if let card = wordCard {
                                wordDefinitionCard(card)
                                    .transition(AppMotion.cardTransition)
                            }

                            // Compact tap-to-step hint area
                            Text("‹ 轻点左侧上一句 · 轻点右侧下一句 ›")
                                .font(.caption2)
                                .foregroundStyle(bottomSecondaryColor.opacity(0.55))
                                .padding(.top, 8)
                                .padding(.bottom, 64)
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .frame(minHeight: Swift.max(220, totalGeo.size.height - topZoneHeight - 60), alignment: .top)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            if location.x < totalGeo.size.width / 2.0 {
                                stepPrev()
                            } else {
                                stepNext()
                            }
                        }
                    }

                    // Floating Liquid Glass Bottom TOC Pill
                    Button {
                        showTocSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "list.bullet")
                                .font(.caption.weight(.semibold))
                            Text("目录 · \(chapterIndex + 1)/\(Swift.max(1, parsedBook.chapters.count))")
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                        }
                        .foregroundStyle(customBottomBg != nil ? customBottomBg!.contrastingTextColor : .primary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(.white.opacity(0.38), lineWidth: 0.75)
                        }
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    }
                    .buttonStyle(GlassPressButtonStyle())
                    .padding(.bottom, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Top Bar & Scrubber

    private var readerTopBar: some View {
        HStack(spacing: 10) {
            Button {
                flushProgressNow()
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(readerTextColor)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(book.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(readerTextColor)
                    .lineLimit(1)
                Text(parsedBook.chapters.indices.contains(chapterIndex) ? parsedBook.chapters[chapterIndex].title : "")
                    .font(.caption2)
                    .foregroundStyle(readerSecondaryColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(safeIndex + 1) / \(Swift.max(1, units.count))")
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(readerSecondaryColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(readerTextColor.opacity(0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(readerTextColor.opacity(0.10), lineWidth: 0.5))

            if book.format.uppercased() == "PDF" {
                Button {
                    togglePdfOriginalMode()
                } label: {
                    Image(systemName: "doc.richtext")
                        .font(.subheadline)
                        .foregroundStyle(readerTextColor)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }

            Button {
                showPrefsSheet = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.subheadline)
                    .foregroundStyle(readerTextColor)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var chapterScrubberBar: some View {
        let chapterProgress = units.isEmpty ? 0.0 : Double(safeIndex + 1) / Double(units.count)
        let visualProgress = isScrubbingProgress ? scrubFraction : chapterProgress

        return GeometryReader { geo in
            let w = Swift.max(1, geo.size.width)
            let barH: CGFloat = isScrubbingProgress ? 5.5 : 2.5
            let fillW = Swift.min(w, Swift.max(0, w * visualProgress))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(readerTextColor.opacity(0.12))
                    .frame(height: barH)

                Capsule()
                    .fill(palette.accent)
                    .frame(width: fillW, height: barH)

                if isScrubbingProgress {
                    Circle()
                        .fill(palette.accent)
                        .frame(width: 13, height: 13)
                        .shadow(color: palette.accent.opacity(0.35), radius: 4)
                        .offset(x: Swift.min(w - 13, Swift.max(0, fillW - 6.5)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard units.count > 1 else { return }
                        if !isScrubbingProgress {
                            withAnimation(.easeOut(duration: 0.14)) {
                                isScrubbingProgress = true
                            }
                        }
                        scrubFraction = Swift.min(1.0, Swift.max(0.0, Double(value.location.x / w)))
                    }
                    .onEnded { _ in
                        if units.count > 1 {
                            let targetIdx = scrubTargetIndex()
                            if targetIdx != safeIndex {
                                lastInteractionDate = Date()
                                clearWordCard()
                                unitIndex = targetIdx
                                queueProgress(chapter: chapterIndex, index: targetIdx, immediate: true)
                            }
                        }
                        withAnimation(.easeOut(duration: 0.14)) {
                            isScrubbingProgress = false
                        }
                    }
            )
        }
        .frame(height: 22)
        .padding(.horizontal, 16)
    }

    private func scrubTargetIndex() -> Int {
        guard units.count > 1 else { return 0 }
        let idx = Int((Swift.min(1.0, Swift.max(0.0, scrubFraction)) * Double(units.count - 1)).rounded())
        return Swift.min(units.count - 1, Swift.max(0, idx))
    }

    // MARK: - Sentence Translation Card

    private var sentenceTranslationCard: some View {
        let currentNote = currentSentenceNote
        let isStarred = currentNote != nil
        let hasNoteText = !(currentNote?.noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let isErrorSrc = sentenceSource.contains("失败") || sentenceSource.contains("未就绪")

        return GlassCard(cornerRadius: 20, tintColor: customSentenceCardBg) {
            VStack(alignment: .leading, spacing: 8) {
                if translatingSentence {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在翻译当前句...")
                            .font(.caption)
                            .foregroundStyle(sentenceCardSecondaryColor)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sentenceCardTextColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Text(sentenceTranslation.isEmpty ? "已关闭自动翻译" : sentenceTranslation)
                        .font(.subheadline)
                        .lineSpacing(4)
                        .foregroundStyle(sentenceCardTextColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Controls row
                HStack(spacing: 6) {
                    if !settings.autoTranslateSentence && sentenceTranslation.isEmpty && !translatingSentence {
                        Button {
                            Task {
                                await loadSentenceTranslation(forceRefresh: true, ignoreAutoSetting: true)
                            }
                        } label: {
                            Text("点击翻译")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(palette.accent.opacity(0.16), in: Capsule())
                                .foregroundStyle(palette.accent)
                        }
                        .buttonStyle(.plain)
                    } else if !translatingSentence && !sentenceTranslation.isEmpty && !sentenceSource.isEmpty {
                        MinimalTagPill(
                            text: sentenceSource,
                            tintColor: isErrorSrc ? Color.red.opacity(0.14) : sentenceCardTextColor.opacity(0.07),
                            textColor: isErrorSrc ? .red : sentenceCardSecondaryColor
                        )
                    }

                    Spacer()

                    if !settings.autoAiAnalyze && !targetSentence.isEmpty {
                        Button {
                            Task { await triggerManualSentenceAi() }
                        } label: {
                            Label("AI 精讲", systemImage: "sparkles")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(palette.accent.opacity(0.14), in: Capsule())
                                .foregroundStyle(palette.accent)
                        }
                        .buttonStyle(.plain)
                    }

                    if !sentenceTranslation.isEmpty && !translatingSentence && !targetSentence.isEmpty {
                        Button {
                            Task {
                                await loadSentenceTranslation(forceRefresh: true, ignoreAutoSetting: true)
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(sentenceCardSecondaryColor)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // Bookmark star
                    Button {
                        toggleSentenceBookmark()
                    } label: {
                        Image(systemName: isStarred ? "star.fill" : "star")
                            .font(.subheadline)
                            .foregroundStyle(isStarred ? palette.accent : sentenceCardSecondaryColor)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Edit note button
                    Button {
                        if !targetSentence.isEmpty {
                            noteDraft = currentNote?.noteText ?? ""
                            showNoteSheet = true
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.subheadline)
                            .foregroundStyle(hasNoteText ? palette.accent : sentenceCardSecondaryColor)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Inline saved note
                if let saved = currentNote, !saved.noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        noteDraft = saved.noteText
                        showNoteSheet = true
                    } label: {
                        Text("笔记：\(saved.noteText)")
                            .font(.caption)
                            .foregroundStyle(sentenceCardTextColor)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(palette.accent.opacity(0.20), lineWidth: 0.6)
                            )
                    }
                    .buttonStyle(.plain)
                    .transition(AppMotion.panelTransition)
                }

                // Inline Sentence AI Analysis
                if sentenceAiLoading || !sentenceAiResult.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("AI 上下文解析", systemImage: "sparkles")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(palette.accent)
                            Spacer()
                            if !settings.autoAiAnalyze && !sentenceAiLoading {
                                Button("收起") {
                                    sentenceAiResult = ""
                                }
                                .font(.caption2)
                            }
                        }
                        if sentenceAiLoading {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("AI 正在分析上下文...")
                                    .font(.caption)
                                    .foregroundStyle(sentenceCardSecondaryColor)
                            }
                        } else {
                            Text(sentenceAiResult)
                                .font(.footnote)
                                .lineSpacing(4)
                                .foregroundStyle(sentenceCardTextColor)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sentenceCardTextColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(sentenceCardTextColor.opacity(0.08), lineWidth: 0.6)
                    )
                    .transition(AppMotion.panelTransition)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Word Definition Card

    private func wordDefinitionCard(_ card: WordCardState) -> some View {
        let formattedTrans = card.translation
            .replacingOccurrences(of: "\n\n+", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return GlassCard(cornerRadius: 20, tintColor: customWordCardBg) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(card.word)
                        .font(.title3.bold())
                        .foregroundStyle(palette.accent)

                    if !card.phonetic.isEmpty {
                        MinimalTagPill(
                            text: card.phonetic,
                            tintColor: wordCardTextColor.opacity(0.07),
                            textColor: wordCardSecondaryColor
                        )
                    }

                    Button {
                        speech.speak(card.word)
                    } label: {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption)
                            .foregroundStyle(palette.accent)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)

                    if card.isSaved {
                        MinimalTagPill(
                            text: "×\(card.lookupCount)",
                            tintColor: palette.accent.opacity(0.16),
                            textColor: palette.accent
                        )
                    }

                    Spacer()

                    if !settings.autoAiAnalyze {
                        Button {
                            Task { await triggerManualWordAi(card: card) }
                        } label: {
                            Image(systemName: "sparkles")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(palette.accent)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        toggleWordBookmark(card)
                    } label: {
                        Image(systemName: card.isSaved ? "star.fill" : "star")
                            .font(.subheadline)
                            .foregroundStyle(card.isSaved ? palette.accent : wordCardSecondaryColor)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Bilingual EN block
                if card.englishLoading || !card.englishTranslation.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Text("EN")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(palette.secondaryAccent, in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                        if card.englishLoading && card.englishTranslation.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("英文释义查询中...")
                                    .font(.caption)
                                    .foregroundStyle(wordCardSecondaryColor)
                            }
                        } else {
                            Text(card.englishTranslation)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(wordCardTextColor)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(wordCardTextColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                // Primary translation
                Text(formattedTrans)
                    .font(.subheadline)
                    .lineSpacing(3)
                    .foregroundStyle(wordCardTextColor)
                    .lineLimit(wordDefExpanded ? nil : 4)
                    .textSelection(.enabled)
                    .onTapGesture {
                        withAnimation(AppMotion.panelSpring) {
                            wordDefExpanded.toggle()
                        }
                    }

                if formattedTrans.count > 120 {
                    Button(wordDefExpanded ? "收起" : "展开全部") {
                        withAnimation(AppMotion.panelSpring) {
                            wordDefExpanded.toggle()
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .buttonStyle(.plain)
                }

                // Word AI Analysis
                if wordAiLoading || !wordAiResult.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if wordAiLoading {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("AI 正在分析语境...")
                                    .font(.caption)
                                    .foregroundStyle(wordCardSecondaryColor)
                            }
                        } else {
                            Text(wordAiResult)
                                .font(.footnote)
                                .lineSpacing(4)
                                .foregroundStyle(wordCardTextColor)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(wordCardTextColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(AppMotion.panelTransition)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
        }
    }

    // MARK: - PDF Original / Image-Only Reader

    @ViewBuilder
    private func pdfImageReaderView(isForcedImageOnly: Bool, preloadedData: Data? = nil) -> some View {
        let totalPages = Swift.max(1, parsedBook.pageCount)
        let dataToRender = preloadedData ?? pdfData

        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 10) {
                Button {
                    flushProgressNow()
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 1) {
                    Text(book.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("第 \(pdfCurrentPage + 1) / \(totalPages) 页")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !isForcedImageOnly {
                    Button {
                        pdfOriginalMode = false
                    } label: {
                        Label("精读排版", systemImage: "text.alignleft")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    showTocSheet = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.subheadline)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            if let dataToRender {
                PdfOriginalPageView(data: dataToRender, currentPage: $pdfCurrentPage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: pdfCurrentPage) { _, newPage in
                        lastInteractionDate = Date()
                        savePdfPageProgress(newPage, immediate: false)
                    }
            } else {
                Spacer()
                Text("未能加载 PDF 原文档")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            // Bottom page controls
            HStack(spacing: 12) {
                Button {
                    if pdfCurrentPage > 0 {
                        pdfCurrentPage -= 1
                        feedbackPlayer.playStep(noteCount: 1)
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(pdfCurrentPage <= 0)

                if totalPages > 1 {
                    Slider(
                        value: Binding(
                            get: { Double(pdfCurrentPage) },
                            set: { pdfCurrentPage = Int($0.rounded()) }
                        ),
                        in: 0...Double(totalPages - 1),
                        step: 1
                    )
                    .tint(palette.accent)
                } else {
                    Spacer()
                }

                Button {
                    if pdfCurrentPage + 1 < totalPages {
                        pdfCurrentPage += 1
                        feedbackPlayer.playStep(noteCount: 1)
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(pdfCurrentPage + 1 >= totalPages)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Note Editor Sheet

    private var noteEditorSheet: some View {
        let existing = currentSentenceNote
        return NavigationStack {
            Form {
                Section("原句摘录") {
                    Text(targetSentence)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("我的想法 / 批注") {
                    TextEditor(text: $noteDraft)
                        .frame(minHeight: 120)
                }
                if let existing {
                    Section {
                        Button("取消收藏并删除笔记", role: .destructive) {
                            db.deleteNote(id: existing.id)
                            showNoteSheet = false
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "收藏并添加笔记" : "编辑句子笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { showNoteSheet = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        saveCurrentSentenceNote(noteText: noteDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                        showNoteSheet = false
                    }
                    .bold()
                }
            }
        }
    }

    // MARK: - Actions & Logic

    private func syncFeedbackConfig() {
        feedbackPlayer.configure(
            track: settings.stepSoundTrack,
            intervalMs: settings.stepNoteIntervalMs,
            hapticLevel: settings.stepHapticLevel,
            hapticMode: settings.stepHapticMode
        )
    }

    private func scrollToFocus(proxy: ScrollViewProxy, animated: Bool) {
        guard !units.isEmpty else { return }
        let anchor = UnitPoint(x: 0.5, y: Swift.min(1.0, Swift.max(0.0, settings.readingPositionBias)))
        if animated {
            withAnimation(AppMotion.panelSpring) {
                proxy.scrollTo(safeIndex, anchor: anchor)
            }
        } else {
            proxy.scrollTo(safeIndex, anchor: anchor)
        }
    }

    private func tokensFor(_ text: String) -> [TextToken] {
        if let hit = tokenCache[text] { return hit }
        let computed = TextTokenizer.tokenizeMixedText(text)
        return computed
    }

    private func pretokenizeAround(index: Int) {
        guard !units.isEmpty else { return }
        let start = Swift.max(0, index - Swift.max(settings.visibleCount, 5) - 4)
        let end = Swift.min(units.count, index + 1 + settings.visibleCount + 16)
        var added = 0
        for i in start..<end {
            let t = units[i].text
            if tokenCache[t] == nil {
                tokenCache[t] = TextTokenizer.tokenizeMixedText(t)
                added += 1
            }
        }
        if tokenCache.count > 420 && added > 0 {
            let keys = Array(tokenCache.keys.prefix(120))
            for k in keys { tokenCache.removeValue(forKey: k) }
        }
    }

    private func resolvePendingUnitAdjustments() {
        guard !units.isEmpty else { return }
        if pendingJumpToEnd {
            pendingJumpToEnd = false
            pendingTargetParagraph = nil
            unitIndex = units.count - 1
        } else if let targetPara = pendingTargetParagraph {
            pendingTargetParagraph = nil
            unitIndex = units.firstIndex(where: { $0.paragraphIndex >= targetPara }) ?? 0
        } else if unitIndex >= units.count {
            unitIndex = units.count - 1
        }
    }

    private func clearWordCard() {
        wordCard = nil
        wordAiResult = ""
        wordAiLoading = false
        wordDefExpanded = false
    }

    private func estimateVisualLineCount(for text: String) -> Int {
        guard !text.isEmpty else { return 1 }
        let approxCharsPerLine = Swift.max(18.0, (Double(stageWidth) - 54.0) / (settings.fontSize * 0.62))
        let count = Int(ceil(Double(text.count) / approxCharsPerLine))
        return Swift.min(6, Swift.max(1, count))
    }

    private func stepNext() {
        guard !units.isEmpty else { return }
        lastInteractionDate = Date()
        clearWordCard()

        if safeIndex + 1 < units.count {
            let target = units[safeIndex + 1]
            withAnimation(AppMotion.panelSpring) {
                unitIndex = safeIndex + 1
            }
            feedbackPlayer.playStep(noteCount: estimateVisualLineCount(for: target.text))
            queueProgress(chapter: chapterIndex, index: safeIndex + 1, deltaUnits: 1)
        } else if chapterIndex + 1 < parsedBook.chapters.count {
            let nextChap = chapterIndex + 1
            pendingJumpToEnd = false
            pendingTargetParagraph = nil
            chapterIndex = nextChap
            unitIndex = 0
            let firstText = parsedBook.chapters[nextChap].paragraphs.first ?? ""
            feedbackPlayer.playStep(noteCount: estimateVisualLineCount(for: firstText))
            queueProgress(chapter: nextChap, index: 0, deltaUnits: 1, immediate: true)
        }
    }

    private func stepPrev() {
        guard !units.isEmpty else { return }
        lastInteractionDate = Date()
        clearWordCard()

        if safeIndex > 0 {
            let target = units[safeIndex - 1]
            withAnimation(AppMotion.panelSpring) {
                unitIndex = safeIndex - 1
            }
            feedbackPlayer.playStep(noteCount: estimateVisualLineCount(for: target.text))
            queueProgress(chapter: chapterIndex, index: safeIndex - 1)
        } else if chapterIndex > 0 {
            let prevChap = chapterIndex - 1
            pendingJumpToEnd = true
            pendingTargetParagraph = nil
            chapterIndex = prevChap
            let prevUnits = BookParser.segmentChapter(
                parsedBook.chapters[prevChap],
                mode: settings.stepMode,
                fontSize: settings.fontSize,
                maxWidth: Double(Swift.max(240, stageWidth - 36))
            )
            let lastIdx = Swift.max(0, prevUnits.count - 1)
            unitIndex = lastIdx
            let targetText = prevUnits.last?.text ?? ""
            feedbackPlayer.playStep(noteCount: estimateVisualLineCount(for: targetText))
            queueProgress(chapter: prevChap, index: lastIdx, immediate: true)
        }
    }

    private func lookupWord(rawToken: String, unit: ReadingUnit) {
        let isCjk = rawToken.contains(where: { TextTokenizer.isChineseChar($0) })
        let clean: String
        if isCjk {
            clean = rawToken.filter { TextTokenizer.isChineseChar($0) }
        } else {
            clean = rawToken
                .trimmingCharacters(in: CharacterSet.letters.inverted)
                .lowercased()
        }
        guard !clean.isEmpty else { return }
        lastInteractionDate = Date()

        let hit = db.lookupDictionary(word: clean)
        let contextSent = unit.parentSentence.isEmpty ? unit.text : unit.parentSentence
        let existing = db.vocabList.first(where: { $0.word == clean })
        let isSaved = existing != nil
        let nextLookupCount = (existing?.lookupCount ?? 0) + 1

        let cachedEn = isCjk
            ? (TranslationService.getCachedZhToEnWord(word: clean, db: db)
               ?? (existing?.englishTranslation.isEmpty == false ? existing?.englishTranslation : nil))
            : nil

        wordDefExpanded = false
        withAnimation(AppMotion.cardSpring) {
            wordCard = WordCardState(
                word: clean,
                lemma: hit.lemma,
                phonetic: hit.phonetic,
                translation: hit.translation,
                englishTranslation: cachedEn ?? "",
                englishLoading: isCjk ? (cachedEn == nil) : true,
                lookupCount: nextLookupCount,
                contextSentence: contextSent,
                isSaved: isSaved
            )
        }

        // Record lookup count in reading logs and update existing vocab entry if already saved
        if existing != nil {
            let updated = db.recordVocabLookup(
                word: clean,
                lemma: hit.lemma,
                phonetic: hit.phonetic,
                translation: hit.translation,
                englishTranslation: cachedEn ?? "",
                contextSentence: contextSent,
                contextTranslation: TranslationService.isErrorPlaceholder(sentenceTranslation) ? "" : sentenceTranslation,
                bookId: book.id,
                bookTitle: book.title
            )
            if wordCard?.word == clean {
                wordCard?.lookupCount = updated.lookupCount
            }
        } else {
            db.recordReadingLog(bookId: book.id, bookTitle: book.title, deltaSeconds: 0, unitsDelta: 0, lookupsDelta: 1)
        }

        // Fetch bilingual English translation or English dictionary definition
        Task {
            if isCjk {
                if cachedEn == nil {
                    let enRes = await TranslationService.translateWordToEnglishOffline(
                        word: clean,
                        db: db,
                        appleTranslator: { text, toEn in
                            try await appleBridge.translate(text, toEnglish: toEn)
                        }
                    )
                    if let enRes, !enRes.isEmpty, isSaved {
                        db.updateVocabEnglishTranslation(word: clean, englishTranslation: enRes)
                    }
                    if wordCard?.word == clean {
                        wordCard?.englishTranslation = enRes ?? ""
                        wordCard?.englishLoading = false
                    }
                }
            } else {
                let enDef = await TranslationService.fetchEnglishDefinition(for: hit.lemma)
                if wordCard?.word == clean {
                    wordCard?.englishTranslation = enDef ?? ""
                    wordCard?.englishLoading = false
                }
            }
        }
    }

    private func toggleWordBookmark(_ card: WordCardState) {
        if card.isSaved {
            if let existing = db.vocabList.first(where: { $0.word == card.word }) {
                db.deleteVocab(id: existing.id)
            }
            if wordCard?.word == card.word {
                wordCard?.isSaved = false
            }
        } else {
            let validSentTrans = TranslationService.isErrorPlaceholder(sentenceTranslation) ? "" : sentenceTranslation
            let saved = db.recordVocabLookup(
                word: card.word,
                lemma: card.lemma,
                phonetic: card.phonetic,
                translation: card.translation,
                englishTranslation: card.englishTranslation,
                contextSentence: card.contextSentence,
                contextTranslation: validSentTrans,
                bookId: book.id,
                bookTitle: book.title
            )
            if wordCard?.word == card.word {
                wordCard?.isSaved = true
                wordCard?.lookupCount = saved.lookupCount
            }
        }
    }

    private func toggleSentenceBookmark() {
        guard !targetSentence.isEmpty else { return }
        if let existing = currentSentenceNote {
            if existing.noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                db.deleteNote(id: existing.id)
            } else {
                noteDraft = existing.noteText
                showNoteSheet = true
            }
        } else {
            saveCurrentSentenceNote(noteText: "")
        }
    }

    private func saveCurrentSentenceNote(noteText: String) {
        guard !targetSentence.isEmpty else { return }
        let existing = currentSentenceNote
        let validTrans = (!sentenceTranslation.isEmpty && !TranslationService.isErrorPlaceholder(sentenceTranslation))
            ? sentenceTranslation
            : (existing?.sentenceTranslation ?? "")
        let validAi = (!sentenceAiResult.isEmpty && !sentenceAiResult.hasPrefix("AI "))
            ? sentenceAiResult
            : (existing?.aiAnalysis ?? "")
        let chapTitle = parsedBook.chapters.indices.contains(chapterIndex) ? parsedBook.chapters[chapterIndex].title : ""
        db.saveSentenceNote(
            bookId: book.id,
            bookTitle: book.title,
            chapterIndex: existing?.chapterIndex ?? chapterIndex,
            chapterTitle: (existing?.chapterTitle.isEmpty == false ? existing?.chapterTitle : chapTitle) ?? chapTitle,
            unitIndex: existing?.unitIndex ?? safeIndex,
            sentenceText: targetSentence,
            sentenceTranslation: validTrans,
            aiAnalysis: validAi,
            noteText: noteText
        )
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

    private func loadSentenceTranslation(forceRefresh: Bool, ignoreAutoSetting: Bool = false) async {
        let target = targetSentence
        guard !target.isEmpty else {
            translatingSentence = false
            sentenceTranslation = ""
            sentenceSource = ""
            return
        }
        if !ignoreAutoSetting && !settings.autoTranslateSentence {
            translatingSentence = false
            sentenceTranslation = ""
            sentenceSource = ""
            return
        }

        let neighbors = contextNeighbors
        let effective = TranslationService.resolveEffectiveSentenceEngine(settings)

        // Lookahead prefetch for next sentence
        if !forceRefresh && effective != "apple" && !neighbors.next1.isEmpty &&
            TranslationService.getCachedSentenceMemory(text: neighbors.next1, settings: settings) == nil {
            let sSnap = settings
            let bTitle = book.title
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                _ = await TranslationService.translateSentenceProgressive(
                    text: neighbors.next1,
                    settings: sSnap,
                    db: db,
                    prevSentence: target,
                    nextSentence: neighbors.next2,
                    bookTitle: bTitle,
                    allowOfflineFallback: false
                )
            }
        }

        if !forceRefresh {
            if let mem = TranslationService.getCachedSentenceMemory(text: target, settings: settings) {
                translatingSentence = false
                sentenceTranslation = mem
                sentenceSource = TranslationService.getCachedSentenceSource(text: target, settings: settings) ?? ""
                return
            }
            if let dbHit = TranslationService.getCachedSentenceTranslation(text: target, db: db, settings: settings) {
                translatingSentence = false
                sentenceTranslation = dbHit
                sentenceSource = TranslationService.getCachedSentenceSource(text: target, settings: settings) ?? ""
                return
            }
        }

        translatingSentence = true
        sentenceSource = ""
        if !forceRefresh {
            try? await Task.sleep(for: .milliseconds(140))
            if Task.isCancelled { return }
        }

        var fastApplied = false
        let finalRes = await TranslationService.translateSentenceProgressive(
            text: target,
            settings: settings,
            db: db,
            prevSentence: neighbors.prev,
            nextSentence: neighbors.next1,
            bookTitle: book.title,
            forceRefresh: forceRefresh,
            appleTranslator: { text, toEn in
                try await appleBridge.translate(text, toEnglish: toEn)
            },
            onFastPreview: { preview in
                guard !fastApplied, target == targetSentence else { return }
                fastApplied = true
                sentenceTranslation = preview
                sentenceSource = TranslationService.getCachedSentenceSource(text: target, settings: settings) ?? "在线翻译"
                translatingSentence = false
            }
        )
        guard !Task.isCancelled, target == targetSentence else { return }
        sentenceTranslation = finalRes
        sentenceSource = TranslationService.getCachedSentenceSource(text: target, settings: settings) ?? ""
        translatingSentence = false
    }

    private func loadAutoSentenceAi() async {
        let target = targetSentence
        guard settings.autoAiAnalyze, !target.isEmpty else {
            sentenceAiLoading = false
            sentenceAiResult = ""
            return
        }
        if let cached = sentenceAiCache[target] {
            sentenceAiLoading = false
            sentenceAiResult = cached
            return
        }
        sentenceAiResult = ""
        sentenceAiLoading = true
        try? await Task.sleep(for: .milliseconds(380))
        if Task.isCancelled || target != targetSentence { return }
        let res = await TranslationService.analyzeWithAi(settings: settings, sentence: target, targetWord: nil)
        guard !Task.isCancelled, target == targetSentence else { return }
        if !res.hasPrefix("⚠️") && !res.hasPrefix("AI 接口") && !res.hasPrefix("AI 请求") {
            sentenceAiCache[target] = res
        }
        sentenceAiResult = res
        sentenceAiLoading = false
    }

    private func triggerManualSentenceAi() async {
        let target = targetSentence
        guard !target.isEmpty else { return }
        if let cached = sentenceAiCache[target] {
            sentenceAiResult = cached
            return
        }
        sentenceAiLoading = true
        let res = await TranslationService.analyzeWithAi(settings: settings, sentence: target, targetWord: nil)
        if target == targetSentence {
            if !res.hasPrefix("⚠️") && !res.hasPrefix("AI 接口") && !res.hasPrefix("AI 请求") {
                sentenceAiCache[target] = res
            }
            sentenceAiResult = res
            sentenceAiLoading = false
        }
    }

    private func loadAutoWordAi() async {
        guard settings.autoAiAnalyze, let card = wordCard else {
            wordAiLoading = false
            wordAiResult = ""
            return
        }
        let cacheKey = "\(card.word)\u{0000}\(card.contextSentence)"
        if let cached = wordAiCache[cacheKey] {
            wordAiLoading = false
            wordAiResult = cached
            return
        }
        wordAiResult = ""
        wordAiLoading = true
        let res = await TranslationService.analyzeWithAi(settings: settings, sentence: card.contextSentence, targetWord: card.word)
        guard !Task.isCancelled, wordCard?.word == card.word else { return }
        if !res.hasPrefix("⚠️") && !res.hasPrefix("AI 接口") && !res.hasPrefix("AI 请求") {
            wordAiCache[cacheKey] = res
        }
        wordAiResult = res
        wordAiLoading = false
    }

    private func triggerManualWordAi(card: WordCardState) async {
        let cacheKey = "\(card.word)\u{0000}\(card.contextSentence)"
        if let cached = wordAiCache[cacheKey] {
            wordAiResult = cached
            return
        }
        wordAiLoading = true
        let res = await TranslationService.analyzeWithAi(settings: settings, sentence: card.contextSentence, targetWord: card.word)
        if wordCard?.word == card.word {
            if !res.hasPrefix("⚠️") && !res.hasPrefix("AI 接口") && !res.hasPrefix("AI 请求") {
                wordAiCache[cacheKey] = res
            }
            wordAiResult = res
            wordAiLoading = false
        }
    }

    private func queueProgress(chapter: Int, index: Int, deltaUnits: Int = 0, immediate: Bool = false) {
        pendingDeltaUnits += deltaUnits
        if immediate {
            let unitCount = Swift.max(1, units.count)
            let overall = BookParser.computeOverallProgress(
                parsedBook: parsedBook,
                chapterIndex: chapter,
                unitIndex: index,
                chapterUnitCount: unitCount
            )
            let secs = pendingDeltaSeconds
            let uDelta = pendingDeltaUnits
            pendingDeltaSeconds = 0
            pendingDeltaUnits = 0
            db.updateBookProgress(
                bookId: book.id,
                bookTitle: book.title,
                chapter: chapter,
                index: index,
                total: unitCount,
                overallProgress: overall,
                deltaSeconds: secs,
                unitsDelta: uDelta
            )
        }
    }

    private func savePdfPageProgress(_ page: Int, immediate: Bool) {
        let total = Swift.max(1, parsedBook.pageCount)
        let overall = Float(page + 1) / Float(total)
        if immediate {
            let secs = pendingDeltaSeconds
            pendingDeltaSeconds = 0
            db.updateBookProgress(
                bookId: book.id,
                bookTitle: book.title,
                chapter: 0,
                index: page,
                total: total,
                overallProgress: overall,
                deltaSeconds: secs,
                unitsDelta: 1
            )
        } else {
            db.updateBookProgress(
                bookId: book.id,
                bookTitle: book.title,
                chapter: 0,
                index: page,
                total: total,
                overallProgress: overall,
                deltaSeconds: 0,
                unitsDelta: 1
            )
        }
    }

    private func flushProgressNow() {
        if parsedBook.isImageOnlyPdf || pdfOriginalMode {
            let total = Swift.max(1, parsedBook.pageCount)
            let secs = pendingDeltaSeconds
            pendingDeltaSeconds = 0
            db.updateBookProgress(
                bookId: book.id,
                bookTitle: book.title,
                chapter: 0,
                index: pdfCurrentPage,
                total: total,
                overallProgress: Float(pdfCurrentPage + 1) / Float(total),
                deltaSeconds: secs,
                unitsDelta: 0
            )
            return
        }
        let unitCount = Swift.max(1, units.count)
        let overall = BookParser.computeOverallProgress(
            parsedBook: parsedBook,
            chapterIndex: chapterIndex,
            unitIndex: safeIndex,
            chapterUnitCount: unitCount
        )
        let secs = pendingDeltaSeconds
        let uDelta = pendingDeltaUnits
        pendingDeltaSeconds = 0
        pendingDeltaUnits = 0
        db.updateBookProgress(
            bookId: book.id,
            bookTitle: book.title,
            chapter: chapterIndex,
            index: safeIndex,
            total: unitCount,
            overallProgress: overall,
            deltaSeconds: secs,
            unitsDelta: uDelta
        )
    }
}

// MARK: - TOC & Book Notes Sheet

private struct ReaderTocAndNotesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appPalette) private var palette

    let parsedBook: ParsedBook
    let chapterIndex: Int
    let currentParagraphIndex: Int
    let currentPdfPage: Int
    let isPdfImageMode: Bool
    let bookNotes: [SentenceNote]
    var onSelectToc: (TocEntry) -> Void
    var onSelectNote: (SentenceNote) -> Void

    @State private var tab = 0

    private var displayToc: [TocEntry] {
        if !parsedBook.tocEntries.isEmpty {
            return parsedBook.tocEntries
        }
        return parsedBook.chapters.enumerated().map { idx, chap in
            TocEntry(title: chap.title, chapterIndex: idx, paragraphIndex: 0, level: 0)
        }
    }

    private var activeTocIdx: Int {
        if isPdfImageMode {
            var best = 0
            for (idx, e) in displayToc.enumerated() where e.paragraphIndex <= currentPdfPage {
                best = idx
            }
            return best
        }
        var best = -1
        for (idx, e) in displayToc.enumerated() {
            if e.chapterIndex < chapterIndex || (e.chapterIndex == chapterIndex && e.paragraphIndex <= currentParagraphIndex) {
                best = idx
            } else if e.chapterIndex > chapterIndex {
                break
            }
        }
        return best >= 0 ? best : (displayToc.firstIndex(where: { $0.chapterIndex == chapterIndex }) ?? 0)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Picker("导航", selection: $tab) {
                    Text("目录 (\(displayToc.count))").tag(0)
                    Text("本书笔记 (\(bookNotes.count))").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if tab == 0 {
                    ScrollViewReader { proxy in
                        List {
                            ForEach(Array(displayToc.enumerated()), id: \.offset) { idx, entry in
                                let isActive = idx == activeTocIdx
                                let indent = CGFloat(Swift.min(4, Swift.max(0, entry.level)) * 16)
                                Button {
                                    onSelectToc(entry)
                                } label: {
                                    HStack {
                                        Text(entry.title)
                                            .font(entry.level > 0 ? .subheadline : .body)
                                            .fontWeight(isActive ? .bold : (entry.level == 0 ? .medium : .regular))
                                            .foregroundStyle(isActive ? palette.accent : (entry.level > 0 ? .secondary : .primary))
                                            .lineLimit(2)
                                        Spacer()
                                        if isActive {
                                            Image(systemName: "checkmark")
                                                .font(.caption.bold())
                                                .foregroundStyle(palette.accent)
                                        }
                                    }
                                    .padding(.leading, indent)
                                }
                                .id(idx)
                            }
                        }
                        .listStyle(.plain)
                        .onAppear {
                            let target = Swift.max(0, activeTocIdx - 2)
                            proxy.scrollTo(target, anchor: .top)
                        }
                    }
                } else {
                    if bookNotes.isEmpty {
                        Spacer()
                        Text("本书还没有收藏句子或笔记\n在阅读下方句卡点击星标或编辑按钮即可记录")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(24)
                        Spacer()
                    } else {
                        List(bookNotes) { note in
                            Button {
                                onSelectNote(note)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(note.chapterTitle.isEmpty ? "第 \(note.chapterIndex + 1) 章" : note.chapterTitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(note.sentenceText)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    if !note.noteText.isEmpty {
                                        Text("笔记：\(note.noteText)")
                                            .font(.caption)
                                            .foregroundStyle(palette.accent)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle("目录与笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Reader Preferences Sheet (4 Collapsible Liquid Glass Sections)

private struct ReaderPreferencesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(StepFeedbackPlayer.self) private var feedbackPlayer
    @Environment(\.appPalette) private var palette

    @State private var colorsExpanded = false
    @State private var layoutExpanded = false
    @State private var feedbackExpanded = false
    @State private var activeColorTarget: ReaderColorTarget = .background

    private var hasCustomColors: Bool {
        let s = settingsStore.settings
        return s.readerBgColorHex >= 0 ||
            s.readerFocusColorHex >= 0 ||
            s.readerBottomBgColorHex >= 0 ||
            s.readerSentenceCardColorHex >= 0 ||
            s.readerWordCardColorHex >= 0
    }

    private func resolvedColor(for target: ReaderColorTarget) -> Color {
        let stored = target.value(in: settingsStore.settings)
        if let custom = Color(hexInt64: stored) {
            return custom
        }
        switch target {
        case .background: return palette.backgroundBase
        case .focusUnit: return palette.accent.opacity(0.14)
        case .bottomBar: return palette.surfaceTint
        case .sentenceCard: return palette.surfaceTint
        case .wordCard: return palette.nestedTint
        }
    }

    var body: some View {
        @Bindable var store = settingsStore

        NavigationStack {
            ZStack {
                AmbientGlassBackdrop(themeMode: store.settings.themeMode)

                ScrollView {
                    VStack(spacing: 12) {
                        // 1. Custom 5 Reader Colors
                        CollapsibleGlassSection(
                            title: "自定义配色",
                            subtitle: hasCustomColors ? "已自定义 · 基础：\(store.settings.themeMode.displayName)" : "跟随全局主题（\(store.settings.themeMode.displayName)）",
                            systemImage: "paintpalette",
                            expanded: $colorsExpanded
                        ) {
                            HStack {
                                Text("自定义各区域颜色")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if hasCustomColors {
                                    Button("全部恢复默认") {
                                        store.settings.readerBgColorHex = -1
                                        store.settings.readerFocusColorHex = -1
                                        store.settings.readerBottomBgColorHex = -1
                                        store.settings.readerSentenceCardColorHex = -1
                                        store.settings.readerWordCardColorHex = -1
                                    }
                                    .font(.caption)
                                }
                            }

                            // 5 target preview dots & pills
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(ReaderColorTarget.allCases) { target in
                                        let selected = activeColorTarget == target
                                        let isCustomized = target.value(in: store.settings) >= 0
                                        let swatch = resolvedColor(for: target)
                                        Button {
                                            activeColorTarget = target
                                        } label: {
                                            HStack(spacing: 6) {
                                                Circle()
                                                    .fill(swatch)
                                                    .frame(width: 12, height: 12)
                                                    .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.6))
                                                Text(isCustomized ? "\(target.title)*" : target.title)
                                                    .font(.caption.weight(selected ? .semibold : .medium))
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(selected ? palette.accent.opacity(0.18) : Color.secondary.opacity(0.10), in: Capsule())
                                            .foregroundStyle(selected ? palette.accent : .primary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }

                            let targetVal = activeColorTarget.value(in: store.settings)
                            let targetColor = resolvedColor(for: activeColorTarget)
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Circle()
                                        .fill(targetColor)
                                        .frame(width: 20, height: 20)
                                        .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.8))
                                    Text(activeColorTarget.title)
                                        .font(.subheadline.weight(.semibold))
                                    MinimalTagPill(text: targetColor.hexString)
                                    Spacer()
                                    if targetVal >= 0 {
                                        Button("恢复默认") {
                                            activeColorTarget.update(-1, in: &store.settings)
                                        }
                                        .font(.caption)
                                    }
                                }

                                // Preset Swatches
                                HStack(spacing: 10) {
                                    ForEach(Array(activeColorTarget.presetColors.enumerated()), id: \.offset) { _, swatch in
                                        let hex = swatch.toStoredHexInt64()
                                        let selected = targetVal == hex
                                        Button {
                                            activeColorTarget.update(hex, in: &store.settings)
                                        } label: {
                                            Circle()
                                                .fill(swatch)
                                                .frame(width: 28, height: 28)
                                                .overlay(
                                                    Circle().strokeBorder(selected ? palette.accent : Color.secondary.opacity(0.45), lineWidth: selected ? 2.2 : 0.8)
                                                )
                                                .overlay {
                                                    if selected {
                                                        Image(systemName: "checkmark")
                                                            .font(.caption2.bold())
                                                            .foregroundStyle(swatch.contrastingTextColor)
                                                    }
                                                }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    Spacer()
                                }

                                ColorPicker(
                                    "自定义调色板",
                                    selection: Binding(
                                        get: { targetColor },
                                        set: { newColor in
                                            activeColorTarget.update(newColor.toStoredHexInt64(), in: &store.settings)
                                        }
                                    ),
                                    supportsOpacity: activeColorTarget == .focusUnit
                                )
                                .font(.caption)
                            }
                            .padding(12)
                            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }

                        // 2. Layout & Typography
                        CollapsibleGlassSection(
                            title: "排版与布局",
                            subtitle: "\(store.settings.stepMode.displayName) · +\(store.settings.visibleCount) · \(Int(store.settings.fontSize))pt · \(String(format: "%.2f", store.settings.lineSpacingMultiplier))×",
                            systemImage: "textformat.size",
                            expanded: $layoutExpanded
                        ) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("推进模式").font(.caption).foregroundStyle(.secondary)
                                Picker("推进模式", selection: $store.settings.stepMode) {
                                    ForEach(StepMode.allCases, id: \.self) { m in
                                        Text(m.displayName).tag(m)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }

                            Stepper("后续显示句/行数：+\(store.settings.visibleCount)", value: $store.settings.visibleCount, in: 1...8)
                                .font(.subheadline)

                            sliderRow(
                                title: "正文字号",
                                valueText: "\(Int(store.settings.fontSize)) pt",
                                value: $store.settings.fontSize,
                                range: 16...28,
                                step: 1
                            )

                            sliderRow(
                                title: "行间距",
                                valueText: "\(String(format: "%.2f", store.settings.lineSpacingMultiplier))×",
                                value: $store.settings.lineSpacingMultiplier,
                                range: 1.0...1.8,
                                step: 0.05
                            )

                            let posPct = Int((store.settings.readingPositionBias * 100).rounded())
                            let posLabel = store.settings.readingPositionBias < 0.25 ? "靠上" : (store.settings.readingPositionBias > 0.75 ? "靠下" : "居中")
                            sliderRow(
                                title: "阅读行位置",
                                valueText: "\(posPct)% · \(posLabel)",
                                value: $store.settings.readingPositionBias,
                                range: 0.0...1.0,
                                step: 0.05
                            )

                            let zonePct = Int((store.settings.readingZoneRatio * 100).rounded())
                            sliderRow(
                                title: "阅读 / 词义占比",
                                valueText: "\(zonePct)% / \(100 - zonePct)%",
                                value: $store.settings.readingZoneRatio,
                                range: 0.25...0.75,
                                step: 0.05
                            )

                            Toggle("正文中对已查单词显示底部虚线", isOn: $store.settings.underlineLookedUpWords)
                                .font(.subheadline)
                        }

                        // 3. Step Feedback
                        CollapsibleGlassSection(
                            title: "翻句反馈（上一句 / 下一句）",
                            subtitle: "钢琴音效：\(store.settings.stepSoundTrack.displayName) · 震动：\(hapticLabel(store.settings.stepHapticLevel))",
                            systemImage: "music.note",
                            expanded: $feedbackExpanded
                        ) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("钢琴音效曲目（按目标句视觉行数演奏，最多 6 音）")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(StepSoundTrack.allCases, id: \.self) { track in
                                            let selected = store.settings.stepSoundTrack == track
                                            Button {
                                                store.settings.stepSoundTrack = track
                                                feedbackPlayer.playTrackPreview(track: track)
                                            } label: {
                                                Text(track.displayName)
                                                    .font(.caption.weight(selected ? .semibold : .medium))
                                                    .padding(.horizontal, 11)
                                                    .padding(.vertical, 6)
                                                    .background(selected ? palette.accent.opacity(0.18) : Color.secondary.opacity(0.10), in: Capsule())
                                                    .foregroundStyle(selected ? palette.accent : .primary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("翻句震动强度").font(.caption).foregroundStyle(.secondary)
                                Picker("震动强度", selection: Binding(
                                    get: { store.settings.stepHapticLevel },
                                    set: { val in
                                        store.settings.stepHapticLevel = val
                                        feedbackPlayer.playHapticPreview(level: val, followLines: store.settings.stepHapticMode == .line)
                                    }
                                )) {
                                    Text("关闭").tag(0)
                                    Text("轻柔").tag(1)
                                    Text("适中").tag(2)
                                    Text("强烈").tag(3)
                                }
                                .pickerStyle(.segmented)
                            }

                            if store.settings.stepHapticLevel > 0 {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("震动方式").font(.caption).foregroundStyle(.secondary)
                                    Picker("震动方式", selection: Binding(
                                        get: { store.settings.stepHapticMode },
                                        set: { val in
                                            store.settings.stepHapticMode = val
                                            feedbackPlayer.playHapticPreview(level: store.settings.stepHapticLevel, followLines: val == .line)
                                        }
                                    )) {
                                        ForEach(StepHapticMode.allCases, id: \.self) { mode in
                                            Text(mode.displayName).tag(mode)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                }
                            }

                            if store.settings.stepSoundTrack != .off || (store.settings.stepHapticLevel > 0 && store.settings.stepHapticMode == .line) {
                                sliderRow(
                                    title: store.settings.stepSoundTrack != .off ? "音符 / 连震节奏间隔" : "连震节奏间隔",
                                    valueText: "\(store.settings.stepNoteIntervalMs) ms",
                                    value: Binding(
                                        get: { Double(store.settings.stepNoteIntervalMs) },
                                        set: { store.settings.stepNoteIntervalMs = Int($0.rounded()) }
                                    ),
                                    range: 180...700,
                                    step: 20
                                )
                            }
                        }

                        // 4. Auto Assistants
                        GlassCard(cornerRadius: 22) {
                            VStack(spacing: 12) {
                                Toggle(isOn: $store.settings.autoTranslateSentence) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("默认开启整句翻译").font(.subheadline.weight(.medium))
                                        Text("翻到新句时自动加载译文").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Divider()
                                Toggle(isOn: $store.settings.autoAiAnalyze) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("默认开启 AI 语境精讲").font(.subheadline.weight(.medium))
                                        Text("自动进行整句精讲与点词上下文释义").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(16)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func hapticLabel(_ level: Int) -> String {
        switch level {
        case 1: return "轻柔"
        case 2: return "适中"
        case 3: return "强烈"
        default: return "关闭"
        }
    }

    private func sliderRow(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                MinimalTagPill(text: valueText, tintColor: palette.accent.opacity(0.12), textColor: palette.accent)
            }
            Slider(value: value, in: range, step: step)
                .tint(palette.accent)
        }
    }
}

// MARK: - PDF Original View Representable (Two-way page sync)

private struct PdfOriginalPageView: UIViewRepresentable {
    let data: Data
    @Binding var currentPage: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        let doc = PDFDocument(data: data)
        view.document = doc
        if let doc, currentPage >= 0, currentPage < doc.pageCount, let page = doc.page(at: currentPage) {
            view.go(to: page)
        }
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        context.coordinator.parent = self
        guard let doc = uiView.document,
              currentPage >= 0,
              currentPage < doc.pageCount,
              let targetPage = doc.page(at: currentPage),
              uiView.currentPage != targetPage else {
            return
        }
        if abs((doc.index(for: uiView.currentPage ?? targetPage)) - currentPage) > 0 && !context.coordinator.isUpdatingFromPdf {
            uiView.go(to: targetPage)
        }
    }

    final class Coordinator: NSObject {
        var parent: PdfOriginalPageView
        var isUpdatingFromPdf = false

        init(_ parent: PdfOriginalPageView) {
            self.parent = parent
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let doc = pdfView.document,
                  let cur = pdfView.currentPage else { return }
            let idx = doc.index(for: cur)
            if idx != parent.currentPage {
                isUpdatingFromPdf = true
                DispatchQueue.main.async { [weak self] in
                    self?.parent.currentPage = idx
                    self?.isUpdatingFromPdf = false
                }
            }
        }
    }
}

// MARK: - Tokenized Text Flow

private struct TokenizedUnitTextView: View {
    let tokens: [TextToken]
    let fontSize: Double
    let lineSpacing: CGFloat
    let isFocus: Bool
    let underlineEnabled: Bool
    let lookedUpMap: [String: Int]
    let selectedWord: String?
    let textColor: Color
    let accentColor: Color
    var onWordTap: (String) -> Void

    var body: some View {
        ReaderWordFlowLayout(horizontalSpacing: 2, verticalSpacing: lineSpacing) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                if token.isLookupable {
                    let clean: String = token.isCjk
                        ? token.text.filter { TextTokenizer.isChineseChar($0) }
                        : token.text.trimmingCharacters(in: CharacterSet.letters.inverted).lowercased()
                    let isKnown = underlineEnabled && !clean.isEmpty && (lookedUpMap[clean] ?? 0) > 0
                    let isSelected = !clean.isEmpty && selectedWord == clean

                    Text(token.text)
                        .font(.system(size: fontSize, weight: isFocus ? .medium : .regular, design: .serif))
                        .foregroundStyle(isSelected ? .white : textColor)
                        .padding(.horizontal, token.isCjk ? 1 : 2.5)
                        .padding(.vertical, 1)
                        .background(isSelected ? accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(alignment: .bottom) {
                            if isKnown && !isSelected {
                                DashedUnderlineShape()
                                    .stroke(style: StrokeStyle(lineWidth: 1.4, dash: [3.5, 2.5]))
                                    .foregroundStyle(Color.orange.opacity(0.8))
                                    .frame(height: 1.5)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onWordTap(token.text)
                        }
                } else {
                    Text(token.text)
                        .font(.system(size: fontSize, weight: isFocus ? .medium : .regular, design: .serif))
                        .foregroundStyle(textColor)
                }
            }
        }
    }
}

private struct DashedUnderlineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

private struct ReaderWordFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 2
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
