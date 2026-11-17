import SwiftUI

@main
struct BookReaderApp: App {
    @State private var db = DatabaseManager()
    @State private var settingsStore = SettingsStore()
    @State private var speech = SpeechManager()
    @State private var feedbackPlayer = StepFeedbackPlayer()

    var body: some Scene {
        WindowGroup {
            RootContentView()
                .environment(db)
                .environment(settingsStore)
                .environment(speech)
                .environment(feedbackPlayer)
        }
    }
}

private struct RootContentView: View {
    @Environment(DatabaseManager.self) private var db
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.colorScheme) private var systemScheme

    @State private var activeBook: BookItem?
    @State private var parsedBook: ParsedBook?
    @State private var jumpChapter: Int?
    @State private var jumpUnit: Int?
    @State private var isOpeningBook = false
    @State private var openingTitle = ""
    @State private var openError: String?
    @State private var openTask: Task<Void, Never>?

    private var palette: AppThemePalette {
        AppThemePalette.resolve(mode: settingsStore.settings.themeMode, systemScheme: systemScheme)
    }

    var body: some View {
        ZStack {
            if let book = activeBook, let parsed = parsedBook {
                ReaderView(
                    book: book,
                    parsedBook: parsed,
                    initialChapter: jumpChapter,
                    initialUnit: jumpUnit,
                    onBack: {
                        withAnimation(AppMotion.bookSpring) {
                            activeBook = nil
                            parsedBook = nil
                            jumpChapter = nil
                            jumpUnit = nil
                        }
                    }
                )
                .id(book.id)
                .transition(AppMotion.bookTransition)
            } else {
                TabView {
                    Tab("书架", systemImage: "books.vertical") {
                        LibraryView { book in
                            openBook(book, chapter: nil, unit: nil)
                        }
                    }

                    Tab("笔记", systemImage: "bookmark") {
                        NotesAndVocabView { book, chap, unit in
                            openBook(book, chapter: chap, unit: unit)
                        }
                    }

                    Tab("统计", systemImage: "chart.bar") {
                        ReadingHistoryView()
                    }

                    Tab("设置", systemImage: "gearshape") {
                        SettingsView { book in
                            openBook(book, chapter: nil, unit: nil)
                        }
                    }
                }
                .tint(palette.accent)
            }

            if isOpeningBook {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .transition(.opacity)

                GlassCard(cornerRadius: 22) {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("正在打开《\(openingTitle)》...")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                }
                .padding(.horizontal, 40)
                .transition(AppMotion.cardTransition)
            }
        }
        .environment(\.appPalette, palette)
        .preferredColorScheme(colorSchemeFor(settingsStore.settings.themeMode))
        .task {
            BookCache.precacheMissingSequentially(books: db.books, db: db)
        }
        .alert("无法打开图书", isPresented: Binding(
            get: { openError != nil },
            set: { if !$0 { openError = nil } }
        )) {
            Button("确定", role: .cancel) { openError = nil }
        } message: {
            Text(openError ?? "")
        }
    }

    private func colorSchemeFor(_ mode: AppThemeMode) -> ColorScheme? {
        switch mode {
        case .light, .sepia, .sage: return .light
        case .dark, .slate, .amoled: return .dark
        case .dynamic: return nil
        }
    }

    private func openBook(_ book: BookItem, chapter: Int?, unit: Int?) {
        if let cached = BookCache.load(for: book) {
            withAnimation(AppMotion.bookSpring) {
                jumpChapter = chapter
                jumpUnit = unit
                parsedBook = cached
                activeBook = book
            }
            return
        }

        openTask?.cancel()
        openingTitle = book.title
        withAnimation(AppMotion.cardSpring) {
            isOpeningBook = true
        }
        openTask = Task {
            do {
                let parsed = try await BookCache.getOrParse(for: book)
                if Task.isCancelled { return }
                await MainActor.run {
                    withAnimation(AppMotion.cardSpring) {
                        isOpeningBook = false
                    }
                    withAnimation(AppMotion.bookSpring) {
                        jumpChapter = chapter
                        jumpUnit = unit
                        parsedBook = parsed
                        activeBook = book
                    }
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    withAnimation(AppMotion.cardSpring) {
                        isOpeningBook = false
                    }
                    openError = error.localizedDescription
                }
            }
        }
    }
}
