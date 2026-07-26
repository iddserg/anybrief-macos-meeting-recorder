
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
                    .font(ABTypography.captionMedium)
                    .foregroundStyle(.red)
                }

                logPanel(
                    title: String(localized: "Activity log"),
                    text: viewModel.activityLog.isEmpty ? String(localized: "No logs yet.") : viewModel.activityLog,
                    minHeight: 180
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                logPanel(
                    title: String(localized: "Errors"),
                    text: viewModel.errorLog.isEmpty ? String(localized: "No warnings or errors.") : viewModel.errorLog,
                    minHeight: 160
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
