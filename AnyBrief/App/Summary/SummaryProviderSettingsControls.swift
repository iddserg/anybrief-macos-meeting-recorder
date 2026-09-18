
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
        WorkspaceFormField(title: label, help: help, fillWidth: fillWidth, content: content)
    }

    /// Keep fields together when space allows; stack them in narrow editors.
    static func wrappingFieldRow<Content: View>(
        spacing: CGFloat = 20,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: spacing) { content() }
            VStack(alignment: .leading, spacing: spacing) { content() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .background(ABDesign.controlBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(ABDesign.border, lineWidth: 1)
                )
        }
    }

    static func compactHelpText(_ text: String) -> some View {
        Text(text)
            .font(ABTypography.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
