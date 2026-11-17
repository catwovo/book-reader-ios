import Charts
import SwiftUI

struct ReadingHistoryView: View {
    @Environment(DatabaseManager.self) private var db
    @State private var category = 0 // 0 = 书籍阅读, 1 = 词汇复习

    private var totalSeconds: Int64 {
        db.books.reduce(0) { $0 + $1.readingSeconds }
    }

    private var recentDailySeconds: [(day: String, minutes: Double)] {
        let grouped = Dictionary(grouping: db.readingLogs, by: { $0.dateKey })
        return grouped.keys.sorted().suffix(14).map { key in
            let secs = grouped[key]?.reduce(0) { $0 + $1.readingSeconds } ?? 0
            let short = String(key.suffix(5))
            return (short, Double(secs) / 60.0)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("维度", selection: $category) {
                        Text("书籍阅读").tag(0)
                        Text("词汇复习").tag(1)
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

                if category == 0 {
                    Section("累计概览") {
                        LabeledContent("累计精读时长", value: formatDuration(totalSeconds))
                        LabeledContent("书架藏书", value: "\(db.books.count) 本")
                        LabeledContent("已收录生词", value: "\(db.vocabList.count) 词")
                    }

                    if !recentDailySeconds.isEmpty {
                        Section("近期每日阅读时长（分钟）") {
                            Chart(recentDailySeconds, id: \.day) { item in
                                BarMark(
                                    x: .value("日期", item.day),
                                    y: .value("分钟", item.minutes)
                                )
                                .foregroundStyle(Color.accentColor.gradient)
                                .cornerRadius(4)
                            }
                            .frame(height: 180)
                            .padding(.vertical, 8)
                        }
                    }

                    Section("每日阅读记录") {
                        if db.readingLogs.isEmpty {
                            Text("暂无阅读记录，开始阅读后会自动统计每日有效时长")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        } else {
                            ForEach(db.readingLogs) { log in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(log.bookTitle).font(.subheadline.weight(.medium))
                                        Text("\(log.dateKey) · 推进 \(log.unitsRead) 句 · 查词 \(log.lookupsCount) 次")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(formatDuration(log.readingSeconds))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                } else {
                    Section("词汇复习统计") {
                        let knownTotal = db.vocabReviewLogs.reduce(0) { $0 + $1.knownCount }
                        let fuzzyTotal = db.vocabReviewLogs.reduce(0) { $0 + $1.fuzzyCount }
                        let unknownTotal = db.vocabReviewLogs.reduce(0) { $0 + $1.unknownCount }
                        LabeledContent("累计认识", value: "\(knownTotal) 次")
                        LabeledContent("累计模糊", value: "\(fuzzyTotal) 次")
                        LabeledContent("累计不认识", value: "\(unknownTotal) 次")
                    }

                    Section("每日复习明细") {
                        if db.vocabReviewLogs.isEmpty {
                            Text("在「笔记与词库 → 闪卡」复习后，这里会记录每日复习成果")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        } else {
                            ForEach(db.vocabReviewLogs) { log in
                                HStack {
                                    Text(log.dateKey).font(.subheadline)
                                    Spacer()
                                    Text("认识 \(log.knownCount) · 模糊 \(log.fuzzyCount) · 忘 \(log.unknownCount)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("阅读统计")
        }
    }
}
