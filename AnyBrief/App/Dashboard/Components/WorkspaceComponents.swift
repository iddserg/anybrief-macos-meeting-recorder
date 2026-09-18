import SwiftUI

/// Shared geometry and controls for the 2.0 workspace.
enum WorkspaceDesign {
    static let sidebarWidth: CGFloat = 192
    static let navigationFont = Font.system(size: 13, weight: .medium)
    static let listWidth: CGFloat = 230
    static let listRowVerticalInset: CGFloat = 6
    static let listRowSpacing: CGFloat = 2
    static let listDetailSpacing: CGFloat = 3
    static let inset: CGFloat = 24
    static let audioStatusWidth: CGFloat = 96
    static let controlHeight: CGFloat = 34
    static let numericFieldWidth: CGFloat = 96
    static let fieldSpacing: CGFloat = 8
    static let formSpacing: CGFloat = 24
    static let surface = ABDesign.surface
    static let secondarySurface = ABDesign.secondarySurface
}

struct WorkspaceButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ABTypography.bodyMedium)
            .padding(.horizontal, 12)
            .frame(minHeight: WorkspaceDesign.controlHeight)
            .foregroundStyle(prominent ? Color.white : ABDesign.primaryText)
            .background(prominent ? (destructive ? ABDesign.red : ABDesign.accent) : WorkspaceDesign.surface)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(prominent ? Color.clear : ABDesign.hairline))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

struct WorkspaceEmptyState: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(ABDesign.secondaryText)
            Text(title).font(ABTypography.itemTitle)
            Text(detail).font(ABTypography.body).foregroundStyle(ABDesign.secondaryText)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WorkspaceTab: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(ABTypography.bodyMedium)
                .foregroundStyle(selected ? ABDesign.primaryText : ABDesign.secondaryText)
                .padding(.vertical, 14)
                .overlay(alignment: .bottom) {
                    if selected { Rectangle().fill(ABDesign.accent).frame(height: 2) }
                }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The same label geometry for a plain button and a provider-selection menu.
struct WorkspaceCollectionActionIcon: View {
    let systemImage: String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: systemImage)
            .font(ABTypography.bodySemibold)
            .foregroundStyle(ABDesign.accent)
            .frame(width: 44, height: WorkspaceDesign.controlHeight)
            .background(WorkspaceDesign.surface)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(ABDesign.hairline))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct WorkspaceCollectionActions<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                content()
                Spacer(minLength: 0)
            }
            .buttonStyle(.plain)
            .padding(12)
        }
    }
}

/// One visual hierarchy for enableable settings sections across modules.
struct WorkspaceSettingsSectionHeader: View {
    let title: String
    @Binding var isOn: Bool
    var showsStatus = true

    var body: some View {
        HStack(spacing: 10) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(title)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(ABTypography.itemTitle)
                    .foregroundStyle(ABDesign.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if showsStatus {
                    Text(isOn ? String(localized: "Enabled") : String(localized: "Disabled"))
                        .font(ABTypography.caption)
                        .foregroundStyle(isOn ? ABDesign.green : ABDesign.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
    }
}

/// Shared form geometry for Dashboard and provider-owned settings.
struct WorkspaceFormField<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    var help: String? = nil
    var fillWidth = true
    let content: Content

    init(title: String, help: String? = nil, fillWidth: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.help = help
        self.fillWidth = fillWidth
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceDesign.fieldSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(title).font(ABTypography.bodySemibold)
                    .foregroundStyle(ABDesign.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let help { HelpTooltipIcon(text: help) }
            }
            content
                // AppKit-backed pickers can retain their old label drawing after a theme switch.
                .id(colorScheme)
                .font(ABTypography.field)
                .controlSize(.regular)
                .frame(minHeight: WorkspaceDesign.controlHeight, alignment: .leading)
        }
        .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
    }
}

/// Native stepper with a stable value column and the same row height as other fields.
struct WorkspaceIntegerStepper: View {
    let title: String
    let valueText: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 8) {
            Text(valueText).monospacedDigit().lineLimit(1)
                .frame(minWidth: 56, alignment: .leading)
            Stepper(title, value: $value, in: range).labelsHidden().fixedSize()
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
        .font(ABTypography.field).controlSize(.regular)
        .frame(minHeight: WorkspaceDesign.controlHeight, alignment: .leading)
    }
}

/// Resolve collection edits by identity, even if an old field commits after reordering/removal.
enum WorkspaceCollectionBinding {
    static func item<Item: Identifiable>(_ snapshot: Item, in source: Binding<[Item]>) -> Binding<Item> {
        Binding(
            get: { source.wrappedValue.first(where: { $0.id == snapshot.id }) ?? snapshot },
            set: { updated in
                guard updated.id == snapshot.id,
                      let index = source.wrappedValue.firstIndex(where: { $0.id == snapshot.id }) else { return }
                source.wrappedValue[index] = updated
            }
        )
    }
}
