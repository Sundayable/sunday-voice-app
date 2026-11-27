import Combine
import AppKit
import ApplicationServices
import LocalMeetingEngine
import XCTest
import SwiftUI
@testable import Sunday_Voice

final class MeetingDetectionTests: XCTestCase {
    private let candidate = MeetingCandidate(appName: "Google Chrome", bundleID: "com.google.Chrome")

    private func snapshot(call: String = "call-a", microphone: Bool = true, visible: Bool = true) -> MeetingDetectionSnapshot {
        MeetingDetectionSnapshot(observations: microphone && visible ? [MeetingObservation(candidate: candidate,
            callID: call, microphoneOwnerID: candidate.bundleID)] : [], activeMicrophoneOwners: microphone ? [candidate.bundleID] : [])
    }

    func testMeetingWindowAloneAndUnrelatedAppsDoNotQualify() {
        XCTAssertNil(MeetingAppIdentity.recognize("com.apple.VoiceMemos"))
        XCTAssertNil(MeetingAppIdentity.recognize("com.apple.WebKit.GPU")) // shared WebKit host cannot be attributed safely
        XCTAssertEqual(MeetingAppIdentity.recognize("com.google.Chrome.helper")?.kind, .browser)
        XCTAssertFalse(MeetingAppIdentity.hasCallWindow(title: "Inbox — Google Chrome", kind: .browser))
        XCTAssertTrue(MeetingAppIdentity.hasCallWindow(title: "Meet - Example meeting", kind: .browser))
        XCTAssertTrue(MeetingAppIdentity.hasCallWindow(title: "Meet - Webinar - Lauren - Microphone recording - Aside - Dan Jeong (Sundayable)", kind: .browser))
        XCTAssertTrue(MeetingAppIdentity.hasCallWindow(title: "Google Meet - Microphone recording - Aside", kind: .browser))
        XCTAssertFalse(MeetingAppIdentity.hasCallWindow(title: "Google Meet - Aside - Dan Jeong (Sundayable)", kind: .browser))
        XCTAssertFalse(MeetingAppIdentity.hasCallWindow(title: "Google Meet - Settings - Aside", kind: .browser))
        XCTAssertFalse(MeetingAppIdentity.hasCallWindow(title: "Google Calendar - Google Meet setup - Aside", kind: .browser))
        XCTAssertFalse(MeetingAppIdentity.hasCallTab(title: "Google Meet - Settings - Audio"))
        XCTAssertFalse(MeetingAppIdentity.hasCallTab(title: "Google Calendar - Week of Nov 26"))
        var policy = MeetingDetectionPolicy()
        XCTAssertNil(policy.observe(snapshot(microphone: false), now: 0))
        XCTAssertNil(policy.observe(snapshot(microphone: false), now: 3))
    }

    func testSlackAndFaceTimeNeedCallWindowEvidence() {
        XCTAssertFalse(MeetingAppIdentity.hasCallWindow(title: "Slack", kind: .slack))
        XCTAssertFalse(MeetingAppIdentity.hasCallWindow(title: "Workspace | Slack", kind: .slack))
        XCTAssertTrue(MeetingAppIdentity.hasCallWindow(title: "Huddle", kind: .slack))
        XCTAssertFalse(MeetingAppIdentity.hasCallWindow(title: "FaceTime", kind: .faceTime))
        XCTAssertTrue(MeetingAppIdentity.hasCallWindow(title: "FaceTime Video Call", kind: .faceTime))
    }

    func testTwoConsecutiveObservationsAreRequired() {
        var policy = MeetingDetectionPolicy()
        XCTAssertNil(policy.observe(snapshot(), now: 0))
        XCTAssertNil(policy.observe(snapshot(visible: false), now: 3))
        XCTAssertNil(policy.observe(snapshot(), now: 6))
        XCTAssertEqual(policy.observe(snapshot(), now: 9)?.candidate, candidate)
        XCTAssertNil(policy.observe(snapshot(), now: 12))
    }

    func testDismissedCallStaysSuppressedUntilThirtySecondsOfMicrophoneQuiet() {
        var policy = MeetingDetectionPolicy()
        _ = policy.observe(snapshot(), now: 0)
        let offered = policy.observe(snapshot(), now: 3)!
        policy.dismiss(offered)
        // A hidden/minimized meeting window does not count as microphone quiet.
        XCTAssertNil(policy.observe(snapshot(visible: false), now: 6))
        XCTAssertNil(policy.observe(snapshot(), now: 39))
        XCTAssertNil(policy.observe(snapshot(), now: 42))
        XCTAssertNil(policy.observe(snapshot(microphone: false), now: 45))
        XCTAssertNil(policy.observe(snapshot(microphone: false), now: 74))
        XCTAssertNil(policy.observe(snapshot(microphone: false), now: 75))
        XCTAssertNil(policy.observe(snapshot(), now: 78))
        XCTAssertEqual(policy.observe(snapshot(), now: 81)?.candidate, candidate)
    }

    func testDifferentCallCanBeSuggestedWithoutRearmingTheDismissedCall() {
        var policy = MeetingDetectionPolicy()
        _ = policy.observe(snapshot(), now: 0)
        let first = policy.observe(snapshot(), now: 3)!
        policy.dismiss(first)
        XCTAssertNil(policy.observe(snapshot(call: "call-b"), now: 6))
        XCTAssertEqual(policy.observe(snapshot(call: "call-b"), now: 9)?.callID, "call-b")
        XCTAssertNil(policy.observe(snapshot(), now: 12))
        XCTAssertNil(policy.observe(snapshot(), now: 15))
    }

    func testOpenMicrophonesWithoutCallWindowsAreNotMeetingPresence() {
        let apps = ["com.google.Chrome.helper", "at.studio.AsideBrowser.helper",
                    "com.tinyspeck.slackmacgap", "com.apple.FaceTime", "com.apple.VoiceMemos"]
        let activities = apps.enumerated().map {
            MeetingAudioActivity(bundleID: $0.element, processID: pid_t($0.offset + 1), input: true, output: false)
        }
        let result = MeetingDetector.snapshot(from: activities, applicationPID: { _ in nil }, callWindow: { _, _ in nil })
        XCTAssertEqual(result.activeMicrophoneOwners, ["com.google.Chrome", "at.studio.AsideBrowser",
                                                       "com.tinyspeck.slackmacgap", "com.apple.FaceTime"])
        XCTAssertTrue(result.activeCallOwners.isEmpty)
        XCTAssertTrue(result.observations.isEmpty)
    }

    func testMeetEndsWhileAnotherBrowserKeepsItsMicrophoneOpen() {
        // Same collector used by CoreAudio polling; no live devices or user recordings involved.
        let unrelated = MeetingAudioActivity(bundleID: "com.google.Chrome.helper", processID: 20, input: true, output: true)
        func poll(meetInput: Bool) -> MeetingDetectionSnapshot {
            MeetingDetector.snapshot(from: [
                MeetingAudioActivity(bundleID: "at.studio.AsideBrowser.helper", processID: 10, input: meetInput, output: true),
                unrelated
            ], applicationPID: { _ in nil }, callWindow: { pid, _ in pid == 10 ? "meet-window" : nil })
        }
        var end = MeetingEndPolicy()
        let joined = poll(meetInput: true)
        XCTAssertEqual(joined.activeMicrophoneOwners, ["at.studio.AsideBrowser", "com.google.Chrome"])
        XCTAssertEqual(joined.activeCallOwners, ["at.studio.AsideBrowser"])
        XCTAssertFalse(end.observe(activeCallOwners: joined.activeCallOwners, now: 0))
        // Meet's title/playback remain after Leave, while Chrome's unrelated mic stays open.
        let left = poll(meetInput: false)
        XCTAssertEqual(left.activeMicrophoneOwners, ["com.google.Chrome"])
        XCTAssertTrue(left.activeCallOwners.isEmpty)
        XCTAssertFalse(end.observe(activeCallOwners: left.activeCallOwners, now: 3))
        XCTAssertTrue(end.observe(activeCallOwners: left.activeCallOwners, now: 48))
    }

