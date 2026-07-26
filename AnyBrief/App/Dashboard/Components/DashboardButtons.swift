
import SwiftUI

struct CompactActionButton: View {
    let title: String
    let systemImage: String
    var isEnabled = true
    var role: ButtonRole?
    var identifier: String?
    let action: () -> Void

    var body: some View {
        Button(role: role) {
            guard isEnabled else { return }
            action()
        } label: {
            Image(systemName: systemImage)
                .frame(width: 18, height: 16)
        }
        .controlSize(.mini)
        .buttonStyle(.bordered)
        .disabled(!isEnabled)
        .help(title)
        .accessibilityLabel(Text(title))
        .modifier(OptionalAccessibilityIdentifier(identifier: identifier))
    }
}

private struct OptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

struct HelpTooltipIcon: View {
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(ABTypography.captionSemibold)
                .foregroundStyle(isPresented ? ABDesign.accent : ABDesign.secondaryText)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            Text(text)
                .font(ABTypography.tooltip)
                .foregroundStyle(ABDesign.primaryText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(width: 260, alignment: .leading)
        }
        .accessibilityLabel(Text(String(localized: "Show help")))
        .accessibilityHint(Text(text))
    }
}

struct ToolbarIconButtonView: View {
    let title: String
    let systemImage: String
    let help: String
    var role: DashboardView.ToolbarButtonRole = .plain
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button {
            guard isEnabled else { return }
            action()
        } label: {
            Image(systemName: systemImage)
                .font(ABTypography.bodyMedium)
                .frame(width: 34, height: 34)
                .foregroundStyle(foregroundColor)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(backgroundColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(borderColor, lineWidth: isEnabled && role == .plain ? 1 : 0)
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(Text(title))
    }

    private var backgroundColor: Color {
        guard isEnabled else {
            return Color.black.opacity(0.035)
        }
        switch role {
        case .plain:
            return ABDesign.controlBackground
        case .primary:
            return ABDesign.accent
        case .destructive:
            return ABDesign.red
        }
    }

    private var foregroundColor: Color {
        guard isEnabled else {
            return ABDesign.disabledText
        }
        switch role {
        case .plain:
            return ABDesign.primaryText
        case .primary, .destructive:
            return .white
        }
    }

    private var borderColor: Color {
        isEnabled ? ABDesign.hairline : .clear
    }
}
