import AppKit
import SwiftUI

extension DashboardView {
    private var liveTranscriptColumnDividerWidth: CGFloat { 12 }

    var liveTranscriptSection: some View {
        sectionCard(fillsHeight: true) {
            VStack(alignment: .leading, spacing: 12) {
                liveTranscriptHeader

                GeometryReader { proxy in
                    liveTranscriptSplitLayout(size: proxy.size)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            viewModel.setLiveTranscriptVisible(true)
            liveTranscriptDisplayState.applyIncomingText(viewModel.liveTranscriptSnapshot.text)
        }
        .onDisappear {
            viewModel.setLiveTranscriptVisible(false)
            viewModel.cancelLiveTranscriptPromptProcessing()
        }
        .onChange(of: viewModel.liveTranscriptSnapshot.text) { newText in
            liveTranscriptDisplayState.applyIncomingText(newText)
            viewModel.processLiveTranscriptPromptIfAutoEnabled()
        }
        .onChange(of: viewModel.liveTranscriptPrompt) { _ in
            viewModel.processLiveTranscriptPromptIfAutoEnabled()
        }
        .onChange(of: viewModel.liveTranscriptAutoProcessEnabled) { enabled in
            if enabled {
                viewModel.processLiveTranscriptPromptIfAutoEnabled()
            } else {
                viewModel.cancelLiveTranscriptPromptProcessing()
            }
        }
        .onReceive(liveTranscriptCountdownTimer) { date in
            liveTranscriptStatusNow = date
        }
    }

    private func liveTranscriptSplitLayout(size: CGSize) -> some View {
        let widths = liveTranscriptColumnWidths(totalWidth: size.width)

        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                liveTranscriptPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                liveTranscriptPromptPane
                    .frame(maxWidth: .infinity)
            }
            .frame(width: widths.left, height: size.height, alignment: .topLeading)

            liveTranscriptColumnDivider(totalWidth: size.width)
                .frame(width: liveTranscriptColumnDividerWidth, height: size.height)

            liveTranscriptOutputPane
                .frame(width: widths.right, height: size.height, alignment: .topLeading)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func liveTranscriptColumnWidths(totalWidth: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let contentWidth = max(0, totalWidth - liveTranscriptColumnDividerWidth)
        let minimumColumnWidth = min(300, contentWidth / 2)
        let maximumLeftWidth = max(minimumColumnWidth, contentWidth - minimumColumnWidth)
        let desiredLeftWidth = contentWidth * liveTranscriptLeftColumnFraction
        let leftWidth = min(max(desiredLeftWidth, minimumColumnWidth), maximumLeftWidth)

        return (leftWidth, max(0, contentWidth - leftWidth))
    }

    private func liveTranscriptColumnDivider(totalWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.black.opacity(0.16))
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
            .onHover { isHovering in
                if isHovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if liveTranscriptColumnDragStartFraction == nil {
                            liveTranscriptColumnDragStartFraction = liveTranscriptLeftColumnFraction
                        }

                        let contentWidth = max(1, totalWidth - liveTranscriptColumnDividerWidth)
                        let minimumColumnWidth = min(300, contentWidth / 2)
                        let maximumLeftWidth = max(minimumColumnWidth, contentWidth - minimumColumnWidth)
                        let startLeftWidth = (liveTranscriptColumnDragStartFraction ?? liveTranscriptLeftColumnFraction) * contentWidth
                        let proposedLeftWidth = startLeftWidth + value.translation.width
                        let leftWidth = min(max(proposedLeftWidth, minimumColumnWidth), maximumLeftWidth)

                        liveTranscriptLeftColumnFraction = leftWidth / contentWidth
                    }
                    .onEnded { _ in
                        liveTranscriptColumnDragStartFraction = nil
                    }
            )
            .accessibilityLabel(Text("Resize transcript and output columns"))
    }

