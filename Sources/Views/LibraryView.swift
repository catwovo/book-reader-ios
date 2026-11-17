import SwiftUI
import UniformTypeIdentifiers

func formatDuration(_ seconds: Int64) -> String {
    let s = max(0, seconds)
    let hrs = s / 3600
    let mins = (s % 3600) / 60
    let secs = s % 60
    if hrs > 0 { return "\(hrs)小时 \(mins)分" }
    if mins > 0 { return "\(mins)分 \(secs)秒" }
    return "\(secs)秒"
}

func computeBookProgress(_ book: BookItem) -> Double {
    let isUnread = book.currentChapter == 0 && book.currentIndex == 0 && book.readingSeconds == 0
    if isUnread { return 0 }
    if book.overallProgress >= 0 {
        return min(1.0, max(0.0, Double(book.overallProgress)))
    }
    if book.totalItems > 0 {
        return min(1.0, max(0.0, Double(book.currentIndex + 1) / Double(book.totalItems)))
    }
    return 0
}

private var supportedBookContentTypes: [UTType] {
    var types: [UTType] = [.epub, .plainText, .pdf, .data]
    if let mobi = UTType(filenameExtension: "mobi") { types.append(mobi) }
    if let azw3 = UTType(filenameExtension: "azw3") { types.append(azw3) }
    return types
}

