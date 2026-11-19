import SwiftUI
#if canImport(Translation)
import Translation
#endif
import UniformTypeIdentifiers

private let fullDictThreshold = 500

private enum DictDeleteTarget: String, Identifiable {
    case english
    case chinese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english: return "删除英文词库"
        case .chinese: return "删除中文词典"
        }
    }

    var desc: String {
        switch self {
        case .english:
            return "确定删除已下载的 ECDICT 英文词库吗？删除后将仅保留少量基础内置词条并释放存储空间。"
        case .chinese:
            return "确定删除已下载的汉语词典（汉字/成语/词语）吗？删除后将仅保留少量基础内置词条并释放存储空间。"
        }
    }
}

private var settingsBookContentTypes: [UTType] {
    var types: [UTType] = [.epub, .plainText, .pdf, .data]
    if let mobi = UTType(filenameExtension: "mobi") { types.append(mobi) }
    if let azw3 = UTType(filenameExtension: "azw3") { types.append(azw3) }
    return types
}

private struct AppIconOption: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let iconName: String? // nil = 默认 AppIcon
    let previewAssetName: String
}

private let appIconOptions: [AppIconOption] = [
    AppIconOption(id: "warm_orange", title: "展翼暖橙", subtitle: "暖橙底 · 棕咖猫", iconName: nil, previewAssetName: "IconPreviewWarmOrange"),
    AppIconOption(id: "pearl_white", title: "环抱白瓷", subtitle: "白瓷底 · 暖橘猫", iconName: "AppIconPearl", previewAssetName: "IconPreviewPearlWhite"),
    AppIconOption(id: "midnight_blue", title: "叠页靛蓝", subtitle: "靛蓝底 · 奶白猫", iconName: "AppIconMidnight", previewAssetName: "IconPreviewMidnightBlue")
]

struct SettingsView: View {
    @Environment(DatabaseManager.self) private var db
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(BackupService.self) private var backupService
    @Environment(\.appPalette) private var palette
    @Environment(\.colorScheme) private var systemScheme

    var onOpenBook: (BookItem) -> Void = { _ in }

    private enum ImporterMode {
        case books
        case backupFolder
    }

    @State private var themeSectionExpanded = false
    @State private var appIconSectionExpanded = false
    @State private var importSectionExpanded = false
    @State private var dictSectionExpanded = false
    @State private var aiSectionExpanded = false
    @State private var backupSectionExpanded = false
    @State private var cacheSectionExpanded = false

    @State private var currentAlternateIconName: String? = UIApplication.shared.alternateIconName
    @State private var iconSwitchError: String? = nil

    // Local import & folder permission picker
    @State private var showFileImporter = false
    @State private var importerMode: ImporterMode = .books
    @State private var showRestoreConfirmAlert = false
    @State private var importFeedbackMsg: String?
    @State private var importFeedbackIsError = false

    // WebDAV
    @State private var webDavConfigExpanded = false
    @State private var showWebDavPassword = false
    @State private var testingWebDav = false
    @State private var webDavTestMsg: String?
    @State private var webDavTestIsError = false
    @State private var showWebDavBrowser = false

    // OPDS
    @State private var editingOpdsSource: OpdsSource?
    @State private var showOpdsEditSheet = false

    // Dictionaries & Apple Offline Translation
    @State private var pendingDelete: DictDeleteTarget?
    @State private var isDeletingDict = false
    @State private var appleBridge = AppleTranslationBridge()
    @State private var en2zhStatus = "检测中..."
    @State private var zh2enStatus = "检测中..."
    @State private var preparingEn2Zh = false
    @State private var preparingZh2En = false
    @State private var appleStatusMsg: String?
    @State private var appleStatusIsError = false

    // AI
    @State private var showAiApiKey = false
    @State private var testingAiSpeed = false
    @State private var aiTestMsg: String?
    @State private var aiTestIsError = false

    // Cache
    @State private var cacheStats = CacheStats()
    @State private var managedBooksReport = ManagedBooksCleanupReport()
    @State private var translationCacheCount = 0
    @State private var isClearingCache = false
    @State private var cacheFeedbackMsg: String?