    func testHelperProcessesShareOneCorroborationAndCallIdentity() {
        let activities = [
            MeetingAudioActivity(bundleID: "com.google.Chrome.helper", processID: 10, input: true, output: false),
            MeetingAudioActivity(bundleID: "com.google.Chrome.helper.renderer", processID: 11, input: false, output: true)
        ]
        var inspected: [pid_t] = []
        let result = MeetingDetector.snapshot(from: activities, applicationPID: { _ in 100 }, callWindow: { pid, _ in
            inspected.append(pid); return "call-window"
        })
        XCTAssertEqual(inspected, [100])
        XCTAssertEqual(result.activeCallOwners, ["com.google.Chrome"])
        XCTAssertEqual(result.observations.map(\.callID), ["com.google.Chrome:100:call-window"])
    }

    func testMutedNativeCallPlaybackStillCountsButBrowserPlaybackDoesNot() {
        for bundleID in ["us.zoom.xos", "com.microsoft.teams2", "com.tinyspeck.slackmacgap", "com.apple.FaceTime", "at.studio.AsideBrowser"] {
            let result = MeetingDetector.snapshot(from: [
                MeetingAudioActivity(bundleID: bundleID, processID: 10, input: false, output: true)
            ], applicationPID: { _ in nil }, callWindow: { _, _ in "call-window" })
            XCTAssertEqual(result.activeCallOwners, bundleID == "at.studio.AsideBrowser" ? [] : [bundleID])
            XCTAssertTrue(result.observations.isEmpty, "playback alone must not offer a new recording")
        }
    }

    func testIdleProcessesWithOldMeetingWindowDoNotCount() {
        let result = MeetingDetector.snapshot(from: [
            MeetingAudioActivity(bundleID: "at.studio.AsideBrowser", processID: 10, input: false, output: false)
        ], applicationPID: { _ in nil }, callWindow: { _, _ in "old-meet-window" })
        XCTAssertTrue(result.activeCallOwners.isEmpty)
        XCTAssertTrue(result.activeMicrophoneOwners.isEmpty)
    }

    func testBackgroundMeetTabCorroboratesWhileIdleMeetHomeTabDoesNot() {
        XCTAssertTrue(MeetingAppIdentity.hasCallTab(title: "Meet - Lauren <> Dan - Branding - Memory usage - 88.8 MB"))
        XCTAssertTrue(MeetingAppIdentity.hasCallTab(title: "Meet - pvi-eprv-diw"))
        XCTAssertTrue(MeetingAppIdentity.hasCallTab(title: "Google Meet - Camera and microphone recording"))
        XCTAssertTrue(MeetingAppIdentity.hasCallTab(title: "Zoom Meeting - Memory usage - 120 MB"))
        XCTAssertFalse(MeetingAppIdentity.hasCallTab(title: "Google Meet - Part of unnamed group - Memory usage - 251 MB"))
        XCTAssertFalse(MeetingAppIdentity.hasCallTab(title: "Lauren 사이트 컨셉 리뷰 (Dan 전용) - Memory usage - 88.8 MB"))
        XCTAssertFalse(MeetingAppIdentity.hasCallTab(title: "Tweet - Product launch"))

        let bg = MeetingDetector.corroboratingTitle(
            windowTitle: "Lauren 사이트 컨셉 리뷰 (Dan 전용) - Aside - Dan Jeong (Sundayable)",
            tabTitles: ["Sundayable - Calendar", "Google Meet - Part of unnamed group", "Meet - Lauren <> Dan - Branding"],
            kind: .browser
        )
        XCTAssertEqual(bg?.source, "tab")
        XCTAssertEqual(bg?.title, "Meet - Lauren <> Dan - Branding")

        let idleOnly = MeetingDetector.corroboratingTitle(
            windowTitle: "Help me finish free business directory l... ⋅ Chats - Aside",
            tabTitles: ["Sundayable - Calendar", "Google Meet - Part of unnamed group - Memory usage - 251 MB"],
            kind: .browser
        )
        XCTAssertNil(idleOnly)

        let active = MeetingDetector.corroboratingTitle(
            windowTitle: "Meet - Weekly Group - Camera and microphone recording - Aside",
            tabTitles: ["Meet - Other Call"],
            kind: .browser
        )
        XCTAssertEqual(active?.source, "window")
        XCTAssertEqual(active?.title, "Meet - Weekly Group - Camera and microphone recording - Aside")
    }

    func testChromiumAndAsideGoogleMeetPWAShimsCorroborateEvenWithEmptyWindowTitle() {
        let asideMeetEmptyTitle = BrowserPWAApp(
            bundleID: "at.studio.AsideBrowser.app.kjgfgldnnfoeklkmfkjfagphfepbbdan",
            localizedName: "Google Meet",
            processID: 4201,
            windowTitles: [""],
            tabTitles: [],
            hasOpenWindow: true
        )
        let matched = MeetingDetector.corroboratingPWA(ownerBundleID: "at.studio.AsideBrowser", apps: [asideMeetEmptyTitle])
        XCTAssertEqual(matched?.id, "pwa:4201")
        XCTAssertEqual(matched?.title, "Google Meet")

        // Chrome Meet PWA must not corroborate an Aside mic owner (wrong parent browser).
        let chromeMeet = BrowserPWAApp(
            bundleID: "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan",
            localizedName: "Google Meet",
            processID: 4202,
            windowTitles: ["Meet - Lauren <> Dan - Branding"],
            tabTitles: [],
            hasOpenWindow: true
        )
        XCTAssertNil(MeetingDetector.corroboratingPWA(ownerBundleID: "at.studio.AsideBrowser", apps: [chromeMeet]))
        let chromeMatched = MeetingDetector.corroboratingPWA(ownerBundleID: "com.google.Chrome", apps: [chromeMeet])
        XCTAssertEqual(chromeMatched?.id, "pwa:4202")
        XCTAssertEqual(chromeMatched?.title, "Meet - Lauren <> Dan - Branding")

        // Unrelated PWA (e.g. Notion/Gmail) or a Meet PWA with no open windows must not match.
        let notionPWA = BrowserPWAApp(
            bundleID: "at.studio.AsideBrowser.app.abcdef1234567890",
            localizedName: "Notion",
            processID: 4203,
            windowTitles: ["Roadmap"],
            tabTitles: [],
            hasOpenWindow: true
        )
        let windowlessMeet = BrowserPWAApp(
            bundleID: "at.studio.AsideBrowser.app.kjgfgldnnfoeklkmfkjfagphfepbbdan",
            localizedName: "Google Meet",
            processID: 4204,
            windowTitles: [],
            tabTitles: [],
            hasOpenWindow: false
        )
        XCTAssertNil(MeetingDetector.corroboratingPWA(ownerBundleID: "at.studio.AsideBrowser", apps: [notionPWA, windowlessMeet]))
    }
}

