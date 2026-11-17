import SwiftUI

struct SettingsView: View {
    @Environment(DatabaseManager.self) private var db
    @Environment(SettingsStore.self) private var settingsStore

    @State private var downloadingDict = false
    @State private var dictMessage = ""
    @State private var cacheBytes: Int64 = BookCache.totalCacheBytes()

    @State private var showAddOpds = false
    @State private var opdsName = ""
    @State private var opdsUrl = ""
    @State private var opdsUser = ""
    @State private var opdsPass = ""

    var body: some View {
        @Bindable var store = settingsStore

        NavigationStack {
            Form {
                Section("外观与阅读体验") {
                    Picker("主题配色", selection: $store.settings.themeMode) {
                        ForEach(AppThemeMode.allCases, id: \.self) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    Picker("默认推进粒度", selection: $store.settings.stepMode) {
                        ForEach(StepMode.allCases, id: \.self) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    Stepper("后续显示：+\(store.settings.visibleCount)", value: $store.settings.visibleCount, in: 1...8)
                    Toggle("自动翻译当前焦点句", isOn: $store.settings.autoTranslateSentence)
                    Picker("整句翻译引擎", selection: $store.settings.sentenceTranslateEngine) {
                        Text("Apple 系统离线").tag("apple")
                        Text("自定义 AI").tag("ai")
                    }
                    Toggle("翻句自动 AI 精讲", isOn: $store.settings.autoAiAnalyze)
                    Toggle("正文中对已查单词显示底部虚线", isOn: $store.settings.underlineLookedUpWords)
                }

                Section("阅读器 5 项自定义配色") {
                    colorPresetRow(title: "阅读区背景", hex: $store.settings.readerBgColorHex)
                    colorPresetRow(title: "焦点句高亮", hex: $store.settings.readerFocusColorHex)
                    colorPresetRow(title: "下半区背景", hex: $store.settings.readerBottomBgColorHex)
                    colorPresetRow(title: "译文卡片底色", hex: $store.settings.readerSentenceCardColorHex)
                    colorPresetRow(title: "单词卡片底色", hex: $store.settings.readerWordCardColorHex)
                    Button("恢复默认玻璃透明配色") {
                        store.settings.readerBgColorHex = -1
                        store.settings.readerFocusColorHex = -1
                        store.settings.readerBottomBgColorHex = -1
                        store.settings.readerSentenceCardColorHex = -1
                        store.settings.readerWordCardColorHex = -1
                    }
                }

                Section("步进音效与震动反馈") {
                    Picker("翻句音效", selection: $store.settings.stepSoundTrack) {
                        ForEach(StepSoundTrack.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    Picker("震动强度", selection: $store.settings.stepHapticLevel) {
                        Text("关闭").tag(0)
                        Text("轻柔").tag(1)
                        Text("适中").tag(2)
                        Text("强烈").tag(3)
                    }
                }

                Section("离线英语词库") {
                    LabeledContent("当前词库词条数", value: "\(db.dictionaryCount) 词")
                    Button {
                        downloadingDict = true
                        dictMessage = "正在下载开源 ECDICT 常用词库..."
                        Task {
                            do {
                                let entries = try await TranslationService.downloadEcdictMini()
                                db.bulkInsertDictionary(entries)
                                dictMessage = "导入成功！新增/更新 \(entries.count) 词"
                            } catch {
                                dictMessage = "下载失败：\(error.localizedDescription)"
                            }
                            downloadingDict = false
                        }
                    } label: {
                        HStack {
                            Text(downloadingDict ? "正在下载导入..." : "一键下载完整开源词库 (ECDICT)")
                            if downloadingDict {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(downloadingDict)
                    if !dictMessage.isEmpty {
                        Text(dictMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("图书解析缓存") {
                    LabeledContent("已缓存图书体积", value: ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                    Button("清理全部解析缓存", role: .destructive) {
                        BookCache.clearAll()
                        cacheBytes = BookCache.totalCacheBytes()
                    }
                }

                Section("自定义 AI 接口（兼容 OpenAI / DeepSeek / Ollama）") {
                    TextField("API Base URL", text: $store.settings.aiBaseUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $store.settings.aiApiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("模型名称 (Model)", text: $store.settings.aiModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("OPDS 多书源管理") {
                    ForEach(store.settings.opdsSources) { src in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(src.name).font(.subheadline.weight(.medium))
                            Text(src.url).font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                store.settings.opdsSources.removeAll { $0.id == src.id }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                    Button {
                        opdsName = ""
                        opdsUrl = ""
                        opdsUser = ""
                        opdsPass = ""
                        showAddOpds = true
                    } label: {
                        Label("添加 OPDS 书源", systemImage: "plus.circle")
                    }
                }

                Section("WebDAV 书库配置") {
                    TextField("WebDAV 地址", text: $store.settings.webdavUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("用户名", text: $store.settings.webdavUsername)
                        .textInputAutocapitalization(.never)
                    SecureField("密码", text: $store.settings.webdavPassword)
                }
            }
            .navigationTitle("设置")
            .onAppear {
                cacheBytes = BookCache.totalCacheBytes()
            }
            .sheet(isPresented: $showAddOpds) {
                NavigationStack {
                    Form {
                        TextField("书源名称", text: $opdsName)
                        TextField("OPDS URL", text: $opdsUrl)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("用户名（可选）", text: $opdsUser)
                            .textInputAutocapitalization(.never)
                        SecureField("密码（可选）", text: $opdsPass)
                    }
                    .navigationTitle("添加 OPDS 书源")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("取消") { showAddOpds = false }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("保存") {
                                let name = opdsName.trimmingCharacters(in: .whitespacesAndNewlines)
                                let url = opdsUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !url.isEmpty {
                                    store.settings.opdsSources.append(
                                        OpdsSource(name: name.isEmpty ? "OPDS 书源" : name, url: url, username: opdsUser, password: opdsPass)
                                    )
                                }
                                showAddOpds = false
                            }
                            .bold()
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private func colorPresetRow(title: String, hex: Binding<Int64>) -> some View {
        let presets: [(String, Int64)] = [
            ("默认", -1),
            ("柔白", 0xFFFDFDFD),
            ("羊皮", 0xFFF4ECD8),
            ("浅绿", 0xFFE6F2EA),
            ("浅蓝", 0xFFE8F1FA),
            ("深灰", 0xFF1E293B)
        ]
        return HStack {
            Text(title).font(.subheadline)
            Spacer()
            HStack(spacing: 6) {
                ForEach(presets, id: \.1) { name, val in
                    Button {
                        hex.wrappedValue = val
                    } label: {
                        Text(name)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(hex.wrappedValue == val ? Color.accentColor : Color.secondary.opacity(0.15))
                            .foregroundStyle(hex.wrappedValue == val ? .white : .primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
