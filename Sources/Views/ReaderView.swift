import PDFKit
import SwiftUI
#if canImport(Translation)
import Translation
#endif

struct WordCardState: Equatable {
    let word: String
    let lemma: String
    let phonetic: String
    var translation: String
    var translationLoading: Bool = false
    var translationSource: String = ""
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

    // Token & segmentation cache
    @State private var tokenCache: [String: [TextToken]] = [:]
    @State private var units: [ReadingUnit] = []
    @State private var unitsCache: [String: [ReadingUnit]] = [:]
    @State private var unitsCacheKey: String = ""

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
            rebuildUnitsIfNeeded()
            resolvePendingUnitAdjustments()
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
            rebuildUnitsIfNeeded()
            resolvePendingUnitAdjustments()
            pretokenizeAround(index: safeIndex)
        }
        .onChange(of: settings.stepMode) { _, _ in
            rebuildUnitsIfNeeded()
            resolvePendingUnitAdjustments()
            pretokenizeAround(index: safeIndex)
        }
        .onChange(of: settings.fontSize) { _, _ in
            rebuildUnitsIfNeeded()
            resolvePendingUnitAdjustments()
        }
        .onChange(of: stageWidth) { _, _ in
            if settings.stepMode != .sentence {
                rebuildUnitsIfNeeded()
                resolvePendingUnitAdjustments()
            }
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
                            let maxContextBehind = Swift.max(settings.visibleCount, 5)
                            let lineGap = CGFloat((settings.lineSpacingMultiplier - 1.0) * 5.0)
                            let unitGap = CGFloat((settings.lineSpacingMultiplier - 1.0) * 14.0 + 6.0)
                            let focusFill = customFocusBg ?? palette.accent.opacity(0.11)

                            LazyVStack(alignment: .leading, spacing: unitGap) {
                                // Generous vertical spacer padding so first & last units glide smoothly to readingPositionBias
                                Color.clear
                                    .frame(height: Swift.max(16, topZoneHeight * 0.50 * settings.readingPositionBias))

                                ForEach(units) { unit in
                                    let dist = abs(unit.index - safeIndex)
                                    let isFocus = dist == 0
                                    let withinWindow = unit.index >= safeIndex
                                        ? (dist <= settings.visibleCount)
                                        : (dist <= maxContextBehind)
                                    let targetAlpha: Double = isFocus
                                        ? 1.0
                                        : (withinWindow ? Swift.max(0.08, 0.34 * pow(0.60, Double(dist - 1))) : 0.0)

                                    TokenizedUnitTextView(
                                        tokens: tokensFor(unit.text),
                                        fontSize: settings.fontSize,
                                        lineSpacing: Swift.max(3, lineGap),
                                        underlineEnabled: settings.underlineLookedUpWords,
                                        lookedUpMap: lookedUpMap,
                                        selectedWord: wordCard?.word,
                                        textColor: isFocus ? focusTextColor : readerTextColor,
                                        accentColor: palette.accent,
                                        onWordTap: { token in
                                            lookupWord(rawToken: token, unit: unit)
                                        }
                                    )
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background {
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(.regularMaterial)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                                    .fill(focusFill)
                                            )
                                            .overlay(alignment: .leading) {
                                                Capsule()
                                                    .fill(palette.accent.opacity(0.85))
                                                    .frame(width: 3.5)
                                                    .padding(.vertical, 10)
                                                    .padding(.leading, 6)
                                            }
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                                    .strokeBorder(
                                                        customFocusBg != nil ? focusTextColor.opacity(0.14) : Color.white.opacity(palette.isLight ? 0.65 : 0.22),
                                                        lineWidth: 0.6
                                                    )
                                            )
                                            .shadow(color: .black.opacity(palette.isLight ? 0.04 : 0.16), radius: 8, x: 0, y: 3)
                                            .opacity(isFocus ? 1.0 : 0.0)
                                    }
                                    .opacity(targetAlpha)
                                    .allowsHitTesting(targetAlpha > 0.05)
                                    .animation(.easeInOut(duration: 0.28), value: safeIndex)
                                    .id(unit.index)
                                }

                                Color.clear
                                    .frame(height: Swift.max(32, topZoneHeight * 0.55))
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
                                .padding(.bottom, 68)
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

                    // Floating Liquid Glass Bottom Dock: Back(icon) · Chapter(icon + x/N) · Settings(icon)
                    readerBottomGlassDock(
                        tocTitle: "\(chapterIndex + 1)/\(Swift.max(1, parsedBook.chapters.count))"
                    )
                    .padding(.bottom, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Top Bar & Bottom Glass Dock

    @ViewBuilder
    private func readerGlassCapsulePill(
        title: String?,
        accessibilityLabel: String,
        systemImage: String,
        isEmphasized: Bool = false,
        horizontalPadding: CGFloat = 14,
        respectCustomBottomBg: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        let activeCustomBg = respectCustomBottomBg ? customBottomBg : nil
        let isLightDock = activeCustomBg != nil ? (activeCustomBg!.relativeLuminance > 0.44) : palette.isLight
        let fgColor: Color = activeCustomBg != nil ? activeCustomBg!.contrastingTextColor : .primary
        let hasTitle = !(title?.isEmpty ?? true)

        Button(action: action) {
            let label = Group {
                if let title, !title.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isEmphasized ? palette.accent : fgColor.opacity(0.88))
                        Text(title)
                            .font(.subheadline.weight(isEmphasized ? .semibold : .medium))
                            .monospacedDigit()
                            .lineLimit(1)
                            .foregroundStyle(fgColor)
                    }
                    .padding(.horizontal, horizontalPadding)
                    .frame(minWidth: 92)
                    .frame(height: 44)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isEmphasized ? palette.accent : fgColor.opacity(0.90))
                        .frame(width: 44, height: 44)
                }
            }
            .contentShape(Capsule())

            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                let tint: Color? = {
                    if let activeCustomBg {
                        return activeCustomBg.opacity(0.38)
                    }
                    if isEmphasized {
                        return palette.accent.opacity(0.16)
                    }
                    return palette.mode != .dynamic ? palette.surfaceTint.opacity(palette.isLight ? 0.22 : 0.28) : nil
                }()
                let glass: Glass = tint != nil ? .regular.tint(tint!).interactive() : .regular.interactive()
                if hasTitle {
                    label
                        .glassEffect(glass, in: Capsule())
                        .contentShape(Capsule())
                } else {
                    label
                        .glassEffect(glass, in: Circle())
                        .contentShape(Circle())
                }
            } else {
                legacyReaderDockCapsule(label: label, activeCustomBg: activeCustomBg, isLightDock: isLightDock)
            }
            #else
            legacyReaderDockCapsule(label: label, activeCustomBg: activeCustomBg, isLightDock: isLightDock)
            #endif
        }
        .buttonStyle(GlassPressButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func legacyReaderDockCapsule<L: View>(label: L, activeCustomBg: Color?, isLightDock: Bool) -> some View {
        label
            .background {
                ZStack {
                    Capsule().fill(.regularMaterial)
                    if let activeCustomBg {
                        Capsule().fill(activeCustomBg.opacity(0.42))
                    } else if palette.mode != .dynamic {
                        Capsule().fill(palette.surfaceTint.opacity(palette.isLight ? 0.34 : 0.28))
                    }
                    Capsule().fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(isLightDock ? 0.36 : 0.12),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(isLightDock ? 0.82 : 0.34),
                                .white.opacity(isLightDock ? 0.20 : 0.08),
                                .white.opacity(0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            }
            .shadow(color: .black.opacity(isLightDock ? 0.10 : 0.32), radius: 12, x: 0, y: 5)
    }

    @ViewBuilder
    private func readerBottomGlassDock(tocTitle: String, respectCustomBottomBg: Bool = true) -> some View {
        let row = HStack(spacing: 10) {
            readerGlassCapsulePill(
                title: nil,
                accessibilityLabel: "返回",
                systemImage: "chevron.left",
                respectCustomBottomBg: respectCustomBottomBg
            ) {
                flushProgressNow()
                onBack()
            }

            readerGlassCapsulePill(
                title: tocTitle,
                accessibilityLabel: "目录",
                systemImage: "list.bullet",
                isEmphasized: true,
                horizontalPadding: 16,
                respectCustomBottomBg: respectCustomBottomBg
            ) {
                showTocSheet = true
            }

            readerGlassCapsulePill(
                title: nil,
                accessibilityLabel: "设置",
                systemImage: "slider.horizontal.3",
                respectCustomBottomBg: respectCustomBottomBg
            ) {
                showPrefsSheet = true
            }
        }
        .padding(.horizontal, 12)

        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 10) {
                row
            }
        } else {
            row
        }
        #else
        row
        #endif
    }

    private var readerTopBar: some View {
        HStack(spacing: 10) {
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
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .appleLiquidGlassCapsule(interactive: false)

            if book.format.uppercased() == "PDF" {
                Button {
                    togglePdfOriginalMode()
                } label: {
                    Label("原版", systemImage: "doc.richtext")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(readerTextColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .appleLiquidGlassCapsule()
                }
                .buttonStyle(GlassPressButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
        let isTranslationExpanded = translatingSentence || !sentenceTranslation.isEmpty

        return GlassCard(cornerRadius: isTranslationExpanded ? 22 : 18, customFill: customSentenceCardBg) {
            VStack(alignment: .leading, spacing: isTranslationExpanded ? 10 : 8) {
                if isTranslationExpanded {
                    if translatingSentence {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在翻译当前句...")
                                .font(.caption)
                                .foregroundStyle(sentenceCardSecondaryColor)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(sentenceCardTextColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        Text(sentenceTranslation)
                            .font(.subheadline)
                            .lineSpacing(4.5)
                            .foregroundStyle(sentenceCardTextColor)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider()
                        .opacity(0.45)
                }

                // Controls row (always visible; acts as the compact collapsed bar when translation is off)
                HStack(spacing: 6) {
                    if !isTranslationExpanded {
                        Button {
                            Task {
                                await loadSentenceTranslation(forceRefresh: true, ignoreAutoSetting: true)
                            }
                        } label: {
                            Label("点击翻译", systemImage: "translate")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5.5)
                                .background(palette.accent.opacity(0.14), in: Capsule())
                                .foregroundStyle(palette.accent)
                        }
                        .buttonStyle(GlassPressButtonStyle())
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
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(palette.accent.opacity(0.14), in: Capsule())
                                .foregroundStyle(palette.accent)
                        }
                        .buttonStyle(GlassPressButtonStyle())
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
                                .background(sentenceCardTextColor.opacity(0.06), in: Circle())
                        }
                        .buttonStyle(GlassPressButtonStyle())

                        if !settings.autoTranslateSentence {
                            Button {
                                withAnimation(AppMotion.panelSpring) {
                                    sentenceTranslation = ""
                                    sentenceSource = ""
                                }
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(sentenceCardSecondaryColor)
                                    .frame(width: 28, height: 28)
                                    .background(sentenceCardTextColor.opacity(0.06), in: Circle())
                            }
                            .buttonStyle(GlassPressButtonStyle())
                        }
                    }

                    // Bookmark star
                    Button {
                        toggleSentenceBookmark()
                    } label: {
                        Image(systemName: isStarred ? "star.fill" : "star")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isStarred ? palette.accent : sentenceCardSecondaryColor)
                            .frame(width: 28, height: 28)
                            .background((isStarred ? palette.accent.opacity(0.15) : sentenceCardTextColor.opacity(0.06)), in: Circle())
                    }
                    .buttonStyle(GlassPressButtonStyle())

                    // Edit note button
                    Button {
                        if !targetSentence.isEmpty {
                            noteDraft = currentNote?.noteText ?? ""
                            showNoteSheet = true
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(hasNoteText ? palette.accent : sentenceCardSecondaryColor)
                            .frame(width: 28, height: 28)
                            .background((hasNoteText ? palette.accent.opacity(0.15) : sentenceCardTextColor.opacity(0.06)), in: Circle())
                    }
                    .buttonStyle(GlassPressButtonStyle())
                }

                // Inline saved note
                if let saved = currentNote, !saved.noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        noteDraft = saved.noteText
                        showNoteSheet = true
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "note.text")
                                .font(.caption)
                                .foregroundStyle(palette.accent)
                                .padding(.top, 2)
                            Text(saved.noteText)
                                .font(.caption)
                                .foregroundStyle(sentenceCardTextColor)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(palette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(palette.accent.opacity(0.18), lineWidth: 0.55)
                        )
                    }
                    .buttonStyle(.plain)
                    .transition(AppMotion.panelTransition)
                }

                // Inline Sentence AI Analysis
                if sentenceAiLoading || !sentenceAiResult.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            AppleIconBadge(systemImage: "sparkles", size: 20, cornerRadius: 6)
                            Text("AI 上下文解析")
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
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sentenceCardTextColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(sentenceCardTextColor.opacity(0.08), lineWidth: 0.55)
                    )
                    .transition(AppMotion.panelTransition)
                }
            }
            .padding(.horizontal, isTranslationExpanded ? 16 : 14)
            .padding(.vertical, isTranslationExpanded ? 13 : 9)
            .animation(AppMotion.panelSpring, value: isTranslationExpanded)
        }
    }

    // MARK: - Word Definition Card

    private func wordDefinitionCard(_ card: WordCardState) -> some View {
        let formattedTrans = card.translation
            .replacingOccurrences(of: "\n\n+", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return GlassCard(cornerRadius: 22, customFill: customWordCardBg) {
            VStack(alignment: .leading, spacing: 9) {
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
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.accent)
                            .frame(width: 28, height: 28)
                            .background(palette.accent.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(GlassPressButtonStyle())

                    if card.isSaved {
                        MinimalTagPill(
                            text: "×\(card.lookupCount)",
                            tintColor: palette.accent.opacity(0.14),
                            textColor: palette.accent
                        )
                    }

                    if !card.translationSource.isEmpty {
                        MinimalTagPill(
                            text: card.translationSource,
                            tintColor: wordCardTextColor.opacity(0.07),
                            textColor: wordCardSecondaryColor
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
                                .background(palette.accent.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(GlassPressButtonStyle())
                    }

                    Button {
                        toggleWordBookmark(card)
                    } label: {
                        Image(systemName: card.isSaved ? "star.fill" : "star")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(card.isSaved ? palette.accent : wordCardSecondaryColor)
                            .frame(width: 28, height: 28)
                            .background((card.isSaved ? palette.accent.opacity(0.15) : wordCardTextColor.opacity(0.06)), in: Circle())
                    }
                    .buttonStyle(GlassPressButtonStyle())
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

                // Primary translation (Local dictionary or Apple System Translation)
                if card.translationLoading && formattedTrans.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在通过 Apple 翻译查询释义...")
                            .font(.caption)
                            .foregroundStyle(wordCardSecondaryColor)
                    }
                    .padding(.vertical, 4)
                } else if !formattedTrans.isEmpty {
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
                            .appleLiquidGlassCapsule()
                    }
                    .buttonStyle(GlassPressButtonStyle())
                }
            }
            .padding(.horizontal, 16)
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

            // Bottom page controls + Liquid Glass Dock
            VStack(spacing: 10) {
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

                readerBottomGlassDock(
                    tocTitle: "\(pdfCurrentPage + 1)/\(totalPages)",
                    respectCustomBottomBg: false
                )
            }
            .padding(.top, 10)
            .padding(.bottom, 10)
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
            withAnimation(.spring(response: 0.44, dampingFraction: 0.92)) {
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

    private func rebuildUnitsIfNeeded() {
        guard chapterIndex >= 0, chapterIndex < parsedBook.chapters.count else {
            units = []
            unitsCacheKey = ""
            return
        }
        let widthBucket = settings.stepMode == .sentence ? 0 : Int((Double(Swift.max(240, stageWidth - 36)) / 8.0).rounded())
        let key = "\(book.id)-\(chapterIndex)-\(settings.stepMode.rawValue)-\(Int(settings.fontSize))-\(widthBucket)"
        guard key != unitsCacheKey else { return }
        unitsCacheKey = key
        if let hit = unitsCache[key] {
            units = hit
            return
        }
        let computed = BookParser.segmentChapter(
            parsedBook.chapters[chapterIndex],
            mode: settings.stepMode,
            fontSize: settings.fontSize,
            maxWidth: Double(Swift.max(240, stageWidth - 36))
        )
        if unitsCache.count > 12 {
            unitsCache.removeAll()
        }
        unitsCache[key] = computed
        units = computed
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
        let availableWidth = Swift.max(200.0, Double(stageWidth) - 52.0)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var totalLines = 0
        for line in lines {
            let str = String(line)
            if str.isEmpty {
                totalLines += 1
                continue
            }
            var lineWidth = 0.0
            var wordCount = 0
            var inAsciiWord = false
            for ch in str {
                if TextTokenizer.isChineseChar(ch) || ch.unicodeScalars.contains(where: { $0.value >= 0x3000 }) {
                    lineWidth += settings.fontSize * 1.06
                    inAsciiWord = false
                } else if ch.isWhitespace {
                    lineWidth += settings.fontSize * 0.30
                    inAsciiWord = false
                } else {
                    if !inAsciiWord {
                        wordCount += 1
                        inAsciiWord = true
                    }
                    lineWidth += settings.fontSize * 0.58
                }
            }
            lineWidth += Double(wordCount) * 5.0
            let estimated = Int(ceil((lineWidth * 1.10) / availableWidth))
            totalLines += Swift.max(1, estimated)
        }
        return Swift.min(12, Swift.max(1, totalLines))
    }

    private func stepNext() {
        guard !units.isEmpty else { return }
        lastInteractionDate = Date()
        clearWordCard()

        if safeIndex + 1 < units.count {
            let target = units[safeIndex + 1]
            unitIndex = safeIndex + 1
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
            unitIndex = safeIndex - 1
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
        let hasLocalDict = hit.found && !TranslationService.isDictionaryPlaceholder(hit.translation)
        let contextSent = unit.parentSentence.isEmpty ? unit.text : unit.parentSentence
        let existing = db.vocabList.first(where: { $0.word == clean })
        let isSaved = existing != nil
        let nextLookupCount = (existing?.lookupCount ?? 0) + 1

        let cachedEn = isCjk
            ? (TranslationService.getCachedZhToEnWord(word: clean, db: db)
               ?? (existing?.englishTranslation.isEmpty == false ? existing?.englishTranslation : nil))
            : nil

        let initialTrans: String = {
            if hasLocalDict { return hit.translation }
            if let existingTrans = existing?.translation, !TranslationService.isDictionaryPlaceholder(existingTrans) {
                return existingTrans
            }
            return ""
        }()

        wordDefExpanded = false
        withAnimation(AppMotion.cardSpring) {
            wordCard = WordCardState(
                word: clean,
                lemma: hit.lemma,
                phonetic: hit.phonetic,
                translation: initialTrans,
                translationLoading: !isCjk && initialTrans.isEmpty,
                translationSource: hasLocalDict ? "本地词库" : (initialTrans.isEmpty ? "Apple 翻译" : "Apple 翻译"),
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
                translation: initialTrans,
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

        // Fetch Apple native translation & English definition
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
                    if let enRes, !enRes.isEmpty {
                        if wordCard?.word == clean && wordCard?.isSaved == true {
                            db.updateVocabEnglishTranslation(word: clean, englishTranslation: enRes)
                            if !hasLocalDict {
                                db.updateVocabTranslation(word: clean, translation: enRes)
                            }
                        }
                    }
                    if wordCard?.word == clean {
                        wordCard?.englishTranslation = enRes ?? ""
                        wordCard?.englishLoading = false
                        if !hasLocalDict, let enRes, !enRes.isEmpty {
                            wordCard?.translation = enRes
                        } else if !hasLocalDict {
                            wordCard?.translation = hit.translation
                        }
                    }
                } else if !hasLocalDict, let cachedEn, wordCard?.word == clean {
                    wordCard?.translation = cachedEn
                }
            } else {
                // If not in local dictionary, translate directly via Apple System Translation
                if !hasLocalDict {
                    let appleRes = await TranslationService.translateWordToChinese(
                        word: clean,
                        lemma: hit.lemma,
                        phonetic: hit.phonetic,
                        db: db,
                        appleTranslator: { text, toEn in
                            try await appleBridge.translate(text, toEnglish: toEn)
                        }
                    )
                    if wordCard?.word == clean {
                        if let appleRes, !appleRes.text.isEmpty {
                            wordCard?.translation = appleRes.text
                            wordCard?.translationSource = appleRes.source
                            wordCard?.translationLoading = false
                            if wordCard?.isSaved == true {
                                db.updateVocabTranslation(word: clean, translation: appleRes.text)
                            }
                        } else {
                            wordCard?.translation = hit.translation
                            wordCard?.translationLoading = false
                        }
                    }
                }

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
                guard target == targetSentence else { return }
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

private struct TocHierarchyInfo {
    let minLevel: Int
    let parentIndex: [Int?]
    let hasChildren: [Bool]
    let descendantCount: [Int]
    let hasHierarchy: Bool

    static func build(for entries: [TocEntry]) -> TocHierarchyInfo {
        let count = entries.count
        guard count > 0 else {
            return TocHierarchyInfo(minLevel: 0, parentIndex: [], hasChildren: [], descendantCount: [], hasHierarchy: false)
        }
        let minLevel = entries.map(\.level).min() ?? 0
        var parentIndex = [Int?](repeating: nil, count: count)
        var hasChildren = [Bool](repeating: false, count: count)
        var descendantCount = [Int](repeating: 0, count: count)
        var stack: [(idx: Int, level: Int)] = []

        for i in 0..<count {
            let lvl = entries[i].level
            while let last = stack.last, last.level >= lvl {
                stack.removeLast()
            }
            if let parent = stack.last {
                parentIndex[i] = parent.idx
                hasChildren[parent.idx] = true
            }
            stack.append((idx: i, level: lvl))
        }

        for i in (0..<count).reversed() {
            if let p = parentIndex[i] {
                descendantCount[p] += 1 + descendantCount[i]
            }
        }

        let hasHierarchy = hasChildren.contains(true)
        return TocHierarchyInfo(
            minLevel: minLevel,
            parentIndex: parentIndex,
            hasChildren: hasChildren,
            descendantCount: descendantCount,
            hasHierarchy: hasHierarchy
        )
    }

    func ancestorChain(of index: Int) -> Set<Int> {
        var result: Set<Int> = []
        var cur = index >= 0 && index < parentIndex.count ? parentIndex[index] : nil
        while let p = cur {
            result.insert(p)
            cur = parentIndex[p]
        }
        return result
    }

    func visibleIndices(in entries: [TocEntry], collapsedParents: Set<Int>) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(entries.count)
        var hiddenAboveLevel: Int? = nil

        for i in 0..<entries.count {
            let lvl = entries[i].level
            if let threshold = hiddenAboveLevel {
                if lvl > threshold {
                    continue
                } else {
                    hiddenAboveLevel = nil
                }
            }
            result.append(i)
            if hasChildren[i] && collapsedParents.contains(i) {
                hiddenAboveLevel = lvl
            }
        }
        return result
    }
}

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
    @State private var collapsedTocParents: Set<Int> = []
    @State private var expandedFlatGroups: Set<Int> = []
    @State private var didInitFoldState = false

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

    private var flatGroupSize: Int {
        displayToc.count >= 120 ? 50 : 20
    }

    private func flatGroupCount(totalCount: Int, groupSize: Int) -> Int {
        guard totalCount > 0 else { return 0 }
        return (totalCount + groupSize - 1) / groupSize
    }

    private func initializeFoldStateIfNeeded(tree: TocHierarchyInfo) {
        guard !didInitFoldState else { return }
        didInitFoldState = true
        if tree.hasHierarchy {
            if displayToc.count > 80 {
                let activeAncestors = tree.ancestorChain(of: activeTocIdx)
                let allParents = Set((0..<displayToc.count).filter { tree.hasChildren[$0] })
                collapsedTocParents = allParents.subtracting(activeAncestors)
            } else {
                collapsedTocParents = []
            }
        } else if displayToc.count >= 16 {
            let activeGroup = Swift.max(0, activeTocIdx) / flatGroupSize
            expandedFlatGroups = [activeGroup]
        }
    }

    private func allCollapsed(tree: TocHierarchyInfo, usesFlatGroups: Bool, groupCount: Int) -> Bool {
        if tree.hasHierarchy {
            let allParents = (0..<displayToc.count).filter { tree.hasChildren[$0] }
            return !allParents.isEmpty && allParents.allSatisfy { collapsedTocParents.contains($0) }
        } else if usesFlatGroups {
            return expandedFlatGroups.isEmpty && groupCount > 0
        }
        return false
    }

    private func toggleFoldAll(tree: TocHierarchyInfo, usesFlatGroups: Bool, groupCount: Int) {
        withAnimation(AppMotion.panelSpring) {
            if tree.hasHierarchy {
                if allCollapsed(tree: tree, usesFlatGroups: false, groupCount: 0) {
                    collapsedTocParents.removeAll()
                } else {
                    collapsedTocParents = Set((0..<displayToc.count).filter { tree.hasChildren[$0] })
                }
            } else if usesFlatGroups {
                if expandedFlatGroups.isEmpty {
                    expandedFlatGroups = Set(0..<groupCount)
                } else {
                    expandedFlatGroups.removeAll()
                }
            }
        }
    }

    var body: some View {
        let tree = TocHierarchyInfo.build(for: displayToc)
        let usesFlatGroups = !tree.hasHierarchy && displayToc.count >= 16
        let groupSize = flatGroupSize
        let groupCount = flatGroupCount(totalCount: displayToc.count, groupSize: groupSize)
        let isFoldable = tree.hasHierarchy || usesFlatGroups

        NavigationStack {
            VStack(spacing: 10) {
                GlassSegmentedControl(
                    titles: ["目录 (\(displayToc.count))", "本书笔记 (\(bookNotes.count))"],
                    selection: $tab,
                    compact: true
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if tab == 0 {
                    ScrollViewReader { proxy in
                        VStack(spacing: 6) {
                            if isFoldable {
                                tocFoldActionBar(
                                    tree: tree,
                                    usesFlatGroups: usesFlatGroups,
                                    groupCount: groupCount,
                                    groupSize: groupSize,
                                    proxy: proxy
                                )
                            }

                            List {
                                if tree.hasHierarchy {
                                    let visibleIndices = tree.visibleIndices(in: displayToc, collapsedParents: collapsedTocParents)
                                    let activeAncestors = tree.ancestorChain(of: activeTocIdx)
                                    ForEach(visibleIndices, id: \.self) { idx in
                                        hierarchicalTocRow(
                                            idx: idx,
                                            entry: displayToc[idx],
                                            tree: tree,
                                            activeAncestors: activeAncestors
                                        )
                                        .id(idx)
                                    }
                                } else if usesFlatGroups {
                                    ForEach(0..<groupCount, id: \.self) { gIdx in
                                        let start = gIdx * groupSize
                                        let end = Swift.min((gIdx + 1) * groupSize, displayToc.count)
                                        let isExpanded = expandedFlatGroups.contains(gIdx)
                                        let containsActive = activeTocIdx >= start && activeTocIdx < end

                                        flatGroupHeaderRow(
                                            groupIndex: gIdx,
                                            start: start,
                                            end: end,
                                            isExpanded: isExpanded,
                                            containsActive: containsActive
                                        )
                                        .id("toc_group_\(gIdx)")

                                        if isExpanded {
                                            ForEach(start..<end, id: \.self) { idx in
                                                flatTocRow(idx: idx, entry: displayToc[idx], indented: true)
                                                    .id(idx)
                                            }
                                        }
                                    }
                                } else {
                                    ForEach(Array(displayToc.enumerated()), id: \.offset) { idx, entry in
                                        flatTocRow(idx: idx, entry: entry, indented: false)
                                            .id(idx)
                                    }
                                }
                            }
                            .listStyle(.plain)
                            .contentMargins(.bottom, 12, for: .scrollContent)
                            .onAppear {
                                initializeFoldStateIfNeeded(tree: tree)
                                DispatchQueue.main.async {
                                    let target = Swift.max(0, activeTocIdx - 2)
                                    proxy.scrollTo(target, anchor: .top)
                                }
                            }
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
                        .contentMargins(.bottom, 12, for: .scrollContent)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Text("完成")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(minWidth: 164, minHeight: 46)
                            .contentShape(Capsule())
                            .background(Color.black.opacity(0.001), in: Capsule())
                            .appleLiquidGlassCapsule(tint: palette.accent.opacity(0.14), interactive: true)
                            .contentShape(Capsule())
                            .shadow(color: .black.opacity(palette.isLight ? 0.10 : 0.28), radius: 12, x: 0, y: 4)
                    }
                    .buttonStyle(GlassPressButtonStyle())
                    .contentShape(Capsule())
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .navigationTitle("目录与笔记")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func tocFoldActionBar(
        tree: TocHierarchyInfo,
        usesFlatGroups: Bool,
        groupCount: Int,
        groupSize: Int,
        proxy: ScrollViewProxy
    ) -> some View {
        let isAllCollapsed = allCollapsed(tree: tree, usesFlatGroups: usesFlatGroups, groupCount: groupCount)
        HStack(spacing: 8) {
            Button {
                withAnimation(AppMotion.panelSpring) {
                    if tree.hasHierarchy {
                        let ancestors = tree.ancestorChain(of: activeTocIdx)
                        collapsedTocParents.subtract(ancestors)
                    } else if usesFlatGroups {
                        let activeGroup = Swift.max(0, activeTocIdx) / groupSize
                        expandedFlatGroups.insert(activeGroup)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    withAnimation(AppMotion.panelSpring) {
                        proxy.scrollTo(activeTocIdx, anchor: .center)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "location.fill")
                        .font(.caption2)
                    Text("定位当前")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(palette.accent.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                toggleFoldAll(tree: tree, usesFlatGroups: usesFlatGroups, groupCount: groupCount)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isAllCollapsed ? "chevron.down.circle" : "chevron.up.circle")
                        .font(.caption2)
                    Text(isAllCollapsed ? "全部展开" : "全部折叠")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func hierarchicalTocRow(
        idx: Int,
        entry: TocEntry,
        tree: TocHierarchyInfo,
        activeAncestors: Set<Int>
    ) -> some View {
        let isActive = idx == activeTocIdx
        let hasKids = tree.hasChildren[idx]
        let isCollapsed = hasKids && collapsedTocParents.contains(idx)
        let containsActive = isCollapsed && activeAncestors.contains(idx)
        let relativeLevel = Swift.max(0, entry.level - tree.minLevel)
        let indent = CGFloat(Swift.min(4, relativeLevel) * 16)

        HStack(spacing: 8) {
            Button {
                onSelectToc(entry)
            } label: {
                HStack(spacing: 8) {
                    Text(entry.title)
                        .font(relativeLevel > 0 ? .subheadline : .body)
                        .fontWeight(isActive || containsActive ? .bold : (relativeLevel == 0 ? .medium : .regular))
                        .foregroundStyle((isActive || containsActive) ? palette.accent : (relativeLevel > 0 ? .secondary : .primary))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 4)

                    if isActive {
                        Image(systemName: "checkmark")
                            .font(.caption.bold())
                            .foregroundStyle(palette.accent)
                    } else if containsActive {
                        Text("当前")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(palette.accent.opacity(0.12), in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hasKids {
                Button {
                    withAnimation(AppMotion.panelSpring) {
                        if collapsedTocParents.contains(idx) {
                            collapsedTocParents.remove(idx)
                        } else {
                            collapsedTocParents.insert(idx)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(tree.descendantCount[idx])")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.down")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.08), in: Capsule())
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, indent)
    }

    @ViewBuilder
    private func flatGroupHeaderRow(
        groupIndex: Int,
        start: Int,
        end: Int,
        isExpanded: Bool,
        containsActive: Bool
    ) -> some View {
        Button {
            withAnimation(AppMotion.panelSpring) {
                if expandedFlatGroups.contains(groupIndex) {
                    expandedFlatGroups.remove(groupIndex)
                } else {
                    expandedFlatGroups.insert(groupIndex)
                }
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("第 \(start + 1) – \(end) 节")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(containsActive ? palette.accent : .primary)
                        if containsActive {
                            Text("当前")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(palette.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(palette.accent.opacity(0.12), in: Capsule())
                        }
                    }
                    if start < displayToc.count, end - 1 < displayToc.count {
                        Text("\(displayToc[start].title) … \(displayToc[end - 1].title)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    Text("\(end - start)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.08), in: Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func flatTocRow(idx: Int, entry: TocEntry, indented: Bool) -> some View {
        let isActive = idx == activeTocIdx
        Button {
            onSelectToc(entry)
        } label: {
            HStack {
                Text(entry.title)
                    .font(indented ? .subheadline : .body)
                    .fontWeight(isActive ? .bold : (indented ? .regular : .medium))
                    .foregroundStyle(isActive ? palette.accent : .primary)
                    .lineLimit(2)
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(palette.accent)
                }
            }
            .padding(.leading, indented ? 14 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    @State private var showCustomPalette = false
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

                                HStack(spacing: 10) {
                                    Text("自定义调色板")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        withAnimation(AppMotion.panelSpring) {
                                            showCustomPalette.toggle()
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(targetColor)
                                                .frame(width: 18, height: 18)
                                                .overlay {
                                                    Circle().strokeBorder(
                                                        AngularGradient(
                                                            colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                                            center: .center
                                                        ),
                                                        lineWidth: 2
                                                    )
                                                }
                                            Text(showCustomPalette ? "收起" : "调色")
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.primary)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.secondary.opacity(0.10), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }

                                if showCustomPalette {
                                    InlineCustomColorPalette(
                                        color: Binding(
                                            get: { targetColor },
                                            set: { newColor in
                                                activeColorTarget.update(newColor.toStoredHexInt64(), in: &store.settings)
                                            }
                                        ),
                                        supportsOpacity: activeColorTarget == .focusUnit,
                                        targetKey: activeColorTarget.rawValue
                                    )
                                    .transition(AppMotion.panelTransition)
                                }
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
                                GlassSegmentedControl(
                                    options: StepMode.allCases.map { ($0, $0.displayName) },
                                    selection: $store.settings.stepMode,
                                    compact: true
                                )
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
                            // Row 1: 音效（单行）
                            HStack(spacing: 8) {
                                Text("音效")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(StepSoundTrack.allCases, id: \.self) { track in
                                            let selected = store.settings.stepSoundTrack == track
                                            GlassCapsuleChip(title: track.displayName, selected: selected) {
                                                store.settings.stepSoundTrack = track
                                                feedbackPlayer.playTrackPreview(track: track)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }

                            // Row 2: 震动方式（强度与方式合行，最多两行）
                            HStack(spacing: 8) {
                                Text("震动")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .fixedSize()

                                GlassSegmentedControl(
                                    titles: ["关闭", "轻柔", "适中", "强烈"],
                                    selection: Binding(
                                        get: { store.settings.stepHapticLevel },
                                        set: { val in
                                            store.settings.stepHapticLevel = val
                                            feedbackPlayer.playHapticPreview(level: val, followLines: store.settings.stepHapticMode == .line)
                                        }
                                    ),
                                    compact: true
                                )
                                .frame(maxWidth: .infinity)

                                if store.settings.stepHapticLevel > 0 {
                                    let isLine = store.settings.stepHapticMode == .line
                                    GlassCapsuleChip(
                                        title: isLine ? "随行" : "单次",
                                        systemImage: "waveform",
                                        selected: isLine
                                    ) {
                                        let next: StepHapticMode = isLine ? .single : .line
                                        withAnimation(AppMotion.panelSpring) {
                                            store.settings.stepHapticMode = next
                                        }
                                        feedbackPlayer.playHapticPreview(level: store.settings.stepHapticLevel, followLines: next == .line)
                                    }
                                    .fixedSize()
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

private struct InlineCustomColorPalette: View {
    @Binding var color: Color
    let supportsOpacity: Bool
    let targetKey: String

    @State private var hue: Double = 0.58
    @State private var saturation: Double = 0.4
    @State private var brightness: Double = 0.9
    @State private var alpha: Double = 1.0

    var body: some View {
        let currentColor = Color(hue: hue, saturation: saturation, brightness: brightness, opacity: supportsOpacity ? alpha : 1.0)
        VStack(alignment: .leading, spacing: 10) {
            // 2D Saturation x Brightness Spectrum Pad
            GeometryReader { geo in
                let gw = max(1, geo.size.width)
                let gh = max(1, geo.size.height)
                let w = Double(gw)
                let h = Double(gh)
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(hue: hue, saturation: 1, brightness: 1))
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white, .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.clear, .black],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.28), lineWidth: 0.7)

                    Circle()
                        .fill(Color(hue: hue, saturation: saturation, brightness: brightness))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .overlay(Circle().strokeBorder(.black.opacity(0.28), lineWidth: 0.6))
                        .position(
                            x: min(max(9, CGFloat(saturation) * gw), gw - 9),
                            y: min(max(9, CGFloat(1.0 - brightness) * gh), gh - 9)
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            saturation = min(1.0, max(0.0, Double(value.location.x) / w))
                            brightness = min(1.0, max(0.0, 1.0 - Double(value.location.y) / h))
                            pushColor()
                        }
                )
            }
            .frame(height: 132)

            // Hue Bar
            GeometryReader { geo in
                let gw = max(1, geo.size.width)
                let gh = geo.size.height
                let w = Double(gw)
                ZStack {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(hue: 0.0, saturation: 1, brightness: 1),
                                    Color(hue: 1.0 / 6.0, saturation: 1, brightness: 1),
                                    Color(hue: 2.0 / 6.0, saturation: 1, brightness: 1),
                                    Color(hue: 3.0 / 6.0, saturation: 1, brightness: 1),
                                    Color(hue: 4.0 / 6.0, saturation: 1, brightness: 1),
                                    Color(hue: 5.0 / 6.0, saturation: 1, brightness: 1),
                                    Color(hue: 1.0, saturation: 1, brightness: 1)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 12)
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.24), lineWidth: 0.6))

                    Circle()
                        .fill(Color(hue: hue, saturation: 1, brightness: 1))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .overlay(Circle().strokeBorder(.black.opacity(0.28), lineWidth: 0.6))
                        .position(x: min(max(9, CGFloat(hue) * gw), gw - 9), y: gh * 0.5)
                }
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            hue = min(1.0, max(0.0, Double(value.location.x) / w))
                            pushColor()
                        }
                )
            }
            .frame(height: 22)

            // Opacity Bar (only for focusUnit)
            if supportsOpacity {
                GeometryReader { geo in
                    let gw = max(1, geo.size.width)
                    let gh = geo.size.height
                    let w = Double(gw)
                    let pure = Color(hue: hue, saturation: saturation, brightness: brightness)
                    ZStack {
                        Capsule()
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 12)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [pure.opacity(0.05), pure],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(height: 12)
                            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.24), lineWidth: 0.6))

                        Circle()
                            .fill(currentColor)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                            .overlay(Circle().strokeBorder(.black.opacity(0.28), lineWidth: 0.6))
                            .position(x: min(max(9, CGFloat((alpha - 0.05) / 0.95) * gw), gw - 9), y: gh * 0.5)
                    }
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let t = min(1.0, max(0.0, Double(value.location.x) / w))
                                alpha = 0.05 + t * 0.95
                                pushColor()
                            }
                    )
                }
                .frame(height: 22)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(currentColor)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 0.6))
                Text(currentColor.hexString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                if supportsOpacity {
                    Text("· \(Int((alpha * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.top, 4)
        .onAppear {
            syncFromExternalColor()
        }
        .onChange(of: targetKey) { _, _ in
            syncFromExternalColor()
        }
        .onChange(of: color.toStoredHexInt64()) { _, newHex in
            let currentHex = Color(hue: hue, saturation: saturation, brightness: brightness, opacity: supportsOpacity ? alpha : 1.0).toStoredHexInt64()
            if newHex != currentHex {
                syncFromExternalColor()
            }
        }
    }

    private func syncFromExternalColor() {
        let comps = color.hsbComponents()
        hue = comps.hue
        saturation = comps.saturation
        brightness = comps.brightness
        alpha = supportsOpacity ? max(0.05, comps.alpha) : 1.0
    }

    private func pushColor() {
        color = Color(
            hue: hue,
            saturation: saturation,
            brightness: brightness,
            opacity: supportsOpacity ? alpha : 1.0
        )
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

private struct TokenAttachPrevKey: LayoutValueKey {
    static let defaultValue: Bool = false
}

private struct TokenAttachNextKey: LayoutValueKey {
    static let defaultValue: Bool = false
}

private enum ReaderPunctHelper {
    static let closingSet: Set<Character> = [
        ",", ".", "!", "?", ";", ":", ")", "]", "}", "”", "’", "%", "…", "—",
        "，", "。", "、", "！", "？", "；", "：", "）", "】", "》", "」", "』"
    ]
    static let openingSet: Set<Character> = [
        "(", "[", "{", "“", "‘", "$", "（", "【", "《", "「", "『"
    ]
    static let asciiClosingSet: Set<Character> = [",", ".", "!", "?", ";", ":", ")", "]", "}"]

    static func attachesToPrevious(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return closingSet.contains(first)
    }

    static func attachesToNext(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return openingSet.contains(last)
    }

    static func trailingSpacing(for text: String) -> CGFloat {
        guard let last = text.last else { return 0 }
        return asciiClosingSet.contains(last) ? 2.5 : 0
    }
}

private struct TokenizedUnitTextView: View {
    let tokens: [TextToken]
    let fontSize: Double
    let lineSpacing: CGFloat
    let underlineEnabled: Bool
    let lookedUpMap: [String: Int]
    let selectedWord: String?
    let textColor: Color
    let accentColor: Color
    var onWordTap: (String) -> Void

    var body: some View {
        ReaderWordFlowLayout(horizontalSpacing: 0, verticalSpacing: lineSpacing) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                if token.isLookupable {
                    let clean: String = token.isCjk
                        ? token.text.filter { TextTokenizer.isChineseChar($0) }
                        : token.text.trimmingCharacters(in: CharacterSet.letters.inverted).lowercased()
                    let isKnown = underlineEnabled && !clean.isEmpty && (lookedUpMap[clean] ?? 0) > 0
                    let isSelected = !clean.isEmpty && selectedWord == clean

                    Text(token.text)
                        .font(.system(size: fontSize, weight: .regular, design: .serif))
                        .foregroundStyle(isSelected ? .white : textColor)
                        .padding(.horizontal, token.isCjk ? 0.5 : 2.5)
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
                    let attachPrev = ReaderPunctHelper.attachesToPrevious(token.text)
                    let attachNext = ReaderPunctHelper.attachesToNext(token.text)
                    Text(token.text)
                        .font(.system(size: fontSize, weight: .regular, design: .serif))
                        .foregroundStyle(textColor)
                        .padding(.vertical, 1)
                        .padding(.trailing, ReaderPunctHelper.trailingSpacing(for: token.text))
                        .layoutValue(key: TokenAttachPrevKey.self, value: attachPrev)
                        .layoutValue(key: TokenAttachNextKey.self, value: attachNext)
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
    var horizontalSpacing: CGFloat = 0
    var verticalSpacing: CGFloat = 4

    private struct TokenCluster {
        let range: Range<Int>
        let sizes: [CGSize]
        let width: CGFloat
        let height: CGFloat
    }

    private func buildClusters(subviews: Subviews) -> [TokenCluster] {
        var result: [TokenCluster] = []
        var i = 0
        while i < subviews.count {
            var end = i + 1
            while end < subviews.count && subviews[end - 1][TokenAttachNextKey.self] && (end - i) < 3 {
                end += 1
            }
            while end < subviews.count && subviews[end][TokenAttachPrevKey.self] && (end - i) < 4 {
                end += 1
            }
            var sizes: [CGSize] = []
            sizes.reserveCapacity(end - i)
            var w: CGFloat = 0
            var h: CGFloat = 0
            for k in i..<end {
                let s = subviews[k].sizeThatFits(.unspecified)
                sizes.append(s)
                w += s.width + (k > i ? horizontalSpacing : 0)
                h = Swift.max(h, s.height)
            }
            result.append(TokenCluster(range: i..<end, sizes: sizes, width: w, height: h))
            i = end
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        let clusters = buildClusters(subviews: subviews)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for cluster in clusters {
            if x + cluster.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            x += cluster.width + horizontalSpacing
            rowHeight = Swift.max(rowHeight, cluster.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let clusters = buildClusters(subviews: subviews)
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for cluster in clusters {
            if x + cluster.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            var cx = x
            for (offset, k) in cluster.range.enumerated() {
                let size = cluster.sizes[offset]
                subviews[k].place(at: CGPoint(x: cx, y: y), proposal: ProposedViewSize(size))
                cx += size.width + horizontalSpacing
            }
            x += cluster.width + horizontalSpacing
            rowHeight = Swift.max(rowHeight, cluster.height)
        }
    }
}