    private var liveTranscriptHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Live transcript")
                    .font(ABTypography.sectionTitle)
                    .foregroundStyle(ABDesign.primaryText)
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.liveTranscriptStatusColor)
                        .frame(width: 7, height: 7)
                    Text(viewModel.liveTranscriptStatusText(now: liveTranscriptStatusNow))
                        .font(ABTypography.captionMedium)
                        .foregroundStyle(ABDesign.secondaryText)
                }
            }

            Spacer()

            Button {
                viewModel.clearLiveTranscript()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "trash")
                        .font(ABTypography.captionSemibold)
                    Text("Clear")
                        .font(ABTypography.bodyMedium)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.canClearLiveTranscript ? ABDesign.primaryText : ABDesign.disabledText)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(ABDesign.hairline, lineWidth: 1)
                    )
            )
            .disabled(!viewModel.canClearLiveTranscript)

            Button {
                viewModel.toggleLiveTranscript()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: viewModel.liveTranscriptSnapshot.isUserEnabled ? "stop.fill" : "play.fill")
                        .font(ABTypography.captionSemibold)
                    Text(viewModel.liveTranscriptSnapshot.isUserEnabled ? "Stop live transcript" : "Start live transcript")
                        .font(ABTypography.bodyMedium)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.liveTranscriptSnapshot.isUserEnabled ? ABDesign.red : .white)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(viewModel.liveTranscriptSnapshot.isUserEnabled ? Color.black.opacity(0.04) : ABDesign.accent)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(viewModel.liveTranscriptSnapshot.isUserEnabled ? ABDesign.hairline : Color.clear, lineWidth: 1)
                    )
            )
        }
    }

    private var liveTranscriptPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript")
                .font(ABTypography.itemTitle)
                .foregroundStyle(ABDesign.primaryText)

            SelectableLiveTranscriptTextView(
                text: liveTranscriptDisplayState.visibleText,
                placeholder: viewModel.liveTranscriptPlaceholder,
                onUserInteractionChanged: { isActive in
                    liveTranscriptDisplayState.setUserInteractionActive(isActive)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ABDesign.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black.opacity(0.16), lineWidth: 1)
            )
        }
    }

    private var liveTranscriptSettingsPane: some View {
        DisclosureGroup(isExpanded: $liveSettingsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                labeledField(
                    String(localized: "Live connection"),
                    help: String(localized: "Auto tries enabled connections top to bottom in their LLM tab order. Pick a specific connection to always use only that one.")
                ) {
                    connectionPicker(selection: $viewModel.liveConnectionID)
                }

                labeledField(
                    String(localized: "Live prompt"),
                    help: String(localized: "Prefills the prompt editor below.")
                ) {
                    promptPicker(selection: $viewModel.livePromptID, allowsNone: true)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                    .font(ABTypography.captionSemibold)
                Text(String(localized: "Live settings"))
                    .font(ABTypography.bodySemibold)
                    .foregroundStyle(ABDesign.primaryText)
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var liveTranscriptPromptPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            liveTranscriptSettingsPane

            HStack(spacing: 10) {
                Text("Prompt")
                    .font(ABTypography.itemTitle)
                    .foregroundStyle(ABDesign.primaryText)

                Spacer()

                Toggle(isOn: $viewModel.liveTranscriptAutoProcessEnabled) {
                    Text("Auto process")
                        .font(ABTypography.captionMedium)
                }
                .toggleStyle(.checkbox)

                Button {
                    viewModel.processLiveTranscriptPrompt()
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.isProcessingLiveTranscriptPrompt {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "sparkles")
                                .font(ABTypography.captionSemibold)
                        }
                        Text(viewModel.isProcessingLiveTranscriptPrompt ? "Processing" : "Process via LLM")
                            .font(ABTypography.captionSemibold)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(viewModel.canProcessLiveTranscriptPrompt ? .white : ABDesign.disabledText)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(viewModel.canProcessLiveTranscriptPrompt ? ABDesign.accent : Color.black.opacity(0.04))
                )
                .disabled(!viewModel.canProcessLiveTranscriptPrompt)
            }

            TextEditor(text: $viewModel.liveTranscriptPrompt)
                .font(ABTypography.field)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 126, maxHeight: 170)
                .background(Color.white.opacity(0.86))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.black.opacity(0.16), lineWidth: 1)
                )

            if let message = viewModel.liveTranscriptPromptMessage {
                Text(message)
                    .font(ABTypography.caption)
                    .foregroundStyle(viewModel.liveTranscriptPromptMessageIsError ? ABDesign.red : ABDesign.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var liveTranscriptOutputPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LLM output")
                .font(ABTypography.itemTitle)
                .foregroundStyle(ABDesign.primaryText)

            SelectableLiveTranscriptTextView(
                text: viewModel.liveTranscriptLLMOutput,
                placeholder: viewModel.liveTranscriptLLMPlaceholder,
                rendering: .markdown,
                onUserInteractionChanged: { _ in }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ABDesign.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black.opacity(0.16), lineWidth: 1)
            )
        }
    }
}