    var body: some View {
        @Bindable var store = settingsStore
        @Bindable var backup = backupService
        let translationService = TranslationService.shared
        let engineLabel: String = {
            switch store.settings.sentenceTranslateEngine {
            case "ai": return "AI"
            case "online": return "在线"
            case "apple", "offline": return "离线"
            default: return "智能"
            }
        }()
        let aiSummary = TranslationService.hasAiConfigured(store.settings) && !store.settings.aiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "已配置 · \(store.settings.aiModel)"
            : "兼容 OpenAI / DeepSeek / 阿里百炼"

        let currentIconOption = appIconOptions.first { $0.iconName == currentAlternateIconName } ?? appIconOptions[0]

        ZStack {
            AmbientGlassBackdrop(themeMode: store.settings.themeMode)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("设置")
                        .font(.title2.bold())
                    MinimalTagPill(
                        text: store.settings.themeMode.displayName,
                        tintColor: palette.accent.opacity(0.14),
                        textColor: palette.accent
                    )
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)

                ScrollView {
                    VStack(spacing: 3) {
                        // 1. 外观主题（7 套配色方案 + 阅读器自定义联动重置）
                        GlassGroupedCard(index: 0, count: 7, outerRadius: 22, innerRadius: 6) {
                            settingsGroupSection(
                                title: "外观主题",
                                subtitle: "当前：\(store.settings.themeMode.displayName)",
                                systemImage: "paintpalette",
                                expanded: $themeSectionExpanded
                            ) {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 94), spacing: 8)], spacing: 8) {
                                    ForEach(AppThemeMode.allCases, id: \.self) { mode in
                                        let previewPalette = AppThemePalette.resolve(mode: mode, systemScheme: systemScheme)
                                        let selected = store.settings.themeMode == mode
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.24)) {
                                                store.applyThemeMode(mode)
                                            }
                                        } label: {
                                            HStack(spacing: 6) {
                                                Circle()
                                                    .fill(previewPalette.previewColor)
                                                    .frame(width: 12, height: 12)
                                                    .overlay(
                                                        Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.6)
                                                    )
                                                Text(mode.displayName)
                                                    .font(.caption.weight(selected ? .semibold : .medium))
                                                    .lineLimit(1)
                                                Spacer(minLength: 0)
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 8)
                                            .background {
                                                ZStack {
                                                    Capsule().fill(selected ? .regularMaterial : .ultraThinMaterial)
                                                    if selected {
                                                        Capsule().fill(palette.accent.opacity(palette.isLight ? 0.16 : 0.24))
                                                    } else {
                                                        Capsule().fill(palette.nestedTint.opacity(0.32))
                                                    }
                                                }
                                            }
                                            .foregroundStyle(selected ? palette.accent : .primary)
                                            .overlay {
                                                Capsule().strokeBorder(
                                                    selected ? palette.accent.opacity(0.55) : .white.opacity(palette.isLight ? 0.50 : 0.18),
                                                    lineWidth: selected ? 1.0 : 0.7
                                                )
                                            }
                                            .shadow(color: .black.opacity(palette.isLight ? 0.04 : 0.16), radius: 4, x: 0, y: 1.5)
                                        }
                                        .buttonStyle(GlassPressButtonStyle())
                                    }
                                }

                                Text("切换预设将同步应用到全局液态玻璃界面与阅读器，阅读器内仍可微调 5 项自定义颜色。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // 2. 桌面图标
                        GlassGroupedCard(index: 1, count: 7, outerRadius: 22, innerRadius: 6) {
                            settingsGroupSection(
                                title: "桌面图标",
                                subtitle: "当前：\(currentIconOption.title)",
                                systemImage: "app.badge",
                                expanded: $appIconSectionExpanded
                            ) {
                                HStack(spacing: 12) {
                                    ForEach(appIconOptions) { option in
                                        let isSelected = currentAlternateIconName == option.iconName
                                        Button {
                                            selectAppIcon(option)
                                        } label: {
                                            VStack(spacing: 6) {
                                                ZStack(alignment: .topTrailing) {
                                                    Image(option.previewAssetName)
                                                        .resizable()
                                                        .scaledToFill()
                                                        .frame(width: 64, height: 64)
                                                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                                        .overlay {
                                                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                                                .strokeBorder(
                                                                    isSelected ? palette.accent : Color.white.opacity(palette.isLight ? 0.65 : 0.22),
                                                                    lineWidth: isSelected ? 2.4 : 0.8
                                                                )
                                                        }
                                                        .shadow(
                                                            color: isSelected ? palette.accent.opacity(0.32) : .black.opacity(0.14),
                                                            radius: isSelected ? 8 : 4,
                                                            x: 0,
                                                            y: 2
                                                        )

                                                    if isSelected {
                                                        Image(systemName: "checkmark.circle.fill")
                                                            .font(.system(size: 16))
                                                            .foregroundStyle(.white, palette.accent)
                                                            .offset(x: 4, y: -4)
                                                    }
                                                }

                                                Text(option.title)
                                                    .font(.caption.weight(isSelected ? .semibold : .medium))
                                                    .foregroundStyle(isSelected ? palette.accent : .primary)
                                                    .lineLimit(1)

                                                Text(option.subtitle)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 6)
                                        }
                                        .buttonStyle(GlassPressButtonStyle())
                                    }
                                }

                                if let iconSwitchError {
                                    Text(iconSwitchError)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                } else {
                                    Text("点击上方图标即可切换 iOS 桌面应用图标。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        // 3. 图书导入与网盘
                        GlassGroupedCard(index: 2, count: 7, outerRadius: 22, innerRadius: 6) {
                            settingsGroupSection(
                                title: "图书导入与网盘",
                                subtitle: "本地导入 · WebDAV · OPDS（\(store.opdsSources.count) 个）",
                                systemImage: "books.vertical",
                                expanded: $importSectionExpanded
                            ) {
                                // 2.1 本地文件导入
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("本地文件导入")
                                        .font(.subheadline.weight(.semibold))
                                    Text("支持 EPUB · TXT · PDF · MOBI · AZW3，导入后自动加入书架，打开时按需秒速解析")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Button {
                                        importerMode = .books
                                        showFileImporter = true
                                    } label: {
                                        Label("关联本地图书", systemImage: "folder.badge.plus")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(palette.accent)

                                    if let importFeedbackMsg {
                                        Text(importFeedbackMsg)
                                            .font(.caption)
                                            .foregroundStyle(importFeedbackIsError ? .red : palette.accent)
                                    }
                                }

                                Divider()

                                // 2.2 WebDAV 网盘读取
                                VStack(alignment: .leading, spacing: 8) {
                                    let hasWebDavUrl = !store.settings.webdavUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    HStack {
                                        Label("WebDAV 网盘读取", systemImage: "icloud")
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        MinimalTagPill(
                                            text: hasWebDavUrl ? "已配置" : "未配置",
                                            tintColor: hasWebDavUrl ? palette.accent.opacity(0.16) : nil,
                                            textColor: hasWebDavUrl ? palette.accent : .secondary
                                        )
                                    }
                                    Text(
                                        hasWebDavUrl
                                            ? store.settings.webdavUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                                            : "支持坚果云、AList（可挂载阿里云盘 / 夸克 / 百度等）、NAS / Nextcloud"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)

                                    HStack(spacing: 8) {
                                        Button {
                                            if !hasWebDavUrl {
                                                withAnimation(AppMotion.panelSpring) {
                                                    webDavConfigExpanded = true
                                                }
                                                webDavTestIsError = true
                                                webDavTestMsg = "请先填写 WebDAV 服务器地址"
                                            } else {
                                                showWebDavBrowser = true
                                            }
                                        } label: {
                                            Label("浏览网盘图书", systemImage: "icloud.and.arrow.down")
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(palette.accent.opacity(0.85))

                                        Button(webDavConfigExpanded ? "收起配置" : "网盘配置") {
                                            withAnimation(AppMotion.panelSpring) {
                                                webDavConfigExpanded.toggle()
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    if webDavConfigExpanded {
                                        VStack(alignment: .leading, spacing: 8) {
                                            TextField("WebDAV 服务器地址 (https://...)", text: $store.settings.webdavUrl)
                                                .textFieldStyle(.roundedBorder)
                                                .keyboardType(.URL)
                                                .textInputAutocapitalization(.never)
                                                .autocorrectionDisabled()
                                                .onChange(of: store.settings.webdavUrl) { _, _ in webDavTestMsg = nil }

                                            TextField("用户名（可选）", text: $store.settings.webdavUsername)
                                                .textFieldStyle(.roundedBorder)
                                                .textInputAutocapitalization(.never)
                                                .autocorrectionDisabled()
                                                .onChange(of: store.settings.webdavUsername) { _, _ in webDavTestMsg = nil }

                                            HStack(spacing: 6) {
                                                Group {
                                                    if showWebDavPassword {
                                                        TextField("密码 / 应用密码（可选）", text: $store.settings.webdavPassword)
                                                    } else {
                                                        SecureField("密码 / 应用密码（可选）", text: $store.settings.webdavPassword)
                                                    }
                                                }
                                                .textFieldStyle(.roundedBorder)
                                                .textInputAutocapitalization(.never)
                                                .autocorrectionDisabled()
                                                .onChange(of: store.settings.webdavPassword) { _, _ in webDavTestMsg = nil }

                                                Button {
                                                    showWebDavPassword.toggle()
                                                } label: {
                                                    Image(systemName: showWebDavPassword ? "eye.slash" : "eye")
                                                        .foregroundStyle(.secondary)
                                                }
                                                .buttonStyle(.plain)
                                            }

                                            HStack(spacing: 10) {
                                                Button(testingWebDav ? "测试中..." : "测试连接") {
                                                    testWebDav(store.settings)
                                                }
                                                .buttonStyle(.bordered)
                                                .disabled(testingWebDav || !hasWebDavUrl)

                                                if let webDavTestMsg {
                                                    Text(webDavTestMsg)
                                                        .font(.caption)
                                                        .foregroundStyle(webDavTestIsError ? .red : palette.accent)
                                                }
                                            }
                                            if testingWebDav {
                                                ProgressView()
                                                    .progressViewStyle(.linear)
                                            }
                                        }
                                        .padding(.top, 4)
                                        .transition(AppMotion.panelTransition)
                                    }
                                }

                                Divider()

                                // 2.3 OPDS 在线书源
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Label("OPDS 在线书源", systemImage: "globe")
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        MinimalTagPill(
                                            text: store.opdsSources.isEmpty ? "未添加" : "\(store.opdsSources.count) 个",
                                            tintColor: store.opdsSources.isEmpty ? nil : palette.accent.opacity(0.16),
                                            textColor: store.opdsSources.isEmpty ? .secondary : palette.accent
                                        )
                                    }

                                    Text("配置后可直接在「书架」右侧切换到在线书库浏览下载（支持 Calibre-Web / Komga / 标准 OPDS 1.2）")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    if !store.opdsSources.isEmpty {
                                        VStack(spacing: 6) {
                                            ForEach(store.opdsSources) { src in
                                                HStack(spacing: 8) {
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(src.name)
                                                            .font(.subheadline.weight(.medium))
                                                            .lineLimit(1)
                                                        Text(src.url)
                                                            .font(.caption2)
                                                            .foregroundStyle(.secondary)
                                                            .lineLimit(1)
                                                    }
                                                    Spacer()
                                                    Button {
                                                        editingOpdsSource = src
                                                        showOpdsEditSheet = true
                                                    } label: {
                                                        Image(systemName: "pencil")
                                                            .font(.caption)
                                                            .padding(6)
                                                            .background(palette.accent.opacity(0.12))
                                                            .clipShape(Circle())
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(palette.nestedTint.opacity(0.55))
                                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                            }
                                        }
                                    }

                                    HStack(spacing: 8) {
                                        Button {
                                            editingOpdsSource = nil
                                            showOpdsEditSheet = true
                                        } label: {
                                            Label("添加 OPDS 书源", systemImage: "plus")
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)

                                        Button("恢复默认书源") {
                                            store.restoreDefaultOpdsSources()
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }

                        // 4. 词库与翻译引擎
                        GlassGroupedCard(index: 3, count: 7, outerRadius: 22, innerRadius: 6) {
                            settingsGroupSection(
                                title: "词库与翻译引擎",
                                subtitle: "Apple 原生查词/翻译 · 整句：\(engineLabel)",
                                systemImage: "character.book.closed",
                                expanded: $dictSectionExpanded
                            ) {
                                let englishCount = max(0, db.dictionaryCount - db.chineseDictionaryCount)
                                let isEnglishDownloaded = englishCount > fullDictThreshold
                                let isChineseDownloaded = db.chineseDictionaryCount > fullDictThreshold
                                let ecdictState = translationService.ecdictState
                                let chineseState = translationService.chineseDictState

                                // 3.1 Apple 系统原生翻译（单词查词 + 整句双向翻译）
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Apple 原生翻译（单词查词 + 整句翻译）")
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        MinimalTagPill(
                                            text: "已直接接入",
                                            tintColor: palette.accent.opacity(0.16),
                                            textColor: palette.accent
                                        )
                                    }

                                    Text("阅读时点按任意英文或中文单词，已直接调用 Apple 系统内置翻译引擎实时获取释义并自动缓存（无需必须下载第三方词库）。预下载系统语言包后支持完全断网查词与翻译。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    VStack(spacing: 6) {
                                        HStack {
                                            Text("英译中语言包（英文查词 / 整句）")
                                                .font(.caption)
                                            Spacer()
                                            Text(en2zhStatus)
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(en2zhStatus.contains("已安装") ? palette.accent : .secondary)
                                        }
                                        HStack {
                                            Text("中译英语言包（中文查词 / 整句）")
                                                .font(.caption)
                                            Spacer()
                                            Text(zh2enStatus)
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(zh2enStatus.contains("已安装") ? palette.accent : .secondary)
                                        }
                                    }
                                    .padding(10)
                                    .background(palette.nestedTint.opacity(0.55))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                    HStack(spacing: 8) {
                                        Button {
                                            prepareApplePack(toEnglish: false)
                                        } label: {
                                            Text(preparingEn2Zh ? "准备中..." : "预下载英译中")
                                                .font(.caption.weight(.semibold))
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(preparingEn2Zh || preparingZh2En)

                                        Button {
                                            prepareApplePack(toEnglish: true)
                                        } label: {
                                            Text(preparingZh2En ? "准备中..." : "预下载中译英")
                                                .font(.caption.weight(.semibold))
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(preparingEn2Zh || preparingZh2En)
                                    }

                                    if let appleStatusMsg {
                                        Text(appleStatusMsg)
                                            .font(.caption)
                                            .foregroundStyle(appleStatusIsError ? .red : palette.accent)
                                    }
                                }

                                Divider()

                                // 3.2 整句翻译引擎 & 阅读交互开关
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("整句翻译引擎")
                                        .font(.subheadline.weight(.semibold))

                                    GlassSegmentedControl(
                                        options: [
                                            ("auto", "智能"),
                                            ("ai", "AI"),
                                            ("online", "在线"),
                                            ("apple", "离线")
                                        ],
                                        selection: Binding(
                                            get: {
                                                store.settings.sentenceTranslateEngine == "offline"
                                                    ? "apple"
                                                    : store.settings.sentenceTranslateEngine
                                            },
                                            set: { store.settings.sentenceTranslateEngine = $0 }
                                        ),
                                        compact: true
                                    )

                                    Text(engineDescription(store.settings.sentenceTranslateEngine))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Toggle("自动翻译当前焦点句", isOn: $store.settings.autoTranslateSentence)
                                        .font(.subheadline)
                                    Toggle("正文中对已查单词显示底部虚线", isOn: $store.settings.underlineLookedUpWords)
                                        .font(.subheadline)
                                }

                                Divider()

                                // 3.3 可选扩展：ECDICT 英文词库
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("可选增强：开源英汉词库 (ECDICT)")
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        MinimalTagPill(
                                            text: isEnglishDownloaded ? "已下载" : "可选",
                                            tintColor: isEnglishDownloaded ? palette.accent.opacity(0.16) : nil,
                                            textColor: isEnglishDownloaded ? palette.accent : .secondary
                                        )
                                    }
                                    Text(
                                        ecdictState.message ?? (
                                            isEnglishDownloaded
                                                ? "已下载 · 本地英文词库 \(englishCount) 词（提供音标与多词性详尽释义）"
                                                : "未下载时自动使用 Apple 原生翻译查词；下载后可额外提供离线音标与多词性词典释义"
                                        )
                                    )
                                    .font(.caption)
                                    .foregroundStyle(ecdictState.isError ? .red : .secondary)

                                    if ecdictState.isDownloading {
                                        ProgressView()
                                            .progressViewStyle(.linear)
                                    }

                                    if isEnglishDownloaded {
                                        HStack(spacing: 8) {
                                            Button {
                                                translationService.startEcdictDownload(db: db)
                                            } label: {
                                                Label(
                                                    ecdictState.isDownloading ? "正在更新..." : "已下载 · 重下",
                                                    systemImage: "checkmark.circle.fill"
                                                )
                                                .frame(maxWidth: .infinity)
                                            }
                                            .buttonStyle(.bordered)
                                            .disabled(ecdictState.isDownloading || isDeletingDict)

                                            Button(role: .destructive) {
                                                pendingDelete = .english
                                            } label: {
                                                Label("删除", systemImage: "trash")
                                            }
                                            .buttonStyle(.bordered)
                                            .disabled(ecdictState.isDownloading || isDeletingDict)
                                        }
                                    } else {
                                        Button {
                                            translationService.startEcdictDownload(db: db)
                                        } label: {
                                            Text(ecdictState.isDownloading ? "正在后台下载英文词库..." : "下载完整开源英汉词库 (ECDICT)")
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(ecdictState.isDownloading || isDeletingDict)
                                    }
                                }

                                Divider()

                                // 3.4 汉语词典
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("可选增强：汉语词典（新华字典+成语+词语）")
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        MinimalTagPill(
                                            text: isChineseDownloaded ? "已下载" : "可选",
                                            tintColor: isChineseDownloaded ? palette.accent.opacity(0.16) : nil,
                                            textColor: isChineseDownloaded ? palette.accent : .secondary
                                        )
                                    }
                                    Text(
                                        chineseState.message ?? (
                                            isChineseDownloaded
                                                ? "已下载 · 本地中文词典 \(db.chineseDictionaryCount) 词"
                                                : "未下载完整词典（当前含内置基础 \(db.chineseDictionaryCount) 词，查词支持 Apple 中译英）"
                                        )
                                    )
                                    .font(.caption)
                                    .foregroundStyle(chineseState.isError ? .red : .secondary)

                                    if chineseState.isDownloading {
                                        ProgressView()
                                            .progressViewStyle(.linear)
                                    }

                                    if isChineseDownloaded {
                                        HStack(spacing: 8) {
                                            Button {
                                                translationService.startChineseDictDownload(db: db)
                                            } label: {
                                                Label(
                                                    chineseState.isDownloading ? "正在更新..." : "已下载 · 重下",
                                                    systemImage: "checkmark.circle.fill"
                                                )
                                                .frame(maxWidth: .infinity)
                                            }
                                            .buttonStyle(.bordered)
                                            .disabled(chineseState.isDownloading || isDeletingDict)

                                            Button(role: .destructive) {
                                                pendingDelete = .chinese
                                            } label: {
                                                Label("删除", systemImage: "trash")
                                            }
                                            .buttonStyle(.bordered)
                                            .disabled(chineseState.isDownloading || isDeletingDict)
                                        }
                                    } else {
                                        Button {
                                            translationService.startChineseDictDownload(db: db)
                                        } label: {
                                            Text(chineseState.isDownloading ? "正在后台下载中文词典..." : "下载完整汉语词典（新华字典+成语+词语）")
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(chineseState.isDownloading || isDeletingDict)
                                    }
                                }
                            }
                        }

                        // 5. 自定义 AI 接口
                        GlassGroupedCard(index: 4, count: 7, outerRadius: 22, innerRadius: 6) {
                            settingsGroupSection(
                                title: "自定义 AI 接口",
                                subtitle: aiSummary,
                                systemImage: "sparkles",
                                expanded: $aiSectionExpanded
                            ) {
                                Text("配置后将自动用于「整句 AI 精译」（智能/AI模式）以及句子、词汇语境精讲。\n低延迟推荐：qwen-mt-flash（阿里百炼专用翻译小模型，约 0.3s）、qwen-flash、glm-4-flash、deepseek-chat。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Toggle("点词自动 AI 语境解析", isOn: $store.settings.autoAiAnalyze)
                                    .font(.subheadline)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        aiPresetButton("OpenAI", url: "https://api.openai.com/v1", model: "gpt-4o-mini", store: store)
                                        aiPresetButton("DeepSeek", url: "https://api.deepseek.com/v1", model: "deepseek-chat", store: store)
                                        aiPresetButton("阿里百炼", url: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-mt-flash", store: store)
                                        aiPresetButton("智谱 GLM", url: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4-flash", store: store)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("API Base URL").font(.caption).foregroundStyle(.secondary)
                                    TextField("https://api.openai.com/v1", text: $store.settings.aiBaseUrl)
                                        .textFieldStyle(.roundedBorder)
                                        .keyboardType(.URL)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .onChange(of: store.settings.aiBaseUrl) { _, _ in aiTestMsg = nil }

                                    Text("API Key").font(.caption).foregroundStyle(.secondary)
                                    HStack(spacing: 6) {
                                        Group {
                                            if showAiApiKey {
                                                TextField("sk-...", text: $store.settings.aiApiKey)
                                            } else {
                                                SecureField("sk-...", text: $store.settings.aiApiKey)
                                            }
                                        }
                                        .textFieldStyle(.roundedBorder)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .onChange(of: store.settings.aiApiKey) { _, _ in aiTestMsg = nil }

                                        Button {
                                            showAiApiKey.toggle()
                                        } label: {
                                            Image(systemName: showAiApiKey ? "eye.slash" : "eye")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }

                                    Text("模型名称 (Model)").font(.caption).foregroundStyle(.secondary)
                                    TextField("gpt-4o-mini", text: $store.settings.aiModel)
                                        .textFieldStyle(.roundedBorder)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .onChange(of: store.settings.aiModel) { _, _ in aiTestMsg = nil }

                                    Text("精讲系统提示词 (System Prompt)").font(.caption).foregroundStyle(.secondary)
                                    TextField("System Prompt", text: $store.settings.aiSystemPrompt, axis: .vertical)
                                        .lineLimit(2...4)
                                        .textFieldStyle(.roundedBorder)
                                }

                                HStack(spacing: 10) {
                                    Button(testingAiSpeed ? "测速中..." : "测试响应速度") {
                                        testAiSpeed(store.settings)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(testingAiSpeed)

                                    if let aiTestMsg {
                                        Text(aiTestMsg)
                                            .font(.caption)
                                            .foregroundStyle(aiTestIsError ? .red : palette.accent)
                                    }
                                }

                                if testingAiSpeed {
                                    ProgressView()
                                        .progressViewStyle(.linear)
                                }
                            }
                        }

                        // 6. 数据权限与重装备份
                        GlassGroupedCard(index: 5, count: 7, outerRadius: 22, innerRadius: 6) {
                            settingsGroupSection(
                                title: "数据权限与重装备份",
                                subtitle: backupService.isAuthorized ? "已授权：\(backupService.authorizedFolderName)" : "未授权 · 卸载重装防丢失",
                                systemImage: "folder.badge.person.crop",
                                expanded: $backupSectionExpanded
                            ) {
                                Text("iOS 卸载应用时会清空本地沙盒。通过「文件」App 授权一个外部持久目录（强烈建议选择「iCloud 云盘」中的目录），默认仅同步阅读进度、阅读时长、笔记、生词本、分类与设置到 MiaoyueBackup/backup_manifest.json，不重复拷贝大体积电子书原文件。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                VStack(spacing: 8) {
                                    HStack {
                                        Text("外部存储权限")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        MinimalTagPill(
                                            text: backupService.isAuthorized ? "已授权" : "未授权",
                                            tintColor: backupService.isAuthorized ? palette.accent.opacity(0.16) : nil,
                                            textColor: backupService.isAuthorized ? palette.accent : .secondary
                                        )
                                    }
                                    if backupService.isAuthorized {
                                        cacheStatRow("授权目录", backupService.authorizedFolderName)
                                        if backupService.lastBackupAtMs > 0 {
                                            cacheStatRow("最近同步", formatSettingsBackupTime(backupService.lastBackupAtMs))
                                        }
                                    }
                                }
                                .padding(12)
                                .background(palette.nestedTint.opacity(0.55))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                if backupService.isSandboxOwnDocumentsWarning {
                                    Text("⚠️ 检测到您选择了本应用自身的沙盒目录（我的 iPhone/喵阅），卸载重装时该目录会被系统清除！请重新选择「iCloud 云盘」或外部云盘目录。")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }

                                if let preview = backupService.detectedBackupPreview {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("已检测到可恢复备份")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(palette.accent)
                                        Text("\(preview.bookCount) 本图书记录 · \(preview.folderCount) 个文件夹 · \(preview.noteCount) 条笔记 · \(preview.vocabCount) 个生词")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text(
                                            preview.backupBooksCount > 0
                                                ? "原书副本：\(preview.backupBooksCount) 个（\(formatSettingsCacheSize(preview.backupBooksBytes))）"
                                                : "模式：仅阅读记录备份（未拷贝原书文件）"
                                        )
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        Text("备份时间：\(formatSettingsBackupTime(preview.exportedAtMs))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)

                                        if preview.backupBooksCount > 0 {
                                            Button(role: .destructive) {
                                                Task {
                                                    await backupService.clearBackupBookCopies()
                                                }
                                            } label: {
                                                Text("清理备份中的原书副本（保留阅读记录）")
                                                    .font(.caption)
                                                    .frame(maxWidth: .infinity)
                                            }
                                            .buttonStyle(.bordered)
                                            .padding(.top, 4)
                                            .disabled(backupService.isBackingUp || backupService.isRestoring)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(palette.accent.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }

                                Toggle("仅同步阅读记录与设置（不复制原书）", isOn: $backup.recordsOnlyBackupEnabled)
                                    .font(.subheadline)

                                if backupService.isAuthorized {
                                    Toggle("退至后台自动增量同步", isOn: $backup.autoBackupEnabled)
                                        .font(.subheadline)
                                }

                                Button {
                                    importerMode = .backupFolder
                                    showFileImporter = true
                                } label: {
                                    Label(
                                        backupService.isAuthorized ? "更换持久数据目录" : "授权持久数据目录（推荐 iCloud 云盘）",
                                        systemImage: "folder.badge.plus"
                                    )
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(palette.accent)
                                .disabled(backupService.isBackingUp || backupService.isRestoring)

                                if backupService.isAuthorized {
                                    HStack(spacing: 8) {
                                        Button {
                                            Task {
                                                await backupService.backupNow(db: db, settingsStore: settingsStore, silent: false)
                                            }
                                        } label: {
                                            Text(backupService.isBackingUp ? "同步中..." : "立即同步备份")
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(backupService.isBackingUp || backupService.isRestoring)

                                        Button {
                                            if db.books.count > 1 {
                                                showRestoreConfirmAlert = true
                                            } else {
                                                Task {
                                                    await backupService.restoreFromAuthorizedFolder(db: db, settingsStore: settingsStore)
                                                }
                                            }
                                        } label: {
                                            Text(backupService.isRestoring ? "恢复中..." : "从备份恢复")
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(backupService.isBackingUp || backupService.isRestoring || backupService.detectedBackupPreview == nil)
                                    }

                                    Button("取消目录授权", role: .destructive) {
                                        backupService.revokeBackupFolder()
                                    }
                                    .font(.caption)
                                }

                                if backupService.isBackingUp || backupService.isRestoring {
                                    ProgressView()
                                        .progressViewStyle(.linear)
                                }

                                if let statusMsg = backupService.statusMessage {
                                    Text(statusMsg)
                                        .font(.caption)
                                        .foregroundStyle(backupService.statusIsError ? .red : palette.accent)
                                }
                            }
                        }

                        // 7. 缓存与存储管理
                        GlassGroupedCard(index: 6, count: 7, outerRadius: 22, innerRadius: 6) {
                            settingsGroupSection(
                                title: "缓存与存储管理",
                                subtitle: "缓存 \(formatSettingsCacheSize(cacheStats.totalBytes)) · 原书 \(managedBooksReport.totalFiles) 个",
                                systemImage: "internaldrive",
                                expanded: $cacheSectionExpanded
                            ) {
                                Text("清理缓存仅释放预解析数据、封面缩略图、翻译记录与未关联书架的冗余原书副本，不会删除书架图书和任何阅读记录。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                VStack(spacing: 8) {
                                    cacheStatRow("图书正文解析缓存", formatSettingsCacheSize(cacheStats.bookCacheBytes))
                                    cacheStatRow("封面缩略图缓存", formatSettingsCacheSize(cacheStats.coverCacheBytes))
                                    cacheStatRow("临时缓存文件", formatSettingsCacheSize(cacheStats.tempBytes))
                                    cacheStatRow("已缓存整句翻译", "\(translationCacheCount) 条")
                                    cacheStatRow("沙盒原书目录 (Books)", "\(managedBooksReport.totalFiles) 个 · \(formatSettingsCacheSize(managedBooksReport.totalBytes))")
                                    if managedBooksReport.orphanFiles > 0 {
                                        cacheStatRow("未关联的重复/冗余副本", "\(managedBooksReport.orphanFiles) 个 · \(formatSettingsCacheSize(managedBooksReport.orphanBytes))")
                                    }
                                }
                                .padding(12)
                                .background(palette.nestedTint.opacity(0.55))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                if let cacheFeedbackMsg {
                                    Text(cacheFeedbackMsg)
                                        .font(.caption)
                                        .foregroundStyle(palette.accent)
                                }

                                if managedBooksReport.orphanFiles > 0 {
                                    Button {
                                        cleanOrphanManagedBooks()
                                    } label: {
                                        Text("清理冗余原书副本（\(managedBooksReport.orphanFiles) 个 · \(formatSettingsCacheSize(managedBooksReport.orphanBytes))）")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isClearingCache)
                                }

                                HStack(spacing: 8) {
                                    Button {
                                        clearBookCachesOnly()
                                    } label: {
                                        Text("清理图书缓存")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isClearingCache)

                                    Button(role: .destructive) {
                                        clearAllCaches()
                                    } label: {
                                        Text("全部清理")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isClearingCache)
                                }

                                if isClearingCache {
                                    ProgressView()
                                        .progressViewStyle(.linear)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
#if canImport(Translation)
            .translationTask(appleBridge.configuration) { session in
                await appleBridge.handleSession(session)
            }
#endif
            .task {
                refreshCacheStats()
                await refreshAppleLanguagePackStatuses()
            }
            .onChange(of: cacheSectionExpanded) { _, expanded in
                if expanded { refreshCacheStats() }
            }
            .onChange(of: db.books.count) { _, _ in
                if cacheSectionExpanded { refreshCacheStats() }
            }
            .onChange(of: dictSectionExpanded) { _, expanded in
                if expanded {
                    Task { await refreshAppleLanguagePackStatuses() }
                }
            }
            .onChange(of: backupSectionExpanded) { _, expanded in
                if expanded, backupService.isAuthorized {
                    Task { await backupService.refreshAuthorizedFolderState() }
                }
            }
            .onAppear {
                if store.settings.webdavUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    webDavConfigExpanded = true
                }
                refreshCacheStats()
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: importerMode == .books ? settingsBookContentTypes : [.folder],
                allowsMultipleSelection: importerMode == .books
            ) { result in
                guard case .success(let urls) = result else { return }
                switch importerMode {
                case .books:
                    importLocalBooks(urls)
                case .backupFolder:
                    if let folderUrl = urls.first {
                        backupService.authorizeBackupFolder(folderUrl)
                    }
                }
            }
            .alert("从备份恢复数据", isPresented: $showRestoreConfirmAlert) {
                Button("立即恢复", role: .destructive) {
                    Task {
                        await backupService.restoreFromAuthorizedFolder(db: db, settingsStore: settingsStore)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将从已授权目录中的 MiaoyueBackup 合并恢复图书、文件夹、阅读进度、笔记、生词与阅读设置。")
            }
            .sheet(isPresented: $showOpdsEditSheet) {
                OpdsSourceEditSheet(
                    initial: editingOpdsSource,
                    onSave: { saved in
                        settingsStore.addOrUpdateOpdsSource(saved)
                        showOpdsEditSheet = false
                    },
                    onDelete: editingOpdsSource.map { toDelete in
                        {
                            settingsStore.deleteOpdsSource(toDelete.id)
                            showOpdsEditSheet = false
                        }
                    }
                )
            }
            .fullScreenCover(isPresented: $showWebDavBrowser) {
                WebDavBrowserSheet(
                    rootUrl: NetworkBookService.normalizeUrl(store.settings.webdavUrl),
                    username: store.settings.webdavUsername,
                    password: store.settings.webdavPassword,
                    onOpenBook: { book in
                        showWebDavBrowser = false
                        onOpenBook(book)
                    }
                )
            }
            .alert(item: $pendingDelete) { target in
                Alert(
                    title: Text(target.title),
                    message: Text(target.desc),
                    primaryButton: .destructive(Text("确认删除")) {
                        isDeletingDict = true
                        switch target {
                        case .english:
                            TranslationService.shared.deleteEnglishDict(db: db)
                        case .chinese:
                            TranslationService.shared.deleteChineseDict(db: db)
                        }
                        isDeletingDict = false
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
    }

    // MARK: - Section Builder & Helpers

    @ViewBuilder
    private func settingsGroupSection<Content: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        expanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(AppMotion.panelSpring) {
                    expanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    AppleIconBadge(
                        systemImage: systemImage,
                        size: 34,
                        cornerRadius: 10,
                        filled: expanded.wrappedValue
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded.wrappedValue ? 180 : 0))
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded.wrappedValue {
                Divider()
                    .padding(.horizontal, 16)
                VStack(alignment: .leading, spacing: 14) {
                    content()
                }
                .padding(16)
                .transition(AppMotion.panelTransition)
            }
        }
        .clipped()
    }

    private func cacheStatRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
        }
    }

    private func aiPresetButton(_ label: String, url: String, model: String, store: SettingsStore) -> some View {
        Button(label) {
            store.settings.aiBaseUrl = url
            store.settings.aiModel = model
            aiTestMsg = nil
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(palette.nestedTint.opacity(0.65))
        .clipShape(Capsule())
        .buttonStyle(GlassPressButtonStyle())
    }

    private func engineDescription(_ engine: String) -> String {
        switch engine {
        case "ai":
            return "优先调用下方 AI 接口结合上下文直译（效果最佳，未配置时回退在线）"
        case "online":
            return "免 Key 调用微软必应 / MyMemory 在线神经网络翻译"
        case "apple", "offline":
            return "仅使用 Apple 系统内置离线翻译引擎（断网可用，免流量）"
        default:
            return "智能模式：已配置 AI 接口时优先 AI 精译，否则自动使用在线高清翻译，断网自动回退 Apple 离线翻译"
        }
    }

    // MARK: - Actions

    private func selectAppIcon(_ option: AppIconOption) {
        iconSwitchError = nil
        guard UIApplication.shared.supportsAlternateIcons else {
            iconSwitchError = "当前系统不支持更换应用图标"
            return
        }
        guard currentAlternateIconName != option.iconName else { return }
        UIApplication.shared.setAlternateIconName(option.iconName) { error in
            DispatchQueue.main.async {
                if let error {
                    iconSwitchError = "切换图标失败：\(error.localizedDescription)"
                } else {
                    withAnimation(AppMotion.panelSpring) {
                        currentAlternateIconName = UIApplication.shared.alternateIconName ?? option.iconName
                    }
                }
            }
        }
    }

    private func importLocalBooks(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importFeedbackIsError = false
        importFeedbackMsg = "正在导入 \(urls.count) 本图书..."
        let scopedUrls = urls.map { (url: $0, accessed: $0.startAccessingSecurityScopedResource()) }
        Task.detached(priority: .userInitiated) {
            var prepared: [(title: String, bookmarkData: Data?, filePathHint: String, format: String, folderId: Int64?)] = []
            prepared.reserveCapacity(scopedUrls.count)

            for item in scopedUrls {
                if let imported = BookParser.importLocalFileToManagedBooks(
                    item.url,
                    alreadyAccessingSecurityScope: item.accessed
                ) {
                    prepared.append((
                        title: imported.title,
                        bookmarkData: imported.bookmarkData,
                        filePathHint: imported.filePathHint,
                        format: imported.format,
                        folderId: nil
                    ))
                }
            }

            let addedCount = await MainActor.run {
                db.addBooksBatch(prepared).count
            }

            await MainActor.run {
                if addedCount == 0 {
                    importFeedbackIsError = true
                    importFeedbackMsg = "未能导入所选文件"
                } else {
                    importFeedbackIsError = false
                    importFeedbackMsg = "已导入 \(addedCount) 本图书到书架"
                }
            }
        }
    }

    private func testWebDav(_ settings: ReaderSettings) {
        testingWebDav = true
        webDavTestIsError = false
        webDavTestMsg = "正在测试连接..."
        Task {
            let res = await NetworkBookService.testWebDavConnection(
                urlString: settings.webdavUrl,
                username: settings.webdavUsername,
                password: settings.webdavPassword
            )
            await MainActor.run {
                switch res {
                case .success(let msg):
                    webDavTestIsError = false
                    webDavTestMsg = msg
                case .failure(let err):
                    webDavTestIsError = true
                    webDavTestMsg = err.localizedDescription
                }
                testingWebDav = false
            }
        }
    }

    private func testAiSpeed(_ settings: ReaderSettings) {
        testingAiSpeed = true
        aiTestIsError = false
        aiTestMsg = "正在测试响应速度..."
        Task {
            let res = await TranslationService.testAiTranslationSpeed(settings: settings)
            await MainActor.run {
                switch res {
                case .success(let (ms, preview)):
                    aiTestIsError = false
                    aiTestMsg = "耗时 \(ms)ms · 示例：\(preview)"
                case .failure(let err):
                    aiTestIsError = true
                    aiTestMsg = err.localizedDescription
                }
                testingAiSpeed = false
            }
        }
    }

    private func refreshAppleLanguagePackStatuses() async {
        async let en2zh = AppleTranslationBridge.checkAvailability(toEnglish: false)
        async let zh2en = AppleTranslationBridge.checkAvailability(toEnglish: true)
        let (s1, s2) = await (en2zh, zh2en)
        await MainActor.run {
            en2zhStatus = s1
            zh2enStatus = s2
        }
    }

    private func prepareApplePack(toEnglish: Bool) {
        if toEnglish { preparingZh2En = true } else { preparingEn2Zh = true }
        appleStatusMsg = "正在触发系统下载离线翻译包..."
        appleStatusIsError = false
        Task {
            do {
                try await appleBridge.prepareLanguagePack(toEnglish: toEnglish)
                await refreshAppleLanguagePackStatuses()
                await MainActor.run {
                    appleStatusIsError = false
                    appleStatusMsg = toEnglish ? "中译英离线包已准备就绪" : "英译中离线包已准备就绪"
                }
            } catch {
                await MainActor.run {
                    appleStatusIsError = true
                    appleStatusMsg = "预下载失败：\(error.localizedDescription)"
                }
            }
            await MainActor.run {
                if toEnglish { preparingZh2En = false } else { preparingEn2Zh = false }
            }
        }
    }

    private func refreshCacheStats() {
        let activeBooks = db.books
        translationCacheCount = db.translationCacheCount()
        Task.detached(priority: .utility) {
            let stats = BookCache.getCacheStats()
            let report = BookCache.inspectManagedBooks(activeBooks: activeBooks)
            await MainActor.run {
                cacheStats = stats
                managedBooksReport = report
            }
        }
    }

    private func cleanOrphanManagedBooks() {
        isClearingCache = true
        cacheFeedbackMsg = nil
        let activeBooks = db.books
        Task.detached(priority: .userInitiated) {
            let result = BookCache.cleanOrphanedManagedBooks(activeBooks: activeBooks)
            await MainActor.run {
                refreshCacheStats()
                if result.removedFiles > 0 {
                    cacheFeedbackMsg = "已清理 \(result.removedFiles) 个冗余原书副本，释放 \(formatSettingsCacheSize(result.freedBytes))"
                } else {
                    cacheFeedbackMsg = "未发现未关联书架的冗余原书副本"
                }
                isClearingCache = false
            }
        }
    }

    private func clearBookCachesOnly() {
        isClearingCache = true
        cacheFeedbackMsg = nil
        Task {
            BookCache.clearAll()
            await MainActor.run {
                refreshCacheStats()
                cacheFeedbackMsg = "已清理图书解析与封面缓存"
                isClearingCache = false
            }
        }
    }

    private func clearAllCaches() {
        isClearingCache = true
        cacheFeedbackMsg = nil
        Task {
            BookCache.clearAll()
            TranslationService.clearMemoryCaches()
            db.clearTranslationCache()
            await MainActor.run {
                refreshCacheStats()
                cacheFeedbackMsg = "已释放全部缓存空间"
                isClearingCache = false
            }
        }
    }
}

// MARK: - WebDAV Browser Sheet

private struct WebDavBrowserSheet: View {
    @Environment(DatabaseManager.self) private var db
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.appPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    let rootUrl: String
    let username: String
    let password: String
    var onOpenBook: (BookItem) -> Void

    @State private var pathStack: [String] = []
    @State private var entries: [WebDavEntry] = []
    @State private var isLoading = true
    @State private var errorMsg: String?
    @State private var onlyBooks = true
    @State private var reloadNonce = 0

    @State private var downloadingUrl: String?
    @State private var downloadingName = ""
    @State private var downloadedBytes: Int64 = 0
    @State private var totalBytes: Int64 = -1
    @State private var statusBanner: String?
    @State private var statusIsError = false

    private var currentUrl: String {
        pathStack.last ?? rootUrl
    }

    private var currentFolderTitle: String {
        if pathStack.count <= 1 { return "WebDAV 网盘" }
        let trimmed = currentUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let last = trimmed.components(separatedBy: "/").last ?? "子目录"
        let decoded = last.removingPercentEncoding ?? last
        return decoded.isEmpty ? "子目录" : decoded
    }

    private var visibleEntries: [WebDavEntry] {
        if onlyBooks {
            return entries.filter { $0.isDirectory || $0.format != nil }
        }
        return entries
    }

    private var bookByUri: [String: BookItem] {
        var map: [String: BookItem] = [:]
        for book in db.books {
            map[book.filePathHint] = book
            if let fileName = URL(string: book.filePathHint)?.lastPathComponent,
               fileName.hasPrefix("webdav_") {
                map[fileName] = book
            }
        }
        return map
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientGlassBackdrop(themeMode: settingsStore.settings.themeMode)

                VStack(spacing: 0) {
                    // Path bar & filter
                    HStack {
                        if pathStack.count > 1 {
                            Button {
                                goUpOrClose()
                            } label: {
                                Text("← 返回上级目录")
                                    .font(.caption.weight(.medium))
                            }
                            .disabled(downloadingUrl != nil)
                        } else {
                            Text("根目录")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            onlyBooks.toggle()
                        } label: {
                            MinimalTagPill(
                                text: onlyBooks ? "仅看电子书 ✓" : "全部文件",
                                tintColor: onlyBooks ? palette.accent.opacity(0.18) : nil,
                                textColor: onlyBooks ? palette.accent : .secondary
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    // Download progress or banner
                    if downloadingUrl != nil {
                        VStack(alignment: .leading, spacing: 6) {
                            let progressText: String = {
                                if totalBytes > 0 {
                                    let pct = min(100, max(0, Int((downloadedBytes * 100) / totalBytes)))
                                    return "正在下载《\(downloadingName)》· \(pct)% (\(NetworkBookService.formatFileSize(downloadedBytes)) / \(NetworkBookService.formatFileSize(totalBytes)))"
                                } else {
                                    return "正在下载《\(downloadingName)》· \(NetworkBookService.formatFileSize(downloadedBytes))"
                                }
                            }()
                            Text(progressText)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(palette.accent)
                            if totalBytes > 0 {
                                SmoothLinearProgressBar(
                                    progress: Double(downloadedBytes) / Double(totalBytes),
                                    height: 5
                                )
                            } else {
                                ProgressView()
                                    .progressViewStyle(.linear)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                    } else if let statusBanner {
                        Text(statusBanner)
                            .font(.caption)
                            .foregroundStyle(statusIsError ? .red : palette.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                    }

                    Divider()

                    // Body
                    if isLoading {
                        Spacer()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("正在读取网盘目录...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    } else if let errorMsg {
                        Spacer()
                        VStack(spacing: 12) {
                            Text(errorMsg)
                                .font(.subheadline)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                            HStack(spacing: 10) {
                                if pathStack.count > 1 {
                                    Button("返回上级") { goUpOrClose() }
                                        .buttonStyle(.bordered)
                                }
                                Button("重试") { reloadNonce += 1 }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(24)
                        Spacer()
                    } else if visibleEntries.isEmpty {
                        Spacer()
                        VStack(spacing: 10) {
                            Text(
                                onlyBooks && !entries.isEmpty
                                    ? "当前目录暂无支持的电子书（共 \(entries.count) 个其他文件）"
                                    : "当前目录为空"
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            if onlyBooks && !entries.isEmpty {
                                Button("显示全部文件") { onlyBooks = false }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .padding(24)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(visibleEntries) { entry in
                                    if entry.isDirectory {
                                        Button {
                                            guard downloadingUrl == nil else { return }
                                            statusBanner = nil
                                            pathStack.append(entry.url)
                                        } label: {
                                            GlassCard(cornerRadius: 14) {
                                                HStack(spacing: 12) {
                                                    Image(systemName: "folder.fill")
                                                        .foregroundStyle(palette.accent)
                                                    Text(entry.name)
                                                        .font(.body.weight(.medium))
                                                        .foregroundStyle(.primary)
                                                        .lineLimit(2)
                                                    Spacer()
                                                    Image(systemName: "chevron.right")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 12)
                                            }
                                        }
                                        .buttonStyle(GlassPressButtonStyle())
                                        .disabled(downloadingUrl != nil)
                                    } else {
                                        let fmt = entry.format
                                        let localUri = fmt.map { NetworkBookService.localUriForWebDavUrl(entry.url, format: $0) }
                                        let localName = localUri.flatMap { URL(string: $0)?.lastPathComponent }
                                        let existingBook = localUri.flatMap { bookByUri[$0] }
                                            ?? localName.flatMap { bookByUri[$0] }
                                        let isThisDownloading = downloadingUrl == entry.url

                                        GlassCard(cornerRadius: 14) {
                                            HStack(spacing: 12) {
                                                Image(systemName: fmt != nil ? "book.closed.fill" : "doc")
                                                    .foregroundStyle(fmt != nil ? palette.accent : .secondary)

                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(entry.name)
                                                        .font(.subheadline.weight(.medium))
                                                        .foregroundStyle(fmt != nil ? .primary : .secondary)
                                                        .lineLimit(2)

                                                    HStack(spacing: 8) {
                                                        if let fmt {
                                                            MinimalTagPill(
                                                                text: fmt,
                                                                tintColor: palette.accent.opacity(0.16),
                                                                textColor: palette.accent
                                                            )
                                                        }
                                                        let sizeText = NetworkBookService.formatFileSize(entry.sizeBytes)
                                                        if !sizeText.isEmpty {
                                                            Text(sizeText)
                                                                .font(.caption2)
                                                                .foregroundStyle(.secondary)
                                                        }
                                                        if existingBook != nil {
                                                            Text("已在书架")
                                                                .font(.caption2.weight(.semibold))
                                                                .foregroundStyle(palette.accent)
                                                        }
                                                    }
                                                }

                                                Spacer(minLength: 4)

                                                if let existingBook {
                                                    Button("阅读") {
                                                        onOpenBook(existingBook)
                                                    }
                                                    .buttonStyle(.borderedProminent)
                                                    .tint(palette.accent.opacity(0.85))
                                                    .controlSize(.small)
                                                    .disabled(downloadingUrl != nil)
                                                } else if let fmt {
                                                    Button(isThisDownloading ? "下载中" : "导入") {
                                                        downloadEntry(entry, format: fmt)
                                                    }
                                                    .buttonStyle(.borderedProminent)
                                                    .tint(palette.accent)
                                                    .controlSize(.small)
                                                    .disabled(downloadingUrl != nil)
                                                } else {
                                                    Text("不支持")
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 12)
                                        }
                                    }
                                }
                            }
                            .padding(16)
                        }
                    }
                }
            }
            .navigationTitle(currentFolderTitle)
            .navigationBarTitleDisplayMode(.inline)
            .adaptiveGlassNavBar()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        goUpOrClose()
                    } label: {
                        Image(systemName: pathStack.count > 1 ? "chevron.left" : "xmark")
                    }
                    .disabled(downloadingUrl != nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        reloadNonce += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading || downloadingUrl != nil)
                }
            }
            .onAppear {
                if pathStack.isEmpty {
                    pathStack = [rootUrl]
                }
            }
            .task(id: "\(currentUrl)#\(reloadNonce)") {
                guard !currentUrl.isEmpty else { return }
                await loadCurrentDirectory()
            }
        }
    }

    private func goUpOrClose() {
        guard downloadingUrl == nil else { return }
        if pathStack.count > 1 {
            pathStack.removeLast()
        } else {
            dismiss()
        }
    }

    private func loadCurrentDirectory() async {
        isLoading = true
        errorMsg = nil
        let res = await NetworkBookService.listWebDav(
            urlString: currentUrl,
            username: username,
            password: password
        )
        await MainActor.run {
            switch res {
            case .success(let list):
                entries = list
            case .failure(let err):
                errorMsg = err.localizedDescription
            }
            isLoading = false
        }
    }

    private func downloadEntry(_ entry: WebDavEntry, format: String) {
        downloadingUrl = entry.url
        downloadingName = (entry.name as NSString).deletingPathExtension
        downloadedBytes = 0
        totalBytes = entry.sizeBytes
        statusBanner = nil

        Task {
            let res = await NetworkBookService.downloadWebDavBook(
                remoteUrl: entry.url,
                fileName: entry.name,
                format: format,
                username: username,
                password: password
            ) { dl, total in
                await MainActor.run {
                    downloadedBytes = dl
                    if total > 0 { totalBytes = total }
                }
            }
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
                    statusIsError = false
                    statusBanner = "已导入《\(dl.title)》到书架并开始后台缓存"
                case .failure(let err):
                    statusIsError = true
                    statusBanner = err.localizedDescription
                }
                downloadingUrl = nil
            }
        }
    }
}

private func formatSettingsCacheSize(_ bytes: Int64) -> String {
    if bytes <= 0 { return "0 KB" }
    let kb = Double(bytes) / 1024.0
    if kb < 1024.0 {
        return "\(Int(max(1.0, kb).rounded())) KB"
    }
    let mb = kb / 1024.0
    return String(format: "%.1f MB", mb)
}

private func formatSettingsBackupTime(_ ms: Int64) -> String {
    guard ms > 0 else { return "未知" }
    let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd HH:mm"
    return fmt.string(from: date)
}
