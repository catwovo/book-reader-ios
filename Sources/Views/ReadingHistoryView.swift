import SwiftUI

private let historyCategories = ["书籍", "词汇"]
private let bookPeriodOptions = ["按月", "按年"]
private let vocabPeriodOptions = ["按日", "按周", "按月", "按年"]
private let yearMonthsDesc = Array((1...12).reversed())

private struct VocabTotals {
    var unknown: Int = 0
    var fuzzy: Int = 0
    var known: Int = 0
    var activeDays: Int = 0

    var total: Int { unknown + fuzzy + known }
}

private struct BookMonthSummary: Identifiable {
    var id: Int { month }
    let month: Int
    let days: Int
    let seconds: Int64
    let bookCount: Int
}

private extension Array where Element == VocabReviewLog {
    func sumTotals() -> VocabTotals {
        var u = 0
        var f = 0
        var k = 0
        var days = 0
        for log in self {
            u += log.unknownCount
            f += log.fuzzyCount
            k += log.knownCount
            if log.total > 0 {
                days += 1
            }
        }
        return VocabTotals(unknown: u, fuzzy: f, known: k, activeDays: days)
    }
}

private enum HistoryDateHelper {
    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Monday
        return cal
    }()

    static func dateKey(for date: Date) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 2026, comps.month ?? 1, comps.day ?? 1)
    }

    static func yearMonthKey(year: Int, month: Int) -> String {
        String(format: "%04d-%02d", year, month)
    }

    static func parseDateKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]),
              let m = Int(parts[1]),
              let d = Int(parts[2]) else {
            return nil
        }
        return calendar.date(from: DateComponents(year: y, month: m, day: d))
    }

    static func weekdayShortName(for date: Date) -> String {
        switch calendar.component(.weekday, from: date) {
        case 1: return "周日"
        case 2: return "周一"
        case 3: return "周二"
        case 4: return "周三"
        case 5: return "周四"
        case 6: return "周五"
        case 7: return "周六"
        default: return ""
        }
    }

    static func formatDateHeader(_ key: String) -> String {
        guard let d = parseDateKey(key) else { return key }
        let m = calendar.component(.month, from: d)
        let day = calendar.component(.day, from: d)
        return "\(m)月\(day)日 · \(weekdayShortName(for: d))"
    }

    static func startOfWeek(for date: Date) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let daysFromMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysFromMonday, to: calendar.startOfDay(for: date)) ?? date
    }

    static func addDays(_ days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    static func shiftYearMonth(year: Int, month: Int, delta: Int) -> (Int, Int) {
        var totalMonths = year * 12 + (month - 1) + delta
        if totalMonths < 0 { totalMonths = 0 }
        return (totalMonths / 12, (totalMonths % 12) + 1)
    }
}

