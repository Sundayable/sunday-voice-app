import AppKit
import LocalMeetingEngine
import SwiftUI

/// A separate, nonactivating panel: dictation HUD updates cannot hide a meeting recording.
@MainActor
private final class MeetingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class MeetingHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class MeetingPanelController {
    private var panel: NSPanel?
    private var resizeObserver: NSObjectProtocol?
    private(set) var anchorFrame = NSRect.zero
    var frame: NSRect? { panel?.frame }
    var contentView: NSView? { panel?.contentView }

    func show(coordinator: MeetingCoordinator, activate: Bool = false) {
        let panel: NSPanel
        if let existing = self.panel { panel = existing } else {
            panel = MeetingPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            panel.title = "Meeting transcription"
            panel.level = .statusBar
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            self.panel = panel
            resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                object: panel, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let size = self.panel?.frame.size, !self.anchorFrame.isEmpty else { return }
                        self.resize(to: size)
                    }
                }
        }
        let host = MeetingHostingView(rootView: MeetingPanelView(coordinator: coordinator))
        panel.contentView = host
        let size = host.fittingSize
        panel.setContentSize(size)
        let mouse = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        anchorFrame = screen
        panel.setFrameOrigin(Self.origin(for: size, on: screen))
        if activate {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// A started recording shows the full card briefly, then folds into the pill.
    static var recordingIntroSeconds: Double = 3
    /// Resting the pointer this long on the pill unfolds it; passing over it does not.
    static var hoverExpandSeconds: Double = 0.45

    /// Only a healthy recording folds away. Preparing, reconnecting, finishing and the
    /// "Meeting ended" countdown keep the full card.
    static func showsCompactRecording(kind: MeetingPanelKind?, phase: MeetingPhase, expanded: Bool, endingSoon: Bool = false) -> Bool {
        kind == .recording && phase == .recording && !expanded && !endingSoon
    }

    static func origin(for size: NSSize, on screen: NSRect) -> NSPoint {
        NSPoint(x: screen.minX + HUD.edgeInset, y: (screen.midY - size.height / 2).rounded())
    }

    private func resize(to size: NSSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let target = NSRect(origin: Self.origin(for: size, on: anchorFrame), size: size)
        // NSHostingView can resize its window first while preserving the top edge.
        // Re-centre even when the new size has already been applied by AppKit.
        guard abs(panel.frame.height - target.height) > 0.5 || abs(panel.frame.width - target.width) > 0.5 ||
              abs(panel.frame.minY - target.minY) > 0.5 || abs(panel.frame.minX - target.minX) > 0.5 else { return }
        panel.setFrame(target, display: true)
    }

    func hide() { panel?.orderOut(nil); panel?.contentView = nil }

    deinit { if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) } }
}

struct MeetingPanelView: View {
    @ObservedObject var coordinator: MeetingCoordinator
    @ObservedObject private var lang = UILanguageObserver.shared
    @Environment(\.colorScheme) private var scheme
    /// Each `show` builds a new view, so a re-presented recording starts with the full card again.
    @State private var introducing: Bool
    @State private var pinned = false
    @State private var hovering = false
    @State private var hoverWork: Task<Void, Never>?

    init(coordinator: MeetingCoordinator, startCompact: Bool = false) {
        self.coordinator = coordinator
        _introducing = State(initialValue: !startCompact)
    }

    private var ko: Bool { UILanguage.isKorean }

    private var compact: Bool {
        MeetingPanelController.showsCompactRecording(kind: coordinator.panelKind, phase: coordinator.phase,
                                                     expanded: introducing || pinned || hovering,
                                                     endingSoon: coordinator.autoStopDeadline != nil)
    }

    var body: some View {
        let _ = lang.revision
        // No animation: the panel resizes with its content and re-centres; a tween would drift.
        Group {
            if compact { pill } else { card }
        }
        .onHover(perform: hover)
        .task(id: coordinator.phase) {
            guard coordinator.phase == .recording, introducing else { return }
            try? await Task.sleep(for: .seconds(MeetingPanelController.recordingIntroSeconds))
            if !Task.isCancelled { introducing = false }
        }
        .padding(10)
    }