@MainActor
private final class FakeMeetingService: MeetingServiceProviding {
    var recordingContext: RecordingMeetingContext?
    var phase: MeetingPhase = .idle
    var statusMessage = "Ready"
    var segments: [MeetingSegment] = []
    var elapsedSeconds: TimeInterval = 0
    var modelReady = false
    var lastSavedURL: URL?
    var setupProgress: Double = 0
    var captureWarning: String?
    var transcription: MeetingTranscriptionState = .idle
    var speakerModelReady: Bool { modelReady }
    var lastTranscriptURL: URL?
    var keepsAudio = false
    var transcriptDirectory = URL(fileURLWithPath: "/private/tmp/sunday-voice-meeting-test-unused")
    let changes = PassthroughSubject<Void, Never>()
    var meetingChanges: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }
    var prepareCalls = 0, startCalls = 0, stopCalls = 0, resumeCalls = 0, cancelTranscriptionCalls = 0
    /// What the real service reports once capture has ended.
    var transcriptionAfterStop: MeetingTranscriptionState?
    func resumePendingTranscriptions() { resumeCalls += 1 }
    func cancelTranscription() { cancelTranscriptionCalls += 1 }
    var startFails = false
    var startCancelled = false
    var events: [String] = []
    var startGate: CheckedContinuation<Void, Never>?
    var waitDuringStart = false
    var onStart: () -> Void = {}

    func prepareModel() async throws { prepareCalls += 1; modelReady = true; phase = .idle }
    func start() async throws {
        startCalls += 1; events.append("start")
        onStart()
        if waitDuringStart { await withCheckedContinuation { startGate = $0 } }
        if startCancelled { throw CancellationError() }
        if startFails { throw TestFailure.start }
        phase = .recording
    }
    func stop() async {
        stopCalls += 1; events.append("stop"); phase = .idle
        if let transcriptionAfterStop { transcription = transcriptionAfterStop }
    }
    enum TestFailure: Error { case start }
}

private final class FakeMeetingDetector: MeetingDetecting {
    var onCandidate: (@MainActor (MeetingCandidate) -> Void)?
    var onPresence: (@MainActor (MeetingDetectionSnapshot) -> Void)?
    var starts = 0, stops = 0, dismisses = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func dismissCurrentCandidate() { dismisses += 1 }
}

@MainActor
private final class FakeMeetingCalendar: MeetingCalendarProviding {
    var onEvents: (([CalendarMeeting]) -> Void)?
    var onStatus: ((String) -> Void)?
    func start() {}
    func stop() {}
    func requestAccess() async {}
}

@MainActor
final class MeetingCoordinatorTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    override func setUp() {
        super.setUp()
        suite = "SundayVoice.MeetingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite); super.tearDown() }

    private func coordinator(_ service: FakeMeetingService, detector: FakeMeetingDetector = FakeMeetingDetector()) -> MeetingCoordinator {
        let auth = FakeGoogleCalendarAuth()
        auth.user = nil
        return MeetingCoordinator(service: service, detector: detector, defaults: defaults, presentsPanels: false, calendar: FakeMeetingCalendar(),
            googleCalendar: GoogleMeetingCalendar(auth: auth, defaults: defaults))
    }

    func testDetectedAppAndWindowPersistOnlyWhenRecordingStarts() async {
        let service = FakeMeetingService(), detector = FakeMeetingDetector()
        service.modelReady = true
        let model = coordinator(service, detector: detector)
        model.startMonitoring()
        let candidate = MeetingCandidate(appName: "Aside", bundleID: "at.studio.AsideBrowser", windowTitle: "Meet - Synthetic title")
        detector.onCandidate?(candidate)
        XCTAssertNil(service.recordingContext)
        await model.startRecording()
        XCTAssertEqual(service.recordingContext, RecordingMeetingContext(appName: candidate.appName, bundleID: candidate.bundleID, windowTitle: candidate.windowTitle))
        await model.stop()
        model.presentManualStart()
        await model.startRecording()
        XCTAssertNil(service.recordingContext?.windowTitle)
        XCTAssertNil(service.recordingContext?.appName)
        await model.stop()
    }

    func testDetectionNeverDownloadsAndFirstStartRecordsBeforeAnyModelExists() async {
        let service = FakeMeetingService(), detector = FakeMeetingDetector()
        let model = coordinator(service, detector: detector)
        model.startMonitoring()
        detector.onCandidate?(MeetingCandidate(appName: "Zoom", bundleID: "us.zoom.xos"))
        XCTAssertEqual(model.panelKind, .invitation)
        XCTAssertEqual(service.startCalls, 0)
        XCTAssertEqual(service.prepareCalls, 0)
        XCTAssertTrue(model.needsModelSetup)
        // Recording is never held back by a missing model: the meeting is captured now, transcribed later.
        await model.startRecording()
        XCTAssertEqual(model.panelKind, .recording)
        XCTAssertEqual(service.startCalls, 1)
        XCTAssertEqual(service.prepareCalls, 0)
        service.transcriptionAfterStop = .waitingForModel(pending: 1)
        await model.stop()
        XCTAssertEqual(model.panelKind, .result)
        XCTAssertEqual(model.transcription, .waitingForModel(pending: 1))
        XCTAssertEqual(model.resultTitle, "Recording saved")
        // Download stays an explicit action.
        XCTAssertEqual(service.prepareCalls, 0)
        await model.prepareModel()
        XCTAssertTrue(model.modelReady)
        XCTAssertFalse(model.needsModelSetup)
        XCTAssertEqual(service.prepareCalls, 1)
        XCTAssertEqual(service.startCalls, 1)
    }

