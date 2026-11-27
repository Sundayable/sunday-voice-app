import AppKit
import AVFoundation
import CoreGraphics
import Combine
import LocalMeetingEngine
import OSLog
import SwiftUI

@MainActor
protocol MeetingServiceProviding: AnyObject {
    var recordingContext: RecordingMeetingContext? { get set }
    var phase: MeetingPhase { get }
    var statusMessage: String { get }
    var segments: [MeetingSegment] { get }
    var elapsedSeconds: TimeInterval { get }
    var modelReady: Bool { get }
    var lastSavedURL: URL? { get }
    var setupProgress: Double { get }
    var captureWarning: String? { get }
    var transcription: MeetingTranscriptionState { get }
    var speakerModelReady: Bool { get }
    var lastTranscriptURL: URL? { get }
    var keepsAudio: Bool { get set }
    var transcriptDirectory: URL { get }
    var meetingChanges: AnyPublisher<Void, Never> { get }
    func prepareModel() async throws
    func start() async throws
    func stop() async
    func resumePendingTranscriptions()
    func cancelTranscription()
}

extension LocalMeetingService: MeetingServiceProviding {
    var meetingChanges: AnyPublisher<Void, Never> { objectWillChange.eraseToAnyPublisher() }
}

enum MeetingPanelKind: Equatable {
    case invitation, setup, recording, result
}

/// Owns user intent and the meeting UI. Detection starts capture only with auto-start enabled;
/// calendar reminders alone never start capture.
/// A meeting is only recorded while it runs; its transcript is written afterwards. Dictation gets the
/// microphone back as soon as the recording is saved, without waiting for the transcript.
@MainActor
final class MeetingCoordinator: ObservableObject {
    @Published private(set) var phase: MeetingPhase = .idle
    @Published private(set) var statusMessage = "Meeting recordings stay on this Mac."
    @Published private(set) var segments: [MeetingSegment] = []
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var modelReady = false
    @Published private(set) var speakerModelReady = false
    @Published private(set) var transcription: MeetingTranscriptionState = .idle
    @Published private(set) var lastSavedURL: URL?
    @Published private(set) var setupProgress: Double = 0
    @Published private(set) var suggestedApp: String?
    @Published private(set) var scheduledMeeting: CalendarMeeting?
    @Published private(set) var calendarStatus = "Connect your calendars to see upcoming meetings."
    @Published var calendarEnabled: Bool {
        didSet {
            defaults.set(calendarEnabled, forKey: "meetingCalendarEnabled")
            updateDetection()
        }
    }
    @Published private(set) var panelKind: MeetingPanelKind?
    @Published private(set) var operationInProgress = false
    @Published private(set) var microphoneAccessGranted = false
    @Published private(set) var systemAudioAccessGranted = false
    @Published var detectionEnabled: Bool {
        didSet {
            defaults.set(detectionEnabled, forKey: Self.detectionPreferenceKey)
            updateDetection()
        }
    }
    @Published var autoStartEnabled: Bool {
        didSet {
            defaults.set(autoStartEnabled, forKey: Self.autoStartPreferenceKey)
            if !autoStartEnabled { pendingAutomaticCandidate = nil }
            updateDetection()
        }
    }
    /// Stop and save when the recorded Meet/Zoom/Teams/Slack call ends.
    @Published var autoStopEnabled: Bool {
        didSet {
            defaults.set(autoStopEnabled, forKey: Self.autoStopPreferenceKey)
            if !autoStopEnabled { keepRecording() }
            updateDetection()
        }
    }
    /// Keep a compact copy of each meeting's audio beside its transcript for 30 days. Off unless chosen.
    @Published var keepAudioEnabled: Bool {
        didSet {
            defaults.set(keepAudioEnabled, forKey: Self.keepAudioPreferenceKey)
            service.keepsAudio = keepAudioEnabled
        }
    }
    /// Set while the "Meeting ended" countdown runs; nil otherwise.
    @Published private(set) var autoStopDeadline: Date?
    @Published private(set) var autoStopped = false

