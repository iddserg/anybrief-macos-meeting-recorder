
import SwiftUI

extension DashboardView {
    var transcriptionSettingsGroup: some View {
        settingsGroup(title: String(localized: "Transcription")) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(viewModel.transcriptionProviderRegistry.modules, id: \.id) { module in
                        Button {
                            viewModel.transcriptionProviderSelection = module.id.rawValue
                            viewModel.transcriptionProviderDidChange()
                        } label: {
                            Label {
                                Text(module.title)
                            } icon: {
                                Image(
                                    systemName: module.id == viewModel.selectedTranscriptionProvider
                                        ? "checkmark"
                                        : module.systemImage
                                )
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selectedTranscriptionProviderModule.systemImage)
                            .foregroundStyle(ABDesign.accent)
                        Text(selectedTranscriptionProviderModule.title)
                            .font(ABTypography.bodyMedium)
                            .foregroundStyle(ABDesign.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(ABTypography.iconTiny)
                            .foregroundStyle(ABDesign.secondaryText)
                    }
                    .padding(.horizontal, 12)
                    .frame(width: 320, height: 36, alignment: .leading)
                    .background(Color.black.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)

                HelpTooltipIcon(
                    text: String(localized: "Choose the engine that recognizes speech. Speaker separation can be enabled below.")
                )
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            if viewModel.selectedTranscriptionProvider == .whisperCpp {
                whisperCppSettings
            }

            transcriptionVocabularyCard

            transcriptionModelStatusCard
            transcriptionTechnologyStatusCard

            microphoneSettingsCard
            speakerSettingsCard
        }
        .onAppear {
            viewModel.refreshTranscriptionModelStatus()
        }
    }

    private var microphoneSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        microphoneSettingsExpanded.toggle()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "Microphone"))
                            .font(ABTypography.bodySemibold)
                            .foregroundStyle(ABDesign.primaryText)
                        Text(systemMicrophonePickerTitle)
                            .font(ABTypography.caption)
                            .foregroundStyle(ABDesign.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()
                disclosureButton(isExpanded: $microphoneSettingsExpanded)
            }

            if microphoneSettingsExpanded {
                labeledField(
                    String(localized: "Microphone"),
                    help: String(localized: "Choose a specific microphone or follow the current macOS system input.")
                ) {
                    Picker("", selection: $viewModel.microphoneDeviceUID) {
                        Text(systemMicrophonePickerTitle).tag("")
                        ForEach(viewModel.availableMicrophoneDevices) { device in
                            Text(device.name).tag(device.uid)
                        }
                        if !viewModel.microphoneDeviceUID.isEmpty,
                           !viewModel.availableMicrophoneDevices.contains(where: {
                               $0.uid == viewModel.microphoneDeviceUID
                           }) {
                            Text(String(localized: "Unavailable microphone"))
                                .tag(viewModel.microphoneDeviceUID)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320)
                }

                settingsToggleRow(
                    title: String(localized: "Microphone voice processing"),
                    detail: String(localized: "If you record without headphones, turn this on to reduce speaker echo in the microphone track. Leave it off when using headphones."),
                    help: String(localized: "Applies Apple's microphone voice-processing mode. It can reduce echo and background noise, but may slightly change voice tone."),
                    isOn: $viewModel.microphoneVoiceProcessingEnabled
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var speakerSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        speakerSettingsExpanded.toggle()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "Separate speakers"))
                            .font(ABTypography.bodySemibold)
                            .foregroundStyle(ABDesign.primaryText)
                        Text(
                            viewModel.transcriptionDiarizationEnabled
                                ? String(localized: "On")
                                : String(localized: "Off")
                        )
                        .font(ABTypography.caption)
                        .foregroundStyle(ABDesign.secondaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()
                disclosureButton(isExpanded: $speakerSettingsExpanded)
            }

            if speakerSettingsExpanded {
                settingsToggleRow(
                    title: String(localized: "Separate speakers"),
                    detail: String(localized: "Identify individual speakers in system audio. Turn this off for faster, simpler recognition without speaker diarization."),
                    help: String(localized: "When disabled, AnyBrief still keeps system audio and microphone as separate tracks, but does not split system audio into individual speakers."),
                    isOn: $viewModel.transcriptionDiarizationEnabled
                )
                .onChange(of: viewModel.transcriptionDiarizationEnabled) { _ in
                    viewModel.refreshTranscriptionModelStatus()
                }

                settingsToggleRow(
                    title: String(localized: "Skip microphone diarization"),
                    detail: String(localized: "Treat the microphone track as one local speaker without running speaker diarization."),
                    help: String(localized: "Disable this only if several people share the same microphone and must be separated into individual speakers."),
                    isOn: $viewModel.skipMicrophoneDiarization
                )
                .disabled(!viewModel.transcriptionDiarizationEnabled)
                .opacity(viewModel.transcriptionDiarizationEnabled ? 1 : 0.5)

                labeledField(
                    String(localized: "Speakers"),
                    help: String(localized: "Controls speaker diarization. Calendar and maximum count set an upper limit; exact count forces N speakers and uses a fallback if the model returns another count.")
                ) {
                    HStack(spacing: 12) {
                        Picker("", selection: selectedSpeakersMode) {
                            Text(String(localized: "Auto-detect")).tag("auto")
                            Text(String(localized: "From calendar (maximum)")).tag("calendar")
                            Text(String(localized: "Exact count")).tag("fixed")
                            Text(String(localized: "Maximum count")).tag("max")
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 180)

                        if ["fixed", "max"].contains(selectedSpeakersMode.wrappedValue) {
                            Stepper("\(selectedSpeakersCount.wrappedValue)",
                                    value: selectedSpeakersCount, in: 1...10)
                                .frame(maxWidth: 120)
                        }
                    }
                }
                .disabled(!viewModel.transcriptionDiarizationEnabled)
                .opacity(viewModel.transcriptionDiarizationEnabled ? 1 : 0.5)

                labeledField(
                    String(localized: "Speaker Sensitivity"),
                    help: String(localized: "Lower values split speech into more speakers. Higher values merge similar voices and produce fewer speakers.")
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Spacer()
                            Text(String(format: "%.2f", selectedSpeakerThreshold.wrappedValue))
                                .font(ABTypography.mono)
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: selectedSpeakerThreshold, in: 0.1...1.0, step: 0.05)
                        HStack(spacing: 4) {
                            Text(String(localized: "0.1 = more speakers"))
                                .font(ABTypography.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(localized: "0.65 = balanced (default)"))
                                .font(ABTypography.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(localized: "1.0 = fewer speakers"))
                                .font(ABTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!viewModel.transcriptionDiarizationEnabled)
                .opacity(viewModel.transcriptionDiarizationEnabled ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var transcriptionVocabularyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        transcriptionVocabularyExpanded.toggle()
                    }
                } label: {
                    Text(String(localized: "Recognition dictionary"))
                        .font(ABTypography.bodySemibold)
                        .foregroundStyle(ABDesign.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HelpTooltipIcon(
                    text: String(localized: "Add one preferred word or phrase per line. To correct known variants, use “Preferred term: variant 1, variant 2”. The dictionary is passed to the selected STT engine.")
                )
                disclosureButton(isExpanded: $transcriptionVocabularyExpanded)
            }

            if transcriptionVocabularyExpanded {
                Text(selectedTranscriptionProviderTitle)
                    .font(ABTypography.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: selectedTranscriptionVocabulary)
                    .font(ABTypography.field)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 96, maxHeight: 150)
                    .background(Color.white.opacity(0.86))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.black.opacity(0.16), lineWidth: 1)
                    )
                Text(String(localized: "Example: Admon\nMGCom: сам же ком, эм-джи-ком"))
                    .font(ABTypography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var whisperCppSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow(alignment: .center) {
                    HStack(spacing: 5) {
                        Text(String(localized: "Whisper model"))
                            .font(ABTypography.bodySemibold)
                            .foregroundStyle(ABDesign.primaryText)
                        HelpTooltipIcon(
                            text: String(localized: "Larger models are usually more accurate but require more disk space, memory, and processing time.")
                        )
                    }
                    .frame(width: 220, alignment: .leading)

                    Picker("", selection: $viewModel.whisperCppModel) {
                        ForEach(WhisperCppModelService.models) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 360, alignment: .leading)
                    .onChange(of: viewModel.whisperCppModel) { _ in
                        viewModel.refreshTranscriptionModelStatus()
                    }
                }

                GridRow(alignment: .center) {
                    HStack(spacing: 5) {
                        Text(String(localized: "Recognition language"))
                            .font(ABTypography.bodySemibold)
                            .foregroundStyle(ABDesign.primaryText)
                        HelpTooltipIcon(
                            text: String(localized: "Auto-detect works for all multilingual Whisper languages. Choosing a language can improve speed and stability.")
                        )
                    }
                    .frame(width: 220, alignment: .leading)

                    Picker("", selection: $viewModel.whisperCppLanguage) {
                        ForEach(WhisperCppModelService.supportedLanguageCodes, id: \.self) { code in
                            Text(whisperLanguageTitle(code)).tag(code)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 360, alignment: .leading)
                }
            }

            settingsToggleRow(
                title: String(localized: "Use Metal acceleration"),
                detail: String(localized: "Run whisper.cpp on the Apple GPU when available. Turn this off to force CPU processing."),
                help: nil,
                isOn: $viewModel.whisperCppUseGPU
            )

            Text(String(localized: "Whisper multilingual models support 99 languages, including Russian, English, Ukrainian, German, French, Spanish, Italian, Portuguese, Polish, Chinese, Japanese, and Korean."))
                .font(ABTypography.caption)
                .foregroundStyle(ABDesign.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
    }

    private var selectedSpeakersMode: Binding<String> {
        viewModel.selectedTranscriptionProvider == .whisperCpp
            ? $viewModel.whisperCppSpeakersMode
            : $viewModel.fluidAudioSTTSpeakersMode
    }

    private var selectedTranscriptionVocabulary: Binding<String> {
        viewModel.selectedTranscriptionProvider == .whisperCpp
            ? $viewModel.whisperCppCustomVocabulary
            : $viewModel.fluidAudioSTTCustomVocabulary
    }

    private var selectedTranscriptionProviderTitle: String {
        viewModel.selectedTranscriptionProvider == .whisperCpp
            ? "whisper.cpp"
            : "FluidAudio STT"
    }

    private var selectedTranscriptionProviderModule: any TranscriptionProviderModule {
        viewModel.transcriptionProviderRegistry.modules.first {
            $0.id == viewModel.selectedTranscriptionProvider
        } ?? viewModel.transcriptionProviderRegistry.modules[0]
    }

    private var selectedSpeakersCount: Binding<Int> {
        viewModel.selectedTranscriptionProvider == .whisperCpp
            ? $viewModel.whisperCppSpeakersCount
            : $viewModel.fluidAudioSTTSpeakersCount
    }

    private var selectedSpeakerThreshold: Binding<Double> {
        viewModel.selectedTranscriptionProvider == .whisperCpp
            ? $viewModel.whisperCppThreshold
            : $viewModel.fluidAudioSTTThreshold
    }

    private func whisperLanguageTitle(_ code: String) -> String {
        let titles = [
            "auto": String(localized: "Auto-detect"),
            "ru": "Русский",
            "en": "English",
            "de": "Deutsch",
            "fr": "Français",
            "es": "Español",
            "it": "Italiano",
            "pt": "Português",
            "pl": "Polski",
            "nl": "Nederlands",
            "uk": "Українська",
            "tr": "Türkçe",
            "ja": "日本語",
            "zh": "中文",
            "ko": "한국어",
        ]
        return titles[code] ?? code
    }

    private var systemMicrophonePickerTitle: String {
        guard let systemDevice = viewModel.availableMicrophoneDevices.first(where: \.isSystemDefault) else {
            return String(localized: "Follow system input")
        }
        return String(localized: "Follow system input") + " (\(systemDevice.name))"
    }

    var transcriptionModelStatusCard: some View {
        let status = viewModel.transcriptionModelStatus
        let isWhisper = viewModel.selectedTranscriptionProvider == .whisperCpp
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        transcriptionModelDetailsExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: status.isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                            .font(ABTypography.iconMedium)
                            .foregroundStyle(status.isInstalled ? ABDesign.green : ABDesign.accent)
                            .frame(width: 24, height: 24)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "Recognition model"))
                                .font(ABTypography.bodySemibold)
                                .foregroundStyle(ABDesign.primaryText)
                            Text(status.isInstalled ? String(localized: "Installed") : String(localized: "Not installed"))
                                .font(ABTypography.bodyMedium)
                                .foregroundStyle(status.isInstalled ? ABDesign.green : ABDesign.red)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    viewModel.downloadTranscriptionModels()
                } label: {
                    if viewModel.isDownloadingTranscriptionModels {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(String(localized: "Downloading…"))
                        }
                    } else {
                        Label(
                            status.isInstalled ? String(localized: "Download again") : String(localized: "Download models"),
                            systemImage: "arrow.down.circle"
                        )
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isDownloadingTranscriptionModels)

                disclosureButton(isExpanded: $transcriptionModelDetailsExpanded)
            }

            if transcriptionModelDetailsExpanded {
                Text(
                    isWhisper && viewModel.transcriptionDiarizationEnabled
                        ? String(localized: "AnyBrief runs whisper.cpp locally in one full-audio pass, then combines its word timestamps with FluidAudio speaker diarization.")
                        : (isWhisper
                            ? String(localized: "AnyBrief runs whisper.cpp locally in one full-audio pass without loading speaker diarization models.")
                            : String(localized: "AnyBrief uses FluidAudio to download NVIDIA Parakeet TDT 0.6B v3 Core ML models on first use. Recognition runs locally; on Apple Silicon Core ML can use Apple Neural Engine (ANE)."))
                )
                .font(ABTypography.caption)
                .foregroundStyle(ABDesign.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                Text(
                    isWhisper
                        ? String(format: String(localized: "Selected model: %@. The recognition model is downloaded separately; FluidAudio diarization models are also required."), viewModel.whisperCppModel)
                        : String(localized: "The model is multilingual and supports 25 languages, including English, Russian, German, French, Spanish, Italian, Portuguese, Polish, Dutch, Ukrainian, and other European languages. Speaker diarization models are stored next to it.")
                )
                .font(ABTypography.caption)
                .foregroundStyle(ABDesign.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(localized: "Path:"))
                        .font(ABTypography.captionSemibold)
                        .foregroundStyle(ABDesign.secondaryText)
                    Text(status.modelsDirectoryURL.path)
                        .font(ABTypography.mono)
                        .foregroundStyle(ABDesign.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                    Text(
                        status.installedSizeBytes > 0
                            ? String(format: String(localized: "Cache size: %@"), status.installedSizeDescription)
                            : String(localized: "Cache size: not downloaded")
                    )
                    .font(ABTypography.caption)
                    .foregroundStyle(ABDesign.secondaryText)

                if !status.isInstalled {
                    Text(
                        String(
                            format: String(localized: "Missing files: %d"),
                            status.missingRelativePaths.count
                        )
                    )
                    .font(ABTypography.caption)
                    .foregroundStyle(ABDesign.secondaryText)
                }

                if let message = viewModel.transcriptionModelMessage {
                    Text(message)
                        .font(ABTypography.caption)
                        .foregroundStyle(viewModel.transcriptionModelMessageIsError ? ABDesign.red : ABDesign.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    var transcriptionTechnologyStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        transcriptionTechnologyDetailsExpanded.toggle()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "Provider technologies"))
                            .font(ABTypography.bodySemibold)
                            .foregroundStyle(ABDesign.primaryText)
                        Text(
                            viewModel.transcriptionTechnologyProviderTitle.isEmpty
                                ? String(localized: "Transcription provider")
                                : viewModel.transcriptionTechnologyProviderTitle
                        )
                        .font(ABTypography.caption)
                        .foregroundStyle(ABDesign.secondaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    viewModel.checkTranscriptionTechnologies()
                } label: {
                    if viewModel.isCheckingTranscriptionTechnologies {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(String(localized: "Checking…"))
                        }
                    } else {
                        Label(String(localized: "Check again"), systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isCheckingTranscriptionTechnologies)

                disclosureButton(isExpanded: $transcriptionTechnologyDetailsExpanded)
            }

            if transcriptionTechnologyDetailsExpanded {
                if viewModel.transcriptionTechnologyChecks.isEmpty,
                   viewModel.isCheckingTranscriptionTechnologies {
                    Text(String(localized: "Checking the technologies required by this transcription provider."))
                        .font(ABTypography.caption)
                        .foregroundStyle(ABDesign.secondaryText)
                } else {
                    VStack(spacing: 0) {
                        ForEach(viewModel.transcriptionTechnologyChecks) { check in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: technologyIcon(for: check.status))
                                    .foregroundStyle(technologyColor(for: check.status))
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(check.title)
                                            .font(ABTypography.bodyMedium)
                                            .foregroundStyle(ABDesign.primaryText)
                                        if check.isRequired {
                                            Text(String(localized: "Required"))
                                                .font(ABTypography.caption)
                                                .foregroundStyle(ABDesign.secondaryText)
                                        }
                                    }
                                    Text(check.detail)
                                        .font(ABTypography.caption)
                                        .foregroundStyle(ABDesign.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 8)

                            if check.id != viewModel.transcriptionTechnologyChecks.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                if let message = viewModel.transcriptionTechnologyMessage {
                    Text(message)
                        .font(ABTypography.captionSemibold)
                        .foregroundStyle(
                            viewModel.transcriptionTechnologyMessageIsError
                                ? ABDesign.red
                                : ABDesign.green
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func disclosureButton(isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            Image(systemName: "chevron.right")
                .font(ABTypography.captionSemibold)
                .foregroundStyle(ABDesign.secondaryText)
                .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isExpanded.wrappedValue
                ? String(localized: "Hide details")
                : String(localized: "Show details")
        )
    }

    private func technologyIcon(for status: TranscriptionTechnologyCheck.Status) -> String {
        switch status {
        case .ready:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .unavailable:
            return "xmark.circle.fill"
        }
    }

    private func technologyColor(for status: TranscriptionTechnologyCheck.Status) -> Color {
        switch status {
        case .ready:
            return ABDesign.green
        case .warning:
            return .orange
        case .unavailable:
            return ABDesign.red
        }
    }

}
