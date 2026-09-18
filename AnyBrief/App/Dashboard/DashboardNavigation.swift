import SwiftUI

extension DashboardView {
    enum Pane: String, CaseIterable, Identifiable {
        case status
        case processing
        case liveTranscript
        case notifications
        case autopilot
        case meetings
        case postProcessing
        case prompts
        case settings
        case logs
        case permissions
        case setup

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .status: return "Current recording"
            case .processing: return "Processing"
            case .liveTranscript: return "Live"
            case .notifications: return "Notifications"
            case .autopilot: return "Today"
            case .meetings: return "Meetings"
            case .postProcessing: return "Templates"
            case .prompts: return "Prompts"
            case .settings: return "Settings"
            case .logs: return "Logs"
            case .permissions: return "Permissions"
            case .setup: return "Readiness"
            }
        }

        var icon: String {
            switch self {
            case .status: return "waveform.path.ecg"
            case .processing: return "gearshape.2"
            case .liveTranscript: return "captions.bubble"
            case .notifications: return "bell.badge"
            case .autopilot: return "calendar.badge.clock"
            case .meetings: return "list.bullet.rectangle"
            case .postProcessing: return "tray.and.arrow.up"
            case .prompts: return "text.badge.star"
            case .settings: return "gearshape"
            case .logs: return "terminal"
            case .permissions: return "lock.shield"
            case .setup: return "checklist"
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
            case .export: return "Export"
            }
        }
    }

    enum SettingsCategory: String, CaseIterable, Identifiable {
        case app
        case microphone
        case transcription
        case summary
        case calendar
        case windows
        case api

        var id: String { rawValue }

        var title: String {
            switch self {
            case .summary: return String(localized: "LLM")
            case .transcription: return String(localized: "Transcription")
            case .calendar: return String(localized: "Calendar")
            case .app: return String(localized: "App")
            case .microphone: return String(localized: "Microphone")
            case .windows: return String(localized: "Windows")
            case .api: return "API"
            }
        }

        var icon: String {
            switch self {
            case .windows: return "macwindow"
            case .api: return "network"
            case .summary: return "cpu"
            case .transcription: return "waveform"
            case .calendar: return "calendar.badge.clock"
            case .app: return "app.badge"
            case .microphone: return "mic"
            }
        }
    }
}
