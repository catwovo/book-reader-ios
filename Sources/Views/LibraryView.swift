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

struct LibraryView: View {
    @Environment(DatabaseManager.self) private var db
    @Environment(SettingsStore.self) private var settingsStore

    var onOpenBook: (BookItem) -> Void

    @State private var heroPageIndex = 0
    @State private var collectionTab = 0 // 0 = 藏书目录, 1 = OPDS 书源
    @State private var expandedFolderIds: Set<Int64> = []

    @State private var showFileImporter = false
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var activeOpdsSource: OpdsSource? = nil
    @State private var showWebDavSheet = false

    private var recentBooks: [BookItem] {
        Array(db.books.prefix(5))
    }

    private var unfolderedBooks: [BookItem] {
        db.books.filter { $0.folderId == nil }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientGlassBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // 1. Hero Continue Reading Carousel
                        if !recentBooks.isEmpty {
                            VStack(spacing: 8) {
                                TabView(selection: $heroPageIndex) {
                                    ForEach(Array(recentBooks.enumerated()), id: \.element.id) { idx, book in
                                        HeroContinueCard(book: book) {
                                            onOpenBook(book)
                                        }
                                        .padding(.horizontal, 16)
                                        .tag(idx)
                                    }
                                }
                                .tabViewStyle(.page(indexDisplayMode: .never))
                                .frame(height: 158)

                                if recentBooks.count > 1 {
                                    HStack(spacing: 6) {
                                        ForEach(0..<recentBooks.count, id: \.self) { idx in
                                            Capsule()
                                                .fill(idx == heroPageIndex ? Color.accentColor : Color.secondary.opacity(0.35))
                                                .frame(width: idx == heroPageIndex ? 18 : 6, height: 6)
                                                .animation(.spring(response: 0.3), value: heroPageIndex)
                                        }
                                    }
                                }
                            }
                        }

                        // 2. Collection Tab Switcher (藏书目录 / OPDS 书源)
                        HStack {
                            Picker("书库分类", selection: $collectionTab) {
                                Text("藏书目录").tag(0)
                                Text("OPDS 书源").tag(1)
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 230)

                            Spacer()

                            if collectionTab == 0 {
                                HStack(spacing: 8) {
                                    if !expandedFolderIds.isEmpty {
                                        Button {
                                            withAnimation(.spring) { expandedFolderIds.removeAll() }
                                        } label: {
                                            Image(systemName: "chevron.up")
                                                .font(.caption.bold())
                                                .frame(width: 34, height: 34)
                                                .background(.ultraThinMaterial, in: Circle())
                                                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.7))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    Button {
                                        newFolderName = ""
                                        showNewFolderAlert = true
                                    } label: {
                                        Image(systemName: "folder.badge.plus")
                                            .font(.subheadline)
                                            .frame(width: 34, height: 34)
                                            .background(Color.accentColor.opacity(0.16), in: Circle())
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)

                        // 3. Page Content
                        if collectionTab == 0 {
                            catalogSection
                        } else {
                            opdsSourcesSection
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
            .navigationTitle("书架")
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("从「文件」关联本地图书", systemImage: "folder")
                        }
                        Button {
                            showWebDavSheet = true
                        } label: {
                            Label("WebDAV 网盘书库", systemImage: "externaldrive.connected.to.line.below")
                        }
                        Divider()
                        Button {
                            newFolderName = ""
                            showNewFolderAlert = true
                        } label: {
                            Label("新建分类文件夹", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.epub, .plainText, .pdf, .data],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    for url in urls {
                        let accessed = url.startAccessingSecurityScopedResource()
                        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                        if accessed { url.stopAccessingSecurityScopedResource() }
                        let ext = url.pathExtension.uppercased()
                        let title = url.deletingPathExtension().lastPathComponent
                        db.addBook(
                            title: title.isEmpty ? "未命名图书" : title,
                            bookmarkData: bookmark,
                            filePathHint: url.absoluteString,
                            format: ext.isEmpty ? "TXT" : ext,
                            folderId: nil
                        )
                    }
                }
            }
            .alert("新建文件夹", isPresented: $showNewFolderAlert) {
                TextField("文件夹名称", text: $newFolderName)
                Button("创建") {
                    db.createFolder(name: newFolderName)
                }
                Button("取消", role: .cancel) {}
            }
            .sheet(item: $activeOpdsSource) { src in
                OpdsBrowserSheet(source: src)
            }
            .sheet(isPresented: $showWebDavSheet) {
                WebDavBrowserSheet()
            }
        }
    }

    @ViewBuilder
    private var catalogSection: some View {
        if db.books.isEmpty && db.folders.isEmpty {
            ContentUnavailableView(
                "书架暂无图书",
                systemImage: "books.vertical",
                description: Text("点击右上角 + 关联本地 EPUB、TXT、PDF、MOBI 或 AZW3")
            )
            .padding(.top, 50)
        } else {
            LazyVStack(spacing: 12) {
                // Collapsible Folders
                ForEach(db.folders) { folder in
                    let folderBooks = db.books.filter { $0.folderId == folder.id }
                    let isExpanded = expandedFolderIds.contains(folder.id)

                    VStack(spacing: 4) {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                if isExpanded {
                                    expandedFolderIds.remove(folder.id)
                                } else {
                                    expandedFolderIds.insert(folder.id)
                                }
                            }
                        } label: {
                            GlassCard(cornerRadius: 18) {
                                HStack {
                                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                                        .foregroundStyle(Color.accentColor)
                                        .font(.title3)
                                    Text(folder.name)
                                        .font(.headline)
                                    Spacer()
                                    Text("\(folderBooks.count) 本")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                }
                                .padding(14)
                            }
                        }
                        .buttonStyle(GlassPressButtonStyle())
                        .contextMenu {
                            Button(role: .destructive) {
                                db.deleteFolder(id: folder.id)
                            } label: {
                                Label("删除文件夹（保留图书）", systemImage: "trash")
                            }
                        }

                        if isExpanded && !folderBooks.isEmpty {
                            VStack(spacing: 3) {
                                ForEach(Array(folderBooks.enumerated()), id: \.element.id) { idx, book in
                                    shelfBookRow(book: book, index: idx, count: folderBooks.count)
                                }
                            }
                            .padding(.leading, 12)
                        }
                    }
                }

                // Unfoldered Books (Grouped Asymmetric Glass Cards)
                if !unfolderedBooks.isEmpty {
                    VStack(spacing: 3) {
                        ForEach(Array(unfolderedBooks.enumerated()), id: \.element.id) { idx, book in
                            shelfBookRow(book: book, index: idx, count: unfolderedBooks.count)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func shelfBookRow(book: BookItem, index: Int, count: Int) -> some View {
        Button {
            onOpenBook(book)
        } label: {
            GlassGroupedCard(index: index, count: count) {
                BookRowView(book: book)
                    .padding(14)
            }
        }
        .buttonStyle(GlassPressButtonStyle())
        .contextMenu {
            if !db.folders.isEmpty {
                Menu("移动到文件夹") {
                    Button("移出文件夹") {
                        db.moveBook(book.id, toFolder: nil)
                    }
                    ForEach(db.folders) { f in
                        Button(f.name) {
                            db.moveBook(book.id, toFolder: f.id)
                        }
                    }
                }
            }
            if book.filePathHint != "sample://art_of_slow_reading" {
                Button(role: .destructive) {
                    db.deleteBook(id: book.id)
                } label: {
                    Label("从书架移除", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var opdsSourcesSection: some View {
        let sources = settingsStore.settings.opdsSources
        if sources.isEmpty {
            ContentUnavailableView(
                "尚未添加 OPDS 书源",
                systemImage: "globe",
                description: Text("请前往「设置 → 导入与 OPDS 书源」添加 Calibre 或在线 OPDS 书源")
            )
            .padding(.top, 50)
        } else {
            LazyVStack(spacing: 3) {
                ForEach(Array(sources.enumerated()), id: \.element.id) { idx, src in
                    Button {
                        activeOpdsSource = src
                    } label: {
                        GlassGroupedCard(index: idx, count: sources.count) {
                            HStack {
                                Image(systemName: "globe")
                                    .foregroundStyle(Color.accentColor)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(src.name).font(.headline)
                                    Text(src.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(14)
                        }
                    }
                    .buttonStyle(GlassPressButtonStyle())
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct HeroContinueCard: View {
    let book: BookItem
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            GlassCard(cornerRadius: 24, tintColor: Color.accentColor.opacity(0.12)) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("继续精读", systemImage: "book.pages.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Text(book.format)
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.16))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }

                    Text(book.title)
                        .font(.title3.bold())
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 2)

                    ProgressView(value: book.progressRatio)
                        .tint(.accentColor)

                    HStack {
                        Label("已读 \(formatDuration(book.readingSeconds))", systemImage: "clock")
                        Spacer()
                        Text("进度 \(Int(book.progressRatio * 100))%")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(GlassPressButtonStyle())
    }
}

private struct BookRowView: View {
    let book: BookItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(book.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer()
                Text(book.format)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
            }

            ProgressView(value: book.progressRatio)
                .tint(.accentColor)

            HStack {
                Label("已读 \(formatDuration(book.readingSeconds))", systemImage: "clock")
                Spacer()
                Text("\(Int(book.progressRatio * 100))%")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - OPDS Browser Sheet
private struct OpdsBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DatabaseManager.self) private var db
    let source: OpdsSource

    @State private var currentUrl: String = ""
    @State private var entries: [OpdsEntry] = []
    @State private var loading = false
    @State private var errorMsg: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorMsg {
                    Text(errorMsg).foregroundStyle(.red).font(.footnote)
                }
                if entries.isEmpty && !loading {
                    ContentUnavailableView("暂无内容", systemImage: "globe")
                } else {
                    ForEach(entries) { entry in
                        Button {
                            if entry.isAcquisition {
                                downloadOpdsBook(entry)
                            } else {
                                currentUrl = entry.linkUrl
                                loadFeed()
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.title).font(.body.weight(.medium))
                                    if !entry.subtitle.isEmpty {
                                        Text(entry.subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: entry.isAcquisition ? "arrow.down.circle" : "chevron.right")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle(source.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("刷新") { loadFeed() }
                }
            }
            .onAppear {
                currentUrl = source.url
                loadFeed()
            }
        }
    }

    private func loadFeed() {
        loading = true
        errorMsg = nil
        Task {
            do {
                entries = try await NetworkBookService.fetchOpdsFeed(
                    urlString: currentUrl,
                    username: source.username,
                    password: source.password
                )
            } catch {
                errorMsg = error.localizedDescription
            }
            loading = false
        }
    }

    private func downloadOpdsBook(_ entry: OpdsEntry) {
        loading = true
        Task {
            do {
                let ext = entry.formatHint.lowercased()
                let dest = try await NetworkBookService.downloadBookToLocal(
                    urlString: entry.linkUrl,
                    suggestedName: "\(entry.title).\(ext)",
                    username: source.username,
                    password: source.password
                )
                db.addBook(title: entry.title, bookmarkData: nil, filePathHint: dest.absoluteString, format: entry.formatHint)
                dismiss()
            } catch {
                errorMsg = error.localizedDescription
            }
            loading = false
        }
    }
}

// MARK: - WebDAV Browser Sheet
private struct WebDavBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DatabaseManager.self) private var db
    @Environment(SettingsStore.self) private var settingsStore

    @State private var currentUrl: String = ""
    @State private var entries: [WebDavEntry] = []
    @State private var loading = false
    @State private var errorMsg: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorMsg {
                    Text(errorMsg).foregroundStyle(.red).font(.footnote)
                }
                if entries.isEmpty && !loading {
                    ContentUnavailableView(
                        "WebDAV 网盘",
                        systemImage: "externaldrive.connected.to.line.below",
                        description: Text("请先在「设置」中填写 WebDAV 地址与账号")
                    )
                } else {
                    ForEach(entries) { entry in
                        Button {
                            if entry.isDirectory {
                                currentUrl = entry.href
                                loadDir()
                            } else {
                                downloadFile(entry)
                            }
                        } label: {
                            HStack {
                                Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                                    .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                                Text(entry.name)
                                Spacer()
                                if !entry.isDirectory {
                                    Image(systemName: "arrow.down.circle")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle("WebDAV 书库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("刷新") { loadDir() }
                }
            }
            .onAppear {
                currentUrl = settingsStore.settings.webdavUrl
                if !currentUrl.isEmpty { loadDir() }
            }
        }
    }

    private func loadDir() {
        loading = true
        errorMsg = nil
        Task {
            do {
                entries = try await NetworkBookService.listWebDav(
                    urlString: currentUrl,
                    username: settingsStore.settings.webdavUsername,
                    password: settingsStore.settings.webdavPassword
                )
            } catch {
                errorMsg = error.localizedDescription
            }
            loading = false
        }
    }

    private func downloadFile(_ entry: WebDavEntry) {
        loading = true
        Task {
            do {
                let dest = try await NetworkBookService.downloadBookToLocal(
                    urlString: entry.href,
                    suggestedName: entry.name,
                    username: settingsStore.settings.webdavUsername,
                    password: settingsStore.settings.webdavPassword
                )
                let ext = dest.pathExtension.uppercased()
                let title = dest.deletingPathExtension().lastPathComponent
                db.addBook(title: title, bookmarkData: nil, filePathHint: dest.absoluteString, format: ext)
                dismiss()
            } catch {
                errorMsg = error.localizedDescription
            }
            loading = false
        }
    }
}
