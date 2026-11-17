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

    @State private var selectedTab = 0
    @State private var activeBook: BookItem?
    @State private var parsedBook: ParsedBook?
    @State private var jumpChapter: Int?
    @State private var jumpUnit: Int?
    @State private var isOpeningBook = false
    @State private var openingTitle = ""
    @State private var openError: String?
    @State private var openTask: Task<Void, Never>?
    @State private var isTabBarHiddenForModal = false

    private var palette: AppThemePalette {
        AppThemePalette.resolve(mode: settingsStore.settings.themeMode, systemScheme: systemScheme)
    }

    private let rootTabs: [LiquidGlassTabItem] = [
        LiquidGlassTabItem(id: 0, title: "书架", systemImage: "books.vertical", selectedImage: "books.vertical.fill"),
        LiquidGlassTabItem(id: 1, title: "笔记", systemImage: "bookmark", selectedImage: "bookmark.fill"),
        LiquidGlassTabItem(id: 2, title: "统计", systemImage: "chart.bar", selectedImage: "chart.bar.fill"),
        LiquidGlassTabItem(id: 3, title: "设置", systemImage: "gearshape", selectedImage: "gearshape.fill")
    ]

    var body: some View {
        let isReaderOpen = activeBook != nil && parsedBook != nil
        ZStack {
            Group {
                #if compiler(>=6.2)
                if #available(iOS 26.0, *) {
                    TabView(selection: $selectedTab) {
                        Tab("书架", systemImage: "books.vertical", value: 0) {
                            LibraryView(
                                onOpenBook: { book in
                                    openBook(book, chapter: nil, unit: nil)
                                },
                                onModalOverlayChange: { hidden in
                                    withAnimation(AppMotion.panelSpring) {
                                        isTabBarHiddenForModal = hidden
                                    }
                                }
                            )
                            .toolbarVisibility(isTabBarHiddenForModal ? .hidden : .visible, for: .tabBar)
                        }

                        Tab("笔记", systemImage: "bookmark", value: 1) {
                            NotesAndVocabView { book, chap, unit in
                                openBook(book, chapter: chap, unit: unit)
                            }
                            .toolbarVisibility(isTabBarHiddenForModal ? .hidden : .visible, for: .tabBar)
                        }

                        Tab("统计", systemImage: "chart.bar", value: 2) {
                            ReadingHistoryView()
                                .toolbarVisibility(isTabBarHiddenForModal ? .hidden : .visible, for: .tabBar)
                        }

                        Tab("设置", systemImage: "gearshape", value: 3) {
                            SettingsView { book in
                                openBook(book, chapter: nil, unit: nil)
                            }
                            .toolbarVisibility(isTabBarHiddenForModal ? .hidden : .visible, for: .tabBar)
                        }
                    }
                    .tint(palette.accent)
                } else {
                    legacyTabShell
                }
                #else
                legacyTabShell
                #endif
            }
            .scaleEffect(isReaderOpen ? 0.96 : 1.0)
            .opacity(isReaderOpen ? 0.86 : 1.0)
            .allowsHitTesting(!isReaderOpen)
            .accessibilityHidden(isReaderOpen)
            .zIndex(0)

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
                .zIndex(10)
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

    @ViewBuilder
    private var legacyTabShell: some View {
        ZStack {
            ZStack {
                LibraryView(
                    onOpenBook: { book in
                        openBook(book, chapter: nil, unit: nil)
                    },
                    onModalOverlayChange: { hidden in
                        isTabBarHiddenForModal = hidden
                    }
                )
                .opacity(selectedTab == 0 ? 1 : 0)
                .allowsHitTesting(selectedTab == 0)
                .zIndex(selectedTab == 0 ? 1 : 0)

                NotesAndVocabView { book, chap, unit in
                    openBook(book, chapter: chap, unit: unit)
                }
                .opacity(selectedTab == 1 ? 1 : 0)
                .allowsHitTesting(selectedTab == 1)
                .zIndex(selectedTab == 1 ? 1 : 0)

                ReadingHistoryView()
                    .opacity(selectedTab == 2 ? 1 : 0)
                    .allowsHitTesting(selectedTab == 2)
                    .zIndex(selectedTab == 2 ? 1 : 0)

                SettingsView { book in
                    openBook(book, chapter: nil, unit: nil)
                }
                .opacity(selectedTab == 3 ? 1 : 0)
                .allowsHitTesting(selectedTab == 3)
                .zIndex(selectedTab == 3 ? 1 : 0)
            }
            .animation(AppMotion.tabSpring, value: selectedTab)
            .safeAreaPadding(.bottom, 74)

            VStack {
                Spacer(minLength: 0)
                LiquidGlassTabBar(items: rootTabs, selectedTab: $selectedTab)
                    .opacity(isTabBarHiddenForModal ? 0 : 1)
                    .allowsHitTesting(!isTabBarHiddenForModal)
                    .animation(AppMotion.panelSpring, value: isTabBarHiddenForModal)
            }
            .ignoresSafeArea(.keyboard)
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