    static let detectionPreferenceKey = "meetingDetectionEnabled"
    static let autoStartPreferenceKey = "meetingAutoStartEnabled"
    static let autoStopPreferenceKey = "meetingAutoStopEnabled"
    static let keepAudioPreferenceKey = "meetingKeepAudioEnabled"
    /// Seconds the "Meeting ended" card waits before stopping, so the user can keep recording.
    var autoStopCountdown: TimeInterval = 10
    /// Seconds a saved auto-stop result stays on screen.
    var autoStopResultSeconds: TimeInterval = 12
    var endPolicy = MeetingEndPolicy()
    /// Parent refuses a start while a dictation is in flight. No user input is cancelled.
    var canStartRecording: () -> Bool = { true }
    /// Read-only preflight: automatic starts never request new macOS permissions.
    var automaticStartPermissionsGranted: () -> Bool = {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && CGPreflightScreenCaptureAccess()
    }
    /// `true` is synchronous before service.start(); `false` follows completed cleanup only.
    var onRecordingChanged: (Bool) -> Void = { _ in }
    /// The app owns one Settings window. Meeting cards must never create another one.
    var onShowSettings: () -> Void = {}
    var onManualPresentation: () -> Void = {}
    var onCalendarSynchronized: () -> Void = {}
    var isBusy: Bool { operationInProgress || phase == .preparing || phase == .recording || phase == .recovering || phase == .finalizing }
    /// A download would add something: the speech model or voice separation is missing.
    var needsModelSetup: Bool { !modelReady || !speakerModelReady }
    var transcriptionProgress: Double? { if case .running(let progress, _, _) = transcription { return progress }; return nil }
    var transcriptionDetail: MeetingTranscriptionProgress? {
        guard case .running(let progress, _, let detail) = transcription else { return nil }
        return detail ?? MeetingTranscriptionProgress(fraction: progress)
    }
    var transcriptDirectory: URL { service.transcriptDirectory }
    var elapsedLabel: String { Self.elapsedLabel(elapsedSeconds) }

    struct TranscriptionStatusSummary: Equatable {
        let progressLabel: String
        let etaLabel: String
    }

    /// Formats live determinate audio progress and smoothed ETA for both Korean and English UI.
    static func transcriptionStatusSummary(_ detail: MeetingTranscriptionProgress, isKorean: Bool) -> TranscriptionStatusSummary {
        let percent = Int((min(1, max(0, detail.fraction)) * 100).rounded())
        let progressLabel: String
        if detail.totalAudioSeconds >= 1 {
            let done = elapsedLabel(min(detail.totalAudioSeconds, detail.processedAudioSeconds))
            let total = elapsedLabel(detail.totalAudioSeconds)
            progressLabel = "\(percent)% · \(done) / \(total)"
        } else if detail.fraction > 0 {
            progressLabel = "\(percent)%"
        } else {
            progressLabel = ""
        }

        let etaLabel: String
        if detail.fraction < 0.015 {
            etaLabel = isKorean ? "음성 모델을 불러오는 중이에요…" : "Loading speech models…"
        } else if detail.isAlmostDone {
            etaLabel = isKorean ? "거의 다 됐어요" : "Almost done"
        } else if let remaining = detail.estimatedRemainingSeconds {
            if remaining < 50 {
                let rounded = max(10, Int((remaining / 5).rounded()) * 5)
                etaLabel = isKorean ? "약 \(rounded)초 남음" : "About \(rounded) sec left"
            } else if remaining < 90 {
                etaLabel = isKorean ? "약 1분 남음" : "About 1 min left"
            } else {
                let minutes = max(2, Int((remaining / 60).rounded()))
                etaLabel = isKorean ? "약 \(minutes)분 남음" : "About \(minutes) min left"
            }
        } else {
            etaLabel = isKorean ? "남은 시간을 계산하고 있어요…" : "Estimating time left…"
        }
        return TranscriptionStatusSummary(progressLabel: progressLabel, etaLabel: etaLabel)
    }

