import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics

enum Permission: String, CaseIterable { case microphone, accessibility, inputMonitoring }

/// System Settings deep links. macOS 26 moved Privacy & Security to a new extension id.
enum SettingsLink {
    static func url(_ permission: Permission, majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> URL {
        let pane = majorVersion >= 26 ? "com.apple.settings.PrivacySecurity.extension" : "com.apple.preference.security"
        let anchor: String
        switch permission {
        case .microphone: anchor = "Privacy_Microphone"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:\(pane)?\(anchor)")!
    }
    static let soundInput = URL(string: "x-apple.systempreferences:com.apple.preference.sound?input")!
}

/// Permission state as the onboarding sees it. `inputMonitoringNeeded` is set only when the
/// engine reports that the tap failed although Accessibility is on.
struct PermissionState: Equatable {
    var microphone: AVAuthorizationStatus = .notDetermined
    var accessibility = false
    var inputMonitoringNeeded = false
    var inputMonitoring = false

    var required: [Permission] { inputMonitoringNeeded ? [.microphone, .accessibility, .inputMonitoring] : [.microphone, .accessibility] }
    func granted(_ p: Permission) -> Bool {
        switch p {
        case .microphone: return microphone == .authorized
        case .accessibility: return accessibility
        case .inputMonitoring: return inputMonitoring
        }
    }
    var allGranted: Bool { required.allSatisfy(granted) }
    /// The card to focus next: first missing permission in order.
    var nextMissing: Permission? { required.first { !granted($0) } }
}

/// Polls every second (and on app activation) while onboarding is visible, because macOS sends
/// no notification when a privacy switch changes.
@MainActor
final class PermissionMonitor: ObservableObject {
    @Published private(set) var state = PermissionState()
    /// Called once per permission when it flips to granted.
    var onGranted: ((Permission) -> Void)?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var axPrompted = false
    private let settingsOpener: (Permission) -> Void
    private(set) var waitingSince: [Permission: Date] = [:]

    init(settingsOpener: @escaping (Permission) -> Void = { NSWorkspace.shared.open(SettingsLink.url($0)) }) {
        self.settingsOpener = settingsOpener
        state = Self.read(previous: nil)
    }

    static func read(previous: PermissionState?) -> PermissionState {
        var s = previous ?? PermissionState()
        s.microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        s.accessibility = AXIsProcessTrusted()
        s.inputMonitoring = CGPreflightListenEventAccess()
        return s
    }

    func start() {
        stop()
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func refresh() {
        let old = state
        let new = Self.read(previous: old)
        guard new != old else { return }
        state = new
        for p in Permission.allCases where new.granted(p) && !old.granted(p) {
            waitingSince[p] = nil
            onGranted?(p)
        }
    }

    func markInputMonitoringNeeded() { state.inputMonitoringNeeded = true }

    /// Waiting longer than 10 s without a change → offer "open Settings again".
    func showRetry(_ p: Permission, now: Date = Date()) -> Bool {
        guard let since = waitingSince[p] else { return false }
        return now.timeIntervalSince(since) > 10
    }

    /// The retry link promises Settings, including while a first microphone prompt is pending.
    /// It must not enqueue a second system permission prompt.
    func openSettings(_ p: Permission) {
        waitingSince[p] = Date()
        settingsOpener(p)
    }

    func request(_ p: Permission) {
        waitingSince[p] = Date()
        switch p {
        case .microphone:
            if state.microphone == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in self.refresh() } }
            } else {
                settingsOpener(.microphone)
            }
        case .accessibility:
            if !axPrompted {
                // Registers the app in the Accessibility list so the user only has to flip the switch.
                axPrompted = true
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            settingsOpener(.accessibility)
            showCoach(for: .accessibility)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
            settingsOpener(.inputMonitoring)
            showCoach(for: .inputMonitoring)
        }
    }

    /// The checklist card ticks itself from the same state this monitor polls.
    private func showCoach(for permission: Permission) {
        PermissionCoach.shared.isGranted = { [weak self] in self?.state.granted($0) ?? false }
        PermissionCoach.shared.show(for: permission)
    }
}
