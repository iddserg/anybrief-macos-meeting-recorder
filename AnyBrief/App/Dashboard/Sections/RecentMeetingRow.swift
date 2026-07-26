
import SwiftUI

struct RecentMeetingsHeader: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("Title", comment: "Recent meetings table title column")
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(String(localized: "Date", comment: "Recent meetings table date column"))
                Text(String(localized: "Time", comment: "Recent meetings table time column"))
            }
            .frame(width: RecentMeetingsLayout.dateWidth, alignment: .leading)
            Rectangle()
                .fill(Color.clear)
                .frame(width: RecentMeetingsLayout.statusWidth, height: 1, alignment: .center)
                .padding(.trailing, RecentMeetingsLayout.statusActionsGap)
            Text("Actions", comment: "Recent meetings table actions column")
                .frame(width: RecentMeetingsLayout.actionsWidth, alignment: .trailing)
        }
        .font(ABTypography.bodyMedium)
        .foregroundStyle(ABDesign.primaryText)
        .frame(height: RecentMeetingsLayout.headerHeight, alignment: .center)
        .padding(.bottom, 1)
    }
}

struct RecentMeetingRow: View {
    let meeting: DashboardViewModel.RecentMeeting
    @ObservedObject var viewModel: DashboardViewModel
    @State private var titleDraft = ""
    @State private var isStatusTooltipPresented = false
    @FocusState private var titleFocused: Bool

    private var trimmedTitle: String {
        titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSaveTitle: Bool {
        !trimmedTitle.isEmpty && (trimmedTitle != meeting.title || meeting.needsFolderRename)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            titleCell
                .frame(maxWidth: .infinity, alignment: .leading)

            timestampCell
                .frame(width: RecentMeetingsLayout.dateWidth, alignment: .leading)

            statusCell
                .frame(width: RecentMeetingsLayout.statusWidth, alignment: .center)
                .padding(.trailing, RecentMeetingsLayout.statusActionsGap)

            actionsCell
                .frame(width: RecentMeetingsLayout.actionsWidth, alignment: .trailing)
        }
        .frame(height: 38)
        .onAppear {
            titleDraft = meeting.title
        }
        .onChange(of: meeting.id) { _ in
            titleDraft = meeting.title
        }
        .onChange(of: meeting.title) { newTitle in
            if !canSaveTitle {
                titleDraft = newTitle
            }
        }
    }