    private let log = Logger(subsystem: "ca.sundayable.sunday-voice", category: "meetings")
    private var service: any MeetingServiceProviding
    private let detector: any MeetingDetecting
    private let calendar: any MeetingCalendarProviding
    let googleCalendar: GoogleMeetingCalendar
    private var localCalendarEvents: [CalendarMeeting] = []
    private var googleCalendarEvents: [CalendarMeeting] = []
    private var calendarPolicy = CalendarMeetingPolicy()
    var revealTranscript: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    private let defaults: UserDefaults
    private let presentsPanels: Bool
    private var subscription: AnyCancellable?
    private var panel: MeetingPanelController?
    private var monitoring = false
    private var ownsAudio = false
    private var shuttingDown = false
    private var suspended = false
    private var stopping = false
    private var previousWarning: String?
    private var suggestedBundleID: String?
    private var pendingAutomaticCandidate: MeetingCandidate?
    private var currentCallOwners: Set<String> = []
    private var currentCandidates: [MeetingCandidate] = []
    private var suggestedWindowTitle: String?
    private var calendarEnrichment: Task<Void, Never>?
    private var enrichedURLs = Set<URL>()
    private var resumedPending = false
    private var automaticStartWork: Task<Void, Never>?
    private var autoStopWork: Task<Void, Never>?
    private var resultDismissWork: Task<Void, Never>?

    init(service: (any MeetingServiceProviding)? = nil, detector: any MeetingDetecting = MeetingDetector(),
         defaults: UserDefaults = .standard, presentsPanels: Bool = true, calendar: (any MeetingCalendarProviding)? = nil,
         googleCalendar: GoogleMeetingCalendar? = nil) {
        let service = service ?? LocalMeetingService()
        self.calendar = calendar ?? MeetingCalendar()
        self.googleCalendar = googleCalendar ?? GoogleMeetingCalendar(defaults: defaults)
        calendarEnabled = defaults.object(forKey: "meetingCalendarEnabled") as? Bool ?? false
        self.service = service; self.detector = detector; self.defaults = defaults; self.presentsPanels = presentsPanels
        detectionEnabled = defaults.object(forKey: Self.detectionPreferenceKey) as? Bool ?? true
        // Existing users retain explicit starts. Dan's local installation opts in separately.
        autoStartEnabled = defaults.object(forKey: Self.autoStartPreferenceKey) as? Bool ?? false
        autoStopEnabled = defaults.object(forKey: Self.autoStopPreferenceKey) as? Bool ?? true
        keepAudioEnabled = defaults.object(forKey: Self.keepAudioPreferenceKey) as? Bool ?? false
        self.service.keepsAudio = keepAudioEnabled
        synchronize()
        subscription = service.meetingChanges.receive(on: DispatchQueue.main).sink { [weak self] in self?.synchronize() }
        detector.onCandidate = { [weak self] candidate in self?.receiveCandidate(candidate) }
        detector.onPresence = { [weak self] snapshot in self?.receivePresence(snapshot, now: ProcessInfo.processInfo.systemUptime) }
        self.calendar.onEvents = { [weak self] events in
            self?.localCalendarEvents = events; self?.combineCalendarEvents()
        }
        self.calendar.onStatus = { [weak self] status in self?.calendarStatus = status }
        self.googleCalendar.onSynchronized = { [weak self] in
            self?.retryCalendarEnrichment()
            self?.onCalendarSynchronized()
        }
        self.googleCalendar.onEvents = { [weak self] events in
            self?.googleCalendarEvents = events; self?.combineCalendarEvents()
        }
    }

    /// Read-only checks. This does not request permission or start an audio stream.
    func refreshPermissions() {
        microphoneAccessGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        systemAudioAccessGranted = CGPreflightScreenCaptureAccess()
    }

    func startMonitoring() {
        guard !shuttingDown else { return }
        suspended = false
        monitoring = true
        updateDetection()
        // Recordings saved before a quit or crash get their transcript now.
        if !resumedPending { resumedPending = true; service.resumePendingTranscriptions() }
    }

    func stopMonitoring() {
        monitoring = false
        pendingAutomaticCandidate = nil
        currentCallOwners = []
        detector.stop(); calendar.stop(); googleCalendar.stop()
    }

