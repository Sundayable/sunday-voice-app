import Foundation
import LocalMeetingEngine

/// A command-line diagnostic only. It neither launches the app nor records a microphone.
/// It runs the same offline pass a finished meeting gets, on local audio files.
@main
struct MeetingEngineCheck {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        func value(_ key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let service = LocalMeetingService(
            transcriptDirectory: value("--output-directory").map { URL(fileURLWithPath: $0, isDirectory: true) },
            modelDirectory: value("--model-directory").map { URL(fileURLWithPath: $0, isDirectory: true) },
            workDirectory: value("--work-directory").map { URL(fileURLWithPath: $0, isDirectory: true) })
        service.keepsAudio = arguments.contains("--keep-audio")
        do {
            if arguments.contains("--prepare") {
                try await service.prepareModel()
                print("MODEL_READY=\(service.modelReady)")
                print("SPEAKER_MODEL_READY=\(service.speakerModelReady)")
            }
            if arguments.contains("--resume") {
                // Transcribes recordings left in the work directory, exactly as the app does at launch.
                print("PENDING=\(service.pendingTranscriptionCount)")
                service.resumePendingTranscriptions()
                await service.waitForTranscription()
                print("PENDING_AFTER=\(service.pendingTranscriptionCount)")
                print("LAST_TRANSCRIPT=\(service.lastTranscriptURL?.path ?? "none")")
            }
            var system = value("--transcribe") ?? value("--system")
            var microphone = value("--microphone")
            if value("--source") == "microphone", microphone == nil { microphone = system; system = nil }
            if system != nil || microphone != nil {
                let started = Date()
                let result = try await service.transcribeRecording(microphone: microphone.map { URL(fileURLWithPath: $0) },
                                                                   system: system.map { URL(fileURLWithPath: $0) })
                let seconds = Date().timeIntervalSince(started)
                print("LOCAL_TRANSCRIBE_OK=\(service.phase == .idle)")
                print("SEGMENT_COUNT=\(service.segments.count)")
                print("SPEAKERS=\(Set(service.segments.map(\.speakerLabel)).sorted().joined(separator: "|"))")
                print("AUDIO_SECONDS=\(Int(service.elapsedSeconds))")
                print(String(format: "PROCESSING_SECONDS=%.1f", seconds))
                if service.elapsedSeconds > 0 { print(String(format: "SPEED=%.1fx", service.elapsedSeconds / seconds)) }
                print("TRANSCRIPT_FILE=\(result.path)")
                if let expected = value("--expected") {
                    let text = service.segments.map(\.text).joined(separator: " ")
                    let matches = text.localizedCaseInsensitiveContains(expected)
                    print("EXPECTED_TEXT_MATCH=\(matches)")
                    if !matches { exit(2) }
                }
                if service.phase != .idle { exit(1) }
            } else if !arguments.contains("--prepare") && !arguments.contains("--resume") {
                print("Use --prepare for an explicit model download, --system/--microphone <local audio file> for offline transcription, or --resume for saved recordings.")
                print("MODEL_READY=\(service.modelReady)")
                print("SPEAKER_MODEL_READY=\(service.speakerModelReady)")
            }
        } catch {
            // Never print dependency errors, file contents, or transcript text.
            print("MEETING_CHECK_FAILED=\(service.statusMessage)")
            exit(1)
        }
    }
}
