import AppKit
import AppIntents
import Combine
import Foundation

/// Feature availability and public action constants for Phase 1 hands-free dictation
/// via Apple Vocal Shortcuts (macOS 15+ on Apple Silicon; hidden on macOS 14 and Intel Macs).
enum HandsFreeSupport {
    static let suggestedPhrases: [String] = ["Hey Sunday", "헤이 선데이"]

    static var currentIsAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Apple Vocal Shortcuts requires macOS Sequoia 15+ on Apple Silicon.
    static func isAvailable(
        majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        isAppleSilicon: Bool = Self.currentIsAppleSilicon
    ) -> Bool {
        isAppleSilicon && majorVersion >= 15
    }

    /// Public URL action that starts hands-free dictation at the current cursor (no personal targets).
    static var cursorWakeURL: URL {
        URL(string: "\(AppIdentity.urlScheme)://wake/cursor")!
    }

    static var cursorWakeURLString: String {
        cursorWakeURL.absoluteString
    }

    /// Returns true if the URL targets the public cursor hands-free action (`<scheme>://wake/cursor`).
    static func isCursorWakeURL(_ url: URL) -> Bool {
        guard url.host?.lowercased() == "wake" else { return false }
        let slug = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return slug == "cursor"
    }
}

/// Coordinates public cursor hands-free triggers (App Intent, `<scheme>://wake/cursor`, and Settings "Test it")
/// without any hard-coded personal targets.
@MainActor
final class HandsFreeCursorBridge: ObservableObject {
    static let shared = HandsFreeCursorBridge()

    @Published private(set) var lastTriggeredAt: Date?
    @Published private(set) var lastTriggerSource: String?
    @Published var isTestArmed = false
    @Published var testTranscript = ""

    /// Wired by `AppDelegate` to start/stop cursor dictation on the live `WakeController`.
    var onTrigger: ((String) -> Void)?

    func trigger(source: String) {
        recordTrigger(source: source)
        onTrigger?(source)
    }

    func recordTrigger(source: String) {
        lastTriggeredAt = Date()
        lastTriggerSource = source
    }

    func receiveTestText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if testTranscript.isEmpty {
            testTranscript = trimmed
        } else {
            let sep = (testTranscript.hasSuffix(" ") || testTranscript.hasSuffix("\n")) ? "" : " "
            testTranscript += sep + trimmed
        }
    }

    func resetTest() {
        testTranscript = ""
        lastTriggeredAt = nil
        lastTriggerSource = nil
    }
}

/// Public App Intent exposed to Apple Vocal Shortcuts and the Shortcuts app.
/// Starts hands-free dictation at the current cursor without stealing app focus or using personal targets.
struct StartDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Dictation"
    static var description = IntentDescription(
        "Start hands-free dictation at your current cursor with Sunday Voice."
    )
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        HandsFreeCursorBridge.shared.trigger(source: "app_intent")
        return .result()
    }
}

/// Exposes the public "Start Dictation" action to macOS Shortcuts & Apple Vocal Shortcuts.
struct SundayVoiceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: [
                "Start dictation with \(.applicationName)",
                "Dictate with \(.applicationName)",
            ],
            shortTitle: "Start Dictation",
            systemImageName: "mic.fill"
        )
    }
}