    private func updateDetection() {
        // While recording, polling also watches for the call to end (auto-stop), even with suggestions off.
        let watchEnd = ownsAudio && autoStopEnabled
        if monitoring && (detectionEnabled || autoStartEnabled || watchEnd) && !shuttingDown { detector.start() } else { detector.stop() }
        if monitoring && calendarEnabled && !shuttingDown { calendar.start() } else { calendar.stop() }
        if monitoring && !shuttingDown { googleCalendar.start() } else { googleCalendar.stop() }
    }

    func connectCalendar() async {
        calendarEnabled = true
        await calendar.requestAccess()
    }

    private func combineCalendarEvents() {
        // When Google is connected its selected calendars are authoritative. Local fallback
        // cannot accidentally surface events from an unchecked Google calendar.
        let useGoogle = googleCalendar.enabled && googleCalendar.account != nil && !googleCalendar.needsConsent
        receiveCalendarEvents(useGoogle ? googleCalendarEvents : (calendarEnabled ? localCalendarEvents : []))
    }

    func receiveCalendarEvents(_ events: [CalendarMeeting], now: Date = Date()) {
        guard monitoring, !shuttingDown, !isBusy, pendingAutomaticCandidate == nil else { return }
        if let scheduledMeeting, !events.contains(where: {
            $0.id == scheduledMeeting.id && $0.endsAt > now &&
            $0.startsAt <= now.addingTimeInterval(120) && $0.startsAt >= now.addingTimeInterval(-120)
        }) {
            self.scheduledMeeting = nil
            if panelKind == .invitation { panelKind = nil; panel?.hide() }
        }
        guard panelKind == nil || panelKind == .invitation,
              let event = calendarPolicy.next(events, now: now) else { return }
        scheduledMeeting = event
        suggestedApp = nil
        suggestedBundleID = nil
        suggestedWindowTitle = nil
        present(.invitation)
    }

    func receiveCandidate(_ candidate: MeetingCandidate) {
        guard monitoring, detectionEnabled || autoStartEnabled, !shuttingDown, !suspended, !isBusy,
              panelKind == nil || (autoStartEnabled && (panelKind == .invitation || panelKind == .result)) else {
            log.notice("candidate_ignored bundle=\(candidate.bundleID, privacy: .public) busy=\(self.isBusy, privacy: .public) autoStart=\(self.autoStartEnabled, privacy: .public)")
            return
        }
        log.notice("candidate_received bundle=\(candidate.bundleID, privacy: .public) autoStart=\(self.autoStartEnabled, privacy: .public)")
        scheduledMeeting = nil
        suggestedApp = candidate.appName
        suggestedBundleID = candidate.bundleID
        suggestedWindowTitle = candidate.windowTitle
        if autoStartEnabled {
            pendingAutomaticCandidate = candidate
            tryAutomaticStart()
        } else {
            present(.invitation)
        }
    }

    private func tryAutomaticStart() {
        guard let candidate = pendingAutomaticCandidate, autoStartEnabled, monitoring, !suspended,
              !shuttingDown, !isBusy, automaticStartWork == nil,
              currentCallOwners.contains(candidate.bundleID) else { return }
        // Recording needs no speech model; a missing model only delays the transcript.
        guard automaticStartPermissionsGranted() else {
            let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let screen = CGPreflightScreenCaptureAccess()
            log.notice("auto_start_skipped reason=permissions_missing bundle=\(candidate.bundleID, privacy: .public) mic=\(mic, privacy: .public) screen=\(screen, privacy: .public)")
            if panelKind != .invitation { present(.invitation) }
            return
        }
        // Leave an in-flight dictation alone; the next presence poll retries after it finishes.
        guard canStartRecording() else {
            log.notice("auto_start_deferred reason=dictation_busy bundle=\(candidate.bundleID, privacy: .public)")
            return
        }
        log.notice("auto_start_triggered bundle=\(candidate.bundleID, privacy: .public)")
        automaticStartWork = Task { [weak self] in
            guard let self else { return }
            defer { self.automaticStartWork = nil }
            guard self.pendingAutomaticCandidate == candidate, self.autoStartEnabled, self.monitoring,
                  !self.suspended, !self.shuttingDown, !self.isBusy,
                  self.currentCallOwners.contains(candidate.bundleID),
                  self.automaticStartPermissionsGranted(), self.canStartRecording() else { return }
            self.pendingAutomaticCandidate = nil
            await self.startRecording()
        }
    }