    private func hover(_ inside: Bool) {
        hoverWork?.cancel(); hoverWork = nil
        guard inside else { hovering = false; return }
        // An open card stays open while the pointer is on it, even when the intro ends.
        guard compact else { hovering = true; return }
        hoverWork = Task {
            try? await Task.sleep(for: .seconds(MeetingPanelController.hoverExpandSeconds))
            if !Task.isCancelled { hovering = true }
        }
    }

    private func collapse() {
        hoverWork?.cancel(); hoverWork = nil
        pinned = false; hovering = false; introducing = false
    }

    /// Recording at rest: dot, timer, Stop. Click (or rest the pointer) for the full card.
    private var pill: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return HStack(spacing: 10) {
            Button { pinned = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted(scheme))
                    Circle().fill(Theme.approval).frame(width: 8, height: 8)
                    Text(coordinator.elapsedLabel).font(Theme.label(13)).monospacedDigit()
                }
                .frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ko ? "미팅 녹음 중, \(coordinator.elapsedLabel)" : "Meeting recording, \(coordinator.elapsedLabel)")
            .accessibilityHint(ko ? "미팅 상세 카드를 열어요" : "Shows meeting details")
            Button(ko ? "중지" : "Stop") { Task { await coordinator.stop() } }.buttonStyle(MeetingPillButton())
                .accessibilityLabel(ko ? "미팅 녹음 중지" : "Stop meeting recording")
        }
        .padding(.leading, 12).padding(.trailing, 5)
        .frame(height: 36)
        .fixedSize()
        .background(Theme.panel(scheme), in: shape)
        .foregroundStyle(Theme.text(scheme))
        .overlay(shape.strokeBorder(Theme.rule(scheme), lineWidth: 1))
        .shadow(color: Theme.night.opacity(0.12), radius: 8, y: 3)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 7) {
                Image(systemName: "waveform").font(.system(size: 12, weight: .semibold))
                Text(verbatim: AppIdentity.name).font(Theme.text(12, medium: true))
                Spacer()
                Text(ko ? "이 MAC에서 처리" : "ON THIS MAC").font(Theme.label(9))
                if coordinator.panelKind == .recording && coordinator.phase == .recording && coordinator.autoStopDeadline == nil {
                    Button(action: collapse) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.leading, 2)
                    .accessibilityLabel(ko ? "미팅 카드 접기" : "Minimize meeting card")
                    .help(ko ? "접기" : "Minimize")
                }
            }
            .foregroundStyle(Theme.muted(scheme))
            switch coordinator.panelKind {
            case .invitation:
                Text(coordinator.scheduledMeeting != nil
                     ? (ko ? "곧 미팅이 시작돼요" : "Meeting starts soon")
                     : coordinator.suggestedApp == nil
                        ? (ko ? "미팅 녹음하기" : "Record a meeting")
                        : (ko ? "미팅이 감지됐어요" : "Meeting detected"))
                    .font(Theme.display(22))
                if let event = coordinator.scheduledMeeting {
                    Text(event.title).font(Theme.text(15, medium: true)).lineLimit(2)
                    Text(event.startsAt, style: .time).font(Theme.label(12)).foregroundStyle(Theme.muted(scheme))
                    if !event.attendees.isEmpty {
                        Text(event.attendees.joined(separator: ", ")).font(Theme.text(12))
                            .foregroundStyle(Theme.muted(scheme)).lineLimit(2)
                    }
                } else {
                    Text(coordinator.suggestedApp.map { ko ? "\($0)에서 마이크를 사용하고 있어요." : "\($0) is using the microphone." }
                         ?? (ko ? "내 마이크와 미팅 오디오를 이 Mac에 녹음하고, 끝나면 전사본을 만들어요." : "Your microphone and meeting audio, recorded on this Mac and written up afterwards."))
                        .font(Theme.text(13)).foregroundStyle(Theme.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(ko ? "녹음을 시작하기 전에 참석자들에게 먼저 알려 주세요." : "Let everyone know before you start.")
                    .font(Theme.text(11)).foregroundStyle(Theme.muted(scheme))
                if coordinator.statusMessage.hasPrefix("Finish your dictation") {
                    Text(ko ? "진행 중인 받아쓰기가 끝난 뒤 미팅을 시작해 주세요." : coordinator.statusMessage).font(Theme.text(12, medium: true))
                }
                HStack {
                    Button(ko ? "나중에" : "Not now") { coordinator.dismissSuggestion() }.buttonStyle(MeetingSecondaryButton())
                    Spacer()
                    Button(ko ? "녹음 시작" : "Start recording") { Task { await coordinator.startRecording() } }.buttonStyle(MeetingPrimaryButton())
                        .disabled(coordinator.isBusy)
                }
            case .setup:
                Text(!coordinator.needsModelSetup
                     ? (ko ? "전사 준비가 끝났어요" : "Ready to transcribe")
                     : coordinator.modelReady
                        ? (ko ? "화자 분리 모델 추가" : "Add voice separation")
                        : (ko ? "로컬 전사 모델 설정" : "Set up local transcription")).font(Theme.display(20))
                Text(!coordinator.needsModelSetup
                     ? (coordinator.autoStartEnabled
                        ? (ko ? "이 Mac에 음성 모델이 준비돼 있어요. 통화가 감지되면 자동으로 녹음하고 끝나면 전사본을 만들어요." : "The speech models are ready on this Mac. Detected calls are recorded automatically and written up afterwards.")
                        : (ko ? "이 Mac에 음성 모델이 준비돼 있어요. 시작을 누를 때만 녹음해요." : "The speech models are ready on this Mac. Recording starts only when you choose Start."))
                     : coordinator.modelReady
                        ? (ko ? "약 11 MB 모델만 한 번 받으면 전사본에 화자별로 구분돼요. 모든 처리는 이 Mac 안에서만 해요." : "One small download (about 11 MB) lets transcripts show who said what. Everything runs on this Mac.")
                        : (ko ? "음성 모델(약 660 MB)을 한 번만 받으면 돼요. 미팅은 바로 녹음되고 끝나면 이 Mac에서 전사해요." : "Download the speech models once: about 660 MB, plus space for on-device preparation. Meetings are recorded straight away and transcribed on this Mac afterwards."))
                    .font(Theme.text(13)).foregroundStyle(Theme.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(coordinator.setupStatusMessage).font(Theme.text(12))
                if coordinator.isBusy {
                    ProgressView(value: coordinator.setupProgress > 0 ? coordinator.setupProgress : nil)
                    Text(ko ? "현재 녹음 중인 미팅이 없어요." : "No meeting is being recorded.").font(Theme.label(10)).foregroundStyle(Theme.muted(scheme))
                }
                HStack {
                    Button(L("meeting.result.close")) { coordinator.dismissSuggestion() }.buttonStyle(MeetingSecondaryButton())
                    Spacer()
                    if !coordinator.needsModelSetup {
                        Button(ko ? "녹음 시작" : "Start recording") { Task { await coordinator.startRecording() } }.buttonStyle(MeetingPrimaryButton()).disabled(coordinator.isBusy)
                    } else {
                        Button(ko ? "다운로드" : "Download") { Task { await coordinator.prepareModel() } }.buttonStyle(MeetingPrimaryButton()).disabled(coordinator.isBusy)
                    }
                }
            case .recording where coordinator.autoStopDeadline != nil:
                HStack(spacing: 9) {
                    Circle().fill(Theme.approval).frame(width: 9, height: 9).accessibilityHidden(true)
                    Text(ko ? "미팅이 끝났어요" : "Meeting ended").font(Theme.display(18))
                    Spacer()
                    Text(coordinator.elapsedLabel).font(Theme.label(13)).monospacedDigit()
                }
                if let deadline = coordinator.autoStopDeadline {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let secs = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                        Text(ko ? "통화가 끝났어요. \(secs)초 뒤 녹음을 저장해요." : "The call has ended. Saving your notes in \(secs) s.")
                            .font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
                    }
                }
                HStack {
                    Button(ko ? "계속 녹음" : "Keep recording") { coordinator.keepRecording() }.buttonStyle(MeetingSecondaryButton())
                    Spacer()
                    Button(ko ? "지금 저장" : "Stop now") { Task { await coordinator.stop() } }.buttonStyle(MeetingPrimaryButton())
                }
            case .recording:
                HStack(spacing: 9) {
                    Circle().fill(coordinator.phase == .recording ? Theme.approval : Theme.slate).frame(width: 9, height: 9)
                        .accessibilityLabel(coordinator.phase == .recording ? (ko ? "녹음 중" : "Recording") : (ko ? "준비 중" : "Preparing"))
                    Text(coordinator.phase == .recovering ? (ko ? "오디오 다시 연결 중" : "Reconnecting audio")
                         : coordinator.phase == .recording ? (ko ? "미팅 녹음 중" : "Meeting recording")
                         : coordinator.phase == .finalizing ? (ko ? "녹음 저장 중" : "Saving recording")
                         : (ko ? "녹음 시작 중" : "Starting recording")).font(Theme.display(18))
                    Spacer()
                    Text(coordinator.elapsedLabel).font(Theme.label(13)).monospacedDigit()
                }
                Text(coordinator.recordingStatusMessage).font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(coordinator.phase == .recording
                         ? (ko ? "실시간 저장 중 · 통화 후 전사" : "Saved as you go · transcript after the call")
                         : (ko ? "녹음은 이 Mac에만 저장돼요" : "Your recording stays here"))
                        .font(Theme.text(11)).foregroundStyle(Theme.muted(scheme))
                    Spacer()
                    Button(ko ? "중지" : "Stop") { Task { await coordinator.stop() } }.buttonStyle(MeetingPrimaryButton())
                        .disabled(coordinator.phase == .finalizing)
                }
            case .result:
                Text(coordinator.resultTitle).font(Theme.display(22))
                Text(coordinator.resultStatusMessage).font(Theme.text(13)).foregroundStyle(Theme.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = coordinator.transcriptionDetail {
                    let summary = MeetingCoordinator.transcriptionStatusSummary(detail, isKorean: ko)
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: detail.fraction > 0 ? min(1, detail.fraction) : nil)
                            .tint(Theme.approval)
                        HStack(spacing: 8) {
                            if !summary.progressLabel.isEmpty {
                                Text(summary.progressLabel)
                                    .font(Theme.label(11)).monospacedDigit()
                                    .foregroundStyle(Theme.text(scheme))
                            }
                            Spacer(minLength: 4)
                            Text(summary.etaLabel)
                                .font(Theme.label(11))
                                .foregroundStyle(Theme.muted(scheme))
                        }
                        Text(L("meeting.result.closeAnytime"))
                            .font(Theme.text(11)).foregroundStyle(Theme.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel([summary.progressLabel, summary.etaLabel].filter { !$0.isEmpty }.joined(separator: ", "))
                }
                HStack {
                    Button(L("meeting.result.close")) { coordinator.dismissSuggestion() }.buttonStyle(MeetingSecondaryButton())
                    Spacer()
                    if case .waitingForModel = coordinator.transcription {
                        Button(L("meeting.result.setupTranscription")) { Task { await coordinator.prepareModel() } }.buttonStyle(MeetingPrimaryButton())
                    } else if coordinator.lastSavedURL != nil {
                        Button(L("meeting.result.openTranscripts")) { coordinator.openTranscripts() }.buttonStyle(MeetingPrimaryButton())
                    } else {
                        Button(L("meeting.result.settings")) { coordinator.presentSettings() }.buttonStyle(MeetingPrimaryButton())
                    }
                }
            case nil: EmptyView()
            }
        }
        .padding(20).frame(width: 360, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.panel(scheme), in: RoundedRectangle(cornerRadius: 18))
        .foregroundStyle(Theme.text(scheme))
        .tint(Theme.text(scheme))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.rule(scheme), lineWidth: 1))
        .shadow(color: Theme.night.opacity(0.12), radius: 8, y: 3)
    }
}

