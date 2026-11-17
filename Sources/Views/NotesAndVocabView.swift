import SwiftUI
#if canImport(Translation)
import Translation
#endif

struct NotesAndVocabView: View {
    @Environment(DatabaseManager.self) private var db
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(SpeechManager.self) private var speech
    @Environment(\.appPalette) private var palette

    var onJumpToBook: (BookItem, Int, Int) -> Void

    @State private var appleBridge = AppleTranslationBridge()
    @State private var segment = 0 // 0 = 句子, 1 = 词汇, 2 = 闪卡
    @State private var showSearch = false
    @State private var searchQuery = ""

    // Notes filters
    @State private var noteFilterMode = 0 // 0 = 全部, 1 = 有批注
    @State private var selectedNoteBookId: Int64? = nil
    @State private var editingNote: SentenceNote? = nil
    @State private var editDraft = ""

    // Vocab & Flashcard shared filters
    @State private var vocabLangFilter = 0 // 0 = 全部, 1 = 英文, 2 = 中文
    @State private var vocabMinLookup = 1
    @State private var vocabBookId: Int64? = nil
    @State private var flashIndex = 0
    @State private var flipped = false

    private var bookMap: [Int64: BookItem] {
        Dictionary(uniqueKeysWithValues: db.books.map { ($0.id, $0) })
    }

    private var noteBooks: [(Int64, String)] {
        var seen = Set<Int64>()
        var res: [(Int64, String)] = []
        for n in db.notes {
            if seen.insert(n.bookId).inserted {
                res.append((n.bookId, n.bookTitle))
            }
        }
        return res
    }