    /// Call presence from each detector poll. Ends a recording only after a call was seen and then
    /// stayed gone for the grace period; a returning call cancels a running countdown.
    func receivePresence(_ snapshot: MeetingDetectionSnapshot, now: TimeInterval) {
        currentCallOwners = snapshot.activeCallOwners
        currentCandidates = snapshot.observations.map(\.candidate)
        if let pending = pendingAutomaticCandidate, !currentCallOwners.contains(pending.bundleID) {
            pendingAutomaticCandidate = nil
        }
        tryAutomaticStart()
        // Once this recording is bound to a call, its own mic (or native muted-call playback)
        // remains valid through tab switches, brief dropouts, and unavailable AX windows.
        // An unrelated app's open mic cannot arm or continue this recording.
        let continuing = snapshot.activeAudioOwners.intersection(endPolicy.recordedCallOwners)
        receivePresence(snapshot.activeCallOwners.union(continuing), now: now)
    }

    func receivePresence(_ owners: Set<String>, now: TimeInterval) {
        guard ownsAudio, autoStopEnabled, !stopping, !shuttingDown,
              phase == .recording || phase == .recovering else { return }
        if autoStopDeadline != nil {
            if endPolicy.recordedCallIsActive(in: owners) {
                cancelAutoStop()
                _ = endPolicy.observe(activeCallOwners: owners, now: now)
            }
            return
        }
        if endPolicy.observe(activeCallOwners: owners, now: now) { beginAutoStop() }
    }

    private func beginAutoStop() {
        autoStopDeadline = Date().addingTimeInterval(autoStopCountdown)
        present(.recording)
        let countdown = autoStopCountdown
        autoStopWork = Task { [weak self] in
            try? await Task.sleep(for: .seconds(countdown))
            guard let self, !Task.isCancelled, self.autoStopDeadline != nil else { return }
            self.autoStopDeadline = nil
            self.autoStopWork = nil
            self.autoStopped = true
            await self.stop()
        }
    }

    private func cancelAutoStop() {
        autoStopWork?.cancel(); autoStopWork = nil
        autoStopDeadline = nil
    }

    /// "Keep recording": cancel the countdown; only a new call that later ends can stop it again.
    func keepRecording() {
        cancelAutoStop()
        endPolicy.reset()
    }

    func presentManualStart() {
        guard !shuttingDown else { return }
        pendingAutomaticCandidate = nil
        onManualPresentation()
        if isBusy { present(ownsAudio ? .recording : .setup, userInitiated: true); return }
        suggestedApp = nil
        suggestedBundleID = nil
        suggestedWindowTitle = nil
        scheduledMeeting = nil
        present(.invitation, userInitiated: true)
    }

    func dismissSuggestion() {
        guard !ownsAudio else { return }
        pendingAutomaticCandidate = nil
        resultDismissWork?.cancel(); resultDismissWork = nil
        if let scheduledMeeting { calendarPolicy.dismiss(scheduledMeeting) }
        detector.dismissCurrentCandidate()
        suggestedBundleID = nil
        suggestedWindowTitle = nil
        panelKind = nil; panel?.hide()
    }

