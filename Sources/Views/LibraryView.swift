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

    @State private var selectedFolderId: Int64? = nil
    @State private var showFileImporter = false
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var showOpdsSheet = false
    @State private var showWebDavSheet = false

    private var filteredBooks: [BookItem] {
        if let fid = selectedFolderId {
            return db.books.filter { $0.folderId == fid }
        }
        return db.books
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientGlassBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !db.folders.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    folderPill(title: "全部", id: nil)
                                    ForEach(db.folders) { folder in
                                        folderPill(title: folder.name, id: folder.id)
                                            .contextMenu {
                                                Button(role: .destructive) {
                                                    db.deleteFolder(id: folder.id)
                                                    if selectedFolderId == folder.id { selectedFolderId = nil }
                                                } label: {
                                                    Label("删除文件夹", systemImage: "trash")
                                                }
                                            }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                            }
                        }

                        if filteredBooks.isEmpty {
                            ContentUnavailableView(
                                "书架暂无图书",
                                systemImage: "books.vertical",
                                description: Text("点击右上角 + 导入本地 EPUB、TXT、PDF、MOBI 或 AZW3")
                            )
                            .padding(.top, 60)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(filteredBooks) { book in
                                    Button {
                                        onOpenBook(book)
                                    } label: {
                                        GlassCard(cornerRadius: 20) {
                                            BookRowView(book: book)
                                                .padding(16)
                                        }
                                    }
                                    .buttonStyle(.plain)
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
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 12)
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
                            showOpdsSheet = true
                        } label: {
                            Label("OPDS 在线书库", systemImage: "globe")
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
                            folderId: selectedFolderId
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
            .sheet(isPresented: $showOpdsSheet) {
                OpdsBrowserSheet(selectedFolderId: selectedFolderId)
            }
            .sheet(isPresented: $showWebDavSheet) {
                WebDavBrowserSheet(selectedFolderId: selectedFolderId)
            }
        }
    }

    private func folderPill(title: String, id: Int64?) -> some View {
        let isSelected = selectedFolderId == id
        return Button {
            withAnimation(.snappy) { selectedFolderId = id }
        } label: {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    if isSelected {
                        Capsule().fill(Color.accentColor)
                    } else {
                        Capsule().fill(.ultraThinMaterial)
                    }
                }
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

private struct BookRowView: View {
    let book: BookItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer()
                Text(book.format)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
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
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - OPDS Browser Sheet (Supports Multi-Source Switching)
private struct OpdsBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DatabaseManager.self) private var db
    @Environment(SettingsStore.self) private var settingsStore
    let selectedFolderId: Int64?

    @State private var currentUrl: String = ""
    @State private var activeUser: String = ""
    @State private var activePass: String = ""
    @State private var entries: [OpdsEntry] = []
    @State private var loading = false
    @State private var errorMsg: String?

    var body: some View {
        NavigationStack {
            List {
                if !settingsStore.settings.opdsSources.isEmpty {
                    Section("已保存书源") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(settingsStore.settings.opdsSources) { src in
                                    Button(src.name) {
                                        currentUrl = src.url
                                        activeUser = src.username
                                        activePass = src.password
                                        loadFeed()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                if let errorMsg {
                    Text(errorMsg).foregroundStyle(.red).font(.footnote)
                }
                if entries.isEmpty && !loading {
                    ContentUnavailableView(
                        "OPDS 书库",
                        systemImage: "globe",
                        description: Text("请在「设置 → OPDS 书源管理」添加书源，或点击右上角刷新")
                    )
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
            .navigationTitle("OPDS 在线书库")
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
                if let first = settingsStore.settings.opdsSources.first {
                    currentUrl = first.url
                    activeUser = first.username
                    activePass = first.password
                } else {
                    currentUrl = settingsStore.settings.opdsUrl
                    activeUser = settingsStore.settings.opdsUsername
                    activePass = settingsStore.settings.opdsPassword
                }
                if !currentUrl.isEmpty { loadFeed() }
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
                    username: activeUser,
                    password: activePass
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
                    username: activeUser,
                    password: activePass
                )
                db.addBook(title: entry.title, bookmarkData: nil, filePathHint: dest.absoluteString, format: entry.formatHint, folderId: selectedFolderId)
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
    let selectedFolderId: Int64?

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
                db.addBook(title: title, bookmarkData: nil, filePathHint: dest.absoluteString, format: ext, folderId: selectedFolderId)
                dismiss()
            } catch {
                errorMsg = error.localizedDescription
            }
            loading = false
        }
    }
}