extension MeetingCoordinator {
    var setupStatusMessage: String {
        if phase == .preparing {
            if setupProgress >= 0.94 { return L("meeting.model.preparing") }
            if setupProgress > 0 {
                let pct = "\(Int((min(1, max(0, setupProgress)) * 100).rounded()))"
                return L("meeting.model.progress", pct)
            }
            return L("meeting.model.downloading")
        }
        if phase == .failed {
            if statusMessage.localizedCaseInsensitiveContains("disk space") {
                return L("meeting.model.lowDisk")
            }
            if statusMessage.localizedCaseInsensitiveContains("model") {
                return L("meeting.model.failed")
            }
            return statusMessage
        }
        if !needsModelSetup { return L("meeting.model.ready") }
        return statusMessage
    }

    var recordingStatusMessage: String {
        guard UILanguage.isKorean else { return statusMessage }
        switch statusMessage {
        case "Recording on this Mac — microphone + Mac audio": return "이 Mac에서 녹음 중이에요 (마이크 + Mac 오디오)"
        case "Starting the recording…": return "녹음을 시작하고 있어요…"
        case "Saving the recording…": return "녹음을 저장하고 있어요…"
        default: return statusMessage
        }
    }
    /// The recording is safe as soon as capture ends; the title follows the transcript from there.
    var resultTitle: String {
        if phase == .failed { return L("meeting.result.needsAttention") }
        switch transcription {
        case .running: return autoStopped ? L("meeting.result.callEndedSaved") : L("meeting.result.saved")
        case .waitingForModel: return L("meeting.result.saved")
        case .failed: return L("meeting.result.delayed")
        case .idle: return autoStopped ? L("meeting.result.callEndedFinished") : L("meeting.result.finished")
        }
    }