    /// Starts capture straight away. The speech model is not needed until the meeting is over.
    func startRecording() async {
        guard !shuttingDown, !suspended, !isBusy else { return }
        guard canStartRecording() else {
            statusMessage = "Finish your dictation, then start the meeting."
            present(.invitation)
            return
        }
        if let scheduledMeeting { calendarPolicy.dismiss(scheduledMeeting) }
        pendingAutomaticCandidate = nil
        detector.dismissCurrentCandidate()
        resultDismissWork?.cancel(); resultDismissWork = nil
        cancelAutoStop()
        endPolicy.reset(tracking: suggestedBundleID.map { [$0] } ?? [])
        // Arm from the corroborated join even if the user leaves before the next 3-second poll.
        if let owner = suggestedBundleID, currentCallOwners.contains(owner) {
            _ = endPolicy.observe(activeCallOwners: [owner], now: ProcessInfo.processInfo.systemUptime)
        }
        autoStopped = false
        operationInProgress = true
        ownsAudio = true
        onRecordingChanged(true)
        updateDetection()
        phase = .preparing
        statusMessage = "Starting the recording…"
        present(.recording)
        defer { operationInProgress = false }
        do {
            let candidate = currentCandidates.first { $0.bundleID == suggestedBundleID } ?? (currentCandidates.count == 1 ? currentCandidates.first : nil)
            service.recordingContext = RecordingMeetingContext(appName: suggestedApp ?? candidate?.appName,
                bundleID: suggestedBundleID ?? candidate?.bundleID, windowTitle: candidate?.windowTitle ?? suggestedWindowTitle)
            try await service.start()
            guard !shuttingDown else { await service.stop(); ownsAudio = false; return }
            synchronize()
        } catch is CancellationError {
            await service.stop()
            releaseAudio()
            synchronize()
            if !shuttingDown && !suspended { present(.result) }
        } catch {
            await service.stop()
            releaseAudio()
            phase = .failed
            statusMessage = Self.readableError(error)
            if !shuttingDown && !suspended { present(.result) }
        }
    }

    /// Preparing a model does not itself start recording. Saved recordings are transcribed once it is ready.
    func prepareModel() async {
        guard !shuttingDown, !isBusy else { return }
        operationInProgress = true
        phase = .preparing
        statusMessage = "Downloading the local speech models…"
        present(.setup)
        defer { operationInProgress = false }
        do {
            try await service.prepareModel()
            synchronize()
            if modelReady, case .idle = transcription {
                statusMessage = "Speech models ready. Recordings are transcribed on this Mac after each meeting."
            }
        } catch {
            synchronize()
            phase = .failed
            statusMessage = Self.readableError(error)
        }
    }

