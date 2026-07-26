
import SwiftUI

enum SummaryProviderSettingsControls {
    static func optionalStringBinding(
        _ source: Binding<String?>,
        default defaultValue: String = ""
    ) -> Binding<String> {
        Binding(
            get: { source.wrappedValue ?? defaultValue },
            set: { source.wrappedValue = $0 }
        )
    }

    static func optionalIntBinding(
        _ source: Binding<Int?>,
        default defaultValue: Int
    ) -> Binding<Int> {
        Binding(
            get: { source.wrappedValue ?? defaultValue },
            set: { source.wrappedValue = $0 }
        )
    }

    static func labeledField<Content: View>(
        _ label: String,
        help: String? = nil,
        fillWidth: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
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
        .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
    }

    /// Lays fields out in a row without letting them stretch to fill
    /// leftover space unevenly (each field sizes to its own content).
    static func wrappingFieldRow<Content: View>(
        spacing: CGFloat = 20,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: spacing) {
            content()
            Spacer(minLength: 0)
        }
    }

    static func promptEditor(text: Binding<String>, height: CGFloat) -> some View {
        labeledField(
            String(localized: "Prompt"),
            help: String(localized: "Instructions sent to the summary provider together with the transcript.")
        ) {
            TextEditor(text: text)
                .font(ABTypography.field)
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(height: height)
                .background(Color.white.opacity(0.86))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.black.opacity(0.16), lineWidth: 1)
                )
        }
    }

    static func compactHelpText(_ text: String) -> some View {
        Text(text)
            .font(ABTypography.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
