
import SwiftUI

struct AudioLevelMetersView: View {
    @ObservedObject var store: AudioLevelStore
    let microphonePaused: Bool
    let microphoneDevices: [MicrophoneDevice]
    let selectedMicrophoneDeviceUID: String
    let onSelectMicrophone: (String) -> Void

    private var levels: AudioLevelSnapshot {
        store.levels
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            AudioLevelMeterRow(
                title: String(localized: "System audio"),
                source: levels.systemSource,
                detail: nil,
                systemImage: "speaker.wave.2",
                level: levels.system,
                color: ABDesign.accent
            )

            if !microphonePaused {
                AudioLevelMeterRow(
                    title: String(localized: "Microphone"),
                    source: levels.microphoneSource,
                    detail: echoCancellationText(for: levels.microphoneEchoCancellation),
                    systemImage: "mic",
                    level: levels.microphone,
                    color: Color(red: 0.20, green: 0.50, blue: 0.88),
                    microphoneDevices: microphoneDevices,
                    selectedMicrophoneDeviceUID: selectedMicrophoneDeviceUID,
                    onSelectMicrophone: onSelectMicrophone
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func echoCancellationText(for status: EchoCancellationStatus) -> String {
        switch status {
        case .enabled:
            return String(localized: "Echo cancellation: on")
        case .disabled:
            return String(localized: "Echo cancellation: off")
        case .unknown:
            return String(localized: "Echo cancellation: unknown")
        }
    }
}

struct AudioLevelMeterRow: View {
    let title: String
    let source: String
    let detail: String?
    let systemImage: String
    let level: Double
    let color: Color
    var microphoneDevices: [MicrophoneDevice] = []
    var selectedMicrophoneDeviceUID: String?
    var onSelectMicrophone: ((String) -> Void)?

    private let barCount = 12

    var body: some View {
        GridRow(alignment: .center) {
            Image(systemName: systemImage)
                .font(ABTypography.body)
                .foregroundStyle(ABDesign.secondaryText)
                .frame(width: 24, height: 28, alignment: .center)
                .gridColumnAlignment(.center)

            VStack(alignment: .leading, spacing: 3) {
                if let onSelectMicrophone {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(ABTypography.bodyMedium)
                            .foregroundStyle(ABDesign.primaryText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Picker(
                            "",
                            selection: Binding(
                                get: { selectedMicrophoneDeviceUID ?? "" },
                                set: onSelectMicrophone
                            )
                        ) {
                            Text(systemInputTitle).tag("")
                            ForEach(microphoneDevices) { device in
                                Text(device.name).tag(device.uid)
                            }
                            if let selectedMicrophoneDeviceUID,
                               !selectedMicrophoneDeviceUID.isEmpty,
                               !microphoneDevices.contains(where: {
                                   $0.uid == selectedMicrophoneDeviceUID
                               }) {
                                Text(String(localized: "Unavailable microphone"))
                                    .tag(selectedMicrophoneDeviceUID)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 235)
                    }

                    Text(displaySubtitle)
                        .font(ABTypography.caption)
                        .foregroundStyle(ABDesign.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(title)
                        .font(ABTypography.bodyMedium)
                        .foregroundStyle(ABDesign.primaryText)
                        .lineLimit(1)
                        .frame(height: 28, alignment: .leading)
                    Text(displaySubtitle)
                        .font(ABTypography.caption)
                        .foregroundStyle(ABDesign.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .gridColumnAlignment(.leading)

            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(barColor(for: index))
                        .frame(width: 5, height: barHeight(for: index))
                }
            }
            .frame(width: 188, height: 28, alignment: .center)
            .gridColumnAlignment(.center)

            Text(level > 0.04 ? String(localized: "Signal") : String(localized: "Silent"))
                .font(ABTypography.caption)
                .foregroundStyle(ABDesign.secondaryText)
                .frame(width: 96, alignment: .leading)
                .gridColumnAlignment(.leading)
        }
    }

    private var systemInputTitle: String {
        guard let systemDevice = microphoneDevices.first(where: \.isSystemDefault) else {
            return String(localized: "Follow system input")
        }
        return String(localized: "Follow system input") + " (\(systemDevice.name))"
    }

    private var displaySource: String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "unavailable" else {
            return String(localized: "Source unavailable")
        }
        if let bracketRange = trimmed.range(of: " [", options: .backwards) {
            return String(trimmed[..<bracketRange.lowerBound])
        }
        return trimmed
    }

    private var displaySubtitle: String {
        guard let detail, !detail.isEmpty else {
            return displaySource
        }
        return "\(displaySource) · \(detail)"
    }

    private func barHeight(for index: Int) -> CGFloat {
        let normalized = min(1, max(0, level))
        guard normalized > 0.025 else {
            return 4
        }
        let position = Double(index + 1) / Double(barCount)
        let wave = 0.78 + 0.22 * sin((Double(index) * 1.7) + normalized * 5.0)
        let active = min(1, normalized / position)
        return CGFloat(4 + active * wave * 22)
    }

    private func barColor(for index: Int) -> Color {
        let threshold = Double(index + 1) / Double(barCount)
        return level >= threshold * 0.72 ? color : ABDesign.hairline
    }
}