    private var filteredNotes: [SentenceNote] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return db.notes.filter { item in
            let passMode = noteFilterMode == 0 || !item.noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let passBook = selectedNoteBookId == nil || item.bookId == selectedNoteBookId
            let passQuery = q.isEmpty ||
                item.sentenceText.lowercased().contains(q) ||
                item.noteText.lowercased().contains(q) ||
                item.sentenceTranslation.lowercased().contains(q) ||
                item.bookTitle.lowercased().contains(q)
            return passMode && passBook && passQuery
        }
    }

    private func isChineseVocab(_ item: VocabItem) -> Bool {
        item.word.contains { TextTokenizer.isChineseChar($0) }
    }

    private var zhCount: Int {
        db.vocabList.filter { isChineseVocab($0) }.count
    }

    private var enCount: Int {
        db.vocabList.count - zhCount
    }

    private var vocabBooks: [(Int64, String)] {
        var seen = Set<Int64>()
        var res: [(Int64, String)] = []
        for item in db.vocabList {
            if let bid = item.bookId, !item.bookTitle.isEmpty, seen.insert(bid).inserted {
                res.append((bid, item.bookTitle))
            }
        }
        return res
    }

    private var filteredVocab: [VocabItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return db.vocabList.filter { item in
            let isZh = isChineseVocab(item)
            let passLang: Bool
            switch vocabLangFilter {
            case 1: passLang = !isZh
            case 2: passLang = isZh
            default: passLang = true
            }
            let passFreq = item.lookupCount >= vocabMinLookup
            let passBook = vocabBookId == nil || item.bookId == vocabBookId
            let passQuery = q.isEmpty ||
                item.word.lowercased().contains(q) ||
                item.lemma.lowercased().contains(q) ||
                item.translation.lowercased().contains(q) ||
                item.englishTranslation.lowercased().contains(q) ||
                item.contextSentence.lowercased().contains(q) ||
                item.bookTitle.lowercased().contains(q)
            return passLang && passFreq && passBook && passQuery
        }
    }

    private var canSearchCurrent: Bool {
        segment == 0 ? !db.notes.isEmpty : !db.vocabList.isEmpty
    }

    var body: some View {
        ZStack {
            AmbientGlassBackdrop(themeMode: settingsStore.settings.themeMode)

            VStack(spacing: 0) {
                // Clean custom header (avoids iOS 26 toolbar auto-glass double wrapping)
                HStack(spacing: 8) {
                    Text("笔记")
                        .font(.title2.bold())
                    if canSearchCurrent || showSearch {
                        GlassCircleIconButton(
                            systemImage: showSearch ? "xmark" : "magnifyingglass",
                            size: 32,
                            iconFont: .caption.bold(),
                            isActive: showSearch
                        ) {
                            withAnimation(AppMotion.panelSpring) {
                                showSearch.toggle()
                                if !showSearch { searchQuery = "" }
                            }
                        }
                    }
                    Spacer()
                    GlassSegmentedControl(
                        titles: ["句子", "词汇", "闪卡"],
                        selection: $segment,
                        compact: true
                    )
                    .frame(width: 184)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)

                if showSearch {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField(
                            segment == 0 ? "搜索句子、批注或书名..." : "搜索生词、释义、例句或书名...",
                            text: $searchQuery
                        )
                        .textFieldStyle(.plain)
                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .appleLiquidGlassRect(cornerRadius: 14, interactive: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
                    .transition(AppMotion.panelTransition)
                }

                GlassHorizontalPager(selection: $segment, pageCount: 3) { page in
                    switch page {
                    case 0: notesPage
                    case 1: vocabPage
                    default: flashcardsPage
                    }
                }
                .onChange(of: segment) { _, _ in
                    flipped = false
                }
            }
        }
        .sheet(item: $editingNote) { note in
            NavigationStack {
                Form {
                    Section("原句") {
                        Text(note.sentenceText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Section("我的想法 / 批注") {
                        TextEditor(text: $editDraft)
                            .frame(minHeight: 130)
                    }
                }
                .navigationTitle("编辑句子笔记")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") { editingNote = nil }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") {
                            db.updateNoteText(id: note.id, noteText: editDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                            editingNote = nil
                        }
                        .bold()
                    }
                }
            }
            .presentationDetents([.medium])
        }
        #if canImport(Translation)
        .translationTask(appleBridge.configuration) { session in
            await appleBridge.handleSession(session)
        }
        #endif
    }

    // MARK: - Page 0: Notes

    private var notesPage: some View {
        VStack(spacing: 0) {
            if !db.notes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChipButton(
                            title: "全部",
                            selected: noteFilterMode == 0 && selectedNoteBookId == nil
                        ) {
                            noteFilterMode = 0
                            selectedNoteBookId = nil
                        }
                        FilterChipButton(
                            title: "有批注",
                            selected: noteFilterMode == 1
                        ) {
                            noteFilterMode = noteFilterMode == 1 ? 0 : 1
                        }
                        ForEach(noteBooks, id: \.0) { bid, bTitle in
                            FilterChipButton(
                                title: bTitle,
                                selected: selectedNoteBookId == bid
                            ) {
                                selectedNoteBookId = selectedNoteBookId == bid ? nil : bid
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                }
            }

            if filteredNotes.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 32))
                        .foregroundStyle(palette.accent)
                        .padding(16)
                        .background(palette.accent.opacity(0.10), in: Circle())
                    Text(db.notes.isEmpty
                         ? "还没有收藏句子或笔记\n阅读时点击句卡右下角的星标或笔记图标即可记录"
                         : "没有找到匹配的句子笔记")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .padding(32)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredNotes) { note in
                            let targetBook = bookMap[note.bookId]
                            NoteCardView(
                                note: note,
                                canJump: targetBook != nil,
                                onJumpToBook: {
                                    if let targetBook {
                                        onJumpToBook(targetBook, note.chapterIndex, note.unitIndex)
                                    }
                                },
                                onEdit: {
                                    editDraft = note.noteText
                                    editingNote = note
                                },
                                onDelete: {
                                    db.deleteNote(id: note.id)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    // MARK: - Page 1: Vocab List

    private var vocabPage: some View {
        VStack(spacing: 0) {
            vocabFilterBar
            if filteredVocab.isEmpty {
                vocabEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredVocab) { item in
                            VocabCardView(
                                item: item,
                                isZh: isChineseVocab(item),
                                onSpeak: { speech.speak($0) },
                                onDelete: { db.deleteVocab(id: item.id) }
                            )
                            .task(id: item.id) {
                                await resolveMissingVocabTranslation(item)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    // MARK: - Page 2: Flashcards

    private var flashcardsPage: some View {
        let deck = filteredVocab.filter { $0.familiarity != 2 }
        return VStack(spacing: 0) {
            vocabFilterBar
            if deck.isEmpty {
                if !filteredVocab.isEmpty {
                    let knownIds = filteredVocab.map(\.id)
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(palette.accent)
                            .padding(16)
                            .background(palette.accent.opacity(0.12), in: Circle())
                        Text("当前 \(filteredVocab.count) 个词汇已全部认识")
                            .font(.headline)
                        Text("标记为「认识」的词汇已从闪卡中移除\n若需再次练习，可重置这些词汇的闪卡状态")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重新复习这些词汇") {
                            flashIndex = 0
                            flipped = false
                            db.resetKnownVocab(ids: knownIds)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(32)
                    Spacer()
                } else {
                    vocabEmptyState
                }
            } else {
                let safeIdx = min(max(0, flashIndex), deck.count - 1)
                let card = deck[safeIdx]
                let isZhCard = isChineseVocab(card)

                GeometryReader { geo in
                    let maxCardH = max(160, geo.size.height - 126)

                    VStack(spacing: 12) {
                        VStack(spacing: 6) {
                            HStack {
                                Text("\(safeIdx + 1) / \(deck.count)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(palette.accent)
                                Spacer()
                                Text("\(isZhCard ? "中文" : "英文") · 已查 \(card.lookupCount) 次")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            SmoothLinearProgressBar(
                                progress: Double(safeIdx + 1) / Double(deck.count),
                                height: 4
                            )
                        }

                        FlashcardDeckCard(
                            card: card,
                            flipped: $flipped,
                            maxHeight: maxCardH,
                            onSpeak: { speech.speak($0) },
                            onResolveMissingTranslation: { item in
                                await resolveMissingVocabTranslation(item)
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                        flashcardActionButtonsRow(safeIdx: safeIdx, deck: deck, card: card)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                }
            }
        }
    }

    private func resolveMissingVocabTranslation(_ item: VocabItem) async {
        guard TranslationService.isDictionaryPlaceholder(item.translation) else { return }
        let isZh = isChineseVocab(item)
        if isZh {
            if let en = await TranslationService.translateWordToEnglishOffline(
                word: item.word,
                db: db,
                appleTranslator: { text, toEn in
                    try await appleBridge.translate(text, toEnglish: toEn)
                }
            ), !en.isEmpty {
                db.updateVocabEnglishTranslation(word: item.word, englishTranslation: en)
                db.updateVocabTranslation(word: item.word, translation: en)
            }
        } else {
            if let res = await TranslationService.translateWordToChinese(
                word: item.word,
                lemma: item.lemma,
                phonetic: item.phonetic,
                db: db,
                appleTranslator: { text, toEn in
                    try await appleBridge.translate(text, toEnglish: toEn)
                }
            ), !res.text.isEmpty {
                db.updateVocabTranslation(word: item.word, translation: res.text)
            }
        }
    }

    @ViewBuilder
    private func flashcardActionButtonsRow(safeIdx: Int, deck: [VocabItem], card: VocabItem) -> some View {
        HStack(spacing: 10) {
            flashActionButton(title: "不认识", tint: .red, prominent: false) {
                db.updateVocabFamiliarity(id: card.id, familiarity: 0)
                withAnimation(AppMotion.cardSpring) {
                    flipped = false
                    flashIndex = (safeIdx + 1) % deck.count
                }
            }

            flashActionButton(title: "模糊", tint: .orange, prominent: false) {
                db.updateVocabFamiliarity(id: card.id, familiarity: 1)
                withAnimation(AppMotion.cardSpring) {
                    flipped = false
                    flashIndex = (safeIdx + 1) % deck.count
                }
            }

            flashActionButton(title: "认识", tint: palette.accent, prominent: true) {
                db.updateVocabFamiliarity(id: card.id, familiarity: 2)
                withAnimation(AppMotion.cardSpring) {
                    flipped = false
                    flashIndex = safeIdx >= deck.count - 1 ? 0 : safeIdx
                }
            }
        }
    }

    // MARK: - Shared Vocab Filter Bar & Empty State

    private var vocabFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChipButton(title: "全部 \(db.vocabList.count)", selected: vocabLangFilter == 0) {
                    vocabLangFilter = 0
                    flashIndex = 0
                    flipped = false
                }
                FilterChipButton(title: "英文 \(enCount)", selected: vocabLangFilter == 1) {
                    vocabLangFilter = 1
                    flashIndex = 0
                    flipped = false
                }
                FilterChipButton(title: "中文 \(zhCount)", selected: vocabLangFilter == 2) {
                    vocabLangFilter = 2
                    flashIndex = 0
                    flipped = false
                }

                Divider().frame(height: 16)

                FilterChipButton(title: "全部频次", selected: vocabMinLookup == 1) {
                    vocabMinLookup = 1
                    flashIndex = 0
                    flipped = false
                }
                FilterChipButton(title: "≥2 次", selected: vocabMinLookup == 2) {
                    vocabMinLookup = 2
                    flashIndex = 0
                    flipped = false
                }
                FilterChipButton(title: "重点 ≥3 次", selected: vocabMinLookup == 3) {
                    vocabMinLookup = 3
                    flashIndex = 0
                    flipped = false
                }

                if !vocabBooks.isEmpty {
                    Divider().frame(height: 16)
                    ForEach(vocabBooks, id: \.0) { bid, title in
                        FilterChipButton(title: title, selected: vocabBookId == bid) {
                            vocabBookId = vocabBookId == bid ? nil : bid
                            flashIndex = 0
                            flipped = false
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
    }

    private var vocabEmptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "character.book.closed")
                .font(.system(size: 34))
                .foregroundStyle(palette.accent)
                .padding(16)
                .background(palette.accent.opacity(0.10), in: Circle())
            Text(db.vocabList.isEmpty
                 ? "暂无生词\n在阅读时轻点单词或词语即可自动收录"
                 : (!searchQuery.isEmpty ? "没有找到匹配的生词" : "暂无符合筛选条件的生词"))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(32)
    }

    @ViewBuilder
    private func flashActionButton(
        title: String,
        tint: Color,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            let label = Text(title)
                .font(.subheadline.weight(prominent ? .semibold : .medium))
                .foregroundStyle(prominent ? .white : tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(Capsule())

            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                let glass: Glass = prominent
                    ? .regular.tint(tint.opacity(0.86)).interactive()
                    : .regular.tint(tint.opacity(0.14)).interactive()
                label.glassEffect(glass, in: Capsule())
            } else {
                legacyFlashButtonLabel(label: label, tint: tint, prominent: prominent)
            }
            #else
            legacyFlashButtonLabel(label: label, tint: tint, prominent: prominent)
            #endif
        }
        .buttonStyle(GlassPressButtonStyle())
    }

    @ViewBuilder
    private func legacyFlashButtonLabel<L: View>(label: L, tint: Color, prominent: Bool) -> some View {
        label
            .background {
                if prominent {
                    ZStack {
                        Capsule().fill(tint)
                        Capsule().fill(
                            LinearGradient(
                                colors: [.white.opacity(0.24), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                } else {
                    ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().fill(tint.opacity(0.10))
                    }
                }
            }
            .overlay {
                Capsule().strokeBorder(
                    prominent ? .white.opacity(0.35) : tint.opacity(0.32),
                    lineWidth: 0.85
                )
            }
            .shadow(color: .black.opacity(palette.isLight ? 0.06 : 0.18), radius: 6, x: 0, y: 2)
    }
}

// MARK: - Reusable Subviews

private struct FilterChipButton: View {
    let title: String
    let selected: Bool
    var action: () -> Void

    var body: some View {
        GlassCapsuleChip(title: title, selected: selected, action: action)
    }
}

private struct NoteCardView: View {
    let note: SentenceNote
    let canJump: Bool
    var onJumpToBook: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    @Environment(\.appPalette) private var palette

    private var formattedDate: String {
        let date = Date(timeIntervalSince1970: Double(note.updatedAt) / 1000.0)
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    var body: some View {
        GlassCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    AppleIconBadge(systemImage: "book.closed.fill", size: 26, cornerRadius: 7)

                    let pillText = note.chapterTitle.isEmpty
                        ? note.bookTitle
                        : "\(note.bookTitle) · \(note.chapterTitle)"
                    Text(pillText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if canJump {
                        Button(action: onJumpToBook) {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(palette.accent)
                                .frame(width: 28, height: 28)
                                .background(palette.accent.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(GlassPressButtonStyle())
                    }
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.secondary.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(GlassPressButtonStyle())
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.secondary.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(GlassPressButtonStyle())
                }

                // Quote block with Apple rounded vertical highlight capsule
                HStack(alignment: .top, spacing: 10) {
                    Capsule()
                        .fill(palette.accent.opacity(0.75))
                        .frame(width: 3.5)
                        .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(note.sentenceText)
                            .font(.system(.subheadline, design: .serif))
                            .lineSpacing(3)
                            .foregroundStyle(.primary)
                        if !note.sentenceTranslation.isEmpty {
                            Divider()
                                .opacity(0.45)
                            Text(note.sentenceTranslation)
                                .font(.caption)
                                .lineSpacing(2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(palette.isLight ? 0.45 : 0.10), lineWidth: 0.5)
                )

                if !note.noteText.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "note.text")
                            .font(.caption)
                            .foregroundStyle(palette.accent)
                            .padding(.top, 2)
                        Text(note.noteText)
                            .font(.subheadline)
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(palette.accent.opacity(0.16), lineWidth: 0.55)
                    )
                }

                HStack {
                    Label(formattedDate, systemImage: "clock")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onEdit) {
                        Text(note.noteText.isEmpty ? "添加批注" : "编辑批注")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(palette.accent.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(GlassPressButtonStyle())
                }
            }
            .padding(16)
        }
    }
}

private struct VocabCardView: View {
    let item: VocabItem
    let isZh: Bool
    var onSpeak: (String) -> Void
    var onDelete: () -> Void

    @Environment(\.appPalette) private var palette
    @State private var transExpanded = false
    @State private var contextExpanded = false

    private var formattedTrans: String {
        item.translation
            .replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canExpandTrans: Bool {
        formattedTrans.count > 90 || formattedTrans.filter { $0 == "\n" }.count >= 3
    }

    var body: some View {
        GlassCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.word)
                            .font(.system(.title3, design: .serif).bold())
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .layoutPriority(1)
                        if !item.phonetic.isEmpty {
                            Text(item.phonetic)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }

                    Button { onSpeak(item.word) } label: {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.accent)
                            .frame(width: 26, height: 26)
                            .background(palette.accent.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(GlassPressButtonStyle())
                    .fixedSize()

                    Spacer(minLength: 4)

                    HStack(spacing: 5) {
                        if item.familiarity == 2 {
                            vocabStatusBadge(text: "已认识", color: .green)
                        } else if item.familiarity == 1 {
                            vocabStatusBadge(text: "模糊", color: .orange)
                        }
                        MinimalTagPill(
                            text: "\(isZh ? "中" : "EN") · ×\(item.lookupCount)",
                            tintColor: (isZh ? Color.teal : palette.accent).opacity(0.12),
                            textColor: isZh ? .teal : palette.accent
                        )
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 26, height: 26)
                                .background(Color.secondary.opacity(0.10), in: Circle())
                        }
                        .buttonStyle(GlassPressButtonStyle())
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                if !item.englishTranslation.isEmpty {
                    HStack(spacing: 8) {
                        Text("EN")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Color.teal, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .foregroundStyle(.white)
                        Text(item.englishTranslation)
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { onSpeak(item.englishTranslation) } label: {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption2)
                                .foregroundStyle(.teal)
                                .frame(width: 24, height: 24)
                                .background(Color.teal.opacity(0.14), in: Circle())
                        }
                        .buttonStyle(GlassPressButtonStyle())
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.teal.opacity(0.18), lineWidth: 0.55)
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    if TranslationService.isDictionaryPlaceholder(formattedTrans) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在通过 Apple 翻译获取释义...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(formattedTrans)
                            .font(.subheadline)
                            .lineSpacing(3)
                            .lineLimit((transExpanded || !canExpandTrans) ? nil : 4)
                        if canExpandTrans {
                            Button(transExpanded ? "收起" : "展开全部") {
                                withAnimation(AppMotion.panelSpring) {
                                    transExpanded.toggle()
                                }
                            }
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.accent)
                        }
                    }
                }

                if !item.contextSentence.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(AppMotion.panelSpring) {
                                contextExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "quote.opening")
                                    .font(.caption2.bold())
                                    .foregroundStyle(palette.accent)
                                Text("原文例句")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(contextExpanded ? "收起" : "展开")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(palette.accent)
                                Image(systemName: "chevron.down")
                                    .font(.caption2.bold())
                                    .foregroundStyle(palette.accent)
                                    .rotationEffect(.degrees(contextExpanded ? 180 : 0))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if contextExpanded {
                            VStack(alignment: .leading, spacing: 5) {
                                Divider()
                                    .opacity(0.45)
                                Text("“\(item.contextSentence)”")
                                    .font(.system(.caption, design: .serif).italic())
                                    .lineSpacing(2)
                                if !item.contextTranslation.isEmpty {
                                    Text(item.contextTranslation)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                            .transition(AppMotion.panelTransition)
                        }
                    }
                    .background(
                        (contextExpanded ? palette.accent.opacity(0.08) : Color.secondary.opacity(0.06)),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(palette.isLight ? 0.40 : 0.10), lineWidth: 0.5)
                    )
                }

                if !item.bookTitle.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "book.closed")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(item.bookTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(16)
        }
    }

    private func vocabStatusBadge(text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(color)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
}

private struct FlashcardDeckCard: View {
    let card: VocabItem
    @Binding var flipped: Bool
    var maxHeight: CGFloat = 340
    var onSpeak: (String) -> Void
    var onResolveMissingTranslation: (VocabItem) async -> Void = { _ in }

    @Environment(\.appPalette) private var palette
    @State private var sentenceExpanded = false

    private func toggleFlip() {
        withAnimation(AppMotion.panelSpring) {
            flipped.toggle()
        }
    }

    @ViewBuilder
    private var cardInnerContent: some View {
        VStack(spacing: 14) {
            HStack(spacing: 5) {
                Image(systemName: flipped ? "sparkles" : "hand.tap")
                    .font(.caption2.weight(.semibold))
                Text(flipped ? "释义已展开 · 点击收起" : "轻点卡片翻看释义")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(flipped ? palette.accent : .secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 4.5)
            .background((flipped ? palette.accent.opacity(0.12) : Color.secondary.opacity(0.10)), in: Capsule())

            Text(card.word)
                .font(.system(.largeTitle, design: .serif).bold())
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            HStack(spacing: 8) {
                if !card.phonetic.isEmpty {
                    Text(card.phonetic)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Button { onSpeak(card.word) } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.accent)
                        .frame(width: 32, height: 32)
                        .background(palette.accent.opacity(0.12), in: Circle())
                }
                .buttonStyle(GlassPressButtonStyle())
            }

            if !card.contextSentence.isEmpty {
                VStack(spacing: 5) {
                    Text("“\(card.contextSentence)”")
                        .font(.system(.caption, design: .serif).italic())
                        .lineSpacing(2.5)
                        .multilineTextAlignment(.center)
                        .lineLimit(sentenceExpanded ? nil : 3)
                    if card.contextSentence.count > 90 {
                        Button(sentenceExpanded ? "收起原句" : "展开原句") {
                            withAnimation(AppMotion.panelSpring) {
                                sentenceExpanded.toggle()
                            }
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.accent)
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(palette.isLight ? 0.40 : 0.10), lineWidth: 0.5)
                )
            }

            if flipped {
                VStack(spacing: 10) {
                    Divider()
                        .opacity(0.5)
                    if !card.englishTranslation.isEmpty {
                        HStack(spacing: 6) {
                            Text(card.englishTranslation)
                                .font(.headline)
                                .foregroundStyle(.teal)
                            Button { onSpeak(card.englishTranslation) } label: {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.caption)
                                    .foregroundStyle(.teal)
                                    .frame(width: 26, height: 26)
                                    .background(Color.teal.opacity(0.14), in: Circle())
                            }
                            .buttonStyle(GlassPressButtonStyle())
                        }
                    }
                    if TranslationService.isDictionaryPlaceholder(card.translation) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在通过 Apple 翻译获取释义...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(card.translation.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression))
                            .font(.headline)
                            .lineSpacing(3)
                            .minimumScaleFactor(0.82)
                            .multilineTextAlignment(.center)
                    }
                    if !card.contextTranslation.isEmpty {
                        Text(card.contextTranslation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.top, 4)
                .transition(
                    .asymmetric(
                        insertion: .opacity
                            .combined(with: .scale(scale: 0.94, anchor: .top))
                            .combined(with: .offset(y: -8)),
                        removal: .opacity
                            .combined(with: .scale(scale: 0.95, anchor: .top))
                            .combined(with: .offset(y: -6))
                    )
                )
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            toggleFlip()
        }
    }

    var body: some View {
        GlassCard(cornerRadius: 26, tintColor: flipped ? palette.accent.opacity(0.05) : nil) {
            cardInnerContent
                .frame(maxHeight: maxHeight)
                .clipped()
        }
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture {
            toggleFlip()
        }
        .task(id: card.id) {
            await onResolveMissingTranslation(card)
        }
        .onChange(of: card.id) { _, _ in
            sentenceExpanded = false
        }
    }
}