    /// Localized subtitle for the result panel; preserves specific engine error messages verbatim.
    var resultStatusMessage: String {
        guard phase != .failed else { return statusMessage }
        switch transcription {
        case .running:
            return L("meeting.result.transcribing")
        case .waitingForModel:
            return L("meeting.result.waitingForModel")
        case .idle where statusMessage == "Transcript ready on this Mac.":
            return L("meeting.result.ready")
        case .idle where statusMessage == "Transcript saved. No speech was detected.":
            return L("meeting.result.noSpeech")
        default:
            return statusMessage
        }
    }
}

struct MeetingSettingsView: View {
    @ObservedObject var coordinator: MeetingCoordinator
    @ObservedObject private var lang = UILanguageObserver.shared
    var isGuest = false
    var googleCalendarAllowed: Bool? = nil
    @Environment(\.colorScheme) private var scheme
    private var ko: Bool { UILanguage.isKorean }
    private var canUseGoogleCalendar: Bool { googleCalendarAllowed ?? !isGuest }

    var body: some View {
        let _ = lang.revision
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(ko ? "미팅" : "Meetings").font(Theme.display(25))
                Text(ko ? "이 Mac에서 녹음하고, 화자별로 구분된 전사본을 만들어요." : "Recorded on this Mac, then written up with who said what.")
                    .font(Theme.text(13)).foregroundStyle(Theme.muted(scheme))
                HStack(spacing: 10) {
                    Button(coordinator.isBusy ? (ko ? "진행 중인 미팅 보기" : "Show meeting") : (ko ? "미팅 시작하기" : "Start a meeting")) { coordinator.presentManualStart() }
                        .buttonStyle(MeetingPrimaryButton())
                    Button(L("meeting.result.openTranscripts")) { coordinator.openTranscripts() }.buttonStyle(MeetingSecondaryButton())
                }.padding(.top, 6)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: coordinator.needsModelSetup ? "arrow.down.circle" : "checkmark.circle.fill")
                        .foregroundStyle(coordinator.needsModelSetup ? Theme.muted(scheme) : Theme.approval)
                    Text(!coordinator.needsModelSetup
                         ? (ko ? "음성 모델 준비됨" : "Speech models ready")
                         : coordinator.modelReady
                            ? (ko ? "화자 분리 모델 미설치" : "Voice separation not downloaded")
                            : (ko ? "음성 모델 미설치" : "Speech models not downloaded"))
                        .font(Theme.display(16, semibold: true))
                }
                MeetingTranscriptionStatus(coordinator: coordinator)
                Text(coordinator.microphoneAccessGranted && coordinator.systemAudioAccessGranted
                     ? (ko ? "마이크와 시스템 오디오 권한이 허용돼 있어요." : "Microphone and system audio access allowed.")
                     : (ko ? "녹음하려면 마이크와 시스템 오디오 권한이 필요해요." : "Microphone and system audio access are needed to record."))
                    .font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
                Rectangle().fill(Theme.rule(scheme)).frame(height: 1)
                SettingsToggleRow(title: ko ? "통화 감지 시 자동으로 녹음 시작" : "Start recording automatically when a call is detected",
                                  isOn: $coordinator.autoStartEnabled)
                SettingsToggleRow(title: ko ? "Meet·Zoom·Teams·Slack 통화 종료 시 자동 저장" : "Stop and save when a Meet, Zoom, Teams or Slack call ends",
                                  isOn: $coordinator.autoStopEnabled)
                SettingsToggleRow(title: ko ? "미팅 오디오 30일 보관" : "Keep meeting audio for 30 days",
                                  isOn: $coordinator.keepAudioEnabled)
                if coordinator.needsModelSetup {
                    Text(coordinator.modelReady
                         ? (ko ? "화자 분리 모델 · 약 11 MB. 설치하지 않으면 '나'와 '미팅 오디오'로만 표시돼요." : "Voice separation · about 11 MB. Without it transcripts show only You and Meeting audio.")
                         : (ko ? "Whisper large-v3-turbo + 화자 분리 · 약 660 MB. 모델이 없어도 녹음은 먼저 저장할 수 있어요." : "Whisper large-v3 turbo + voice separation · about 660 MB download, plus preparation space. Meetings are still recorded without it."))
                        .font(Theme.text(11)).foregroundStyle(Theme.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if coordinator.phase == .preparing && coordinator.needsModelSetup {
                    ProgressView(value: coordinator.setupProgress > 0 ? coordinator.setupProgress : nil)
                }
                if coordinator.needsModelSetup {
                    Button(coordinator.modelReady ? (ko ? "화자 분리 모델 다운로드" : "Download voice separation") : (ko ? "모델 다운로드" : "Download models")) { Task { await coordinator.prepareModel() } }
                        .buttonStyle(MeetingPrimaryButton()).disabled(coordinator.isBusy)
                }
                if !coordinator.microphoneAccessGranted || !coordinator.systemAudioAccessGranted {
                    Text(ko ? "macOS 안내가 뜨면 시스템 설정 → 개인정보 보호 및 보안에서 Sunday Voice를 허용해 주세요." : "Allow Sunday Voice in System Settings → Privacy & Security when macOS asks.")
                        .font(Theme.text(11)).foregroundStyle(Theme.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.modifier(MeetingSettingsCard())
            if canUseGoogleCalendar {
                GoogleCalendarSettingsView(calendar: coordinator.googleCalendar).modifier(MeetingSettingsCard())
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Google Calendar").font(Theme.display(16, semibold: true))
                        ModeBadge(kind: .proComingSoon)
                    }
                    Text(verbatim: L("settings.calendar.comingSoonBody"))
                        .font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .modifier(MeetingSettingsCard())
            }
            DisclosureGroup(ko ? "기타 미팅 감지 방식" : "Other ways to detect meetings") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsToggleRow(title: ko ? "미팅 앱이 마이크를 쓰면 녹음 제안하기" : "Suggest when a meeting uses the microphone",
                                      isOn: $coordinator.detectionEnabled)
                    SettingsToggleRow(title: ko ? "macOS 캘린더를 보조로 사용" : "Use macOS Calendar as a fallback",
                                      isOn: $coordinator.calendarEnabled)
                    Text(coordinator.calendarStatus).font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
                    Text(ko ? "Google 캘린더가 연결되지 않았을 때만 macOS 캘린더를 써요. '전체 접근' 권한은 일정을 읽는 데만 사용해요." : "macOS Calendar is used when Google is disconnected. Its ‘Full Access’ permission is used only to read events.")
                        .font(Theme.text(11)).foregroundStyle(Theme.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Button(ko ? "macOS 캘린더 권한 허용" : "Allow macOS Calendar access") { Task { await coordinator.connectCalendar() } }
                        .buttonStyle(MeetingSecondaryButton())
                }.font(Theme.text(12)).padding(.top, 12)
            }.font(Theme.text(13, medium: true)).tint(Theme.text(scheme))
            VStack(alignment: .leading, spacing: 7) {
                Text(ko ? "오디오와 전사본은 모두 이 Mac에만 남아요. 미팅이 진행되는 동안만 녹음하고, 끝나면 로컬에서 전사한 뒤 보관 옵션을 켜지 않았으면 오디오는 자동으로 삭제해요." : "Audio and transcripts stay on this Mac. A meeting is only recorded while it runs; the transcript is written afterwards, and the audio is removed once it exists unless you keep it.")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(ko ? "화자는 자동으로 구분되지만 실명은 붙이지 않아요. macOS 15 이상이 필요해요." : "Voices are separated automatically, not named. Requires macOS 15 or later.")
                    .font(Theme.text(11)).foregroundStyle(Theme.muted(scheme))
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .foregroundStyle(Theme.text(scheme))
        .background(Theme.ground(scheme))
        .tint(Theme.approval)
        .onAppear { coordinator.refreshPermissions() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            coordinator.refreshPermissions()
        }
    }
}

/// One quiet line about saved recordings that are still waiting for, or getting, their transcript.
private struct MeetingTranscriptionStatus: View {
    @ObservedObject var coordinator: MeetingCoordinator
    @Environment(\.colorScheme) private var scheme
    private var ko: Bool { UILanguage.isKorean }

    var body: some View {
        switch coordinator.transcription {
        case .idle:
            EmptyView()
        case .running(let progress, let pending, let detail):
            let current = detail ?? MeetingTranscriptionProgress(fraction: progress)
            let summary = MeetingCoordinator.transcriptionStatusSummary(current, isKorean: ko)
            VStack(alignment: .leading, spacing: 6) {
                Text(pending > 1
                     ? (ko ? "전사본 작성 중 · \(pending)개 남음" : "Writing transcripts · \(pending) recordings left")
                     : L("meeting.result.transcribing"))
                    .font(Theme.text(12, medium: true))
                ProgressView(value: current.fraction > 0 ? min(1, current.fraction) : nil)
                HStack(spacing: 8) {
                    if !summary.progressLabel.isEmpty {
                        Text(summary.progressLabel)
                            .font(Theme.label(10)).monospacedDigit()
                            .foregroundStyle(Theme.text(scheme))
                    }
                    Spacer(minLength: 4)
                    Text(summary.etaLabel)
                        .font(Theme.label(10))
                        .foregroundStyle(Theme.muted(scheme))
                }
            }
        case .waitingForModel(let pending):
            Text(ko ? "저장된 녹음 \(pending)개가 있어요. 음성 모델을 다운로드하면 바로 전사해요." : "\(pending) saved recording\(pending == 1 ? "" : "s") will be transcribed once the speech models are downloaded.")
                .font(Theme.text(12, medium: true))
        case .failed(let pending):
            Text(ko ? "전사하지 못한 녹음이 \(pending)개 있어요. 오디오는 안전하게 보관되며 \(AppIdentity.name)를 다시 열면 재시도해요." : "\(pending) transcript\(pending == 1 ? "" : "s") could not be written. The audio is kept and tried again the next time \(AppIdentity.name) opens.")
                .font(Theme.text(12, medium: true))
        }
    }
}

private struct GoogleCalendarSettingsView: View {
    @ObservedObject var calendar: GoogleMeetingCalendar
    @Environment(\.colorScheme) private var scheme
    private var ko: Bool { UILanguage.isKorean }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Google Calendar").font(Theme.display(16, semibold: true))
            Text(ko ? "화상 미팅 시작 2분 전에 녹음 시작 카드를 띄워 드려요." : "Get a start card two minutes before a video meeting.")
                .font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
            if let account = calendar.account {
                Text(account.email).font(Theme.text(12, medium: true))
                SettingsToggleRow(title: ko ? "선택한 캘린더의 미팅 제안하기" : "Suggest meetings from selected calendars",
                                  isOn: $calendar.enabled)
                DisclosureGroup(ko ? "캘린더 · \(calendar.selectedIDs.count)개 선택됨" : "Calendars · \(calendar.selectedIDs.count) selected") {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(calendar.calendars) { choice in
                            Toggle(isOn: Binding(get: { calendar.selectedIDs.contains(choice.id) },
                                set: { calendar.select(choice.id, enabled: $0) })) {
                                Text(choice.name + (choice.primary == true ? (ko ? " · 기본" : " · Primary") : ""))
                                    .font(Theme.text(12)).lineLimit(2)
                            }.toggleStyle(.checkbox).disabled(calendar.connecting)
                        }
                    }.padding(.top, 9)
                }.font(Theme.text(12, medium: true)).tint(Theme.text(scheme))
                if calendar.lastSynced != nil {
                    Text(ko ? "캘린더 \(calendar.calendars.count)개 · 앞으로 7일간 화상 미팅 \(calendar.upcomingMeetingCount)건" : "\(calendar.calendars.count) calendars · \(calendar.upcomingMeetingCount) video meetings in the next seven days")
                        .font(Theme.label(10)).foregroundStyle(Theme.muted(scheme))
                }
            }
            Text(calendar.status == "Connect Google Calendar to choose your calendars." && ko
                 ? "Google 캘린더를 연결하면 원하는 캘린더를 고를 수 있어요."
                 : calendar.status)
                .font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
            if let lastSynced = calendar.lastSynced {
                HStack(spacing: 4) {
                    Text(ko ? "마지막 동기화" : "Last synced")
                    Text(lastSynced, style: .time)
                }.font(Theme.label(10)).foregroundStyle(Theme.muted(scheme))
            }
            HStack(spacing: 10) {
                if calendar.account == nil || calendar.needsConsent {
                    Button(calendar.connecting ? (ko ? "연결 중…" : "Connecting…")
                           : calendar.needsConsent ? (ko ? "Google 캘린더 다시 연결" : "Reconnect Google Calendar")
                           : (ko ? "Google 캘린더 연결" : "Connect Google Calendar")) {
                        Task { await calendar.connect() }
                    }.buttonStyle(MeetingSecondaryButton()).disabled(calendar.connecting || calendar.busy)
                } else {
                    Button(calendar.busy ? (ko ? "동기화 중…" : "Syncing…") : (ko ? "지금 동기화" : "Sync now")) { Task { await calendar.refresh() } }
                        .buttonStyle(MeetingSecondaryButton()).disabled(calendar.busy || !calendar.enabled || calendar.connecting)
                }
                if calendar.account != nil {
                    Button(ko ? "연결 해제" : "Disconnect") { calendar.disconnect() }.buttonStyle(MeetingSecondaryButton()).disabled(calendar.connecting)
                }
            }
            Text(ko ? "읽기 전용 · Google 계정 1개에서 여러 캘린더를 선택할 수 있어요." : "Read-only · One Google account, multiple calendars.")
                .font(Theme.text(11)).foregroundStyle(Theme.muted(scheme))
        }
    }
}

private struct MeetingSettingsCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Theme.panel(scheme), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.rule(scheme), lineWidth: 1))
    }
}

private struct MeetingPrimaryButton: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Theme.display(13, semibold: true)).padding(.horizontal, 14).padding(.vertical, 9)
            .foregroundStyle(Theme.onStructure(scheme)).background(Theme.structure(scheme), in: RoundedRectangle(cornerRadius: 8))
            .opacity(!enabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
    }
}

private struct MeetingPillButton: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Theme.display(12, semibold: true)).padding(.horizontal, 12).frame(height: 26)
            .foregroundStyle(Theme.onStructure(scheme)).background(Theme.structure(scheme), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct MeetingSecondaryButton: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Theme.display(13, semibold: true)).padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(Theme.text(scheme)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.rule(scheme), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}
