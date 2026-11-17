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
    @State private var isBookHeaderCollapsed = false

    // Vocab state
    @State private var vocabPeriod = 0 // 0 = 按日, 1 = 按周, 2 = 按月, 3 = 按年
    @State private var selectedVocabDate: Date = HistoryDateHelper.calendar.startOfDay(for: Date())
    @State private var selectedVocabWeekStart: Date = HistoryDateHelper.startOfWeek(for: Date())
    @State private var vocabYear: Int = HistoryDateHelper.calendar.component(.year, from: Date())
    @State private var vocabMonth: Int = HistoryDateHelper.calendar.component(.month, from: Date())
    @State private var vocabListYear: Int = HistoryDateHelper.calendar.component(.year, from: Date())
    @State private var expandedVocabDates: Set<String> = []
    @State private var isVocabHeaderCollapsed = false

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
                    HStack(spacing: 8) {
                        Text("阅读记录")
                            .font(.title2.bold())
                        GlassCircleIconButton(
                            systemImage: (category == 0 ? isBookHeaderCollapsed : isVocabHeaderCollapsed) ? "chevron.down" : "chevron.up",
                            size: 26,
                            iconFont: .caption2.bold()
                        ) {
                            withAnimation(AppMotion.panelSpring) {
                                if category == 0 {
                                    isBookHeaderCollapsed.toggle()
                                } else {
                                    isVocabHeaderCollapsed.toggle()
                                }
                            }
                        }
                        Spacer()
                        GlassSegmentedControl(
                            titles: historyCategories,
                            selection: $category,
                            compact: true
                        )
                        .frame(width: 148)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .background {
                        #if compiler(>=6.2)
                        if #available(iOS 26.0, *) {
                            Color.clear
                        } else {
                            Rectangle()
                                .fill(.ultraThinMaterial.opacity(0.65))
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(Color.white.opacity(palette.isLight ? 0.32 : 0.10))
                                        .frame(height: 0.5)
                                }
                        }
                        #else
                        Rectangle()
                            .fill(.ultraThinMaterial.opacity(0.65))
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(Color.white.opacity(palette.isLight ? 0.32 : 0.10))
                                    .frame(height: 0.5)
                            }
                        #endif
                    }

                    GlassHorizontalPager(selection: $category, pageCount: 2) { page in
                        if page == 0 {
                            bookHistoryPage
                        } else {
                            vocabHistoryPage
                        }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Book History Page

    private var bookHistoryPage: some View {
        let p: CGFloat = isBookHeaderCollapsed ? 1.0 : 0.0
        return VStack(spacing: 0) {
            bookHistoryFloatingHeader(p: p)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            if abs(value.translation.height) > abs(value.translation.width) * 1.4 {
                                withAnimation(AppMotion.panelSpring) {
                                    isBookHeaderCollapsed = value.translation.height < 0
                                }
                            }
                        }
                )
            bookHistoryScrollList
        }
        .animation(AppMotion.panelSpring, value: isBookHeaderCollapsed)
    }

    @ViewBuilder
    private var bookHistoryScrollList: some View {
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
                                            _ = expandedBookDates.remove(dateKey)
                                        } else {
                                            _ = expandedBookDates.insert(dateKey)
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
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, newOffset in
            if newOffset > 28, !isBookHeaderCollapsed {
                withAnimation(AppMotion.panelSpring) {
                    isBookHeaderCollapsed = true
                }
            } else if newOffset < -42, isBookHeaderCollapsed {
                withAnimation(AppMotion.panelSpring) {
                    isBookHeaderCollapsed = false
                }
            }
        }
    }

    @ViewBuilder
    private func bookHistoryFloatingHeader(p: CGFloat) -> some View {
        let cornerR = 20.0 - 6.0 * p
        let card1VertPad = 15.0 - 7.0 * p
        let card1Height = 44.0 - 22.0 * p
        let card1ExpandAlpha = max(0.0, 1.0 - Double(p / 0.55))
        let card1CompactAlpha = max(0.0, Double((p - 0.45) / 0.55))

        let card2VertPad = 14.0 - 7.0 * p
        let pillRatio = min(1.0, p / 0.58)
        let pillHeight = max(0.0, (1.0 - pillRatio) * 32.0)
        let pillGap = max(0.0, (1.0 - pillRatio) * 10.0)
        let pillAlpha = max(0.0, 1.0 - Double(min(1.0, p / 0.48)))

        let statsRatio = min(1.0, p / 0.70)
        let statsHeight = max(0.0, (1.0 - statsRatio) * 44.0)
        let statsGap = max(0.0, (1.0 - statsRatio) * 10.0)
        let statsAlpha = max(0.0, 1.0 - Double(min(1.0, p / 0.58)))

        VStack(spacing: 8 - 2 * p) {
                // Card 1: Overall Book Summary
                GlassCard(cornerRadius: cornerR) {
                    ZStack {
                        if card1ExpandAlpha > 0.01 {
                            HStack(spacing: 0) {
                                HistorySummaryStatItem(label: "累计阅读", value: "\(totalDaysRead) 天", systemImage: "calendar", iconColor: palette.accent)
                                HistoryStatDivider()
                                HistorySummaryStatItem(label: "连续打卡", value: "\(streakDays) 天", systemImage: "flame.fill", iconColor: .orange)
                                HistoryStatDivider()
                                HistorySummaryStatItem(label: "累计时长", value: formatDuration(totalSecondsAll), systemImage: "clock.fill", iconColor: .teal)
                            }
                            .opacity(card1ExpandAlpha)
                        }
                        if card1CompactAlpha > 0.01 {
                            HStack(spacing: 10) {
                                CompactInlineStat(label: "累计", value: "\(totalDaysRead) 天")
                                HistoryStatDivider(height: 14)
                                CompactInlineStat(label: "连续", value: "\(streakDays) 天")
                                HistoryStatDivider(height: 14)
                                CompactInlineStat(label: "总计", value: formatDuration(totalSecondsAll))
                            }
                            .opacity(card1CompactAlpha)
                        }
                    }
                    .frame(height: card1Height)
                    .clipped()
                    .padding(.horizontal, 12)
                    .padding(.vertical, card1VertPad)
                }

                // Card 2: Swipeable Book Period Card (按月 <-> 按年)
                GlassCard(cornerRadius: cornerR) {
                    VStack(spacing: 0) {
                        if pillHeight > 0.5 {
                            GlassSegmentedControl(
                                titles: bookPeriodOptions,
                                selection: $bookPeriod,
                                compact: true
                            )
                            .frame(width: 150)
                            .frame(height: pillHeight)
                            .clipped()
                            .opacity(pillAlpha)

                            Spacer().frame(height: pillGap)
                        }

                        GlassHorizontalPager(selection: $bookPeriod, pageCount: 2, fillHeight: false) { page in
                            if page == 0 {
                                VStack(spacing: 0) {
                                    let title = p > 0.55
                                        ? "\(bookYear)年\(bookMonth)月 · \(formatDuration(monthSeconds))"
                                        : "\(bookYear) 年 \(bookMonth) 月"
                                    PeriodNavigatorRow(
                                        title: title,
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
                                    if statsHeight > 0.5 {
                                        Spacer().frame(height: statsGap)
                                        HStack(spacing: 0) {
                                            HistorySummaryStatItem(label: "本月天数", value: "\(monthByDate.count) 天")
                                            HistorySummaryStatItem(label: "本月时长", value: formatDuration(monthSeconds))
                                            HistorySummaryStatItem(label: "读句 / 查词", value: "\(monthUnits) / \(monthLookups)")
                                        }
                                        .frame(height: statsHeight)
                                        .clipped()
                                        .opacity(statsAlpha)
                                    }
                                }
                                .padding(.horizontal, 16)
                            } else {
                                VStack(spacing: 0) {
                                    let title = p > 0.55
                                        ? "\(bookListYear)年 · \(formatDuration(yearSeconds))"
                                        : "\(bookListYear) 年"
                                    PeriodNavigatorRow(
                                        title: title,
                                        onPrev: { bookListYear -= 1 },
                                        onNext: { bookListYear += 1 }
                                    )
                                    if statsHeight > 0.5 {
                                        Spacer().frame(height: statsGap)
                                        HStack(spacing: 0) {
                                            HistorySummaryStatItem(label: "阅读天数", value: "\(yearDaysCount) 天")
                                            HistorySummaryStatItem(label: "总时长", value: formatDuration(yearSeconds))
                                            HistorySummaryStatItem(label: "读句 / 查词", value: "\(yearUnits) / \(yearLookups)")
                                        }
                                        .frame(height: statsHeight)
                                        .clipped()
                                        .opacity(statsAlpha)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(.vertical, card2VertPad)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, isBookHeaderCollapsed ? 4 : 8)
            .padding(.bottom, 8)
    }

    // MARK: - Vocab History Page

    private var vocabHistoryPage: some View {
        let vp: CGFloat = isVocabHeaderCollapsed ? 1.0 : 0.0
        return VStack(spacing: 0) {
            vocabHistoryFloatingHeader(vp: vp)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            if abs(value.translation.height) > abs(value.translation.width) * 1.4 {
                                withAnimation(AppMotion.panelSpring) {
                                    isVocabHeaderCollapsed = value.translation.height < 0
                                }
                            }
                        }
                )
            vocabHistoryScrollList
        }
        .animation(AppMotion.panelSpring, value: isVocabHeaderCollapsed)
    }

    @ViewBuilder
    private var vocabHistoryScrollList: some View {
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
                                                _ = expandedVocabDates.remove(dateKey)
                                            } else {
                                                _ = expandedVocabDates.insert(dateKey)
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
                                                _ = expandedVocabDates.remove(dateKey)
                                            } else {
                                                _ = expandedVocabDates.insert(dateKey)
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
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, newOffset in
            if newOffset > 28, !isVocabHeaderCollapsed {
                withAnimation(AppMotion.panelSpring) {
                    isVocabHeaderCollapsed = true
                }
            } else if newOffset < -42, isVocabHeaderCollapsed {
                withAnimation(AppMotion.panelSpring) {
                    isVocabHeaderCollapsed = false
                }
            }
        }
    }

    @ViewBuilder
    private func vocabHistoryFloatingHeader(vp: CGFloat) -> some View {
        let cornerR = 20.0 - 6.0 * vp
        let card1VertPad = 15.0 - 7.0 * vp
        let card1StatsH = 44.0 - 22.0 * vp
        let card1ExpandAlpha = max(0.0, 1.0 - Double(vp / 0.55))
        let card1CompactAlpha = max(0.0, Double((vp - 0.45) / 0.55))
        let extraRatio = min(1.0, vp / 0.62)
        let card1ExtraH = max(0.0, (1.0 - extraRatio) * 38.0)
        let card1ExtraAlpha = max(0.0, 1.0 - Double(min(1.0, vp / 0.52)))

        let card2VertPad = 14.0 - 7.0 * vp
        let pillRatio = min(1.0, vp / 0.58)
        let pillHeight = max(0.0, (1.0 - pillRatio) * 32.0)
        let pillGap = max(0.0, (1.0 - pillRatio) * 10.0)
        let pillAlpha = max(0.0, 1.0 - Double(min(1.0, vp / 0.48)))

        let breakdownRatio = min(1.0, vp / 0.72)
        let breakdownH = max(0.0, (1.0 - breakdownRatio) * 76.0)
        let breakdownGap = max(0.0, (1.0 - breakdownRatio) * 10.0)
        let breakdownAlpha = max(0.0, 1.0 - Double(min(1.0, vp / 0.58)))

        VStack(spacing: 8 - 2 * vp) {
                // Card 1: Overall Vocab Summary + Tri-color mastery bar
                GlassCard(cornerRadius: cornerR) {
                    VStack(spacing: 0) {
                        ZStack {
                            if card1ExpandAlpha > 0.01 {
                                HStack(spacing: 0) {
                                    HistorySummaryStatItem(label: "生词总量", value: "\(db.vocabList.count) 词", systemImage: "character.book.closed.fill", iconColor: palette.accent)
                                    HistoryStatDivider()
                                    HistorySummaryStatItem(label: "累计复习", value: "\(allVocabReviewTotals.total) 次", systemImage: "rectangle.stack.fill", iconColor: .orange)
                                    HistoryStatDivider()
                                    HistorySummaryStatItem(label: "已认识", value: "\(vocabPoolCounts.known) 词", systemImage: "checkmark.seal.fill", iconColor: .green)
                                }
                                .opacity(card1ExpandAlpha)
                            }
                            if card1CompactAlpha > 0.01 {
                                HStack(spacing: 10) {
                                    CompactInlineStat(label: "生词", value: "\(db.vocabList.count) 词")
                                    HistoryStatDivider(height: 14)
                                    CompactInlineStat(label: "复习", value: "\(allVocabReviewTotals.total) 次")
                                    HistoryStatDivider(height: 14)
                                    CompactInlineStat(label: "已认识", value: "\(vocabPoolCounts.known) 词")
                                }
                                .opacity(card1CompactAlpha)
                            }
                        }
                        .frame(height: card1StatsH)
                        .clipped()

                        if !db.vocabList.isEmpty && card1ExtraH > 0.5 {
                            VStack(spacing: 8) {
                                Spacer().frame(height: 2)
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
                            .frame(height: card1ExtraH)
                            .clipped()
                            .opacity(card1ExtraAlpha)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, card1VertPad)
                }

                // Card 2: Swipeable Vocab Period Card (按日 / 按周 / 按月 / 按年)
                GlassCard(cornerRadius: cornerR) {
                    VStack(spacing: 0) {
                        if pillHeight > 0.5 {
                            GlassSegmentedControl(
                                titles: vocabPeriodOptions,
                                selection: $vocabPeriod,
                                compact: true
                            )
                            .padding(.horizontal, 16)
                            .frame(height: pillHeight)
                            .clipped()
                            .opacity(pillAlpha)

                            Spacer().frame(height: pillGap)
                        }

                        GlassHorizontalPager(selection: $vocabPeriod, pageCount: 4, fillHeight: false) { page in
                            switch page {
                            case 0:
                                VStack(spacing: 0) {
                                    let isToday = HistoryDateHelper.dateKey(for: selectedVocabDate) == HistoryDateHelper.dateKey(for: today)
                                    let m = HistoryDateHelper.calendar.component(.month, from: selectedVocabDate)
                                    let d = HistoryDateHelper.calendar.component(.day, from: selectedVocabDate)
                                    let y = HistoryDateHelper.calendar.component(.year, from: selectedVocabDate)
                                    let baseTitle = isToday
                                        ? "今天 · \(m)月\(d)日"
                                        : "\(y)年\(m)月\(d)日 · \(HistoryDateHelper.weekdayShortName(for: selectedVocabDate))"
                                    let dayTitle = vp > 0.55 ? "\(baseTitle) · \(selectedDayTotals.total)次" : baseTitle

                                    PeriodNavigatorRow(
                                        title: dayTitle,
                                        onPrev: { selectedVocabDate = HistoryDateHelper.addDays(-1, to: selectedVocabDate) },
                                        onNext: { selectedVocabDate = HistoryDateHelper.addDays(1, to: selectedVocabDate) }
                                    )
                                    if breakdownH > 0.5 {
                                        Spacer().frame(height: breakdownGap)
                                        VocabPeriodBreakdownContent(
                                            totals: selectedDayTotals,
                                            subtitle: "当日 \(selectedDayTotals.total) 次闪卡 · 新增收藏 \(selectedDayCollectedCount) 词"
                                        )
                                        .frame(height: breakdownH)
                                        .clipped()
                                        .opacity(breakdownAlpha)
                                    }
                                }
                                .padding(.horizontal, 16)

                            case 1:
                                VStack(spacing: 0) {
                                    let weekEnd = HistoryDateHelper.addDays(6, to: selectedVocabWeekStart)
                                    let currentY = HistoryDateHelper.calendar.component(.year, from: today)
                                    let startY = HistoryDateHelper.calendar.component(.year, from: selectedVocabWeekStart)
                                    let startM = HistoryDateHelper.calendar.component(.month, from: selectedVocabWeekStart)
                                    let startD = HistoryDateHelper.calendar.component(.day, from: selectedVocabWeekStart)
                                    let endM = HistoryDateHelper.calendar.component(.month, from: weekEnd)
                                    let endD = HistoryDateHelper.calendar.component(.day, from: weekEnd)
                                    let prefix = startY != currentY ? "\(startY)年 " : ""
                                    let baseTitle = "\(prefix)\(startM)月\(startD)日 - \(endM)月\(endD)日"
                                    let weekTitle = vp > 0.55 ? "\(baseTitle) · \(weekTotals.total)次" : baseTitle

                                    PeriodNavigatorRow(
                                        title: weekTitle,
                                        onPrev: { selectedVocabWeekStart = HistoryDateHelper.addDays(-7, to: selectedVocabWeekStart) },
                                        onNext: { selectedVocabWeekStart = HistoryDateHelper.addDays(7, to: selectedVocabWeekStart) }
                                    )
                                    if breakdownH > 0.5 {
                                        Spacer().frame(height: breakdownGap)
                                        VocabPeriodBreakdownContent(
                                            totals: weekTotals,
                                            subtitle: "本周 \(weekTotals.activeDays) 天 · \(weekTotals.total) 次复习 · 收藏 \(weekCollectedCount) 词"
                                        )
                                        .frame(height: breakdownH)
                                        .clipped()
                                        .opacity(breakdownAlpha)
                                    }
                                }
                                .padding(.horizontal, 16)

                            case 2:
                                VStack(spacing: 0) {
                                    let title = vp > 0.55
                                        ? "\(vocabYear)年\(vocabMonth)月 · \(vocabMonthTotals.total)次"
                                        : "\(vocabYear) 年 \(vocabMonth) 月"
                                    PeriodNavigatorRow(
                                        title: title,
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
                                    if breakdownH > 0.5 {
                                        Spacer().frame(height: breakdownGap)
                                        VocabPeriodBreakdownContent(
                                            totals: vocabMonthTotals,
                                            subtitle: "本月 \(vocabMonthTotals.activeDays) 天 · \(vocabMonthTotals.total) 次复习 · 收藏 \(vocabMonthCollectedCount) 词"
                                        )
                                        .frame(height: breakdownH)
                                        .clipped()
                                        .opacity(breakdownAlpha)
                                    }
                                }
                                .padding(.horizontal, 16)

                            default:
                                VStack(spacing: 0) {
                                    let title = vp > 0.55
                                        ? "\(vocabListYear)年 · \(vocabYearTotals.total)次"
                                        : "\(vocabListYear) 年"
                                    PeriodNavigatorRow(
                                        title: title,
                                        onPrev: { vocabListYear -= 1 },
                                        onNext: { vocabListYear += 1 }
                                    )
                                    if breakdownH > 0.5 {
                                        Spacer().frame(height: breakdownGap)
                                        VocabPeriodBreakdownContent(
                                            totals: vocabYearTotals,
                                            subtitle: "全年 \(vocabYearTotals.activeDays) 天 · \(vocabYearTotals.total) 次复习 · 收藏 \(vocabYearCollectedCount) 词"
                                        )
                                        .frame(height: breakdownH)
                                        .clipped()
                                        .opacity(breakdownAlpha)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(.vertical, card2VertPad)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, isVocabHeaderCollapsed ? 4 : 8)
            .padding(.bottom, 8)
    }
}

// MARK: - History Subcomponents

private struct HistoryStatDivider: View {
    var height: CGFloat = 28

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 0.75, height: height)
    }
}

private struct CompactInlineStat: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.bold())
                .lineLimit(1)
        }
    }
}

private struct HistorySummaryStatItem: View {
    let label: String
    let value: String
    var systemImage: String? = nil
    var iconColor: Color? = nil

    @Environment(\.appPalette) private var palette

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.headline.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(iconColor ?? palette.accent)
                }
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
            GlassCircleIconButton(
                systemImage: "chevron.left",
                size: 30,
                iconFont: .caption.weight(.semibold),
                action: onPrev
            )

            Spacer()

            Text(title)
                .font(.subheadline.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer()

            GlassCircleIconButton(
                systemImage: "chevron.right",
                size: 30,
                iconFont: .caption.weight(.semibold),
                action: onNext
            )
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
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

private struct TriColorVocabBar: View {
    let unknown: Int
    let fuzzy: Int
    let known: Int
    var height: CGFloat = 5.5
    var fillFraction: Double = 1.0

    @Environment(\.appPalette) private var palette

    var body: some View {
        let total = unknown + fuzzy + known
        let clampedFill = total > 0 ? min(1.0, max(0.05, fillFraction)) : 0
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.14))
                if total > 0 && clampedFill > 0 {
                    let activeParts = (unknown > 0 ? 1 : 0) + (fuzzy > 0 ? 1 : 0) + (known > 0 ? 1 : 0)
                    let gapSpace = CGFloat(max(0, activeParts - 1)) * 2.0
                    let targetW = max(height, geo.size.width * clampedFill - gapSpace)
                    HStack(spacing: 2) {
                        if unknown > 0 {
                            Capsule()
                                .fill(Color.red)
                                .frame(width: max(height * 0.7, targetW * (Double(unknown) / Double(total))))
                        }
                        if fuzzy > 0 {
                            Capsule()
                                .fill(Color.orange)
                                .frame(width: max(height * 0.7, targetW * (Double(fuzzy) / Double(total))))
                        }
                        if known > 0 {
                            Capsule()
                                .fill(palette.accent)
                                .frame(width: max(height * 0.7, targetW * (Double(known) / Double(total))))
                        }
                    }
                    .frame(height: height)
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
                .monospacedDigit()
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
                .monospacedDigit()
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
            outerRadius: 20,
            innerRadius: 8,
            tintColor: expanded ? palette.accent.opacity(0.06) : nil
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: onToggle) {
                    HStack(spacing: 10) {
                        AppleIconBadge(systemImage: "calendar", size: 28, cornerRadius: 8)
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
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        }
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                            .opacity(0.45)
                        Text("共读 \(totalUnits) 句 · 查词 \(totalLookups) 次")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)

                        ForEach(dayLogs) { log in
                            let book = booksById[log.bookId]
                            let pct = book.map { min(100, max(0, Int(computeBookProgress($0) * 100.0))) }
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    HStack(spacing: 7) {
                                        AppleIconBadge(systemImage: "book.closed.fill", size: 22, cornerRadius: 6)
                                        Text(log.bookTitle)
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if let pct {
                                        Text("总进度 \(pct)%")
                                            .font(.caption2.weight(.semibold))
                                            .monospacedDigit()
                                            .foregroundStyle(palette.accent)
                                    }
                                }
                                HStack {
                                    Spacer()
                                    Text("\(log.unitsRead) 句 · \(log.lookupsCount) 词 · ")
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                    Text(formatDuration(log.readingSeconds))
                                        .font(.caption2.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(palette.accent)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.white.opacity(palette.isLight ? 0.35 : 0.10), lineWidth: 0.5)
                            )
                        }
                    }
                    .padding(.horizontal, 15)
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
            outerRadius: 20,
            innerRadius: 8,
            tintColor: isHighlighted ? palette.accent.opacity(0.11) : (expanded ? palette.accent.opacity(0.05) : nil)
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
                                        .monospacedDigit()
                                        .foregroundStyle(palette.accent)
                                }
                                if !collectedWords.isEmpty {
                                    MinimalTagPill(
                                        text: "藏 \(collectedWords.count)词",
                                        tintColor: palette.accent.opacity(0.12),
                                        textColor: palette.accent
                                    )
                                    Image(systemName: "chevron.down")
                                        .font(.caption2.bold())
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
                                height: 5.5,
                                fillFraction: fillFraction
                            )
                        }
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded && !collectedWords.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                            .opacity(0.45)
                        Text("当日收藏单词 (\(collectedWords.count))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HistoryFlowLayout(horizontalSpacing: 7, verticalSpacing: 7) {
                            ForEach(collectedWords) { item in
                                Text(item.word)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 5.5)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color.white.opacity(palette.isLight ? 0.55 : 0.16), lineWidth: 0.55)
                                    )
                            }
                        }
                    }
                    .padding(.horizontal, 15)
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
            GlassGroupedCard(index: index, count: count, outerRadius: 20, innerRadius: 8) {
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
                                    .monospacedDigit()
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
                        height: 5.5,
                        fillFraction: fillFraction
                    )
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 13)
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
