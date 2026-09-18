import AppKit
import AVFoundation
import Foundation

struct MeetingReaderContent: Sendable {
    var isImported = false
    var summary = ""
    var transcript = ""
    var technicalDetails: MeetingTechnicalDetails { MeetingTechnicalDetails(summary: summary) }
    var summaryError: String?
    var transcriptError: String?
    var summarySkipReason: SummarySkipReason?
    var hasSummaryFailure: Bool {
        MeetingTechnicalDetails.scalars(in: summary)["summary_error"] == "summary_api_failed"
    }

    func missingSummaryMessage(status: String) -> String {
        if status == "completed", let summarySkipReason { return summarySkipReason.message }
        return String(localized: "There is no saved summary for this recording. Check the processing log or use Repeat summary in the meeting menu.")
    }

    enum SummarySkipReason: Equatable, Sendable {
        case shortTranscript(words: Int, minimum: Int)
        case disabled

        var message: String {
            switch self {
            case let .shortTranscript(words, minimum):
                return String(localized: "The recording is too short for a summary: \(words) words; at least \(minimum) are required. The transcript and audio are available in their tabs.")
            case .disabled:
                return String(localized: "Automatic summary was disabled when this recording was processed. The transcript and audio are available in their tabs.")
            }
        }

        static func from(jobLog: String) -> Self? {
            // Use the latest attempt, so an earlier skip cannot hide a later failure.
            for line in jobLog.split(separator: "\n").reversed() {
                if line == "--- summarizing ---" { return nil }
                if line == "ℹ️ Summary skipped: automatic summary is disabled." { return .disabled }
                if let match = line.wholeMatch(of: /ℹ️ Summary skipped: transcript has only (\d+) words; minimum is (\d+)\./),
                   let words = Int(match.1), let minimum = Int(match.2) {
                    return .shortTranscript(words: words, minimum: minimum)
                }
            }
            return nil
        }
    }
}

/// Read-only access to meeting artifacts; the recording pipeline remains their owner.
enum MeetingReaderFiles {
    static func documents(in folder: URL, jobLogURL: URL? = nil) -> MeetingReaderContent {
        var result = MeetingReaderContent()
        result.isImported = MeetingMetadataStore.isImported(in: folder)
        for name in ["summary.md", "transcript.txt"] {
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                if name == "summary.md" { result.summary = content } else { result.transcript = content }
            } catch {
                if name == "summary.md" { result.summaryError = error.localizedDescription }
                else { result.transcriptError = error.localizedDescription }
            }
        }
        if result.summary.isEmpty, let jobLogURL,
           let log = try? String(contentsOf: jobLogURL, encoding: .utf8) {
            result.summarySkipReason = .from(jobLog: log)
        }
        return result
    }

    static func audio(in folder: URL, scratch: URL) throws -> [URL] {
        let names = ["system_audio.mp3", "microphone_audio.mp3"]
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var urls: [URL] = []
        for name in names {
            let destination = scratch.appendingPathComponent(name)
            let candidates = [folder.appendingPathComponent(name), folder.appendingPathComponent("bundle").appendingPathComponent(name)]
            if let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                try FileManager.default.copyItem(at: source, to: destination)
            } else {
                let archive = folder.appendingPathComponent("bundle.zip")
                guard FileManager.default.fileExists(atPath: archive.path) else { continue }
                // Extract only the exact member to our own file; archive paths cannot escape scratch.
                FileManager.default.createFile(atPath: destination.path, contents: nil)
                let output = try FileHandle(forWritingTo: destination)
                defer { try? output.close() }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-p", archive.path, name]
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    try? FileManager.default.removeItem(at: destination)
                    continue
                }
            }
            urls.append(destination)
        }
        return urls
    }
}

@MainActor
final class MeetingReaderModel: ObservableObject {
    @Published var content = MeetingReaderContent()
    @Published var loading = false
    @Published var audioLoading = false
    @Published var audioError: String?
    @Published var playing = false
    @Published var position: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    enum AudioSource: String, CaseIterable, Identifiable {
        case together, system, microphone
        var id: String { rawValue }
        var title: String {
            switch self {
            case .together: return String(localized: "Together")
            case .system: return String(localized: "System audio")
            case .microphone: return String(localized: "Microphone")
            }
        }
    }

    @Published private(set) var audioSources: [AudioSource] = []
    @Published private(set) var selectedAudioSource: AudioSource = .together
    private(set) var playersBySource: [AudioSource: AVAudioPlayer] = [:]
    private var players: [AVAudioPlayer] { [.system, .microphone].compactMap { playersBySource[$0] } }
    private var scratch: URL?
    private var generation = UUID()

    func load(_ meeting: DashboardViewModel.RecentMeeting, jobLogURL: URL? = nil) async {
        stop()
        let token = generation
        loading = true
        let documents = await Task.detached(priority: .userInitiated) {
            MeetingReaderFiles.documents(in: meeting.folderURL, jobLogURL: jobLogURL)
        }.value
        guard !Task.isCancelled, token == generation else { return }
        content = documents
        loading = false
    }

    func loadAudio(folder: URL) async {
        guard players.isEmpty, !audioLoading else { return }
        let token = generation
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anybrief-player-\(UUID().uuidString)")
        audioLoading = true
        audioError = nil
        do {
            let urls = try await Task.detached(priority: .userInitiated) {
                try MeetingReaderFiles.audio(in: folder, scratch: directory)
            }.value
            guard !Task.isCancelled, generation == token else {
                try? FileManager.default.removeItem(at: directory)
                return
            }
            var loaded: [AudioSource: AVAudioPlayer] = [:]
            for url in urls {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                loaded[url.lastPathComponent == "system_audio.mp3" ? .system : .microphone] = player
            }
            playersBySource = loaded
            let tracks: [AudioSource] = [.system, .microphone].filter { loaded[$0] != nil }
            audioSources = tracks.count > 1 ? [.together] + tracks : tracks
            selectAudioSource(audioSources.first ?? .together)
            scratch = directory
            duration = players.map(\.duration).max() ?? 0
            if players.isEmpty { audioError = String(localized: "Meeting audio files are missing.") }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if token == generation { audioError = error.localizedDescription }
        }
        if token == generation { audioLoading = false }
    }

    func selectAudioSource(_ source: AudioSource) {
        guard audioSources.contains(source) else { return }
        selectedAudioSource = source
        // Keep both players on the same timeline so A/B comparisons do not seek or restart.
        for (track, player) in playersBySource {
            player.volume = source == .together || source == track ? 1 : 0
        }
    }

    func togglePlayback() {
        if playing { players.forEach { $0.pause() }; playing = false; return }
        guard let first = players.first else { return }
        if position >= duration - 0.1 { seek(0) }
        let start = first.deviceCurrentTime + 0.1
        players.forEach { player in
            if player.currentTime < player.duration { player.play(atTime: start) }
        }
        playing = true
    }

    func seek(_ time: TimeInterval) {
        position = min(duration, max(0, time))
        players.forEach { $0.currentTime = min(position, $0.duration) }
    }

    func tick() {
        guard playing else { return }
        position = players.map(\.currentTime).max() ?? 0
        if !players.contains(where: \.isPlaying) { playing = false; position = duration }
    }

    func pause() { players.forEach { $0.pause() }; playing = false }

    func stop() {
        generation = UUID()
        players.forEach { $0.stop() }
        playersBySource = [:]
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        scratch = nil
        playing = false
        position = 0
        duration = 0
        audioSources = []
        selectedAudioSource = .together
        audioLoading = false
        audioError = nil
        content = MeetingReaderContent()
    }
}
