import SwiftUI

struct NotesAndVocabView: View {
    @Environment(DatabaseManager.self) private var db
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(SpeechManager.self) private var speech
    @Environment(\.appPalette) private var palette

    var onJumpToBook: (BookItem, Int, Int) -> Void

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
        item.word.unicodeScalars.contains { TextTokenizer.isChineseChar($0) }
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
        NavigationStack {
            ZStack {
                AmbientGlassBackdrop(themeMode: settingsStore.settings.themeMode)

                VStack(spacing: 0) {
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
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.28), lineWidth: 0.7))
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                        .transition(AppMotion.panelTransition)
                    }

                    TabView(selection: $segment) {
                        notesPage.tag(0)
                        vocabPage.tag(1)
                        flashcardsPage.tag(2)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .onChange(of: segment) { _, _ in
                        flipped = false
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 6) {
                        Text("笔记")
                            .font(.title2.bold())
                        if canSearchCurrent || showSearch {
                            Button {
                                withAnimation(AppMotion.panelSpring) {
                                    showSearch.toggle()
                                    if !showSearch { searchQuery = "" }
                                }
                            } label: {
                                Image(systemName: showSearch ? "xmark" : "magnifyingglass")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(showSearch ? palette.accent : .secondary)
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("笔记视图", selection: Binding(
                        get: { segment },
                        set: { next in
                            withAnimation(AppMotion.tabSpring) { segment = next }
                        }
                    )) {
                        Text("句子").tag(0)
                        Text("词汇").tag(1)
                        Text("闪卡").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 174)
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
        }
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
                    .padding(.vertical, 8)
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
                    .padding(.vertical, 10)
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
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
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

                VStack(spacing: 14) {
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
                        onSpeak: { speech.speak($0) }
                    )

                    HStack(spacing: 10) {
                        Button {
                            db.updateVocabFamiliarity(id: card.id, familiarity: 0)
                            withAnimation(AppMotion.cardSpring) {
                                flipped = false
                                flashIndex = (safeIdx + 1) % deck.count
                            }
                        } label: {
                            Text("不认识")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            db.updateVocabFamiliarity(id: card.id, familiarity: 1)
                            withAnimation(AppMotion.cardSpring) {
                                flipped = false
                                flashIndex = (safeIdx + 1) % deck.count
                            }
                        } label: {
                            Text("模糊")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            db.updateVocabFamiliarity(id: card.id, familiarity: 2)
                            withAnimation(AppMotion.cardSpring) {
                                flipped = false
                                flashIndex = safeIdx >= deck.count - 1 ? 0 : safeIdx
                            }
                        } label: {
                            Text("认识")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
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
            .padding(.vertical, 8)
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
}

// MARK: - Reusable Subviews

private struct FilterChipButton: View {
    let title: String
    let selected: Bool
    var action: () -> Void

    @Environment(\.appPalette) private var palette

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(selected ? .semibold : .medium))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(selected ? palette.accent.opacity(0.18) : Color.secondary.opacity(0.11), in: Capsule())
                .foregroundStyle(selected ? palette.accent : .primary)
                .overlay(
                    Capsule().strokeBorder(selected ? palette.accent.opacity(0.55) : Color.clear, lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
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
        GlassCard(cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    let pillText = note.chapterTitle.isEmpty
                        ? note.bookTitle
                        : "\(note.bookTitle) · \(note.chapterTitle)"
                    MinimalTagPill(text: pillText)
                    Spacer()
                    if canJump {
                        Button(action: onJumpToBook) {
                            Image(systemName: "book.pages")
                                .font(.caption)
                                .foregroundStyle(palette.accent)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                    }
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }

                // Quote block with left accent bar
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(palette.accent.opacity(0.62))
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(note.sentenceText)
                            .font(.system(.subheadline, design: .serif))
                            .foregroundStyle(.primary)
                        if !note.sentenceTranslation.isEmpty {
                            Divider()
                            Text(note.sentenceTranslation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if !note.noteText.isEmpty {
                    Text(note.noteText)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.accent.opacity(0.09))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                HStack {
                    Text(formattedDate)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(note.noteText.isEmpty ? "添加批注" : "编辑批注", action: onEdit)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.accent)
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
        GlassCard(cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Text(item.word)
                        .font(.title3.bold())
                    MinimalTagPill(
                        text: isZh ? "中" : "EN",
                        tintColor: (isZh ? Color.teal : palette.accent).opacity(0.14),
                        textColor: isZh ? .teal : palette.accent
                    )
                    if !item.phonetic.isEmpty {
                        Text(item.phonetic)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    MinimalTagPill(text: "×\(item.lookupCount)")
                    if item.familiarity == 2 {
                        MinimalTagPill(text: "已认识", tintColor: Color.green.opacity(0.14), textColor: .green)
                    } else if item.familiarity == 1 {
                        MinimalTagPill(text: "模糊", tintColor: Color.orange.opacity(0.14), textColor: .orange)
                    }
                    Spacer()
                    Button { onSpeak(item.word) } label: {
                        Image(systemName: "speaker.wave.2")
                            .font(.caption)
                            .foregroundStyle(palette.accent)
                    }
                    .buttonStyle(.plain)
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if !item.englishTranslation.isEmpty {
                    HStack(spacing: 8) {
                        Text("EN")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.teal)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        Text(item.englishTranslation)
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { onSpeak(item.englishTranslation) } label: {
                            Image(systemName: "speaker.wave.2")
                                .font(.caption)
                                .foregroundStyle(.teal)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.teal.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(formattedTrans)
                        .font(.subheadline)
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

                if !item.contextSentence.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(AppMotion.panelSpring) {
                                contextExpanded.toggle()
                            }
                        } label: {
                            HStack {
                                Text("原文")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(contextExpanded ? "收起" : "展开")
                                    .font(.caption2)
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
                            VStack(alignment: .leading, spacing: 4) {
                                Text("“\(item.contextSentence)”")
                                    .font(.caption.italic())
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
                    .background(contextExpanded ? palette.accent.opacity(0.08) : Color.secondary.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(palette.accent.opacity(0.45))
                            .frame(width: 3)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if !item.bookTitle.isEmpty {
                    MinimalTagPill(text: item.bookTitle)
                }
            }
            .padding(16)
        }
    }
}

private struct FlashcardDeckCard: View {
    let card: VocabItem
    @Binding var flipped: Bool
    var onSpeak: (String) -> Void

    @Environment(\.appPalette) private var palette
    @State private var sentenceExpanded = false

    var body: some View {
        GlassCard(cornerRadius: 24, tintColor: flipped ? palette.accent.opacity(0.05) : nil) {
            ScrollView {
                VStack(spacing: 14) {
                    MinimalTagPill(
                        text: flipped ? "释义已展开 · 点击收起" : "点击卡片查看释义",
                        tintColor: flipped ? palette.accent.opacity(0.14) : Color.secondary.opacity(0.12),
                        textColor: flipped ? palette.accent : .secondary
                    )

                    Text(card.word)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)

                    HStack(spacing: 6) {
                        if !card.phonetic.isEmpty {
                            Text(card.phonetic)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        Button { onSpeak(card.word) } label: {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(palette.accent)
                        }
                    }

                    if !card.contextSentence.isEmpty {
                        VStack(spacing: 4) {
                            Text("“\(card.contextSentence)”")
                                .font(.caption.italic())
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
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if flipped {
                        VStack(spacing: 10) {
                            Divider()
                            if !card.englishTranslation.isEmpty {
                                HStack(spacing: 6) {
                                    Text(card.englishTranslation)
                                        .font(.headline)
                                        .foregroundStyle(.teal)
                                    Button { onSpeak(card.englishTranslation) } label: {
                                        Image(systemName: "speaker.wave.2")
                                            .font(.subheadline)
                                            .foregroundStyle(.teal)
                                    }
                                }
                            }
                            Text(card.translation.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression))
                                .font(.headline)
                                .multilineTextAlignment(.center)
                            if !card.contextTranslation.isEmpty {
                                Text(card.contextTranslation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(.top, 6)
                        .transition(AppMotion.panelTransition)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: 320)
                .contentShape(Rectangle())
            }
            .clipped()
        }
        .onTapGesture {
            withAnimation(AppMotion.panelSpring) {
                flipped.toggle()
            }
        }
        .onChange(of: card.id) { _, _ in
            sentenceExpanded = false
        }
    }
}
