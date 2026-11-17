import SwiftUI

@main
struct BookReaderApp: App {
    @State private var db = DatabaseManager()
    @State private var settingsStore = SettingsStore()
    @State private var speech = SpeechManager()

    @State private var activeBook: BookItem?
    @State private var parsedBook: ParsedBook?
    @State private var jumpChapter: Int?
    @State private var jumpUnit: Int?
    @State private var openError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let book = activeBook, let parsed = parsedBook {
                    ReaderView(
                        book: book,
                        parsedBook: parsed,
                        initialChapter: jumpChapter,
                        initialUnit: jumpUnit,
                        onBack: {
                            activeBook = nil
                            parsedBook = nil
                            jumpChapter = nil
                            jumpUnit = nil
                        }
                    )
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
                            SettingsView()
                        }
                    }
                }
            }
            .environment(db)
            .environment(settingsStore)
            .environment(speech)
            .preferredColorScheme(colorSchemeFor(settingsStore.settings.themeMode))
            .alert("无法打开图书", isPresented: Binding(
                get: { openError != nil },
                set: { if !$0 { openError = nil } }
            )) {
                Button("确定", role: .cancel) { openError = nil }
            } message: {
                Text(openError ?? "")
            }
        }
    }

    private func colorSchemeFor(_ mode: AppThemeMode) -> ColorScheme? {
        switch mode {
        case .light, .sepia: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    private func openBook(_ book: BookItem, chapter: Int?, unit: Int?) {
        do {
            let parsed = try BookParser.parseBook(book: book)
            jumpChapter = chapter
            jumpUnit = unit
            parsedBook = parsed
            activeBook = book
        } catch {
            openError = error.localizedDescription
        }
    }
}
