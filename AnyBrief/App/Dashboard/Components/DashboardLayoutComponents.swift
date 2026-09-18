
import SwiftUI

extension DashboardView {
    func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: WorkspaceDesign.formSpacing) {
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
        .padding(0)
        .frame(
            maxWidth: .infinity,
            maxHeight: fillsHeight ? .infinity : nil,
            alignment: .topLeading
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
        WorkspaceFormField(title: label, help: help, fillWidth: true, content: content)
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
        .frame(height: WorkspaceDesign.controlHeight)
        .background(ABDesign.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ABDesign.border, lineWidth: 1)
        )
    }

    func settingsToggleRow(_ title: String, help: String? = nil, isOn: Binding<Bool>) -> some View {
        settingsToggleRow(title: title, detail: "", help: help, isOn: isOn)
    }

    func settingsToggleRow(title: String, detail: String, help: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(title).font(ABTypography.bodyMedium)
                    if let help { HelpTooltipIcon(text: help) }
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(ABTypography.caption)
                        .foregroundStyle(ABDesign.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel(title)
        }
        .foregroundStyle(ABDesign.primaryText)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
    }

    func settingsActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(WorkspaceButtonStyle())
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
                .stroke(ABDesign.border, lineWidth: 1)
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
