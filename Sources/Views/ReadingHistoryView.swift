import Charts
import SwiftUI

struct ReadingHistoryView: View {
    @Environment(DatabaseManager.self) private var db
    @State private var category = 0 // 0 = 书籍阅读, 1 = 词汇复习
    @State private var bookPeriod = 0 // 0 = 按月, 1 = 按年
    @State private var vocabPeriod = 0 // 0 = 按日, 1 = 按周, 2 = 按月, 3 = 按年

    private var totalSeconds: Int64 {
        db.books.reduce(0) { $0 + $1.readingSeconds }
    }

    private var bookChartData: [(label: String, minutes: Double)] {
        if bookPeriod == 0 {
            let grouped = Dictionary(grouping: db.readingLogs, by: { $0.dateKey })
            return grouped.keys.sorted().suffix(15).map { key in
                let secs = grouped[key]?.reduce(0) { $0 + $1.readingSeconds } ?? 0
                return (String(key.suffix(5)), Double(secs) / 60.0)
            }
        } else {
            let grouped = Dictionary(grouping: db.readingLogs, by: { $0.yearMonth })
            return grouped.keys.sorted().suffix(12).map { ym in
                let secs = grouped[ym]?.reduce(0) { $0 + $1.readingSeconds } ?? 0
                return (String(ym.suffix(2)) + "月", Double(secs) / 60.0)
            }
        }
    }

    private var vocabChartData: [(label: String, count: Int)] {
        let slice = db.vocabReviewLogs.sorted { $0.dateKey < $1.dateKey }
        switch vocabPeriod {
        case 0: // 按日
            return slice.suffix(10).map { (String($0.dateKey.suffix(5)), $0.total) }
        case 1: // 按周（最近7天聚合）
            return slice.suffix(7).map { (String($0.dateKey.suffix(5)), $0.total) }
        case 2: // 按月
            let grouped = Dictionary(grouping: slice, by: { $0.yearMonth })
            return grouped.keys.sorted().suffix(6).map { ym in
                (String(ym.suffix(5)), grouped[ym]?.reduce(0) { $0 + $1.total } ?? 0)
            }
        default: // 按年
            let grouped = Dictionary(grouping: slice, by: { String($0.year) })
            return grouped.keys.sorted().map { yr in
                (yr, grouped[yr]?.reduce(0) { $0 + $1.total } ?? 0)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientGlassBackdrop()

                ScrollView {
                    VStack(spacing: 14) {
                        Picker("维度", selection: $category) {
                            Text("书籍阅读").tag(0)
                            Text("词汇复习").tag(1)
                        }
                        .pickerStyle(.segmented)

                        if category == 0 {
                            GlassCard(cornerRadius: 20) {
                                VStack(spacing: 10) {
                                    LabeledContent("累计精读时长", value: formatDuration(totalSeconds))
                                    Divider()
                                    LabeledContent("书架藏书", value: "\(db.books.count) 本")
                                    Divider()
                                    LabeledContent("已收录生词", value: "\(db.vocabList.count) 词")
                                }
                                .padding(16)
                            }

                            GlassCard(cornerRadius: 20) {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Text("阅读时长趋势（分钟）")
                                            .font(.headline)
                                        Spacer()
                                        Picker("周期", selection: $bookPeriod) {
                                            Text("按月").tag(0)
                                            Text("按年").tag(1)
                                        }
                                        .pickerStyle(.segmented)
                                        .frame(width: 120)
                                    }

                                    if bookChartData.isEmpty {
                                        Text("暂无阅读数据").font(.footnote).foregroundStyle(.secondary)
                                    } else {
                                        Chart(bookChartData, id: \.label) { item in
                                            BarMark(
                                                x: .value("日期", item.label),
                                                y: .value("分钟", item.minutes)
                                            )
                                            .foregroundStyle(Color.accentColor.gradient)
                                            .cornerRadius(5)
                                        }
                                        .frame(height: 180)
                                    }
                                }
                                .padding(16)
                            }

                            GlassCard(cornerRadius: 20) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("每日阅读记录").font(.headline)
                                    if db.readingLogs.isEmpty {
                                        Text("开始阅读后会自动统计每日有效时长")
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
                                            if log.id != db.readingLogs.last?.id { Divider() }
                                        }
                                    }
                                }
                                .padding(16)
                            }
                        } else {
                            let knownTotal = db.vocabReviewLogs.reduce(0) { $0 + $1.knownCount }
                            let fuzzyTotal = db.vocabReviewLogs.reduce(0) { $0 + $1.fuzzyCount }
                            let unknownTotal = db.vocabReviewLogs.reduce(0) { $0 + $1.unknownCount }

                            GlassCard(cornerRadius: 20) {
                                VStack(spacing: 10) {
                                    LabeledContent("累计认识", value: "\(knownTotal) 次")
                                    Divider()
                                    LabeledContent("累计模糊", value: "\(fuzzyTotal) 次")
                                    Divider()
                                    LabeledContent("累计不认识", value: "\(unknownTotal) 次")
                                }
                                .padding(16)
                            }

                            GlassCard(cornerRadius: 20) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("词汇复习量").font(.headline)
                                    Picker("周期", selection: $vocabPeriod) {
                                        Text("按日").tag(0)
                                        Text("按周").tag(1)
                                        Text("按月").tag(2)
                                        Text("按年").tag(3)
                                    }
                                    .pickerStyle(.segmented)

                                    if vocabChartData.isEmpty {
                                        Text("暂无复习数据").font(.footnote).foregroundStyle(.secondary)
                                    } else {
                                        Chart(vocabChartData, id: \.label) { item in
                                            BarMark(
                                                x: .value("周期", item.label),
                                                y: .value("次数", item.count)
                                            )
                                            .foregroundStyle(Color.orange.gradient)
                                            .cornerRadius(5)
                                        }
                                        .frame(height: 170)
                                    }
                                }
                                .padding(16)
                            }

                            GlassCard(cornerRadius: 20) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("每日复习明细").font(.headline)
                                    if db.vocabReviewLogs.isEmpty {
                                        Text("在「笔记与词库 → 闪卡」复习后会记录每日复习成果")
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
                                            if log.dateKey != db.vocabReviewLogs.last?.dateKey { Divider() }
                                        }
                                    }
                                }
                                .padding(16)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("阅读统计")
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
    }
}
