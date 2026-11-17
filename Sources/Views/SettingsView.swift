import SwiftUI

struct SettingsView: View {
    @Environment(DatabaseManager.self) private var db
    @Environment(SettingsStore.self) private var settingsStore

    @State private var downloadingDict = false
    @State private var dictMessage = ""

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
                    Toggle("自动使用 Apple 原生离线翻译当前句", isOn: $store.settings.autoTranslateSentence)
                    Toggle("正文中对已查单词显示底部虚线", isOn: $store.settings.underlineLookedUpWords)
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

                Section("OPDS 在线书库配置") {
                    TextField("OPDS 地址", text: $store.settings.opdsUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("用户名（可选）", text: $store.settings.opdsUsername)
                        .textInputAutocapitalization(.never)
                    SecureField("密码（可选）", text: $store.settings.opdsPassword)
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
        }
    }
}