    func stop() async {
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }
        cancelAutoStop()
        if ownsAudio { phase = .finalizing; statusMessage = "Saving the recording…" }
        await service.stop()
        synchronize()
        releaseAudio()
        updateDetection()
        if !shuttingDown { present(.result) }
        if autoStopped && !shuttingDown && phase != .failed {
            let seconds = autoStopResultSeconds
            resultDismissWork = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, !Task.isCancelled, self.panelKind == .result, !self.isBusy else { return }
                self.dismissSuggestion()
            }
        }
    }

    /// Sign-out stops monitoring and capture; a later sign-in can reuse this coordinator.
    func suspend() async {
        suspended = true
        stopMonitoring()
        await stop()
        panelKind = nil; panel?.hide()
    }

    /// App shutdown must not restart cloud dictation after releasing meeting capture.
    func shutdown() async {
        shuttingDown = true
        cancelAutoStop(); resultDismissWork?.cancel()
        stopMonitoring()
        await service.stop()
        // Unfinished transcripts keep their audio and continue at the next launch.
        service.cancelTranscription()
        ownsAudio = false
        panelKind = nil; panel?.hide()
    }

    func presentSettings() {
        guard !isBusy else { presentManualStart(); return }
        dismissSuggestion()
        onShowSettings()
    }

    func openTranscripts() {
        // Explicit Finder reveal avoids a broken default folder/document handler and raises Finder
        // from a nonactivating panel. Never open a private transcript into an editor automatically.
        let target = lastSavedURL ?? transcriptDirectory
        if FileManager.default.fileExists(atPath: target.path) {
            revealTranscript(target)
        } else if FileManager.default.fileExists(atPath: transcriptDirectory.path) {
            revealTranscript(transcriptDirectory)
        } else {
            statusMessage = "Your transcripts folder is created after the first meeting."
        }
    }

    private func present(_ kind: MeetingPanelKind, userInitiated: Bool = false) {
        guard !shuttingDown else { return }
        panelKind = kind
        guard presentsPanels else { return }
        if panel == nil { panel = MeetingPanelController() }
        panel?.show(coordinator: self, activate: userInitiated)
    }

    private func releaseAudio() {
        guard ownsAudio else { return }
        ownsAudio = false
        if !shuttingDown && !suspended { onRecordingChanged(false) }
    }

    private func synchronize() {
        phase = service.phase
        statusMessage = service.statusMessage
        segments = service.segments
        elapsedSeconds = service.elapsedSeconds
        modelReady = service.modelReady
        speakerModelReady = service.speakerModelReady
        transcription = service.transcription
        lastSavedURL = service.lastSavedURL
        // Calendar details are attached once a transcript is final, including ones finished in the background.
        if let url = service.lastTranscriptURL, enrichedURLs.insert(url).inserted { enrichCalendar([url]) }
        setupProgress = service.setupProgress
        if let warning = service.captureWarning, warning != previousWarning && ownsAudio {
            present(.recording)
            if presentsPanels { NSSound.beep() }
        }
        previousWarning = service.captureWarning
        // A spontaneous capture failure still goes through service.stop() before dictation resumes.
        if service.phase == .failed && ownsAudio && !operationInProgress && !stopping && !shuttingDown {
            Task { [weak self] in await self?.stop() }
        }
    }

    private func enrichCalendar(_ urls: [URL]) {
        guard calendarEnrichment == nil, !urls.isEmpty else { return }
        calendarEnrichment = Task { [weak self] in
            guard let self else { return }
            defer { self.calendarEnrichment = nil }
            for url in urls {
                guard RecordingMetadataStore.isFinalized(url), let metadata = try? RecordingMetadataStore.read(beside: url) else { continue }
                do {
                    let match = try await self.googleCalendar.matchRecording(metadata)
                    try RecordingMetadataStore.save(match: match, beside: url)
                } catch {
                    // Leave the durable transcript/metadata intact. No calendar data in logs.
                    continue
                }
            }
        }
    }

    private func retryCalendarEnrichment() {
        guard calendarEnrichment == nil else { return }
        let folders = (try? FileManager.default.contentsOfDirectory(at: transcriptDirectory,
            includingPropertiesForKeys: nil)) ?? []
        let pending = folders.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(100).compactMap { folder -> URL? in
            let url = folder.appendingPathComponent("Transcript.txt")
            guard RecordingMetadataStore.isFinalized(url), let metadata = try? RecordingMetadataStore.read(beside: url), metadata.calendarMatch == nil,
                  metadata.endedAt != nil else { return nil }
            return url
        }
        enrichCalendar(pending)
    }

    static func elapsedLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) :
            String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Gallery/screenshot preview only: applies a synthetic UI state without touching audio or disk.
    func applyPreviewState(panelKind: MeetingPanelKind? = nil, phase: MeetingPhase = .idle,
                           statusMessage: String? = nil, elapsedSeconds: TimeInterval = 0,
                           modelReady: Bool = true, speakerModelReady: Bool = true,
                           transcription: MeetingTranscriptionState = .idle,
                           suggestedApp: String? = nil, autoStopDeadline: Date? = nil,
                           autoStopped: Bool = false, lastSavedURL: URL? = nil,
                           microphoneGranted: Bool = true, systemAudioGranted: Bool = true) {
        self.panelKind = panelKind
        self.phase = phase
        if let statusMessage { self.statusMessage = statusMessage }
        self.elapsedSeconds = elapsedSeconds
        self.modelReady = modelReady
        self.speakerModelReady = speakerModelReady
        self.transcription = transcription
        self.suggestedApp = suggestedApp
        self.autoStopDeadline = autoStopDeadline
        self.autoStopped = autoStopped
        self.lastSavedURL = lastSavedURL
        self.microphoneAccessGranted = microphoneGranted
        self.systemAudioAccessGranted = systemAudioGranted
    }

    private static func readableError(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription { return description }
        return "Meeting recording could not start. Check microphone and system audio access, then try again."
    }
}