    private var titleCell: some View {
        HStack(spacing: 6) {
            TextField(String(localized: "Meeting title"), text: $titleDraft)
                .textFieldStyle(.plain)
                .font(ABTypography.bodySemibold)
                .focused($titleFocused)
                .onSubmit(renameTitle)
                .lineLimit(1)

            Button {
                titleFocused = true
            } label: {
                Image(systemName: "pencil")
                    .font(ABTypography.captionSemibold)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(String(localized: "Edit meeting title"))
        }
    }

    private var timestampCell: some View {
        Group {
            if let timestamp = meeting.timestamp {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.compactDateFormatter.string(from: timestamp))
                    Text(Self.compactTimeFormatter.string(from: timestamp))
                }
                .lineLimit(1)
            } else {
                Text(meeting.folderURL.lastPathComponent)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .font(ABTypography.captionMedium)
        .foregroundStyle(ABDesign.secondaryText)
    }

    private var statusCell: some View {
        Button {
            isStatusTooltipPresented.toggle()
        } label: {
            Image(systemName: statusIcon)
                .font(ABTypography.captionSemibold)
                .foregroundStyle(statusColor)
                .frame(width: RecentMeetingsLayout.statusWidth, height: 24, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(statusLabel)
        .popover(isPresented: $isStatusTooltipPresented, arrowEdge: .top) {
            Text(statusLabel)
                .font(ABTypography.tooltip)
                .foregroundStyle(ABDesign.primaryText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(width: 220, alignment: .leading)
        }
        .accessibilityLabel(Text(statusLabel))
    }

    private var actionsCell: some View {
        HStack(spacing: 6) {
            Menu {
                Button {
                    viewModel.openPrimaryMeetingDocument(meeting)
                } label: {
                    Label(primaryDocumentTitle, systemImage: "doc.text")
                }
                .disabled(!viewModel.canOpenPrimaryMeetingDocument(meeting))

                Button {
                    viewModel.openTranscript(meeting)
                } label: {
                    Label(String(localized: "Open Transcript"), systemImage: "doc.plaintext")
                }

                Button {
                    viewModel.repeatSummary(meeting)
                } label: {
                    Label(repeatSummaryTitle, systemImage: "arrow.clockwise")
                }
                .disabled(!viewModel.canRepeatSummary(meeting))

                Divider()

                Button {
                    viewModel.repeatMeetingProcessing(meeting, mode: .transcription)
                } label: {
                    Label(String(localized: "Repeat transcription"), systemImage: "waveform")
                }
                .disabled(!viewModel.canRepeatMeetingProcessing(meeting))

                Button {
                    viewModel.repeatMeetingProcessing(meeting, mode: .all)
                } label: {
                    Label(String(localized: "Repeat all"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!viewModel.canRepeatMeetingProcessing(meeting))

                if let reason = viewModel.repeatSummaryUnavailableReason(meeting),
                   !viewModel.resummarizingMeetingIds.contains(meeting.id) {
                    Text(reason)
                }
            } label: {
                Label(primaryDocumentTitle, systemImage: "doc.text")
                    .lineLimit(1)
                    .frame(width: RecentMeetingsLayout.menuLabelWidth, alignment: .leading)
            }
            .controlSize(.mini)
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)
            .font(ABTypography.bodyMedium)
            .frame(width: RecentMeetingsLayout.menuWidth)
            .disabled(
                !viewModel.canOpenPrimaryMeetingDocument(meeting)
                    && !viewModel.canRepeatSummary(meeting)
                    && !viewModel.canRepeatMeetingProcessing(meeting)
            )
            .accessibilityIdentifier("meeting.menu.\(meeting.id)")

            CompactActionButton(
                title: copyDocumentTitle,
                systemImage: "doc.on.doc",
                isEnabled: viewModel.canCopyPrimaryMeetingDocument(meeting),
                identifier: "meeting.copy.\(meeting.id)"
            ) {
                viewModel.copyPrimaryMeetingDocument(meeting)
            }

            CompactActionButton(
                title: String(localized: "Show in Finder"),
                systemImage: "folder",
                identifier: "meeting.showInFinder.\(meeting.id)"
            ) {
                viewModel.showInFinder(meeting)
            }

            CompactActionButton(
                title: String(localized: "Delete"),
                systemImage: "trash",
                isEnabled: meeting.canDelete,
                role: .destructive,
                identifier: "meeting.delete.\(meeting.id)"
            ) {
                viewModel.deleteMeeting(meeting)
            }
        }
    }

    private var statusColor: Color {
        switch displayStatus {
        case "recording":
            return ABDesign.accent
        case "completed":
            return ABDesign.green
        case "processing", "recorded":
            return ABDesign.yellow
        case "failed", "interrupted", "recording_interrupted", "cancelled":
            return ABDesign.red
        default:
            return ABDesign.secondaryText
        }
    }

    private var displayStatus: String {
        viewModel.resummarizingMeetingIds.contains(meeting.id) ? "summarizing" : meeting.status
    }

    private var statusLabel: String {
        DashboardStatusLabels.label(for: displayStatus)
    }

    private var statusIcon: String {
        switch displayStatus {
        case "recording":
            return "record.circle"
        case "completed":
            return "checkmark.circle"
        case "processing", "recorded", "summarizing":
            return "clock"
        case "failed", "interrupted", "recording_interrupted", "cancelled":
            return "exclamationmark.triangle"
        default:
            return "circle"
        }
    }

    private var repeatSummaryTitle: String {
        viewModel.resummarizingMeetingIds.contains(meeting.id)
            ? String(localized: "Repeating summarization...")
            : String(localized: "Repeat summarization")
    }

    private var primaryDocumentTitle: String {
        meeting.summaryURL == nil
            ? String(localized: "Open Transcript")
            : String(localized: "Open Summary")
    }

    private var copyDocumentTitle: String {
        meeting.summaryURL == nil
            ? String(localized: "Copy Transcript")
            : String(localized: "Copy Summary")
    }

    private func renameTitle() {
        guard canSaveTitle else { return }
        viewModel.renameMeeting(meeting, title: trimmedTitle)
        titleFocused = false
    }

    private static let compactDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()

    private static let compactTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private enum RecentMeetingsLayout {
    static let headerHeight: CGFloat = 32
    static let dateWidth: CGFloat = 86
    static let statusWidth: CGFloat = 28
    static let statusActionsGap: CGFloat = 10
    static let actionsWidth: CGFloat = 220
    static let menuWidth: CGFloat = 136
    static let menuLabelWidth: CGFloat = 122
}
