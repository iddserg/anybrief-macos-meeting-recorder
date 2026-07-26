
import SwiftUI

extension DashboardView {
    func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: selectedSettingsCategory == .summary ? 10 : 14) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    func sectionCard<Content: View>(
        title: String? = nil,
        fillsHeight: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(ABTypography.sectionTitle)
            }

            content()
        }
        .padding(14)
        .frame(
            maxWidth: .infinity,
            maxHeight: fillsHeight ? .infinity : nil,
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(ABDesign.cardBackground)
                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 3)
        )
    }

    func gridRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(ABTypography.body)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Rectangle()
                .fill(ABDesign.hairline)
                .frame(width: 1, height: 20)
            Text(value)
                .font(ABTypography.body)
                .textSelection(.enabled)
                .padding(.leading, 10)
            Spacer()
        }
        .frame(minHeight: 22, alignment: .center)
    }

    func labeledField<Content: View>(
        _ label: String,
        help: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: selectedSettingsCategory == .summary ? 4 : 6) {
            HStack(spacing: 5) {
                Text(label)
                    .font(ABTypography.bodySemibold)
                    .foregroundStyle(ABDesign.primaryText)
                if let help {
                    HelpTooltipIcon(text: help)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func settingsReadOnlyField(_ value: String, onCopy: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(value)
                .font(ABTypography.mono)
                .foregroundStyle(ABDesign.primaryText)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button {
                onCopy()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(ABTypography.bodyMedium)
            }
            .buttonStyle(.plain)
            .disabled(value == "—")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color.white.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.16), lineWidth: 1)
        )
    }

    func settingsToggleRow(_ title: String, help: String? = nil, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 5) {
                Text(title)
                if let help {
                    HelpTooltipIcon(text: help)
                }
            }
        }
        .toggleStyle(.checkbox)
        .font(ABTypography.bodyMedium)
        .foregroundStyle(ABDesign.primaryText)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .background(Color.black.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func settingsToggleRow(title: String, detail: String, help: String? = nil, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: isOn) {
                HStack(spacing: 5) {
                    Text(title)
                    if let help {
                        HelpTooltipIcon(text: help)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .font(ABTypography.bodyMedium)
            .foregroundStyle(ABDesign.primaryText)

            Text(detail)
                .font(ABTypography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func settingsActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(ABTypography.bodyMedium)
                .padding(.horizontal, 16)
                .frame(height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(ABDesign.controlBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(ABDesign.hairline, lineWidth: 1)
                )
        )
    }

    func logBox(
        text: String,
        autoScrollEnabled: Bool,
        minHeight: CGFloat = 220,
        maxHeight: CGFloat = 320
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text)
                        .font(ABTypography.logMono)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)

                    Color.clear
                        .frame(height: 1)
                        .id("log-bottom")
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                guard autoScrollEnabled else { return }
                proxy.scrollTo("log-bottom", anchor: .bottom)
            }
            .onChange(of: text) { _ in
                guard autoScrollEnabled else { return }
                proxy.scrollTo("log-bottom", anchor: .bottom)
            }
            .onChange(of: autoScrollEnabled) { enabled in
                guard enabled else { return }
                proxy.scrollTo("log-bottom", anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: maxHeight, alignment: .topLeading)
        .background(ABDesign.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.16), lineWidth: 1)
        )
    }

    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = [.dropLeading]
        return formatter
    }()
}