struct ReadingHistoryView: View {
    @Environment(DatabaseManager.self) private var db
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.appPalette) private var palette

    @State private var category = 0 // 0 = 书籍, 1 = 词汇

    // Book state
    @State private var bookPeriod = 0 // 0 = 按月, 1 = 按年
    @State private var bookYear: Int = HistoryDateHelper.calendar.component(.year, from: Date())
    @State private var bookMonth: Int = HistoryDateHelper.calendar.component(.month, from: Date())
    @State private var bookListYear: Int = HistoryDateHelper.calendar.component(.year, from: Date())
    @State private var expandedBookDates: Set<String> = []

    // Vocab state
    @State private var vocabPeriod = 0 // 0 = 按日, 1 = 按周, 2 = 按月, 3 = 按年
    @State private var selectedVocabDate: Date = HistoryDateHelper.calendar.startOfDay(for: Date())
    @State private var selectedVocabWeekStart: Date = HistoryDateHelper.startOfWeek(for: Date())
    @State private var vocabYear: Int = HistoryDateHelper.calendar.component(.year, from: Date())
    @State private var vocabMonth: Int = HistoryDateHelper.calendar.component(.month, from: Date())
    @State private var vocabListYear: Int = HistoryDateHelper.calendar.component(.year, from: Date())
    @State private var expandedVocabDates: Set<String> = []

    private var today: Date {
        HistoryDateHelper.calendar.startOfDay(for: Date())
    }

    private var booksById: [Int64: BookItem] {
        Dictionary(uniqueKeysWithValues: db.books.map { ($0.id, $0) })
    }

    // 书籍仅统计单条阅读时长满 1 分钟（>= 60 秒）的记录
    private var validBookLogs: [ReadingLog] {
        db.readingLogs.filter { $0.readingSeconds >= 60 }
    }

    private var logsByDate: [String: [ReadingLog]] {
        Dictionary(grouping: validBookLogs, by: \.dateKey)
    }

    private var totalDaysRead: Int {
        logsByDate.count
    }

    private var totalSecondsAll: Int64 {
        validBookLogs.reduce(0) { $0 + $1.readingSeconds }
    }

    private var streakDays: Int {
        let todayKey = HistoryDateHelper.dateKey(for: today)
        var cursor = logsByDate[todayKey] != nil ? today : HistoryDateHelper.addDays(-1, to: today)
        var streak = 0
        while logsByDate[HistoryDateHelper.dateKey(for: cursor)] != nil {
            streak += 1
            cursor = HistoryDateHelper.addDays(-1, to: cursor)
        }
        return streak
    }

    private var selectedBookYmKey: String {
        HistoryDateHelper.yearMonthKey(year: bookYear, month: bookMonth)
    }

    private var monthBookLogs: [ReadingLog] {
        validBookLogs.filter { $0.yearMonth == selectedBookYmKey }
    }

    private var monthByDate: [String: [ReadingLog]] {
        Dictionary(grouping: monthBookLogs, by: \.dateKey)
    }

    private var displayDays: [(String, [ReadingLog])] {
        monthByDate.keys.sorted(by: >).map { ($0, monthByDate[$0] ?? []) }
    }

    private var monthSeconds: Int64 { monthBookLogs.reduce(0) { $0 + $1.readingSeconds } }
    private var monthUnits: Int { monthBookLogs.reduce(0) { $0 + $1.unitsRead } }
    private var monthLookups: Int { monthBookLogs.reduce(0) { $0 + $1.lookupsCount } }

    private var yearBookLogs: [ReadingLog] {
        validBookLogs.filter { log in
            let ly = log.year > 0 ? log.year : (Int(log.dateKey.prefix(4)) ?? 0)
            return ly == bookListYear
        }
    }

    private var yearDaysCount: Int { Set(yearBookLogs.map(\.dateKey)).count }
    private var yearSeconds: Int64 { yearBookLogs.reduce(0) { $0 + $1.readingSeconds } }
    private var yearUnits: Int { yearBookLogs.reduce(0) { $0 + $1.unitsRead } }
    private var yearLookups: Int { yearBookLogs.reduce(0) { $0 + $1.lookupsCount } }

    private var activeBookMonths: [BookMonthSummary] {
        var daysByMonth: [Int: Set<String>] = [:]
        var booksByMonth: [Int: Set<Int64>] = [:]
        var secByMonth: [Int: Int64] = [:]
        for log in yearBookLogs {
            let parts = log.yearMonth.split(separator: "-")
            guard parts.count == 2, let m = Int(parts[1]) else { continue }
            daysByMonth[m, default: []].insert(log.dateKey)
            booksByMonth[m, default: []].insert(log.bookId)
            secByMonth[m, default: 0] += log.readingSeconds
        }
        return yearMonthsDesc.compactMap { m in
            let days = daysByMonth[m]?.count ?? 0
            let sec = secByMonth[m] ?? 0
            let bCount = booksByMonth[m]?.count ?? 0
            if days > 0 || sec > 0 {
                return BookMonthSummary(month: m, days: days, seconds: sec, bookCount: bCount)
            }
            return nil
        }
    }

    private var maxMonthSeconds: Int64 {
        max(1, activeBookMonths.map(\.seconds).max() ?? 1)
    }

    // Vocab aggregations
    private var vocabCollectedByDate: [String: [VocabItem]] {
        var map: [String: [VocabItem]] = [:]
        for item in db.vocabList {
            let ts = item.createdAt > 0 ? item.createdAt : item.updatedAt
            let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000.0)
            let key = HistoryDateHelper.dateKey(for: date)
            map[key, default: []].append(item)
        }
        for (k, list) in map {
            map[k] = list.sorted {
                let t1 = $0.createdAt > 0 ? $0.createdAt : $0.updatedAt
                let t2 = $1.createdAt > 0 ? $1.createdAt : $1.updatedAt
                return t1 > t2
            }
        }
        return map
    }

    private var vocabPoolCounts: VocabTotals {
        var u = 0, f = 0, k = 0
        for item in db.vocabList {
            switch item.familiarity {
            case 2: k += 1
            case 1: f += 1
            default: u += 1
            }
        }
        return VocabTotals(unknown: u, fuzzy: f, known: k)
    }

    private var allVocabReviewTotals: VocabTotals {
        db.vocabReviewLogs.sumTotals()
    }

    private var vocabLogsByDate: [String: VocabReviewLog] {
        Dictionary(uniqueKeysWithValues: db.vocabReviewLogs.map { ($0.dateKey, $0) })
    }

    private var allVocabDatesDesc: [String] {
        Set(vocabLogsByDate.keys).union(vocabCollectedByDate.keys).sorted(by: >)
    }

    private var maxVocabDayTotal: Int {
        max(1, db.vocabReviewLogs.map(\.total).max() ?? 1)
    }

    private var selectedDayKey: String {
        HistoryDateHelper.dateKey(for: selectedVocabDate)
    }

    private var selectedDayTotals: VocabTotals {
        if let log = vocabLogsByDate[selectedDayKey] {
            return VocabTotals(
                unknown: log.unknownCount,
                fuzzy: log.fuzzyCount,
                known: log.knownCount,
                activeDays: log.total > 0 ? 1 : 0
            )
        }
        return VocabTotals()
    }

    private var selectedDayCollectedCount: Int {
        vocabCollectedByDate[selectedDayKey]?.count ?? 0
    }

    private var weekDayTriples: [(Date, VocabReviewLog?, Int)] {
        (0..<7).map { offset in
            let d = HistoryDateHelper.addDays(offset, to: selectedVocabWeekStart)
            let key = HistoryDateHelper.dateKey(for: d)
            return (d, vocabLogsByDate[key], vocabCollectedByDate[key]?.count ?? 0)
        }
    }

    private var weekTotals: VocabTotals {
        weekDayTriples.compactMap { $0.1 }.sumTotals()
    }

    private var weekCollectedCount: Int {
        weekDayTriples.reduce(0) { $0 + $1.2 }
    }

    private var maxWeekDayTotal: Int {
        max(1, weekDayTriples.map { $0.1?.total ?? 0 }.max() ?? 1)
    }

    private var vocabYmKey: String {
        HistoryDateHelper.yearMonthKey(year: vocabYear, month: vocabMonth)
    }

    private var vocabMonthLogs: [VocabReviewLog] {
        db.vocabReviewLogs.filter { $0.yearMonth == vocabYmKey }.sorted { $0.dateKey > $1.dateKey }
    }

    private var vocabMonthDatesDesc: [String] {
        allVocabDatesDesc.filter { $0.hasPrefix(vocabYmKey) }
    }

    private var vocabMonthTotals: VocabTotals {
        vocabMonthLogs.sumTotals()
    }

    private var vocabMonthCollectedCount: Int {
        vocabMonthDatesDesc.reduce(0) { $0 + (vocabCollectedByDate[$1]?.count ?? 0) }
    }

    private var maxMonthDayTotal: Int {
        max(1, vocabMonthLogs.map(\.total).max() ?? 1)
    }

    private var vocabYearLogs: [VocabReviewLog] {
        db.vocabReviewLogs.filter { log in
            let ly = log.year > 0 ? log.year : (Int(log.dateKey.prefix(4)) ?? 0)
            return ly == vocabListYear
        }
    }

    private var vocabYearPrefix: String {
        String(format: "%04d-", vocabListYear)
    }

    private var vocabYearCollectedCount: Int {
        vocabCollectedByDate.filter { $0.key.hasPrefix(vocabYearPrefix) }.values.reduce(0) { $0 + $1.count }
    }

    private var vocabYearTotals: VocabTotals {
        vocabYearLogs.sumTotals()
    }

    private var activeVocabMonths: [(Int, VocabTotals)] {
        var grouped: [Int: [VocabReviewLog]] = [:]
        for log in vocabYearLogs {
            let parts = log.yearMonth.split(separator: "-")
            guard parts.count == 2, let m = Int(parts[1]) else { continue }
            grouped[m, default: []].append(log)
        }
        return yearMonthsDesc.compactMap { m in
            guard let totals = grouped[m]?.sumTotals(), totals.total > 0 else { return nil }
            return (m, totals)
        }
    }

    private var maxVocabMonthTotal: Int {
        max(1, activeVocabMonths.map { $0.1.total }.max() ?? 1)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientGlassBackdrop(themeMode: settingsStore.settings.themeMode)

                VStack(spacing: 0) {
                    // Top bar
                    HStack {
                        Text("阅读记录")
                            .font(.title2.bold())
                        Spacer()
                        Picker("维度", selection: $category) {
                            ForEach(0..<historyCategories.count, id: \.self) { idx in
                                Text(historyCategories[idx]).tag(idx)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 144)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    TabView(selection: $category) {
                        bookHistoryPage
                            .tag(0)
                        vocabHistoryPage
                            .tag(1)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Book History Page

    private var bookHistoryPage: some View {
        VStack(spacing: 10) {
            // Card 1: Overall Book Summary
            GlassCard(cornerRadius: 20) {
                HStack(spacing: 0) {
                    HistorySummaryStatItem(label: "累计阅读", value: "\(totalDaysRead) 天")
                    HistoryStatDivider()
                    HistorySummaryStatItem(label: "连续打卡", value: "\(streakDays) 天")
                    HistoryStatDivider()
                    HistorySummaryStatItem(label: "累计时长", value: formatDuration(totalSecondsAll))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
            }
            .padding(.horizontal, 16)

            // Card 2: Swipeable Book Period Card (按月 <-> 按年)
            GlassCard(cornerRadius: 20) {
                VStack(spacing: 10) {
                    PeriodPillRow(
                        options: bookPeriodOptions,
                        selectedIndex: bookPeriod,
                        onSelect: { target in
                            withAnimation(AppMotion.tabSpring) {
                                bookPeriod = target
                            }
                        }
                    )

                    TabView(selection: $bookPeriod) {
                        VStack(spacing: 12) {
                            PeriodNavigatorRow(
                                title: "\(bookYear) 年 \(bookMonth) 月",
                                onPrev: {
                                    let shifted = HistoryDateHelper.shiftYearMonth(year: bookYear, month: bookMonth, delta: -1)
                                    bookYear = shifted.0
                                    bookMonth = shifted.1
                                },
                                onNext: {
                                    let shifted = HistoryDateHelper.shiftYearMonth(year: bookYear, month: bookMonth, delta: 1)
                                    bookYear = shifted.0
                                    bookMonth = shifted.1
                                }
                            )
                            HStack(spacing: 0) {
                                HistorySummaryStatItem(label: "本月天数", value: "\(monthByDate.count) 天")
                                HistorySummaryStatItem(label: "本月时长", value: formatDuration(monthSeconds))
                                HistorySummaryStatItem(label: "读句 / 查词", value: "\(monthUnits) / \(monthLookups)")
                            }
                        }
                        .padding(.horizontal, 16)
                        .tag(0)

                        VStack(spacing: 12) {
                            PeriodNavigatorRow(
                                title: "\(bookListYear) 年",
                                onPrev: { bookListYear -= 1 },
                                onNext: { bookListYear += 1 }
                            )
                            HStack(spacing: 0) {
                                HistorySummaryStatItem(label: "阅读天数", value: "\(yearDaysCount) 天")
                                HistorySummaryStatItem(label: "总时长", value: formatDuration(yearSeconds))
                                HistorySummaryStatItem(label: "读句 / 查词", value: "\(yearUnits) / \(yearLookups)")
                            }
                        }
                        .padding(.horizontal, 16)
                        .tag(1)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: 98)
                }
                .padding(.vertical, 14)
            }
            .padding(.horizontal, 16)

            // Card 3+: Scrollable records
            ScrollView {
                LazyVStack(spacing: 4) {
                    if bookPeriod == 0 {
                        if displayDays.isEmpty {
                            EmptyHistoryCard(
                                systemImage: "calendar",
                                message: "本月暂无满 1 分钟的阅读记录"
                            )
                        } else {
                            ForEach(Array(displayDays.enumerated()), id: \.element.0) { idx, pair in
                                let dateKey = pair.0
                                let dayLogs = pair.1
                                DailyBookRecordCard(
                                    index: idx,
                                    count: displayDays.count,
                                    dateKey: dateKey,
                                    dayLogs: dayLogs,
                                    booksById: booksById,
                                    expanded: expandedBookDates.contains(dateKey),
                                    onToggle: {
                                        withAnimation(AppMotion.panelSpring) {
                                            if expandedBookDates.contains(dateKey) {
                                                expandedBookDates.remove(dateKey)
                                            } else {
                                                expandedBookDates.insert(dateKey)
                                            }
                                        }
                                    }
                                )
                            }
                        }
                    } else {
                        if activeBookMonths.isEmpty {
                            EmptyHistoryCard(
                                systemImage: "calendar",
                                message: "\(bookListYear) 年暂无满 1 分钟的阅读记录"
                            )
                        } else {
                            ForEach(Array(activeBookMonths.enumerated()), id: \.element.id) { idx, item in
                                Button {
                                    bookYear = bookListYear
                                    bookMonth = item.month
                                    withAnimation(AppMotion.tabSpring) {
                                        bookPeriod = 0
                                    }
                                } label: {
                                    GlassGroupedCard(index: idx, count: activeBookMonths.count, outerRadius: 18, innerRadius: 6) {
                                        VStack(spacing: 8) {
                                            HStack {
                                                Text("\(item.month) 月")
                                                    .font(.subheadline.bold())
                                                    .foregroundStyle(.primary)
                                                Spacer()
                                                Text("\(item.days) 天 · \(formatDuration(item.seconds)) · \(item.bookCount) 本")
                                                    .font(.caption.weight(.medium))
                                                    .foregroundStyle(palette.accent)
                                            }
                                            SmoothLinearProgressBar(
                                                progress: max(0.05, Double(item.seconds) / Double(maxMonthSeconds)),
                                                height: 5
                                            )
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 14)
                                    }
                                }
                                .buttonStyle(GlassPressButtonStyle())
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 24)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Vocab History Page

    private var vocabHistoryPage: some View {
        VStack(spacing: 10) {
            // Card 1: Overall Vocab Summary + Tri-color mastery bar
            GlassCard(cornerRadius: 20) {
                VStack(spacing: 10) {
                    HStack(spacing: 0) {
                        HistorySummaryStatItem(label: "生词总量", value: "\(db.vocabList.count) 词")
                        HistoryStatDivider()
                        HistorySummaryStatItem(label: "累计复习", value: "\(allVocabReviewTotals.total) 次")
                        HistoryStatDivider()
                        HistorySummaryStatItem(label: "已认识", value: "\(vocabPoolCounts.known) 词")
                    }

                    if !db.vocabList.isEmpty {
                        TriColorVocabBar(
                            unknown: vocabPoolCounts.unknown,
                            fuzzy: vocabPoolCounts.fuzzy,
                            known: vocabPoolCounts.known,
                            height: 5
                        )
                        HStack(spacing: 16) {
                            MiniOptionBadge(text: "不认识 \(vocabPoolCounts.unknown)", dotColor: .red)
                            MiniOptionBadge(text: "模糊 \(vocabPoolCounts.fuzzy)", dotColor: .orange)
                            MiniOptionBadge(text: "已认识 \(vocabPoolCounts.known)", dotColor: palette.accent)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .padding(.horizontal, 16)

            // Card 2: Swipeable Vocab Period Card (按日 / 按周 / 按月 / 按年)
            GlassCard(cornerRadius: 20) {
                VStack(spacing: 10) {
                    PeriodPillRow(
                        options: vocabPeriodOptions,
                        selectedIndex: vocabPeriod,
                        onSelect: { target in
                            withAnimation(AppMotion.tabSpring) {
                                vocabPeriod = target
                            }
                        }
                    )

                    TabView(selection: $vocabPeriod) {
                        // Day
                        VStack(spacing: 10) {
                            let isToday = HistoryDateHelper.dateKey(for: selectedVocabDate) == HistoryDateHelper.dateKey(for: today)
                            let m = HistoryDateHelper.calendar.component(.month, from: selectedVocabDate)
                            let d = HistoryDateHelper.calendar.component(.day, from: selectedVocabDate)
                            let y = HistoryDateHelper.calendar.component(.year, from: selectedVocabDate)
                            let dayTitle = isToday
                                ? "今天 · \(m)月\(d)日"
                                : "\(y)年\(m)月\(d)日 · \(HistoryDateHelper.weekdayShortName(for: selectedVocabDate))"

                            PeriodNavigatorRow(
                                title: dayTitle,
                                onPrev: { selectedVocabDate = HistoryDateHelper.addDays(-1, to: selectedVocabDate) },
                                onNext: { selectedVocabDate = HistoryDateHelper.addDays(1, to: selectedVocabDate) }
                            )
                            VocabPeriodBreakdownContent(
                                totals: selectedDayTotals,
                                subtitle: "当日 \(selectedDayTotals.total) 次闪卡 · 新增收藏 \(selectedDayCollectedCount) 词"
                            )
                        }
                        .padding(.horizontal, 16)
                        .tag(0)

                        // Week
                        VStack(spacing: 10) {
                            let weekEnd = HistoryDateHelper.addDays(6, to: selectedVocabWeekStart)
                            let currentY = HistoryDateHelper.calendar.component(.year, from: today)
                            let startY = HistoryDateHelper.calendar.component(.year, from: selectedVocabWeekStart)
                            let startM = HistoryDateHelper.calendar.component(.month, from: selectedVocabWeekStart)
                            let startD = HistoryDateHelper.calendar.component(.day, from: selectedVocabWeekStart)
                            let endM = HistoryDateHelper.calendar.component(.month, from: weekEnd)
                            let endD = HistoryDateHelper.calendar.component(.day, from: weekEnd)
                            let prefix = startY != currentY ? "\(startY)年 " : ""

                            PeriodNavigatorRow(
                                title: "\(prefix)\(startM)月\(startD)日 - \(endM)月\(endD)日",
                                onPrev: { selectedVocabWeekStart = HistoryDateHelper.addDays(-7, to: selectedVocabWeekStart) },
                                onNext: { selectedVocabWeekStart = HistoryDateHelper.addDays(7, to: selectedVocabWeekStart) }
                            )
                            VocabPeriodBreakdownContent(
                                totals: weekTotals,
                                subtitle: "本周 \(weekTotals.activeDays) 天 · \(weekTotals.total) 次复习 · 收藏 \(weekCollectedCount) 词"
                            )
                        }
                        .padding(.horizontal, 16)
                        .tag(1)

                        // Month
                        VStack(spacing: 10) {
                            PeriodNavigatorRow(
                                title: "\(vocabYear) 年 \(vocabMonth) 月",
                                onPrev: {
                                    let shifted = HistoryDateHelper.shiftYearMonth(year: vocabYear, month: vocabMonth, delta: -1)
                                    vocabYear = shifted.0
                                    vocabMonth = shifted.1
                                },
                                onNext: {
                                    let shifted = HistoryDateHelper.shiftYearMonth(year: vocabYear, month: vocabMonth, delta: 1)
                                    vocabYear = shifted.0
                                    vocabMonth = shifted.1
                                }
                            )
                            VocabPeriodBreakdownContent(
                                totals: vocabMonthTotals,
                                subtitle: "本月 \(vocabMonthTotals.activeDays) 天 · \(vocabMonthTotals.total) 次复习 · 收藏 \(vocabMonthCollectedCount) 词"
                            )
                        }
                        .padding(.horizontal, 16)
                        .tag(2)

                        // Year
                        VStack(spacing: 10) {
                            PeriodNavigatorRow(
                                title: "\(vocabListYear) 年",
                                onPrev: { vocabListYear -= 1 },
                                onNext: { vocabListYear += 1 }
                            )
                            VocabPeriodBreakdownContent(
                                totals: vocabYearTotals,
                                subtitle: "全年 \(vocabYearTotals.activeDays) 天 · \(vocabYearTotals.total) 次复习 · 收藏 \(vocabYearCollectedCount) 词"
                            )
                        }
                        .padding(.horizontal, 16)
                        .tag(3)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: 132)
                }
                .padding(.vertical, 14)
            }
            .padding(.horizontal, 16)

            // Card 3+: Scrollable Vocab records
            ScrollView {
                LazyVStack(spacing: 4) {
                    switch vocabPeriod {
                    case 0:
                        if allVocabDatesDesc.isEmpty {
                            EmptyHistoryCard(systemImage: "rectangle.stack", message: "暂无单词收藏与复习记录")
                        } else {
                            ForEach(Array(allVocabDatesDesc.enumerated()), id: \.element) { idx, dateKey in
                                let log = vocabLogsByDate[dateKey]
                                let collectedWords = vocabCollectedByDate[dateKey] ?? []
                                DailyVocabRecordCard(
                                    index: idx,
                                    count: allVocabDatesDesc.count,
                                    dateKey: dateKey,
                                    reviewLog: log,
                                    collectedWords: collectedWords,
                                    maxTotal: maxVocabDayTotal,
                                    expanded: expandedVocabDates.contains(dateKey),
                                    isHighlighted: dateKey == selectedDayKey,
                                    onToggle: {
                                        if let parsed = HistoryDateHelper.parseDateKey(dateKey) {
                                            selectedVocabDate = parsed
                                        }
                                        if !collectedWords.isEmpty {
                                            withAnimation(AppMotion.panelSpring) {
                                                if expandedVocabDates.contains(dateKey) {
                                                    expandedVocabDates.remove(dateKey)
                                                } else {
                                                    expandedVocabDates.insert(dateKey)
                                                }
                                            }
                                        }
                                    }
                                )
                            }
                        }

                    case 1:
                        ForEach(Array(weekDayTriples.enumerated()), id: \.offset) { idx, triple in
                            let date = triple.0
                            let log = triple.1
                            let collectedCount = triple.2
                            let m = HistoryDateHelper.calendar.component(.month, from: date)
                            let d = HistoryDateHelper.calendar.component(.day, from: date)
                            let label = "\(HistoryDateHelper.weekdayShortName(for: date)) · \(m)月\(d)日"
                            let u = log?.unknownCount ?? 0
                            let f = log?.fuzzyCount ?? 0
                            let k = log?.knownCount ?? 0
                            let reviewTotal = u + f + k
                            let sub: String? = (reviewTotal > 0 && collectedCount > 0)
                                ? "\(reviewTotal)次 · 藏\(collectedCount)词"
                                : (collectedCount > 0 ? "藏 \(collectedCount) 词" : nil)

                            VocabPeriodRowCard(
                                index: idx,
                                count: weekDayTriples.count,
                                title: label,
                                subtitle: sub,
                                unknown: u,
                                fuzzy: f,
                                known: k,
                                maxReference: maxWeekDayTotal,
                                emptyText: collectedCount > 0 ? "收藏 \(collectedCount) 词" : "无记录",
                                onClick: {
                                    selectedVocabDate = date
                                    withAnimation(AppMotion.tabSpring) {
                                        vocabPeriod = 0
                                    }
                                }
                            )
                        }

                    case 2:
                        if vocabMonthDatesDesc.isEmpty {
                            EmptyHistoryCard(systemImage: "rectangle.stack", message: "本月暂无单词收藏与复习记录")
                        } else {
                            ForEach(Array(vocabMonthDatesDesc.enumerated()), id: \.element) { idx, dateKey in
                                let log = vocabLogsByDate[dateKey]
                                let collectedWords = vocabCollectedByDate[dateKey] ?? []
                                DailyVocabRecordCard(
                                    index: idx,
                                    count: vocabMonthDatesDesc.count,
                                    dateKey: dateKey,
                                    reviewLog: log,
                                    collectedWords: collectedWords,
                                    maxTotal: maxMonthDayTotal,
                                    expanded: expandedVocabDates.contains(dateKey),
                                    isHighlighted: false,
                                    onToggle: {
                                        if let parsed = HistoryDateHelper.parseDateKey(dateKey) {
                                            selectedVocabDate = parsed
                                        }
                                        if !collectedWords.isEmpty {
                                            withAnimation(AppMotion.panelSpring) {
                                                if expandedVocabDates.contains(dateKey) {
                                                    expandedVocabDates.remove(dateKey)
                                                } else {
                                                    expandedVocabDates.insert(dateKey)
                                                }
                                            }
                                        }
                                    }
                                )
                            }
                        }

                    default:
                        if activeVocabMonths.isEmpty {
                            EmptyHistoryCard(systemImage: "rectangle.stack", message: "\(vocabListYear) 年暂无闪卡复习记录")
                        } else {
                            ForEach(Array(activeVocabMonths.enumerated()), id: \.element.0) { idx, pair in
                                let month = pair.0
                                let mTotals = pair.1
                                VocabPeriodRowCard(
                                    index: idx,
                                    count: activeVocabMonths.count,
                                    title: "\(month) 月",
                                    subtitle: "\(mTotals.activeDays) 天 · \(mTotals.total) 次",
                                    unknown: mTotals.unknown,
                                    fuzzy: mTotals.fuzzy,
                                    known: mTotals.known,
                                    maxReference: maxVocabMonthTotal,
                                    emptyText: "无复习",
                                    onClick: {
                                        vocabYear = vocabListYear
                                        vocabMonth = month
                                        withAnimation(AppMotion.tabSpring) {
                                            vocabPeriod = 2
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 24)
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - History Subcomponents

private struct HistoryStatDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 0.75, height: 28)
    }
}

private struct HistorySummaryStatItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.headline.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PeriodPillRow: View {
    let options: [String]
    let selectedIndex: Int
    var onSelect: (Int) -> Void

    @Environment(\.appPalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<options.count, id: \.self) { idx in
                let selected = idx == selectedIndex
                Button {
                    onSelect(idx)
                } label: {
                    Text(options[idx])
                        .font(.caption.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? palette.accent : .secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(selected ? palette.accent.opacity(0.16) : Color.secondary.opacity(0.10))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PeriodNavigatorRow: View {
    let title: String
    var onPrev: () -> Void
    var onNext: () -> Void

    var body: some View {
        HStack {
            Button(action: onPrev) {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text(title)
                .font(.headline.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer()

            Button(action: onNext) {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct MiniOptionBadge: View {
    let text: String
    let dotColor: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TriColorVocabBar: View {
    let unknown: Int
    let fuzzy: Int
    let known: Int
    var height: CGFloat = 5
    var fillFraction: Double = 1.0

    @Environment(\.appPalette) private var palette

    var body: some View {
        let total = unknown + fuzzy + known
        let clampedFill = total > 0 ? min(1.0, max(0.05, fillFraction)) : 0
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.16))
                if total > 0 && clampedFill > 0 {
                    let targetW = geo.size.width * clampedFill
                    HStack(spacing: 0) {
                        if unknown > 0 {
                            Rectangle()
                                .fill(Color.red)
                                .frame(width: targetW * (Double(unknown) / Double(total)))
                        }
                        if fuzzy > 0 {
                            Rectangle()
                                .fill(Color.orange)
                                .frame(width: targetW * (Double(fuzzy) / Double(total)))
                        }
                        if known > 0 {
                            Rectangle()
                                .fill(palette.accent)
                                .frame(width: targetW * (Double(known) / Double(total)))
                        }
                    }
                    .frame(width: targetW, height: height)
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: height)
    }
}

private struct VocabPeriodBreakdownContent: View {
    let totals: VocabTotals
    let subtitle: String
    @Environment(\.appPalette) private var palette

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ColoredStatItem(label: "不认识", value: "\(totals.unknown) 次", dotColor: .red)
                ColoredStatItem(label: "模糊", value: "\(totals.fuzzy) 次", dotColor: .orange)
                ColoredStatItem(label: "认识", value: "\(totals.known) 次", dotColor: palette.accent)
            }
            TriColorVocabBar(
                unknown: totals.unknown,
                fuzzy: totals.fuzzy,
                known: totals.known,
                height: 6
            )
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct ColoredStatItem: View {
    let label: String
    let value: String
    let dotColor: Color

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.headline.bold())
                .lineLimit(1)
            HStack(spacing: 4) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DailyBookRecordCard: View {
    let index: Int
    let count: Int
    let dateKey: String
    let dayLogs: [ReadingLog]
    let booksById: [Int64: BookItem]
    let expanded: Bool
    var onToggle: () -> Void

    @Environment(\.appPalette) private var palette

    var body: some View {
        let totalSec = dayLogs.reduce(0) { $0 + $1.readingSeconds }
        let totalUnits = dayLogs.reduce(0) { $0 + $1.unitsRead }
        let totalLookups = dayLogs.reduce(0) { $0 + $1.lookupsCount }

        GlassGroupedCard(
            index: index,
            count: count,
            outerRadius: 18,
            innerRadius: 6,
            tintColor: expanded ? palette.accent.opacity(0.06) : nil
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: onToggle) {
                    HStack {
                        Text(HistoryDateHelper.formatDateHeader(dateKey))
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Spacer()
                        HStack(spacing: 8) {
                            MinimalTagPill(
                                text: "\(formatDuration(totalSec)) · \(dayLogs.count)本",
                                tintColor: palette.accent.opacity(0.12),
                                textColor: palette.accent
                            )
                            Image(systemName: "chevron.down")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                        Text("共读 \(totalUnits) 句 · 查词 \(totalLookups) 次")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        ForEach(dayLogs) { log in
                            let book = booksById[log.bookId]
                            let pct = book.map { min(100, max(0, Int(computeBookProgress($0) * 100.0))) }
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    HStack(spacing: 6) {
                                        Image(systemName: "book")
                                            .font(.caption)
                                            .foregroundStyle(palette.accent)
                                        Text(log.bookTitle)
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if let pct {
                                        Text("总进度 \(pct)%")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(palette.accent)
                                    }
                                }
                                HStack {
                                    Spacer()
                                    Text("\(log.unitsRead) 句 · \(log.lookupsCount) 词 · ")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(formatDuration(log.readingSeconds))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(palette.accent)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .transition(AppMotion.panelTransition)
                }
            }
            .clipped()
        }
    }
}

private struct DailyVocabRecordCard: View {
    let index: Int
    let count: Int
    let dateKey: String
    let reviewLog: VocabReviewLog?
    let collectedWords: [VocabItem]
    let maxTotal: Int
    let expanded: Bool
    let isHighlighted: Bool
    var onToggle: () -> Void

    @Environment(\.appPalette) private var palette

    var body: some View {
        let u = reviewLog?.unknownCount ?? 0
        let f = reviewLog?.fuzzyCount ?? 0
        let k = reviewLog?.knownCount ?? 0
        let total = u + f + k
        let fillFraction = total > 0 ? Double(total) / Double(max(1, maxTotal)) : 0

        GlassGroupedCard(
            index: index,
            count: count,
            outerRadius: 18,
            innerRadius: 6,
            tintColor: isHighlighted ? palette.accent.opacity(0.12) : (expanded ? palette.accent.opacity(0.06) : nil)
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: onToggle) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(HistoryDateHelper.formatDateHeader(dateKey))
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            Spacer()
                            HStack(spacing: 8) {
                                if total > 0 {
                                    MiniOptionBadge(text: "\(u)", dotColor: .red)
                                    MiniOptionBadge(text: "\(f)", dotColor: .orange)
                                    MiniOptionBadge(text: "\(k)", dotColor: palette.accent)
                                    Text("\(total)次")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(palette.accent)
                                }
                                if !collectedWords.isEmpty {
                                    MinimalTagPill(
                                        text: "藏 \(collectedWords.count)词",
                                        tintColor: palette.accent.opacity(0.12),
                                        textColor: palette.accent
                                    )
                                    Image(systemName: "chevron.down")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                        .rotationEffect(.degrees(expanded ? 180 : 0))
                                }
                            }
                        }

                        if total > 0 {
                            TriColorVocabBar(
                                unknown: u,
                                fuzzy: f,
                                known: k,
                                height: 5,
                                fillFraction: fillFraction
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded && !collectedWords.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                        Text("当日收藏单词 (\(collectedWords.count))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HistoryFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                            ForEach(collectedWords) { item in
                                Text(item.word)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .transition(AppMotion.panelTransition)
                }
            }
            .clipped()
        }
    }
}

private struct VocabPeriodRowCard: View {
    let index: Int
    let count: Int
    let title: String
    let subtitle: String?
    let unknown: Int
    let fuzzy: Int
    let known: Int
    let maxReference: Int
    let emptyText: String
    var onClick: () -> Void

    @Environment(\.appPalette) private var palette

    var body: some View {
        let total = unknown + fuzzy + known
        let fillFraction = total > 0 ? Double(total) / Double(max(1, maxReference)) : 0

        Button(action: onClick) {
            GlassGroupedCard(index: index, count: count, outerRadius: 18, innerRadius: 6) {
                VStack(spacing: 8) {
                    HStack {
                        Text(title)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Spacer()
                        if total > 0 {
                            HStack(spacing: 10) {
                                MiniOptionBadge(text: "\(unknown)", dotColor: .red)
                                MiniOptionBadge(text: "\(fuzzy)", dotColor: .orange)
                                MiniOptionBadge(text: "\(known)", dotColor: palette.accent)
                                Text(subtitle ?? "\(total) 次")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(palette.accent)
                            }
                        } else {
                            Text(subtitle ?? emptyText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    TriColorVocabBar(
                        unknown: unknown,
                        fuzzy: fuzzy,
                        known: known,
                        height: 5,
                        fillFraction: fillFraction
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .buttonStyle(GlassPressButtonStyle())
    }
}

private struct EmptyHistoryCard: View {
    let systemImage: String
    let message: String

    var body: some View {
        GlassCard(cornerRadius: 20) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary.opacity(0.45))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(28)
        }
    }
}

private struct HistoryFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxUsedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + horizontalSpacing + size.width > maxWidth {
                totalHeight += rowHeight + verticalSpacing
                maxUsedWidth = max(maxUsedWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = rowWidth == 0 ? size.width : rowWidth + horizontalSpacing + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        maxUsedWidth = max(maxUsedWidth, rowWidth)
        return CGSize(width: proposal.width ?? maxUsedWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
