import SwiftUI

extension DashboardView {
    enum Pane: String, CaseIterable, Identifiable {
        case status
        case liveTranscript
        case notifications
        case autopilot
        case meetings
        case postProcessing
        case prompts
        case settings
        case logs
        case permissions

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .status: return "Status"
            case .liveTranscript: return "Live"
            case .notifications: return "Notifications"
            case .autopilot: return "Autopilot"
            case .meetings: return "Meetings"
            case .postProcessing: return "Post-processing"
            case .prompts: return "Prompts"
            case .settings: return "Settings"
            case .logs: return "Logs"
            case .permissions: return "Permissions"
            }
        }

        var icon: String {
            switch self {
            case .status: return "waveform.path.ecg"
            case .liveTranscript: return "captions.bubble"
            case .notifications: return "bell.badge"
            case .autopilot: return "calendar.badge.clock"
            case .meetings: return "list.bullet.rectangle"
            case .postProcessing: return "tray.and.arrow.up"
            case .prompts: return "text.badge.star"
            case .settings: return "gearshape"
            case .logs: return "terminal"
            case .permissions: return "lock.shield"
            }
        }
    }

    enum PostProcessingTab: String, CaseIterable, Identifiable {
        case summary
        case transcript
        case export

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .summary: return "Summary"
            case .transcript: return "Transcript"
            case .export: return "Summary export"
            }
        }
    }

    enum SettingsCategory: String, CaseIterable, Identifiable {
        case summary
        case transcription
        case calendar
        case app
        case automation

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .summary: return "LLM"
            case .transcription: return "Transcription"
            case .calendar: return "Calendar"
            case .app: return "App"
            case .automation: return "Automation"
            }
        }

        var icon: String {
            switch self {
            case .automation: return "bolt.badge.automatic"
            case .summary: return "cpu"
            case .transcription: return "waveform"
            case .calendar: return "calendar.badge.clock"
            case .app: return "app.badge"
            }
        }
    }
}
