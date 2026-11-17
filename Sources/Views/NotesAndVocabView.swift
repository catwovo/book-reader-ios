import SwiftUI

struct NotesAndVocabView: View {
    @Environment(DatabaseManager.self) private var db
    @Environment(SpeechManager.self) private var speech

    var onJumpToBook: (BookItem, Int, Int) -> Void

    @State private var segment = 0 // 0 = 句子, 1 = 词汇, 2 = 闪卡
    @State private var searchText = ""
    @State private var minLookup = 1
    @State private var selectedBookId: Int64? = nil
    @State private var flashIndex = 0
    @State private var flipped = false
    @State private var editingNote: SentenceNote?
    @State private var editDraft = ""

    private var filteredNotes: [SentenceNote] {
        db.notes.filter { note in
            if let bid = selectedBookId, note.bookId != bid { return false }
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                return note.sentenceText.lowercased().contains(q)
                    || note.noteText.lowercased().contains(q)
                    || note.bookTitle.lowercased().contains(q)
            }
            return true
        }
    }

    private var filteredVocab: [VocabItem] {
        db.vocabList.filter { item in
            if let bid = selectedBookId, item.bookId != bid { return false }
            if item.lookupCount < minLookup { return false }
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                return item.word.lowercased().contains(q) || item.translation.lowercased().contains(q)
            }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("分类", selection: $segment) {
                    Text("句子 (\(filteredNotes.count))").tag(0)
                    Text("词汇 (\(filteredVocab.count))").tag(1)
                    Text("闪卡").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .onChange(of: segment) { _, _ in flipped = false }

                if segment == 0 {
                    notesList
                } else if segment == 1 {
                    vocabList
                } else {
                    flashcardView
                }
            }
            .navigationTitle("笔记与词库")
            .searchable(text: $searchText, prompt: "搜索句子、单词或释义")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("全部书籍") { selectedBookId = nil }
                        ForEach(db.books) { b in
                            Button(b.title) { selectedBookId = b.id }
                        }
                        if segment != 0 {
                            Divider()
                            Button("全部次数 (≥1)") { minLookup = 1 }
                            Button("高频生词 (≥2)") { minLookup = 2 }
                            Button("核心难点 (≥3)") { minLookup = 3 }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(item: $editingNote) { note in
                NavigationStack {
                    Form {
                        Section("原句") {
                            Text(note.sentenceText).font(.footnote).foregroundStyle(.secondary)
                        }
                        Section("批注") {
                            TextEditor(text: $editDraft).frame(minHeight: 120)
                        }
                    }
                    .navigationTitle("编辑笔记")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("取消") { editingNote = nil }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("保存") {
                                db.updateNoteText(id: note.id, noteText: editDraft)
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

    private var notesList: some View {
        Group {
            if filteredNotes.isEmpty {
                ContentUnavailableView(
                    "暂无句子笔记",
                    systemImage: "bookmark",
                    description: Text("阅读时点击译文卡片右上角「记笔记」即可收藏句子与批注")
                )
            } else {
                List {
                    ForEach(filteredNotes) { note in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("“\(note.sentenceText)”")
                                .font(.subheadline.italic())
                            if !note.sentenceTranslation.isEmpty {
                                Text(note.sentenceTranslation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !note.noteText.isEmpty {
                                Text(note.noteText)
                                    .font(.footnote)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.accentColor.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            HStack {
                                Text("《\(note.bookTitle)》")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if let book = db.books.first(where: { $0.id == note.bookId }) {
                                    Button("回到原书") {
                                        onJumpToBook(book, note.chapterIndex, note.unitIndex)
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                db.deleteNote(id: note.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                editDraft = note.noteText
                                editingNote = note
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private var vocabList: some View {
        Group {
            if filteredVocab.isEmpty {
                ContentUnavailableView(
                    "暂无生词记录",
                    systemImage: "character.book.closed",
                    description: Text("在阅读器中轻触任意英文单词即可自动收录")
                )
            } else {
                List {
                    ForEach(filteredVocab) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.word)
                                    .font(.headline)
                                    .foregroundStyle(Color.accentColor)
                                Text(item.phonetic)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button {
                                    speech.speak(item.word)
                                } label: {
                                    Image(systemName: "speaker.wave.2")
                                        .font(.caption)
                                }
                                Spacer()
                                Text("×\(item.lookupCount)")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.14))
                                    .clipShape(Capsule())
                            }
                            Text(item.translation).font(.subheadline)
                            if !item.contextSentence.isEmpty {
                                Text("“\(item.contextSentence)”")
                                    .font(.caption.italic())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .swipeActions {
                            Button(role: .destructive) {
                                db.deleteVocab(id: item.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private var flashcardView: some View {
        Group {
            if filteredVocab.isEmpty {
                ContentUnavailableView("暂无可复习生词", systemImage: "rectangle.stack")
            } else {
                let safeIdx = min(flashIndex, filteredVocab.count - 1)
                let card = filteredVocab[safeIdx]

                VStack(spacing: 20) {
                    Text("第 \(safeIdx + 1) / \(filteredVocab.count) 张 · 已查 \(card.lookupCount) 次")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 14) {
                        Spacer()
                        Text(card.word)
                            .font(.largeTitle.bold())
                            .foregroundStyle(Color.accentColor)
                        HStack {
                            Text(card.phonetic).foregroundStyle(.secondary)
                            Button { speech.speak(card.word) } label: {
                                Image(systemName: "speaker.wave.2.fill")
                            }
                        }
                        if !card.contextSentence.isEmpty {
                            Text("“\(card.contextSentence)”")
                                .font(.subheadline.italic())
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        if flipped {
                            Divider().padding(.vertical, 6)
                            Text(card.translation)
                                .font(.headline)
                                .multilineTextAlignment(.center)
                            if !card.contextTranslation.isEmpty {
                                Text(card.contextTranslation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        Spacer()
                        Text(flipped ? "点击下方评估掌握度" : "轻触卡片查看释义")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.3)) { flipped.toggle() }
                    }

                    HStack(spacing: 12) {
                        Button("不认识") {
                            db.updateVocabFamiliarity(id: card.id, familiarity: 0)
                            flipped = false
                            flashIndex = (safeIdx + 1) % filteredVocab.count
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)

                        Button("模糊") {
                            db.updateVocabFamiliarity(id: card.id, familiarity: 1)
                            flipped = false
                            flashIndex = (safeIdx + 1) % filteredVocab.count
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)

                        Button("认识") {
                            db.updateVocabFamiliarity(id: card.id, familiarity: 2)
                            flipped = false
                            flashIndex = (safeIdx + 1) % filteredVocab.count
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(20)
            }
        }
    }
}