struct LibraryView: View {
    @Environment(DatabaseManager.self) private var db
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.appPalette) private var palette

    var onOpenBook: (BookItem) -> Void

    @State private var heroPageIndex = 0
    @State private var collectionTab = 0 // 0 = 本地藏书, 1 = 在线书库
    @State private var expandedFolderIds: Set<Int64> = []

    // Import & Folder Modals
    @State private var showFileImporter = false
    @State private var importTargetFolderId: Int64? = nil
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var renamingFolder: BookFolder? = nil
    @State private var renameFolderName = ""
    @State private var deletingFolder: BookFolder? = nil
    @State private var addBooksTargetFolder: BookFolder? = nil
    @State private var movingBook: BookItem? = nil
    @State private var deletingBook: BookItem? = nil

    private var recentBooks: [BookItem] {
        Array(db.books.sorted { $0.lastReadAt > $1.lastReadAt }.prefix(3))
    }

    private var recentBookIds: Set<Int64> {
        Set(recentBooks.map(\.id))
    }

    private var folderBooksMap: [Int64: [BookItem]] {
        Dictionary(grouping: db.books.filter { $0.folderId != nil }, by: { $0.folderId! })
    }

    private var rootShelfBooks: [BookItem] {
        db.books.filter { $0.folderId == nil && !recentBookIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            attachBookSheets(to: attachFolderAlerts(to: mainShellView))
        }
    }

    private func attachFolderAlerts<Content: View>(to content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar { libraryToolbar }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: supportedBookContentTypes,
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    importPickedFiles(urls, targetFolderId: importTargetFolderId)
                }
            }
            .alert("新建文件夹", isPresented: $showNewFolderAlert) {
                TextField("例如：英文原著、技术文档", text: $newFolderName)
                Button("创建") {
                    let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        db.createFolder(name: trimmed)
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .alert("重命名文件夹", isPresented: Binding(
                get: { renamingFolder != nil },
                set: { if !$0 { renamingFolder = nil } }
            )) {
                TextField("文件夹名称", text: $renameFolderName)
                Button("保存") {
                    let trimmed = renameFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let target = renamingFolder, !trimmed.isEmpty {
                        db.renameFolder(id: target.id, name: trimmed)
                    }
                    renamingFolder = nil
                }
                Button("取消", role: .cancel) { renamingFolder = nil }
            }
            .alert("删除文件夹", isPresented: Binding(
                get: { deletingFolder != nil },
                set: { if !$0 { deletingFolder = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let target = deletingFolder {
                        db.deleteFolder(id: target.id)
                        expandedFolderIds.remove(target.id)
                    }
                    deletingFolder = nil
                }
                Button("取消", role: .cancel) { deletingFolder = nil }
            } message: {
                if let target = deletingFolder {
                    let count = folderBooksMap[target.id]?.count ?? 0
                    Text(count > 0
                         ? "确定删除文件夹「\(target.name)」吗？\n里面的 \(count) 本书籍不会被删除，将自动移回书架根目录。"
                         : "确定删除空文件夹「\(target.name)」吗？")
                }
            }
    }

    private func attachBookSheets<Content: View>(to content: Content) -> some View {
        content
            .alert("移除图书", isPresented: Binding(
                get: { deletingBook != nil },
                set: { if !$0 { deletingBook = nil } }
            )) {
                Button("移除", role: .destructive) {
                    if let target = deletingBook {
                        BookCache.deleteLocalBookFileIfManaged(target)
                        db.deleteBook(id: target.id)
                    }
                    deletingBook = nil
                }
                Button("取消", role: .cancel) { deletingBook = nil }
            } message: {
                if let target = deletingBook {
                    Text("确定从书架移除《\(target.title)》吗？")
                }
            }
            .sheet(item: $addBooksTargetFolder) { folder in
                AddBooksToFolderSheet(
                    folder: folder,
                    allBooks: db.books,
                    folders: db.folders,
                    onConfirm: { selectedIds in
                        db.moveBooks(selectedIds, toFolder: folder.id)
                        withAnimation(AppMotion.panelSpring) {
                            _ = expandedFolderIds.insert(folder.id)
                        }
                    }
                )
            }
            .sheet(item: $movingBook) { book in
                MoveBookToFolderSheet(
                    book: book,
                    folders: db.folders,
                    folderCounts: folderBooksMap.mapValues(\.count),
                    onMove: { folderId in
                        db.moveBook(book.id, toFolder: folderId)
                    }
                )
            }
            .onChange(of: db.books.count) { _, _ in
                if !recentBooks.isEmpty, heroPageIndex >= recentBooks.count {
                    heroPageIndex = max(0, recentBooks.count - 1)
                }
            }
            .onChange(of: db.folders.map(\.id)) { _, validIds in
                expandedFolderIds = expandedFolderIds.intersection(Set(validIds))
            }
    }

    @ViewBuilder
    private var mainShellView: some View {
        ZStack {
            AmbientGlassBackdrop(themeMode: settingsStore.settings.themeMode)

            VStack(spacing: 0) {
                heroContinueSection
                sectionHeaderBar
                collectionPager
            }
        }
    }

    @ViewBuilder
    private var heroContinueSection: some View {
        if !recentBooks.isEmpty {
            VStack(spacing: 8) {
                TabView(selection: $heroPageIndex) {
                    ForEach(Array(recentBooks.enumerated()), id: \.element.id) { idx, book in
                        HeroContinueCard(
                            book: book,
                            isCaching: BookCache.shared.cachingHints.contains(book.filePathHint),
                            onOpen: { onOpenBook(book) },
                            onDelete: { deletingBook = book }
                        )
                        .padding(.horizontal, 16)
                        .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 174)

                if recentBooks.count > 1 {
                    MinimalPagerDots(
                        pageCount: recentBooks.count,
                        currentPage: min(heroPageIndex, recentBooks.count - 1),
                        onSelectPage: { target in
                            withAnimation(AppMotion.tabSpring) {
                                heroPageIndex = target
                            }
                        }
                    )
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var sectionHeaderBar: some View {
        HStack {
            Text(collectionTab == 0 ? "藏书目录" : "OPDS 书源")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()

            if collectionTab == 0 {
                HStack(spacing: 8) {
                    if !expandedFolderIds.isEmpty {
                        Button {
                            withAnimation(AppMotion.panelSpring) {
                                expandedFolderIds.removeAll()
                            }
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.caption.bold())
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.32), lineWidth: 0.7))
                        }
                        .buttonStyle(GlassPressButtonStyle())
                    }

                    Button {
                        newFolderName = ""
                        showNewFolderAlert = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.subheadline)
                            .frame(width: 32, height: 32)
                            .background(palette.accent.opacity(0.15), in: Circle())
                            .foregroundStyle(palette.accent)
                    }
                    .buttonStyle(GlassPressButtonStyle())

                    Button {
                        importTargetFolderId = nil
                        showFileImporter = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.subheadline.bold())
                            .frame(width: 32, height: 32)
                            .background(palette.accent.opacity(0.15), in: Circle())
                            .foregroundStyle(palette.accent)
                    }
                    .buttonStyle(GlassPressButtonStyle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var collectionPager: some View {
        TabView(selection: $collectionTab) {
            localShelfView
                .tag(0)

            OpdsOnlineLibraryPane(onOpenBook: onOpenBook)
                .tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 8) {
                Text("书架")
                    .font(.title2.bold())
                if !db.books.isEmpty {
                    MinimalTagPill(
                        text: "\(db.books.count) 本",
                        tintColor: palette.accent.opacity(0.14),
                        textColor: palette.accent
                    )
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Picker("书库", selection: Binding(
                get: { collectionTab },
                set: { next in
                    withAnimation(AppMotion.tabSpring) { collectionTab = next }
                }
            )) {
                Text("本地藏书").tag(0)
                Text("在线书库").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 174)
        }
    }

    // MARK: - Local Shelf View

    @ViewBuilder
    private var localShelfView: some View {
        if db.books.isEmpty && db.folders.isEmpty {
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "books.vertical")
                    .font(.system(size: 42))
                    .foregroundStyle(palette.accent)
                    .padding(18)
                    .background(palette.accent.opacity(0.12), in: Circle())
                Text("本地书架还是空的")
                    .font(.headline)
                Text("支持 EPUB · TXT · PDF · MOBI · AZW3\n向左滑动即可直接从「在线书库」下载阅读")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    importTargetFolderId = nil
                    showFileImporter = true
                } label: {
                    Label("导入本地图书", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(palette.accent, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(GlassPressButtonStyle())
                Spacer()
            }
            .padding(24)
        } else if db.folders.isEmpty && rootShelfBooks.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Text("当前全部 \(db.books.count) 本藏书均已展示在上方「最近阅读」\n可点击右上「新建文件夹」分类整理，或向左滑动浏览「在线书库」")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding(24)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    // Folders (non-sticky, unified expand/collapse animation, actions in "..." menu)
                    ForEach(Array(db.folders.enumerated()), id: \.element.id) { idx, folder in
                        let folderBooks = folderBooksMap[folder.id] ?? []
                        let isExpanded = expandedFolderIds.contains(folder.id)

                        VStack(spacing: 5) {
                            FolderHeaderGlassCard(
                                folder: folder,
                                bookCount: folderBooks.count,
                                isExpanded: isExpanded,
                                index: idx,
                                count: db.folders.count,
                                onToggleExpand: {
                                    withAnimation(AppMotion.panelSpring) {
                                        if isExpanded {
                                            _ = expandedFolderIds.remove(folder.id)
                                        } else {
                                            _ = expandedFolderIds.insert(folder.id)
                                        }
                                    }
                                },
                                onImportHere: {
                                    withAnimation(AppMotion.panelSpring) {
                                        _ = expandedFolderIds.insert(folder.id)
                                    }
                                    importTargetFolderId = folder.id
                                    showFileImporter = true
                                },
                                onAddExistingBooks: {
                                    addBooksTargetFolder = folder
                                },
                                onRename: {
                                    renameFolderName = folder.name
                                    renamingFolder = folder
                                },
                                onDeleteFolder: {
                                    deletingFolder = folder
                                }
                            )

                            if isExpanded {
                                VStack(spacing: 4) {
                                    if folderBooks.isEmpty {
                                        GlassCard(cornerRadius: 14) {
                                            Text("此文件夹暂无书籍，可点击右上角菜单导入或添加")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 12)
                                                .padding(.horizontal, 12)
                                        }
                                    } else {
                                        ForEach(Array(folderBooks.enumerated()), id: \.element.id) { bIdx, book in
                                            shelfBookRow(
                                                book: book,
                                                index: bIdx,
                                                count: folderBooks.count,
                                                inFolder: true
                                            )
                                        }
                                    }
                                }
                                .padding(.leading, 10)
                                .transition(AppMotion.panelTransition)
                            }
                        }
                        .clipped()
                    }

                    // Root Books
                    if !rootShelfBooks.isEmpty {
                        VStack(spacing: 4) {
                            ForEach(Array(rootShelfBooks.enumerated()), id: \.element.id) { idx, book in
                                shelfBookRow(
                                    book: book,
                                    index: idx,
                                    count: rootShelfBooks.count,
                                    inFolder: false
                                )
                            }
                        }
                        .padding(.top, db.folders.isEmpty ? 0 : 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
    }

    private func shelfBookRow(book: BookItem, index: Int, count: Int, inFolder: Bool) -> some View {
        let canMoveToFolder = inFolder ? db.folders.count > 1 : !db.folders.isEmpty
        return GlassGroupedCard(index: index, count: count) {
            HStack(spacing: 12) {
                Button {
                    onOpenBook(book)
                } label: {
                    ShelfBookRowContent(
                        book: book,
                        isCaching: BookCache.shared.cachingHints.contains(book.filePathHint)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Menu {
                    if inFolder {
                        Button {
                            db.moveBook(book.id, toFolder: nil)
                        } label: {
                            Label("移出文件夹", systemImage: "folder.badge.minus")
                        }
                    }
                    if canMoveToFolder {
                        Button {
                            movingBook = book
                        } label: {
                            Label(inFolder ? "移至其他文件夹" : "移入文件夹", systemImage: "folder")
                        }
                    }
                    if book.filePathHint != "sample://art_of_slow_reading" {
                        Button(role: .destructive) {
                            deletingBook = book
                        } label: {
                            Label("从书架移除", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Local Import Helper

    private func importPickedFiles(_ urls: [URL], targetFolderId: Int64?) {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let booksDir = docsDir.appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: booksDir, withIntermediateDirectories: true)

        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            let rawExt = url.pathExtension.uppercased()
            let fmt = rawExt.isEmpty ? "TXT" : rawExt
            let title = url.deletingPathExtension().lastPathComponent

            // Copy into sandbox Books/ directory for reliable permanent access across restarts
            let destName = "\(UUID().uuidString.prefix(8))_\(url.lastPathComponent)"
            let destUrl = booksDir.appendingPathComponent(destName)
            var filePathHint = url.absoluteString
            var bookmark: Data? = nil

            if (try? FileManager.default.copyItem(at: url, to: destUrl)) != nil {
                filePathHint = destUrl.absoluteString
            } else {
                bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            }

            if let added = db.addBook(
                title: title.isEmpty ? "未命名图书" : title,
                bookmarkData: bookmark,
                filePathHint: filePathHint,
                format: fmt,
                folderId: targetFolderId
            ) {
                BookCache.precacheMissingSequentially(books: [added], db: db)
            }
        }
    }
}

// MARK: - Hero Continue Card

private struct HeroContinueCard: View {
    let book: BookItem
    let isCaching: Bool
    var onOpen: () -> Void
    var onDelete: () -> Void

    @Environment(\.appPalette) private var palette

    var body: some View {
        let progress = computeBookProgress(book)
        GlassCard(cornerRadius: 24, tintColor: palette.accent.opacity(0.08)) {
            VStack(alignment: .leading, spacing: 10) {
                // Top bar
                HStack {
                    MinimalTagPill(
                        text: book.readingSeconds > 0 ? "最近阅读" : "开始阅读",
                        tintColor: palette.accent.opacity(0.14),
                        textColor: palette.accent
                    )
                    Spacer()
                    if isCaching {
                        ProgressView()
                            .controlSize(.mini)
                        Text("解析中")
                            .font(.caption2)
                            .foregroundStyle(palette.accent)
                    } else {
                        Text("\(Int(progress * 100))%")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.accent)
                    }
                    if book.filePathHint != "sample://art_of_slow_reading" {
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Cover + metadata
                Button(action: onOpen) {
                    HStack(spacing: 13) {
                        BookCoverArtwork(book: book, compact: false)
                            .frame(width: 50, height: 68)
                            .shadow(color: .black.opacity(0.14), radius: 4, x: 0, y: 2)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(book.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            HStack(spacing: 5) {
                                Image(systemName: "clock")
                                    .font(.caption2)
                                Text(book.readingSeconds > 0 ? "已读 \(formatDuration(book.readingSeconds))" : "尚未开始")
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)

                            SmoothLinearProgressBar(progress: progress, height: 4.5)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // CTA Pill
                Button(action: onOpen) {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(.caption)
                        Text(book.readingSeconds > 0 ? "继续阅读" : "立即阅读")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(palette.accent, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(GlassPressButtonStyle())
            }
            .padding(14)
        }
    }
}

// MARK: - Folder Header Glass Card

private struct FolderHeaderGlassCard: View {
    let folder: BookFolder
    let bookCount: Int
    let isExpanded: Bool
    let index: Int
    let count: Int
    var onToggleExpand: () -> Void
    var onImportHere: () -> Void
    var onAddExistingBooks: () -> Void
    var onRename: () -> Void
    var onDeleteFolder: () -> Void

    @Environment(\.appPalette) private var palette

    var body: some View {
        let content = HStack(spacing: 12) {
            Button(action: onToggleExpand) {
                HStack(spacing: 12) {
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.title3)
                        .foregroundStyle(palette.accent)
                        .frame(width: 38, height: 38)
                        .background(palette.accent.opacity(isExpanded ? 0.18 : 0.11))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(bookCount > 0 ? "\(bookCount) 本书籍" : "空文件夹")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button(action: onImportHere) {
                    Label("导入新书到此处", systemImage: "plus")
                }
                Button(action: onAddExistingBooks) {
                    Label("添加已有书籍", systemImage: "books.vertical")
                }
                Button(action: onRename) {
                    Label("重命名", systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive, action: onDeleteFolder) {
                    Label("删除文件夹", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }

            Button(action: onToggleExpand) {
                Image(systemName: "chevron.down")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)

        if isExpanded {
            GlassCard(cornerRadius: 18, tintColor: palette.accent.opacity(0.06)) {
                content
            }
        } else {
            GlassGroupedCard(index: index, count: count) {
                content
            }
        }
    }
}

// MARK: - Shelf Book Row Content

private struct ShelfBookRowContent: View {
    let book: BookItem
    let isCaching: Bool

    @Environment(\.appPalette) private var palette

    var body: some View {
        let progress = computeBookProgress(book)
        HStack(spacing: 12) {
            BookCoverArtwork(book: book, compact: true)
                .frame(width: 38, height: 52)
                .shadow(color: .black.opacity(0.10), radius: 2, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(book.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    if !book.format.isEmpty {
                        MinimalTagPill(text: book.format)
                    }
                }

                HStack(spacing: 8) {
                    SmoothLinearProgressBar(progress: progress, height: 3.5)
                    if isCaching {
                        ProgressView().controlSize(.mini)
                        Text("缓存中")
                            .font(.caption2)
                            .foregroundStyle(palette.accent)
                    } else if book.readingSeconds > 0 {
                        Text("\(Int(progress * 100))% · \(formatDuration(book.readingSeconds))")
                            .font(.caption2)
                            .foregroundStyle(progress > 0 ? palette.accent : .secondary)
                    } else {
                        Text("未读")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Folder Management Sheets

private struct AddBooksToFolderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let folder: BookFolder
    let allBooks: [BookItem]
    let folders: [BookFolder]
    var onConfirm: ([Int64]) -> Void

    @State private var selectedIds: Set<Int64> = []

    private var candidates: [BookItem] {
        allBooks.filter { $0.folderId != folder.id }
    }

    private var folderMap: [Int64: String] {
        Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "没有可添加的书籍",
                        systemImage: "books.vertical",
                        description: Text("书库中的所有书籍都已在这个文件夹里了，可以直接点击文件夹右上菜单中的「导入新书到此处」。")
                    )
                } else {
                    List(candidates) { book in
                        let checked = selectedIds.contains(book.id)
                        Button {
                            if checked { selectedIds.remove(book.id) }
                            else { selectedIds.insert(book.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(checked ? Color.accentColor : .secondary)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(book.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    let folderLabel = book.folderId.flatMap { folderMap[$0] }.map { "当前在：\($0)" } ?? "未归类"
                                    Text("\(book.format) · \(folderLabel)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("添加到「\(folder.name)」")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !candidates.isEmpty {
                        Button("添加 (\(selectedIds.count))") {
                            onConfirm(Array(selectedIds))
                            dismiss()
                        }
                        .disabled(selectedIds.isEmpty)
                    }
                }
            }
        }
    }
}

private struct MoveBookToFolderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let book: BookItem
    let folders: [BookFolder]
    let folderCounts: [Int64: Int]
    var onMove: (Int64?) -> Void

    var body: some View {
        NavigationStack {
            List {
                if book.folderId != nil {
                    Button {
                        onMove(nil)
                        dismiss()
                    } label: {
                        Label("移出文件夹（放回根目录）", systemImage: "books.vertical")
                    }
                }
                ForEach(folders.filter { $0.id != book.folderId }) { folder in
                    Button {
                        onMove(folder.id)
                        dismiss()
                    } label: {
                        HStack {
                            Label(folder.name, systemImage: "folder")
                            Spacer()
                            Text("\(folderCounts[folder.id] ?? 0) 本")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("移动《\(book.title)》")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Inline OPDS Online Library Pane

private struct OpdsNavNode: Hashable {
    let url: String
    let title: String
}

struct OpdsOnlineLibraryPane: View {
    @Environment(DatabaseManager.self) private var db
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.appPalette) private var palette

    var onOpenBook: (BookItem) -> Void

    @State private var navStack: [OpdsNavNode] = []
    @State private var entries: [OpdsEntry] = []
    @State private var nextPageUrl: String?
    @State private var searchTemplate: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMsg: String?

    @State private var showSearchBar = false
    @State private var searchQuery = ""

    @State private var downloadingEntryId: String?
    @State private var downloadedBytes: Int64 = 0
    @State private var totalBytes: Int64 = -1
    @State private var bannerMsg: String?
    @State private var bannerIsError = false

    @State private var detailEntry: OpdsEntry?
    @State private var showEditDialog = false
    @State private var editingSource: OpdsSource?

    private var currentSource: OpdsSource? {
        settingsStore.selectedOpdsSource
    }

    private var currentNode: OpdsNavNode? {
        navStack.last
    }

    private func findLocalBook(for entry: OpdsEntry) -> BookItem? {
        for acq in entry.acquisitions {
            let localHint = NetworkBookService.localUriForOpdsBook(acquisitionUrl: acq.url, format: acq.format)
            if let hit = db.books.first(where: { $0.filePathHint == localHint }) {
                return hit
            }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 8) {
            if settingsStore.opdsSources.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "globe")
                        .font(.system(size: 36))
                        .foregroundStyle(palette.accent)
                    Text("还没有配置在线书源")
                        .font(.headline)
                    Text("支持自定义 OPDS 书库地址（如 Calibre-Web、Komga、Kavita 或英文公版源），下载后会自动出现在本地藏书。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        editingSource = nil
                        showEditDialog = true
                    } label: {
                        Label("添加自定义书源", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(palette.accent, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(GlassPressButtonStyle())
                    Button("恢复默认中英文书源") {
                        settingsStore.restoreDefaultOpdsSources()
                    }
                    .font(.caption)
                    Spacer()
                }
                .padding(24)
            } else {
                // Source selector bar
                HStack(spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(settingsStore.opdsSources) { src in
                                let selected = src.id == currentSource?.id
                                Button {
                                    if settingsStore.selectedOpdsSourceId != src.id {
                                        settingsStore.selectOpdsSource(src.id)
                                    }
                                } label: {
                                    Text(src.name)
                                        .font(.caption.weight(selected ? .semibold : .medium))
                                        .lineLimit(1)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 6)
                                        .background(selected ? palette.accent.opacity(0.18) : Color.secondary.opacity(0.10), in: Capsule())
                                        .foregroundStyle(selected ? palette.accent : .primary)
                                        .overlay(
                                            Capsule().strokeBorder(selected ? palette.accent.opacity(0.55) : Color.clear, lineWidth: 0.8)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if searchTemplate != nil {
                        Button {
                            withAnimation(AppMotion.panelSpring) {
                                showSearchBar.toggle()
                            }
                        } label: {
                            Image(systemName: showSearchBar ? "xmark" : "magnifyingglass")
                                .font(.caption.bold())
                                .frame(width: 30, height: 30)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        editingSource = currentSource
                        showEditDialog = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption.bold())
                            .frame(width: 30, height: 30)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        editingSource = nil
                        showEditDialog = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption.bold())
                            .frame(width: 30, height: 30)
                            .background(palette.accent.opacity(0.15), in: Circle())
                            .foregroundStyle(palette.accent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)

                // Search bar
                if showSearchBar, let tpl = searchTemplate {
                    HStack(spacing: 8) {
                        TextField("输入书名或作者搜索...", text: $searchQuery)
                            .textFieldStyle(.plain)
                            .submitLabel(.search)
                            .onSubmit {
                                executeSearch(template: tpl)
                            }
                        Button {
                            executeSearch(template: tpl)
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(palette.accent)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.28), lineWidth: 0.7))
                    .padding(.horizontal, 16)
                    .transition(AppMotion.panelTransition)
                }

                // Breadcrumbs
                if navStack.count > 1 {
                    HStack(spacing: 8) {
                        Button {
                            if navStack.count > 1 { navStack.removeLast() }
                        } label: {
                            Label("返回", systemImage: "chevron.left")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(palette.accent.opacity(0.14), in: Capsule())
                                .foregroundStyle(palette.accent)
                        }
                        .buttonStyle(.plain)

                        Text(currentNode?.title ?? "")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if navStack.count > 2 {
                            Button("首页") {
                                if let first = navStack.first { navStack = [first] }
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                // Banner
                if let bannerMsg {
                    HStack {
                        Text(bannerMsg)
                            .font(.caption)
                            .foregroundStyle(bannerIsError ? .red : palette.accent)
                        Spacer()
                        Button {
                            self.bannerMsg = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background((bannerIsError ? Color.red : palette.accent).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                }

                // Content area
                if isLoading {
                    Spacer()
                    ProgressView("正在加载在线书目...")
                        .font(.caption)
                    Spacer()
                } else if let errorMsg {
                    Spacer()
                    VStack(spacing: 10) {
                        Text(errorMsg)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 10) {
                            Button("修改书源") {
                                editingSource = currentSource
                                showEditDialog = true
                            }
                            .buttonStyle(.bordered)
                            Button("重试") {
                                loadCurrentNode()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(24)
                    Spacer()
                } else if entries.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Text("当前目录没有可显示条目")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("刷新") { loadCurrentNode() }
                            .buttonStyle(.bordered)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                                opdsEntryRow(entry: entry, index: idx, count: entries.count)
                            }

                            if let nextUrl = nextPageUrl {
                                Button {
                                    loadMore(nextUrl: nextUrl)
                                } label: {
                                    HStack(spacing: 6) {
                                        if isLoadingMore {
                                            ProgressView().controlSize(.mini)
                                        }
                                        Text(isLoadingMore ? "加载中..." : "加载更多")
                                            .font(.subheadline.weight(.medium))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(.bordered)
                                .disabled(isLoadingMore)
                                .padding(.top, 6)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .onChange(of: currentSource?.id) { _, _ in
            resetNavigationForCurrentSource()
        }
        .onChange(of: currentSource?.url) { _, _ in
            resetNavigationForCurrentSource()
        }
        .onChange(of: currentNode?.url) { _, _ in
            loadCurrentNode()
        }
        .onAppear {
            if navStack.isEmpty && currentSource != nil {
                resetNavigationForCurrentSource()
            }
        }
        .sheet(isPresented: $showEditDialog) {
            OpdsSourceEditSheet(
                initial: editingSource,
                onSave: { saved in
                    settingsStore.addOrUpdateOpdsSource(saved)
                    showEditDialog = false
                },
                onDelete: editingSource.map { target in
                    {
                        settingsStore.deleteOpdsSource(target.id)
                        showEditDialog = false
                    }
                }
            )
        }
        .sheet(item: $detailEntry) { entry in
            OpdsBookDetailSheet(
                entry: entry,
                existingBook: findLocalBook(for: entry),
                isDownloading: downloadingEntryId == entry.id,
                onOpenSubcategory: entry.navigationUrl.map { navUrl in
                    {
                        detailEntry = nil
                        navStack.append(OpdsNavNode(url: navUrl, title: entry.title))
                    }
                },
                onDownload: { acq in
                    detailEntry = nil
                    startDownload(entry: entry, acquisition: acq)
                },
                onOpenBook: { book in
                    detailEntry = nil
                    onOpenBook(book)
                }
            )
        }
    }

    @ViewBuilder
    private func opdsEntryRow(entry: OpdsEntry, index: Int, count: Int) -> some View {
        if entry.isCategory {
            Button {
                if let navUrl = entry.navigationUrl {
                    navStack.append(OpdsNavNode(url: navUrl, title: entry.title))
                }
            } label: {
                GlassGroupedCard(index: index, count: count) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(palette.accent)
                            .font(.subheadline)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if !entry.summary.isEmpty {
                                Text(entry.summary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
            .buttonStyle(GlassPressButtonStyle())
        } else {
            let existingBook = findLocalBook(for: entry)
            let preferredAcq = NetworkBookService.pickPreferredAcquisition(entry.acquisitions)
            let isDownloading = downloadingEntryId == entry.id

            GlassGroupedCard(index: index, count: count) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Button {
                            detailEntry = entry
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)

                                HStack(spacing: 6) {
                                    if !entry.author.isEmpty {
                                        Text(entry.author)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    ForEach(Array(Set(entry.acquisitions.map(\.format))).sorted().prefix(3), id: \.self) { fmt in
                                        MinimalTagPill(text: fmt)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if let existingBook {
                            Button {
                                onOpenBook(existingBook)
                            } label: {
                                Label("阅读", systemImage: "play.fill")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(palette.accent.opacity(0.16), in: Capsule())
                                    .foregroundStyle(palette.accent)
                            }
                            .buttonStyle(.plain)
                        } else if isDownloading {
                            ProgressView().controlSize(.small)
                        } else if let preferredAcq {
                            Button {
                                startDownload(entry: entry, acquisition: preferredAcq)
                            } label: {
                                Label("下载", systemImage: "arrow.down.circle")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(palette.accent.opacity(0.16), in: Capsule())
                                    .foregroundStyle(palette.accent)
                            }
                            .buttonStyle(.plain)
                            .disabled(downloadingEntryId != nil)
                        }
                    }

                    if !entry.summary.isEmpty {
                        Text(entry.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if isDownloading {
                        if totalBytes > 0 {
                            ProgressView(value: Double(downloadedBytes) / Double(totalBytes))
                                .tint(palette.accent)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
        }
    }

    private func resetNavigationForCurrentSource() {
        navStack.removeAll()
        entries = []
        nextPageUrl = nil
        searchTemplate = nil
        errorMsg = nil
        showSearchBar = false
        searchQuery = ""
        if let src = currentSource {
            navStack = [OpdsNavNode(url: src.url, title: src.name)]
        }
    }

    private func executeSearch(template: String) {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let url = NetworkBookService.buildSearchUrl(template: template, query: q)
        navStack.append(OpdsNavNode(url: url, title: "搜索：\(q)"))
        withAnimation(AppMotion.panelSpring) { showSearchBar = false }
    }

    private func loadCurrentNode() {
        guard let src = currentSource, let node = currentNode else { return }
        isLoading = true
        errorMsg = nil
        Task {
            let res = await NetworkBookService.fetchOpdsFeed(
                urlString: node.url,
                username: src.username,
                password: src.password
            )
            await MainActor.run {
                switch res {
                case .success(let feed):
                    entries = feed.entries
                    nextPageUrl = feed.nextPageUrl
                    if let t = feed.searchUrlTemplate { searchTemplate = t }
                case .failure(let err):
                    errorMsg = err.localizedDescription
                }
                isLoading = false
            }
        }
    }

    private func loadMore(nextUrl: String) {
        guard let src = currentSource, !isLoadingMore else { return }
        isLoadingMore = true
        Task {
            let res = await NetworkBookService.fetchOpdsFeed(
                urlString: nextUrl,
                username: src.username,
                password: src.password
            )
            await MainActor.run {
                switch res {
                case .success(let more):
                    let existingIds = Set(entries.map(\.id))
                    entries.append(contentsOf: more.entries.filter { !existingIds.contains($0.id) })
                    nextPageUrl = more.nextPageUrl
                case .failure(let err):
                    bannerIsError = true
                    bannerMsg = err.localizedDescription
                }
                isLoadingMore = false
            }
        }
    }

    private func startDownload(entry: OpdsEntry, acquisition: OpdsAcquisitionLink) {
        guard downloadingEntryId == nil, let src = currentSource else { return }
        downloadingEntryId = entry.id
        downloadedBytes = 0
        totalBytes = -1
        bannerMsg = nil
        bannerIsError = false

        Task {
            let res = await NetworkBookService.downloadOpdsBook(
                title: entry.title,
                acquisition: acquisition,
                username: src.username,
                password: src.password,
                onProgress: { read, total in
                    await MainActor.run {
                        downloadedBytes = read
                        totalBytes = total
                    }
                }
            )
            await MainActor.run {
                switch res {
                case .success(let dl):
                    if let book = db.addBook(
                        title: dl.title,
                        bookmarkData: nil,
                        filePathHint: dl.uriString,
                        format: dl.format
                    ) {
                        BookCache.precacheMissingSequentially(books: [book], db: db)
                    }
                    bannerIsError = false
                    bannerMsg = "已下载并加入本地藏书：《\(dl.title)》"
                case .failure(let err):
                    bannerIsError = true
                    bannerMsg = err.localizedDescription
                }
                downloadingEntryId = nil
            }
        }
    }
}

// MARK: - OPDS Edit & Detail Sheets

struct OpdsSourceEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initial: OpdsSource?
    var onSave: (OpdsSource) -> Void
    var onDelete: (() -> Void)?

    @State private var name = ""
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var testing = false
    @State private var testMsg: String?
    @State private var testError = false

    var body: some View {
        NavigationStack {
            Form {
                if initial == nil && url.isEmpty {
                    Section("快速填入") {
                        Button("轻小说文库 (中文)") {
                            name = SettingsStore.defaultOpdsZhName
                            url = SettingsStore.defaultOpdsZhUrl
                            testMsg = nil
                        }
                        Button("Project Gutenberg (英文公版)") {
                            name = SettingsStore.defaultOpdsEnName
                            url = SettingsStore.defaultOpdsEnUrl
                            testMsg = nil
                        }
                    }
                }
                Section("书源信息") {
                    TextField("书源名称", text: $name)
                    TextField("OPDS 地址 (https://.../opds)", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("用户名（可选）", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码（可选）", text: $password)
                }
                Section {
                    Button {
                        testing = true
                        testError = false
                        testMsg = "正在测试..."
                        let probe = OpdsSource(
                            id: initial?.id ?? "probe",
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            url: NetworkBookService.normalizeUrl(url),
                            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                            password: password
                        )
                        Task {
                            let res = await NetworkBookService.testOpdsConnection(source: probe)
                            await MainActor.run {
                                switch res {
                                case .success(let msg):
                                    testError = false
                                    testMsg = msg
                                case .failure(let err):
                                    testError = true
                                    testMsg = err.localizedDescription
                                }
                                testing = false
                            }
                        }
                    } label: {
                        HStack {
                            Text(testing ? "测试中..." : "测试连接")
                            Spacer()
                            if testing { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(testing || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let testMsg {
                        Text(testMsg)
                            .font(.caption)
                            .foregroundStyle(testError ? .red : .green)
                    }
                }
                if let onDelete {
                    Section {
                        Button("删除此书源", role: .destructive) {
                            onDelete()
                        }
                    }
                }
            }
            .navigationTitle(initial == nil ? "添加 OPDS 书源" : "编辑 OPDS 书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        let norm = NetworkBookService.normalizeUrl(url)
                        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(OpdsSource(
                            id: initial?.id ?? UUID().uuidString,
                            name: cleanName.isEmpty ? norm : cleanName,
                            url: norm,
                            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                            password: password
                        ))
                    }
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let initial {
                    name = initial.name
                    url = initial.url
                    username = initial.username
                    password = initial.password
                }
            }
        }
    }
}

private struct OpdsBookDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: OpdsEntry
    let existingBook: BookItem?
    let isDownloading: Bool
    var onOpenSubcategory: (() -> Void)?
    var onDownload: (OpdsAcquisitionLink) -> Void
    var onOpenBook: (BookItem) -> Void

    @State private var selectedAcq: OpdsAcquisitionLink?

    private var uniqueAcquisitions: [OpdsAcquisitionLink] {
        var seen = Set<String>()
        return entry.acquisitions.filter { seen.insert($0.format).inserted }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(entry.title)
                        .font(.title3.bold())
                    if !entry.author.isEmpty {
                        Text("作者：\(entry.author)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !entry.summary.isEmpty {
                        Text(entry.summary)
                            .font(.body)
                    }
                    if !uniqueAcquisitions.isEmpty && existingBook == nil {
                        Text("选择下载格式")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach(uniqueAcquisitions, id: \.url) { acq in
                                let selected = selectedAcq?.url == acq.url
                                Button(acq.format) {
                                    selectedAcq = acq
                                }
                                .buttonStyle(.bordered)
                                .tint(selected ? .accentColor : .secondary)
                            }
                        }
                    }
                    Spacer(minLength: 16)
                    if let existingBook {
                        Button {
                            onOpenBook(existingBook)
                        } label: {
                            Label("立即阅读", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else if let selectedAcq {
                        Button {
                            onDownload(selectedAcq)
                        } label: {
                            Label(isDownloading ? "下载中..." : "下载并入库", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isDownloading)
                    } else if let onOpenSubcategory {
                        Button("进入浏览", action: onOpenSubcategory)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(20)
            }
            .navigationTitle("图书详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                selectedAcq = NetworkBookService.pickPreferredAcquisition(uniqueAcquisitions)
            }
        }
    }
}
