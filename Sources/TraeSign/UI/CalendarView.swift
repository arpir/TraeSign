import SwiftUI

// MARK: - 自绘签到日历
/// 成功日绿色圆角块，今日红色描边，支持翻月（只读展示）。
struct CalendarView: View {
    let platform: Platform
    let version: Int  // 外部自增时强制重建，刷新成功日

    @State private var month: Date = CalendarView.startOfMonth(Date())

    private let week = ["一", "二", "三", "四", "五", "六", "日"]
    fileprivate static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2 // 周一为首列
        return c
    }()

    var body: some View {
        let success = History.successDays(platform, year: Self.cal.component(.year, from: month),
                                          month: Self.cal.component(.month, from: month))
        VStack(spacing: 6) {
            // 版本变化时强制重建以刷新成功日
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 18, height: 18) }
                    .buttonStyle(.borderless)
                Spacer()
                Text(title).font(.headline)
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 18, height: 18) }
                    .buttonStyle(.borderless)
            }
            .id(version)

            HStack(spacing: 0) {
                ForEach(week, id: \.self) { w in
                    Text(w).font(.caption).frame(maxWidth: .infinity).foregroundColor(.secondary)
                }
            }

            let cells = Self.buildCells(month)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(cells.indices, id: \.self) { i in
                    DayCell(date: cells[i], success: success.contains(Self.key(cells[i])),
                            inMonth: Self.cal.isDate(cells[i], equalTo: month, toGranularity: .month),
                            isToday: Self.cal.isDateInToday(cells[i]))
                }
            }
        }
        .padding(8)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(8)
        .id(version)
    }

    private var title: String {
        let f = DateFormatter(); f.dateFormat = "yyyy 年 M 月"
        return f.string(from: month)
    }

    private func shift(_ n: Int) {
        if let m = Self.cal.date(byAdding: .month, value: n, to: month) { month = m }
    }

    // MARK: 日期工具
    private static func startOfMonth(_ d: Date) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
    }

    static func buildCells(_ month: Date) -> [Date] {
        let first = startOfMonth(month)
        let weekday = (cal.component(.weekday, from: first) + 5) % 7 // 周一=0
        let start = cal.date(byAdding: .day, value: -weekday, to: first) ?? first
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    static func key(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
}

private struct DayCell: View {
    let date: Date
    let success: Bool
    let inMonth: Bool
    let isToday: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(fillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isToday ? Color.red : Color.clear, lineWidth: isToday ? 2 : 0)
                )
            Text("\(CalendarView.cal.component(.day, from: date))")
                .font(.caption2)
                .foregroundColor(textColor)
        }
        .frame(height: 22)
    }

    private var fillColor: Color {
        if success { return Color.green.opacity(0.85) }
        return Color.clear
    }
    private var textColor: Color {
        if success { return Color.white }
        return inMonth ? Color.primary : Color.secondary.opacity(0.4)
    }
}
