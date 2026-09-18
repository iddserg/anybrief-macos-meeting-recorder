
import SwiftUI

extension DashboardView {
    var logsSection: some View {
        sectionCard(fillsHeight: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer()
                    Toggle(String(localized: "Disable auto-scroll"), isOn: $logAutoScrollDisabled)
                        .toggleStyle(.checkbox)
                        .font(ABTypography.caption)
                    Button(String(localized: "Clear Logs")) {
                        viewModel.clearLogs()
                    }
                    .buttonStyle(WorkspaceButtonStyle(destructive: true))
                }

                logPanel(
                    title: String(localized: "Activity log"),
                    text: viewModel.activityLog.isEmpty ? String(localized: "No logs yet.") : viewModel.activityLog,
                    minHeight: 140
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                logPanel(
                    title: String(localized: "Errors"),
                    text: viewModel.errorLog.isEmpty ? String(localized: "No warnings or errors.") : viewModel.errorLog,
                    minHeight: 120
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                CallStatisticsHeatmapView(days: viewModel.callStatistics)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func logPanel(title: String, text: String, minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(ABTypography.bodySemibold)
                .foregroundStyle(ABDesign.primaryText)
            logBox(
                text: text,
                autoScrollEnabled: !logAutoScrollDisabled,
                minHeight: minHeight,
                maxHeight: .infinity
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

}

private struct CallStatisticsHeatmapView: View {
    let days: [CallStatisticsDay]

    private let maximumCellSize: CGFloat = 10
    private let cellSpacing: CGFloat = 2
    private let weekdayLabelWidth: CGFloat = 24
    private let weekdayGridSpacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    String(
                        format: String(localized: "%lld calls in the last year"),
                        Int64(totalCallCount)
                    )
                )
                .font(ABTypography.bodySemibold)
                .foregroundStyle(ABDesign.primaryText)

                Spacer()

                Text(
                    String(
                        format: String(localized: "Time in calls: %@"),
                        Self.durationFormatter.string(from: totalDuration) ?? "0m"
                    )
                )
                .font(ABTypography.captionMedium)
                .foregroundStyle(ABDesign.secondaryText)
            }

            GeometryReader { geometry in
                heatmapGrid(cellSize: fittedCellSize(for: geometry.size.width))
            }
            .frame(height: 96)

            HStack(spacing: 4) {
                Spacer()
                Text(String(localized: "Less activity"))
                    .font(.system(size: 9))
                    .foregroundStyle(ABDesign.secondaryText)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(legendColor(level: level))
                        .frame(width: maximumCellSize, height: maximumCellSize)
                }
                Text(String(localized: "More activity"))
                    .font(.system(size: 9))
                    .foregroundStyle(ABDesign.secondaryText)
            }
        }
        .padding(10)
        .background(ABDesign.subtleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ABDesign.hairline, lineWidth: 1)
        )
    }

    private func heatmapGrid(cellSize: CGFloat) -> some View {
        HStack(alignment: .top, spacing: weekdayGridSpacing) {
            VStack(alignment: .trailing, spacing: cellSpacing) {
                Color.clear
                    .frame(width: weekdayLabelWidth, height: 11)
                ForEach(0..<7, id: \.self) { weekday in
                    Text(Self.weekdayLabels[weekday])
                        .font(.system(size: 9))
                        .foregroundStyle(ABDesign.secondaryText)
                        .frame(width: weekdayLabelWidth, height: cellSize, alignment: .trailing)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: cellSpacing) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        Text(monthLabel(for: week))
                            .font(.system(size: 9))
                            .foregroundStyle(ABDesign.secondaryText)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: cellSize, height: 11, alignment: .leading)
                    }
                }

                HStack(alignment: .top, spacing: cellSpacing) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: cellSpacing) {
                            ForEach(0..<7, id: \.self) { weekday in
                                if let day = week[weekday] {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(color(for: day))
                                        .frame(width: cellSize, height: cellSize)
                                        .help(tooltip(for: day))
                                        .accessibilityLabel(tooltip(for: day))
                                } else {
                                    Color.clear
                                        .frame(width: cellSize, height: cellSize)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func fittedCellSize(for availableWidth: CGFloat) -> CGFloat {
        let weekCount = max(weeks.count, 1)
        let interWeekSpacing = CGFloat(max(weekCount - 1, 0)) * cellSpacing
        let gridWidth = availableWidth - weekdayLabelWidth - weekdayGridSpacing - interWeekSpacing
        return min(maximumCellSize, max(6, floor(gridWidth / CGFloat(weekCount))))
    }

    private var totalCallCount: Int {
        days.reduce(0) { $0 + $1.callCount }
    }

    private var totalDuration: TimeInterval {
        days.reduce(0) { $0 + $1.duration }
    }

    private var weeks: [[CallStatisticsDay?]] {
        guard let firstDate = days.first?.date else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let weekday = calendar.component(.weekday, from: firstDate)
        let leadingEmptyDays = (weekday + 5) % 7
        var padded: [CallStatisticsDay?] = Array(repeating: nil, count: leadingEmptyDays)
        padded.append(contentsOf: days.map(Optional.some))
        while !padded.count.isMultiple(of: 7) {
            padded.append(nil)
        }
        return stride(from: 0, to: padded.count, by: 7).map {
            Array(padded[$0..<min($0 + 7, padded.count)])
        }
    }

    private func monthLabel(for week: [CallStatisticsDay?]) -> String {
        guard let firstDayOfMonth = week.compactMap({ $0 }).first(where: {
            Calendar.current.component(.day, from: $0.date) == 1
        }) else {
            return ""
        }
        return Self.monthFormatter.string(from: firstDayOfMonth.date)
    }

    private func color(for day: CallStatisticsDay) -> Color {
        let callProgress = Double(day.callCount) / 8
        let durationProgress = day.duration / (8 * 60 * 60)
        return heatColor(progress: max(callProgress, durationProgress))
    }

    private func legendColor(level: Int) -> Color {
        level == 0 ? heatColor(progress: 0) : heatColor(progress: Double(level) / 4)
    }

    private func heatColor(progress: Double) -> Color {
        let value = min(max(progress, 0), 1)
        switch value {
        case 0:
            return ABDesign.mutedBackground
        case ..<0.25:
            return Color(red: 1.0, green: 0.86, blue: 0.72)
        case ..<0.5:
            return Color(red: 1.0, green: 0.63, blue: 0.35)
        case ..<0.75:
            return Color(red: 0.94, green: 0.31, blue: 0.20)
        default:
            return Color(red: 0.66, green: 0.07, blue: 0.10)
        }
    }

    private func tooltip(for day: CallStatisticsDay) -> Text {
        Text(
            String(
                format: String(localized: "%@: %lld calls, %@"),
                Self.dateFormatter.string(from: day.date),
                Int64(day.callCount),
                Self.durationFormatter.string(from: day.duration) ?? "0m"
            )
        )
    }

    private static let weekdayLabels: [String] = {
        let symbols = DateFormatter().shortStandaloneWeekdaySymbols ?? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let mondayFirst = Array(symbols.dropFirst()) + Array(symbols.prefix(1))
        return mondayFirst.enumerated().map { index, value in
            [0, 2, 4].contains(index) ? value : ""
        }
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()
}