    func testDictationIsReleasedWhenTheRecordingIsSavedWhileTheTranscriptIsStillBeingWritten() async {
        let service = FakeMeetingService(); service.modelReady = true
        let model = coordinator(service)
        var claims: [Bool] = []
        model.onRecordingChanged = { claims.append($0) }
        model.startMonitoring()
        XCTAssertEqual(service.resumeCalls, 1, "Recordings left by an earlier quit are picked up at launch")
        model.startMonitoring()
        XCTAssertEqual(service.resumeCalls, 1)
        await model.startRecording()
        service.transcriptionAfterStop = .running(progress: 0.25, pending: 1)
        await model.stop()
        XCTAssertEqual(claims, [true, false], "The microphone goes back to dictation without waiting for the transcript")
        XCTAssertFalse(model.isBusy, "A new meeting can be recorded while the last one is transcribed")
        XCTAssertEqual(model.transcriptionProgress, 0.25)
        XCTAssertEqual(model.resultTitle, "Recording saved")
        service.transcription = .idle
        service.changes.send()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.transcriptionProgress)
        XCTAssertEqual(model.resultTitle, "Meeting finished")
        await model.shutdown()
        XCTAssertEqual(service.cancelTranscriptionCalls, 1, "Quitting leaves unfinished audio for the next launch instead of blocking")
    }

    func testTranscriptionStatusSummaryFormatsDeterminateProgressAndETAsInKoreanAndEnglish() {
        let loading = MeetingTranscriptionProgress(fraction: 0, processedAudioSeconds: 0, totalAudioSeconds: 1200, estimatedRemainingSeconds: nil)
        XCTAssertEqual(MeetingCoordinator.transcriptionStatusSummary(loading, isKorean: false).etaLabel, "Loading speech models…")
        XCTAssertEqual(MeetingCoordinator.transcriptionStatusSummary(loading, isKorean: true).etaLabel, "음성 모델을 불러오는 중이에요…")

        let estimating = MeetingTranscriptionProgress(fraction: 0.05, processedAudioSeconds: 60, totalAudioSeconds: 1200, estimatedRemainingSeconds: nil)
        XCTAssertEqual(MeetingCoordinator.transcriptionStatusSummary(estimating, isKorean: false), .init(progressLabel: "5% · 01:00 / 20:00", etaLabel: "Estimating time left…"))
        XCTAssertEqual(MeetingCoordinator.transcriptionStatusSummary(estimating, isKorean: true), .init(progressLabel: "5% · 01:00 / 20:00", etaLabel: "남은 시간을 계산하고 있어요…"))

        let threeMin = MeetingTranscriptionProgress(fraction: 0.35, processedAudioSeconds: 420, totalAudioSeconds: 1200, estimatedRemainingSeconds: 185)
        XCTAssertEqual(MeetingCoordinator.transcriptionStatusSummary(threeMin, isKorean: false), .init(progressLabel: "35% · 07:00 / 20:00", etaLabel: "About 3 min left"))
        XCTAssertEqual(MeetingCoordinator.transcriptionStatusSummary(threeMin, isKorean: true), .init(progressLabel: "35% · 07:00 / 20:00", etaLabel: "약 3분 남음"))

        let oneMin = MeetingTranscriptionProgress(fraction: 0.72, processedAudioSeconds: 864, totalAudioSeconds: 1200, estimatedRemainingSeconds: 65)
        XCTAssertEqual(MeetingCoordinator.transcriptionStatusSummary(oneMin, isKorean: false).etaLabel, "About 1 min left")
        XCTAssertEqual(MeetingCoordinator.transcriptionStatusSummary(oneMin, isKorean: true).etaLabel, "약 1분 남음")

        let thirtySec = MeetingTranscriptionProgress(fraction: 0.85, processedAudioSeconds: 1020, totalAudioSeconds: 1200, estimatedRemainingSeconds: 28)
        XCTAssertEqual(MeetingCoordinator.transcriptionStatusSummary(thirtySec, isKorean: false).etaLabel, "About 30 sec left")
        XCTAssertEqual(MeetingCoordinator.transcriptionStatusSummary(thirtySec, isKorean: true).etaLabel, "약 30초 남음")

        let almostDone = MeetingTranscriptionProgress(fraction: 0.96, processedAudioSeconds: 1152, totalAudioSeconds: 1200, estimatedRemainingSeconds: 5)
        XCTAssertEqual(MeetingCoordinator.transcriptionStatusSummary(almostDone, isKorean: false).etaLabel, "Almost done")
        XCTAssertEqual(MeetingCoordinator.transcriptionStatusSummary(almostDone, isKorean: true).etaLabel, "거의 다 됐어요")

        let unknownTotal = MeetingTranscriptionProgress(fraction: 0.4, processedAudioSeconds: 0, totalAudioSeconds: 0, estimatedRemainingSeconds: nil)
        XCTAssertEqual(MeetingCoordinator.transcriptionStatusSummary(unknownTotal, isKorean: false), .init(progressLabel: "40%", etaLabel: "Estimating time left…"))
    }

    func testKeepAudioChoiceIsOffByDefaultPersistsAndReachesTheEngine() {
        let service = FakeMeetingService()
        let model = coordinator(service)
        XCTAssertFalse(model.keepAudioEnabled)
        XCTAssertFalse(service.keepsAudio)
        model.keepAudioEnabled = true
        XCTAssertTrue(service.keepsAudio)
        let relaunched = FakeMeetingService()
        XCTAssertTrue(coordinator(relaunched).keepAudioEnabled)
        XCTAssertTrue(relaunched.keepsAudio)
    }

    func testAutoStartPreferencePersistsWithoutOptingInOtherUsers() {
        let model = coordinator(FakeMeetingService())
        XCTAssertFalse(model.autoStartEnabled)
        model.autoStartEnabled = true
        XCTAssertTrue(coordinator(FakeMeetingService()).autoStartEnabled)
        model.autoStartEnabled = false
        XCTAssertFalse(coordinator(FakeMeetingService()).autoStartEnabled)
    }

    private func automaticCoordinator(_ service: FakeMeetingService, detector: FakeMeetingDetector) -> MeetingCoordinator {
        service.modelReady = true
        let model = coordinator(service, detector: detector)
        model.autoStartEnabled = true
        model.automaticStartPermissionsGranted = { true }
        model.startMonitoring()
        return model
    }

    private func detectCall(_ owner: String, detector: FakeMeetingDetector) {
        detector.onPresence?(MeetingDetectionSnapshot(activeCallOwners: [owner], activeAudioOwners: [owner]))
        detector.onCandidate?(MeetingCandidate(appName: "Synthetic call", bundleID: owner))
    }

    func testAutomaticDetectedCallsStartWithoutInvitationAndBindTheirOwner() async {
        for owner in ["at.studio.AsideBrowser", "com.google.Chrome", "com.apple.Safari", "us.zoom.xos",
                      "com.microsoft.teams2", "com.tinyspeck.slackmacgap", "com.apple.FaceTime"] {
            let service = FakeMeetingService(), detector = FakeMeetingDetector()
            let model = automaticCoordinator(service, detector: detector)
            let started = expectation(description: owner)
            service.onStart = { started.fulfill() }
            model.onRecordingChanged = { service.events.append($0 ? "claim" : "release") }
            detectCall(owner, detector: detector)
            XCTAssertNil(model.panelKind) // no start card to click
            await fulfillment(of: [started], timeout: 3)
            XCTAssertEqual(service.startCalls, 1)
            XCTAssertEqual(model.panelKind, .recording)
            XCTAssertEqual(model.endPolicy.recordedCallOwners, [owner])
            XCTAssertTrue(model.endPolicy.armed)
            await model.stop()
            XCTAssertEqual(service.events, ["claim", "start", "stop", "release"])
            model.stopMonitoring()
        }
    }

    func testAutomaticCallWaitsForDictationAndStartsOnTheNextPresencePoll() async {
        let service = FakeMeetingService(), detector = FakeMeetingDetector()
        let model = automaticCoordinator(service, detector: detector)
        var dictationBusy = true
        model.canStartRecording = { !dictationBusy }
        detectCall("at.studio.AsideBrowser", detector: detector)
        XCTAssertEqual(service.startCalls, 0)
        XCTAssertNil(model.panelKind)
        let started = expectation(description: "dictation finished")
        service.onStart = { started.fulfill() }
        dictationBusy = false
        detector.onPresence?(MeetingDetectionSnapshot(activeCallOwners: ["at.studio.AsideBrowser"]))
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(service.startCalls, 1)
        await model.shutdown()
    }

    func testAutomaticStartDoesNotRequestPermissionsOrDownloadModel() async {
        let service = FakeMeetingService(), detector = FakeMeetingDetector()
        let model = automaticCoordinator(service, detector: detector)
        model.automaticStartPermissionsGranted = { false }
        detectCall("us.zoom.xos", detector: detector)
        XCTAssertEqual(model.panelKind, .invitation)
        XCTAssertEqual(service.startCalls, 0)
        model.dismissSuggestion()
        model.automaticStartPermissionsGranted = { true }
        service.modelReady = false
        service.changes.send()
        // A new coordinator reads the absent model synchronously.
        model.stopMonitoring()
        let missingModel = coordinator(service, detector: detector)
        missingModel.autoStartEnabled = true
        missingModel.automaticStartPermissionsGranted = { true }
        missingModel.startMonitoring()
        let started = expectation(description: "records without a model")
        service.onStart = { started.fulfill() }
        detectCall("us.zoom.xos", detector: detector)
        await fulfillment(of: [started], timeout: 3)
        // A detected call is recorded even before the speech model exists; nothing is downloaded for it.
        XCTAssertEqual(service.startCalls, 1)
        XCTAssertEqual(service.prepareCalls, 0)
        await missingModel.stop()
        missingModel.stopMonitoring()
    }

    func testCallEndingOrOptOutBeforeQueuedAutoStartPreventsCapture() async {
        for invalidation in ["call left", "disabled", "dismissed", "monitoring stopped"] {
            let service = FakeMeetingService(), detector = FakeMeetingDetector()
            let model = automaticCoordinator(service, detector: detector)
            detectCall("us.zoom.xos", detector: detector)
            switch invalidation {
            case "call left": detector.onPresence?(MeetingDetectionSnapshot())
            case "disabled": model.autoStartEnabled = false
            case "dismissed": model.dismissSuggestion()
            default: model.stopMonitoring()
            }
            // A following main-actor task runs after the queued automatic attempt.
            await Task { @MainActor in }.value
            XCTAssertEqual(service.startCalls, 0, invalidation)
            model.stopMonitoring()
        }
    }

    func testCalendarReminderAndUnrelatedMicrophoneNeverAutoStart() async {
        let service = FakeMeetingService(), detector = FakeMeetingDetector()
        let model = automaticCoordinator(service, detector: detector)
        let now = Date()
        model.receiveCalendarEvents([CalendarMeeting(id: "future", title: "Synthetic", attendees: [],
            startsAt: now.addingTimeInterval(60), endsAt: now.addingTimeInterval(3600),
            videoURL: URL(string: "https://meet.google.com/abc-defg-hij")!)], now: now)
        detector.onPresence?(MeetingDetectionSnapshot(activeMicrophoneOwners: ["com.google.Chrome"], activeAudioOwners: ["com.google.Chrome"]))
        await Task { @MainActor in }.value
        XCTAssertEqual(service.startCalls, 0)
        XCTAssertEqual(model.panelKind, .invitation)
        let started = expectation(description: "actual joined call overrides reminder")
        service.onStart = { started.fulfill() }
        detectCall("at.studio.AsideBrowser", detector: detector)
        await fulfillment(of: [started], timeout: 3)
        XCTAssertNil(model.scheduledMeeting)
        await model.shutdown()
    }

    func testAutomaticStartWorksWithSuggestionsOffAndAfterPreviousSavedResult() async {
        let service = FakeMeetingService(), detector = FakeMeetingDetector()
        let model = automaticCoordinator(service, detector: detector)
        model.detectionEnabled = false
        let first = expectation(description: "first call")
        service.onStart = { first.fulfill() }
        detectCall("us.zoom.xos", detector: detector)
        await fulfillment(of: [first], timeout: 3)
        await model.stop()
        XCTAssertEqual(model.panelKind, .result)
        let second = expectation(description: "second call")
        service.onStart = { second.fulfill() }
        detectCall("com.microsoft.teams2", detector: detector)
        await fulfillment(of: [second], timeout: 3)
        XCTAssertEqual(service.startCalls, 2)
        XCTAssertEqual(model.endPolicy.recordedCallOwners, ["com.microsoft.teams2"])
        await model.shutdown()
    }

    func testAutomaticallyStartedCallStopsEvenIfItLeavesBeforeAnotherJoinedPoll() async {
        let service = FakeMeetingService(), detector = FakeMeetingDetector()
        let model = automaticCoordinator(service, detector: detector)
        model.endPolicy.grace = 0
        model.autoStopCountdown = 0
        let started = expectation(description: "automatic start")
        let stopped = expectation(description: "automatic stop and save path")
        service.onStart = { started.fulfill() }
        model.onRecordingChanged = { active in if !active { stopped.fulfill() } }
        detectCall("at.studio.AsideBrowser", detector: detector)
        await fulfillment(of: [started], timeout: 3)
        detector.onPresence?(MeetingDetectionSnapshot(activeCallOwners: ["us.zoom.xos"],
            activeAudioOwners: ["us.zoom.xos", "com.google.Chrome"]))
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(service.stopCalls, 1)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.autoStopped)
        await model.shutdown()
    }

    func testCloudMicrophoneOwnershipChangesBeforeStartAndAfterStop() async {
        let service = FakeMeetingService(); service.modelReady = true
        let model = coordinator(service)
        model.onRecordingChanged = { service.events.append($0 ? "claim" : "release") }
        await model.startRecording()
        XCTAssertEqual(service.events, ["claim", "start"])
        await model.stop()
        XCTAssertEqual(service.events, ["claim", "start", "stop", "release"])
    }

    func testBusyDictationIsNotInterrupted() async {
        let service = FakeMeetingService(); service.modelReady = true
        let model = coordinator(service)
        var ownershipChanges = 0
        model.canStartRecording = { false }
        model.onRecordingChanged = { _ in ownershipChanges += 1 }
        await model.startRecording()
        XCTAssertEqual(service.startCalls, 0)
        XCTAssertEqual(ownershipChanges, 0)
        XCTAssertEqual(model.statusMessage, "Finish your dictation, then start the meeting.")
    }

    func testDuplicateStartIsFencedWhilePermissionsOrCapturePrepare() async {
        let service = FakeMeetingService(); service.modelReady = true; service.waitDuringStart = true
        let model = coordinator(service)
        let first = Task { await model.startRecording() }
        for _ in 0..<100 where service.startGate == nil { await Task.yield() }
        guard service.startGate != nil else { first.cancel(); XCTFail("Start did not reach the fake service"); return }
        await model.startRecording()
        XCTAssertEqual(service.startCalls, 1)
        service.startGate?.resume(); service.startGate = nil
        await first.value
    }

    func testStartFailureCleansCaptureBeforeCloudResume() async {
        let service = FakeMeetingService(); service.modelReady = true; service.startFails = true
        let model = coordinator(service)
        model.onRecordingChanged = { service.events.append($0 ? "claim" : "release") }
        await model.startRecording()
        XCTAssertEqual(service.events, ["claim", "start", "stop", "release"])
        XCTAssertEqual(model.phase, .failed)
    }

    func testCancelledStartCleansCaptureWithoutShowingPermissionFailure() async {
        let service = FakeMeetingService(); service.modelReady = true; service.startCancelled = true
        let model = coordinator(service)
        model.onRecordingChanged = { service.events.append($0 ? "claim" : "release") }
        await model.startRecording()
        XCTAssertEqual(service.events, ["claim", "start", "stop", "release"])
        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.statusMessage.contains("could not start"))
        XCTAssertFalse(model.isBusy)
    }

    func testShutdownNeverResumesCloudDictation() async {
        let service = FakeMeetingService(); service.modelReady = true
        let model = coordinator(service)
        model.onRecordingChanged = { service.events.append($0 ? "claim" : "release") }
        await model.startRecording()
        await model.shutdown()
        XCTAssertEqual(service.events, ["claim", "start", "stop"])
        XCTAssertNil(model.panelKind)
        await model.startRecording()
        XCTAssertEqual(service.startCalls, 1)
    }

    func testDisabledDetectionStillAllowsManualStart() {
        let service = FakeMeetingService(), detector = FakeMeetingDetector()
        let model = coordinator(service, detector: detector)
        model.detectionEnabled = false
        model.startMonitoring()
        detector.onCandidate?(MeetingCandidate(appName: "Zoom", bundleID: "us.zoom.xos"))
        XCTAssertNil(model.panelKind)
        model.presentManualStart()
        XCTAssertEqual(model.panelKind, .invitation)
        XCTAssertEqual(detector.starts, 0)
    }

    func testSignOutSuspendsWithoutRestartingCloudDictation() async {
        let service = FakeMeetingService(); service.modelReady = true
        let model = coordinator(service)
        model.onRecordingChanged = { service.events.append($0 ? "claim" : "release") }
        await model.startRecording()
        await model.suspend()
        XCTAssertEqual(service.events, ["claim", "start", "stop"])
        await model.startRecording()
        XCTAssertEqual(service.startCalls, 1)
    }

    func testElapsedTimerSupportsLongMeetings() {
        XCTAssertEqual(MeetingCoordinator.elapsedLabel(65), "01:05")
        XCTAssertEqual(MeetingCoordinator.elapsedLabel(3665), "1:01:05")
    }

    func testOpenTranscriptsRevealsSavedFileAndFallsBackToExistingFolder() throws {
        let service = FakeMeetingService()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("Transcript.txt")
        try Data("Synthetic test".utf8).write(to: transcript)
        service.transcriptDirectory = root
        service.lastSavedURL = transcript
        let model = coordinator(service)
        var revealed: [URL] = []
        model.revealTranscript = { revealed.append($0) }
        model.openTranscripts()
        XCTAssertEqual(revealed, [transcript])
        try FileManager.default.removeItem(at: transcript)
        model.openTranscripts()
        XCTAssertEqual(revealed.last, root)
    }

    func testReconnectKeepsMeetingBusyAndAudioOwned() async throws {
        let service = FakeMeetingService(); service.modelReady = true
        let model = coordinator(service)
        var releases = 0
        model.onRecordingChanged = { if !$0 { releases += 1 } }
        await model.startRecording()
        service.phase = .recovering
        service.statusMessage = "Audio interrupted — reconnecting automatically."
        service.changes.send()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.panelKind, .recording)
        XCTAssertEqual(releases, 0)
        await model.startRecording()
        XCTAssertEqual(service.startCalls, 1)
    }

    func testCalendarPrefillsWithoutStartingAndDismissSuppressesOccurrence() {
        let service = FakeMeetingService()
        let model = coordinator(service)
        model.calendarEnabled = true
        model.startMonitoring()
        let now = Date()
        let event = CalendarMeeting(id: "synthetic", title: "Synthetic meeting", attendees: ["Test attendee"],
            startsAt: now.addingTimeInterval(119), endsAt: now.addingTimeInterval(1800), videoURL: URL(string: "https://meet.google.com/abc-test-xyz")!)
        model.receiveCalendarEvents([event], now: now)
        XCTAssertEqual(model.scheduledMeeting, event)
        XCTAssertEqual(model.panelKind, .invitation)
        XCTAssertEqual(service.startCalls, 0)
        model.dismissSuggestion()
        model.receiveCalendarEvents([event], now: now)
        XCTAssertNil(model.panelKind)
        model.stopMonitoring()
    }

    func testMeetingCardsUseLeftCentreOnOffsetDisplays() {
        let frame = NSRect(x: -1920, y: 200, width: 1920, height: 1080)
        let size = NSSize(width: 384, height: 220)
        let point = MeetingPanelController.origin(for: size, on: frame)
        XCTAssertEqual(point.x, frame.minX + HUD.edgeInset)
        XCTAssertEqual(point.y + size.height / 2, frame.midY)
    }

    func testManualCardClosesSettingsButPassiveDetectionDoesNot() {
        let model = coordinator(FakeMeetingService())
        var closes = 0
        model.onManualPresentation = { closes += 1 }
        model.startMonitoring()
        model.receiveCandidate(MeetingCandidate(appName: "Aside", bundleID: "at.studio.AsideBrowser"))
        XCTAssertEqual(closes, 0)
        model.presentManualStart()
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(model.panelKind, .invitation)
        model.stopMonitoring()
    }

    func testSettingsRoutesToOneAppWindowAndDismissesIdleCard() {
        let model = coordinator(FakeMeetingService())
        var opens = 0
        model.onShowSettings = { opens += 1 }
        model.presentManualStart()
        model.presentSettings()
        XCTAssertNil(model.panelKind)
        XCTAssertEqual(opens, 1)
    }

    func testSettingsDuringRecordingKeepsRecordingCard() async {
        let service = FakeMeetingService(); service.modelReady = true
        let model = coordinator(service)
        var opens = 0
        model.onShowSettings = { opens += 1 }
        await model.startRecording()
        model.presentSettings()
        XCTAssertEqual(model.panelKind, .recording)
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(service.stopCalls, 0)
    }

    func testLongRecoveryMessageResizesCardAroundTheSameCentre() async throws {
        let service = FakeMeetingService(); service.modelReady = true
        let model = coordinator(service)
        await model.startRecording()
        let controller = MeetingPanelController()
        controller.show(coordinator: model)
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(100))
        let first = try XCTUnwrap(controller.frame)
        service.phase = .recovering
        service.statusMessage = String(repeating: "Reconnecting audio. Your saved notes are safe. ", count: 7)
        service.changes.send()
        try await Task.sleep(for: .milliseconds(150))
        let expanded = try XCTUnwrap(controller.frame)
        XCTAssertGreaterThan(expanded.height, first.height)
        XCTAssertEqual(expanded.midY, first.midY, accuracy: 1)
        XCTAssertEqual(expanded.minX, first.minX, accuracy: 1)
    }

    func testOnlyHealthyRecordingFoldsIntoPill() {
        XCTAssertTrue(MeetingPanelController.showsCompactRecording(kind: .recording, phase: .recording, expanded: false))
        XCTAssertFalse(MeetingPanelController.showsCompactRecording(kind: .recording, phase: .recording, expanded: true))
        for phase in [MeetingPhase.preparing, .recovering, .finalizing, .failed] {
            XCTAssertFalse(MeetingPanelController.showsCompactRecording(kind: .recording, phase: phase, expanded: false))
        }
        XCTAssertFalse(MeetingPanelController.showsCompactRecording(kind: .invitation, phase: .idle, expanded: false))
        XCTAssertFalse(MeetingPanelController.showsCompactRecording(kind: .result, phase: .idle, expanded: false))
    }

    func testRecordingCardFoldsIntoPillAroundTheSameCentre() async throws {
        let intro = MeetingPanelController.recordingIntroSeconds
        MeetingPanelController.recordingIntroSeconds = 0.2
        defer { MeetingPanelController.recordingIntroSeconds = intro }
        let service = FakeMeetingService(); service.modelReady = true
        service.statusMessage = "Recording locally — microphone + Mac audio"
        service.elapsedSeconds = 125
        let model = coordinator(service)
        await model.startRecording()
        let controller = MeetingPanelController()
        controller.show(coordinator: model)
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(80))
        let full = try XCTUnwrap(controller.frame)
        try snapshot(controller, "recording-expanded")
        try await Task.sleep(for: .milliseconds(450))
        let pill = try XCTUnwrap(controller.frame)
        try snapshot(controller, "recording-pill")
        XCTAssertLessThan(pill.height, 64)
        XCTAssertLessThan(pill.width, 220)
        XCTAssertLessThan(pill.width * pill.height, full.width * full.height / 5)
        XCTAssertEqual(pill.midY, full.midY, accuracy: 1)
        XCTAssertEqual(pill.minX, full.minX, accuracy: 1)
        // A capture problem must never hide behind the pill.
        service.phase = .recovering
        service.statusMessage = "Audio interrupted — reconnecting automatically. Keep this meeting open."
        service.changes.send()
        try await Task.sleep(for: .milliseconds(150))
        let recovering = try XCTUnwrap(controller.frame)
        XCTAssertGreaterThan(recovering.height, pill.height * 2)
        XCTAssertEqual(recovering.midY, full.midY, accuracy: 1)
    }

    func testCallEndedCountdownAndSavedCardsRender() async throws {
        let service = FakeMeetingService(), detector = FakeMeetingDetector()
        let model = await recordingWithCall(service, detector)
        model.autoStopCountdown = 0.6
        model.autoStopResultSeconds = 5
        service.elapsedSeconds = 2_710
        service.changes.send()
        model.receivePresence([], now: 1)
        model.receivePresence([], now: 47)
        let controller = MeetingPanelController()
        controller.show(coordinator: model)
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(80))
        let countdown = try XCTUnwrap(controller.frame)
        XCTAssertGreaterThan(countdown.height, 100, "the countdown never hides in the pill")
        try snapshot(controller, "call-ended-countdown")
        service.statusMessage = "Saved to Meetings on this Mac."
        service.lastSavedURL = URL(fileURLWithPath: "/private/tmp/sunday-voice-meeting-test-unused/Transcript.txt")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(model.panelKind, .result)
        controller.show(coordinator: model)
        try await Task.sleep(for: .milliseconds(80))
        try snapshot(controller, "call-ended-saved")
    }

    /// `TEST_RUNNER_MEETING_SNAPSHOT_DIR=<dir>` saves the rendered panel for visual review.
    private func snapshot(_ controller: MeetingPanelController, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["MEETING_SNAPSHOT_DIR"],
              let view = controller.contentView else { return }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            view.window?.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(suffix).png"))
        }
        view.window?.appearance = nil
    }

    func testEndPolicyArmsOnlyAfterACallAndWaitsForGrace() {
        var policy = MeetingEndPolicy(); policy.grace = 45
        XCTAssertFalse(policy.observe(activeCallOwners: [], now: 0))
        XCTAssertFalse(policy.observe(activeCallOwners: [], now: 600), "no call seen: in-person meetings never stop")
        XCTAssertFalse(policy.observe(activeCallOwners: ["com.google.Chrome"], now: 601))
        XCTAssertFalse(policy.observe(activeCallOwners: [], now: 610))
        XCTAssertFalse(policy.observe(activeCallOwners: [], now: 654))
        XCTAssertFalse(policy.observe(activeCallOwners: ["com.google.Chrome"], now: 655), "a brief dropout resets the grace")
        XCTAssertFalse(policy.observe(activeCallOwners: [], now: 660))
        XCTAssertTrue(policy.observe(activeCallOwners: [], now: 705))
        XCTAssertFalse(policy.observe(activeCallOwners: [], now: 900), "fires once")
    }

    private func recordingWithCall(_ service: FakeMeetingService, _ detector: FakeMeetingDetector) async -> MeetingCoordinator {
        service.modelReady = true
        let model = coordinator(service, detector: detector)
        model.autoStopCountdown = 0.1
        model.autoStopResultSeconds = 0.1
        model.endPolicy.grace = 45
        await model.startRecording()
        model.receivePresence(["com.google.Chrome"], now: 0)
        return model
    }

    func testCallEndStopsAndSavesAfterGraceAndCountdown() async throws {
        let service = FakeMeetingService(), detector = FakeMeetingDetector()
        let model = await recordingWithCall(service, detector)
        model.autoStopResultSeconds = 0.6
        model.receivePresence([], now: 10)
        model.receivePresence([], now: 50)
        XCTAssertNil(model.autoStopDeadline)
        model.receivePresence([], now: 55)
        XCTAssertNotNil(model.autoStopDeadline)
        XCTAssertEqual(service.stopCalls, 0, "a countdown comes first")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(service.stopCalls, 1)
        XCTAssertTrue(model.autoStopped)
        XCTAssertEqual(model.panelKind, .result)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(model.panelKind, "the saved notice leaves on its own")
    }

    func testAnotherAppsAudioCannotExtendTheRecordedCall() async throws {
        let service = FakeMeetingService(), detector = FakeMeetingDetector()
        let model = await recordingWithCall(service, detector)
        // Another recognized app starts using audio before the original Chrome call ends.
        model.receivePresence(["com.google.Chrome", "us.zoom.xos"], now: 3)
        model.receivePresence(["us.zoom.xos"], now: 6)
        model.receivePresence(["us.zoom.xos"], now: 51)
        XCTAssertNotNil(model.autoStopDeadline)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(service.stopCalls, 1)
        XCTAssertTrue(model.autoStopped)
        XCTAssertFalse(model.isBusy)
    }

    func testTabSwitchAndBriefDropoutDoNotStopCallButAnotherMicCannotContinueIt() async throws {
        let service = FakeMeetingService(); service.modelReady = true
        let detector = FakeMeetingDetector()
        let model = coordinator(service, detector: detector)
        model.autoStopCountdown = 0.1
        await model.startRecording()
        func poll(callInput: Bool, windowVisible: Bool) -> MeetingDetectionSnapshot {
            MeetingDetector.snapshot(from: [
                MeetingAudioActivity(bundleID: "at.studio.AsideBrowser", processID: 10, input: callInput, output: true),
                MeetingAudioActivity(bundleID: "com.google.Chrome", processID: 20, input: true, output: false)
            ], applicationPID: { _ in nil }, callWindow: { pid, _ in
                windowVisible && pid == 10 ? "meet-window" : nil
            })
        }
        model.receivePresence(poll(callInput: true, windowVisible: true), now: 0)
        model.receivePresence(poll(callInput: true, windowVisible: false), now: 60)
        model.receivePresence(poll(callInput: false, windowVisible: false), now: 63)
        model.receivePresence(poll(callInput: true, windowVisible: false), now: 66)
        model.receivePresence(poll(callInput: true, windowVisible: false), now: 120)
        XCTAssertNil(model.autoStopDeadline, "tab switches and a short audio dropout preserve this call")
        model.receivePresence(poll(callInput: false, windowVisible: false), now: 123)
        model.receivePresence(poll(callInput: false, windowVisible: false), now: 168)
        XCTAssertNotNil(model.autoStopDeadline)
        model.receivePresence(poll(callInput: false, windowVisible: false), now: 171)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.autoStopped)
        XCTAssertEqual(service.stopCalls, 1)
    }

    func testAnotherAppCannotCancelTheStopCountdown() async throws {
        let service = FakeMeetingService(), detector = FakeMeetingDetector()
        let model = await recordingWithCall(service, detector)
        model.receivePresence([], now: 3)
        model.receivePresence([], now: 48)
        let deadline = try XCTUnwrap(model.autoStopDeadline)
        model.receivePresence(["at.studio.AsideBrowser"], now: 49)
        XCTAssertEqual(model.autoStopDeadline, deadline)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(service.stopCalls, 1)
        XCTAssertTrue(model.autoStopped)
    }

    func testReturningOriginalCallCancelsCountdownWithOtherAppsPresent() async throws {
        let service = FakeMeetingService(), detector = FakeMeetingDetector()
        let model = await recordingWithCall(service, detector)
        model.receivePresence([], now: 3)
        model.receivePresence([], now: 48)
        XCTAssertNotNil(model.autoStopDeadline)
        model.receivePresence(["com.google.Chrome", "us.zoom.xos"], now: 49)
        XCTAssertNil(model.autoStopDeadline)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(service.stopCalls, 0)
        model.receivePresence(["us.zoom.xos"], now: 52)
        model.receivePresence(["us.zoom.xos"], now: 97)
        XCTAssertNotNil(model.autoStopDeadline)
        await model.stop()
    }

    func testDetectedStartTracksTheSuggestedAppEvenIfAnotherCallIsAlreadyPresent() async throws {
        let service = FakeMeetingService(); service.modelReady = true
        let model = coordinator(service)
        model.startMonitoring()
        model.receiveCandidate(MeetingCandidate(appName: "Aside", bundleID: "at.studio.AsideBrowser"))
        model.autoStopCountdown = 0.1
        await model.startRecording()
        model.receivePresence(["at.studio.AsideBrowser", "us.zoom.xos"], now: 0)
        model.receivePresence(["us.zoom.xos"], now: 3)
        model.receivePresence(["us.zoom.xos"], now: 48)
        XCTAssertNotNil(model.autoStopDeadline)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(service.stopCalls, 1)
        model.stopMonitoring()
    }

    func testUnrelatedMicrophoneDoesNotArmAnInPersonRecording() async {
        let service = FakeMeetingService(); service.modelReady = true
        let model = coordinator(service)
        await model.startRecording()
        let unrelated = MeetingDetector.snapshot(from: [
            MeetingAudioActivity(bundleID: "com.google.Chrome", processID: 10, input: true, output: false)
        ], applicationPID: { _ in nil }, callWindow: { _, _ in nil })
        model.receivePresence(unrelated.activeCallOwners, now: 0)
        model.receivePresence([], now: 3)
        model.receivePresence([], now: 3600)
        XCTAssertNil(model.autoStopDeadline)
        XCTAssertEqual(service.stopCalls, 0)
        await model.stop()
    }

    func testKeepRecordingCancelsUntilANewCallEnds() async throws {
        let service = FakeMeetingService(), detector = FakeMeetingDetector()
        let model = await recordingWithCall(service, detector)
        model.autoStopCountdown = 5
        model.receivePresence([], now: 1)
        model.receivePresence([], now: 50)
        XCTAssertNotNil(model.autoStopDeadline)
        model.keepRecording()
        XCTAssertNil(model.autoStopDeadline)
        model.receivePresence([], now: 500)
        model.receivePresence([], now: 900)
        XCTAssertNil(model.autoStopDeadline)
        model.receivePresence(["us.zoom.xos"], now: 901)
        model.receivePresence([], now: 902)
        model.receivePresence([], now: 950)
        XCTAssertNotNil(model.autoStopDeadline)
        model.receivePresence(["us.zoom.xos"], now: 951)
        XCTAssertNil(model.autoStopDeadline, "a returning call cancels the countdown")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(service.stopCalls, 0)
    }

    func testNoCallOrDisabledNeverAutoStops() async throws {
        let service = FakeMeetingService(); service.modelReady = true
        let model = coordinator(service)
        await model.startRecording()
        model.receivePresence([], now: 0)
        model.receivePresence([], now: 3600)
        XCTAssertNil(model.autoStopDeadline)
        model.autoStopEnabled = false
        model.receivePresence(["com.google.Chrome"], now: 3601)
        model.receivePresence([], now: 3700)
        XCTAssertNil(model.autoStopDeadline)
        XCTAssertEqual(service.stopCalls, 0)
    }

    func testRecordingWatchesForCallEndEvenWithSuggestionsOff() async {
        let service = FakeMeetingService(), detector = FakeMeetingDetector()
        service.modelReady = true
        let model = coordinator(service, detector: detector)
        model.detectionEnabled = false
        model.startMonitoring()
        let before = detector.starts
        await model.startRecording()
        XCTAssertGreaterThan(detector.starts, before)
        let stopsBefore = detector.stops
        await model.stop()
        XCTAssertGreaterThan(detector.stops, stopsBefore)
        model.stopMonitoring()
    }

    /// Opt-in live measurement: `TEST_RUNNER_LIVE_MEET_PROBE=<seconds>` and `TEST_RUNNER_LIVE_MEET_PROBE_OUT=<file>`
    /// poll the real detector and log call-presence changes (bundle IDs and times only).
    func testLiveMeetingPresenceProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["LIVE_MEET_PROBE"], let seconds = Double(raw), let out = env["LIVE_MEET_PROBE_OUT"] else {
            throw XCTSkip("live probe not requested")
        }
        let detector = MeetingDetector()
        var lines = ["start \(Date()) axTrusted=\(AXIsProcessTrusted())"]
        var last: Set<String>?
        let started = Date()
        detector.onPresence = { snapshot in
            let owners = snapshot.activeCallOwners
            guard owners != last else { return }
            last = owners
            lines.append(String(format: "%.1f", Date().timeIntervalSince(started)) + " " + owners.sorted().joined(separator: ","))
            try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
        detector.start()
        defer { detector.stop() }
        try await Task.sleep(for: .seconds(seconds))
        lines.append("end")
        try lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }

    func testCalendarRescheduledLaterWithdrawsOldStartCard() {
        let model = coordinator(FakeMeetingService())
        model.startMonitoring()
        let now = Date()
        let link = URL(string: "https://meet.google.com/abc-defg-hij")!
        let first = CalendarMeeting(id: "same", title: "Synthetic", attendees: [], startsAt: now.addingTimeInterval(120),
                                    endsAt: now.addingTimeInterval(3600), videoURL: link)
        model.receiveCalendarEvents([first], now: now)
        XCTAssertEqual(model.panelKind, .invitation)
        let moved = CalendarMeeting(id: "same", title: "Synthetic", attendees: [], startsAt: now.addingTimeInterval(1800),
                                    endsAt: now.addingTimeInterval(5400), videoURL: link)
        model.receiveCalendarEvents([moved], now: now)
        XCTAssertNil(model.panelKind)
        XCTAssertNil(model.scheduledMeeting)
        model.stopMonitoring()
    }

    func testGoogleCalendarSettingsRenderWithMultipleCalendars() async throws {
        let google = GoogleMeetingCalendar(auth: FakeGoogleCalendarAuth(), defaults: defaults) { request in
            let items: [[String: Any]] = request.url!.path.hasSuffix("calendarList") ? [
                ["id": "primary", "summary": "Work", "primary": true, "accessRole": "owner"],
                ["id": "shared", "summary": "Team meetings", "accessRole": "reader"]] : []
            return (try JSONSerialization.data(withJSONObject: ["items": items, "nextSyncToken": "synthetic"]),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await google.refresh()
        let model = MeetingCoordinator(service: FakeMeetingService(), detector: FakeMeetingDetector(), defaults: defaults,
            presentsPanels: false, calendar: FakeMeetingCalendar(), googleCalendar: google)
        Theme.registerFonts()
        let view = MeetingSettingsView(coordinator: model).padding(28).frame(width: 620)
            .background(Theme.ground(.light)).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sunday-voice-google-calendar-settings.png")
        try data.write(to: out)
        XCTAssertGreaterThan(rep.pixelsWide, 600)
    }
}

final class CalendarMeetingTests: XCTestCase {
    func testVideoLinksMustBeKnownProviderHTTPSHosts() {
        XCTAssertNotNil(CalendarMeeting.videoLink(in: "Join https://meet.google.com/abc-defg-hij"))
        XCTAssertNotNil(CalendarMeeting.videoLink(in: "https://us02web.zoom.us/j/123456"))
        XCTAssertNil(CalendarMeeting.videoLink(in: "https://meet.google.com.evil.example/test"))
        XCTAssertNil(CalendarMeeting.videoLink(in: "http://meet.google.com/test"))
        XCTAssertNil(CalendarMeeting.videoLink(in: "https://example.com/meeting"))
    }

    func testTwoMinuteBoundaryRecurringOccurrenceAndMissedMeetingGrace() {
        let now = Date(timeIntervalSince1970: 1000)
        func event(_ id: String, _ seconds: Double) -> CalendarMeeting {
            CalendarMeeting(id: id, title: "Test", attendees: [], startsAt: now.addingTimeInterval(seconds),
                endsAt: now.addingTimeInterval(seconds + 1800), videoURL: URL(string: "https://meet.google.com/test")!)
        }
        var policy = CalendarMeetingPolicy()
        XCTAssertNil(policy.next([event("early", 121)], now: now))
        let first = event("first", 120)
        XCTAssertEqual(policy.next([first], now: now), first)
        policy.dismiss(first)
        XCTAssertNil(policy.next([first], now: now))
        XCTAssertNotNil(policy.next([event("next-occurrence", 100)], now: now))
        XCTAssertNil(policy.next([event("too-late", -121)], now: now))
    }
}
