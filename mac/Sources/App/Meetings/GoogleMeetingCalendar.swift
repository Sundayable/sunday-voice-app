import AppKit
import Combine
import Foundation
import LocalMeetingEngine

/// Calendar suggestions stay in RAM. Authorized recording matches are saved owner-locally.
/// Defaults contain selection IDs per Google subject,
/// never event titles, attendees, descriptions or tokens. No calendar data goes to our server.
@MainActor
final class GoogleMeetingCalendar: ObservableObject {
    @Published private(set) var account: GoogleCalendarAccount?
    @Published private(set) var calendars: [GoogleCalendarChoice] = []
    @Published private(set) var selectedIDs = Set<String>()
    @Published private(set) var status = "Connect Google Calendar to choose your calendars."
    @Published private(set) var busy = false
    @Published private(set) var connecting = false
    @Published private(set) var needsConsent = false
    @Published private(set) var lastSynced: Date?
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "googleMeetingCalendarEnabled")
            if !enabled { invalidate(); onEvents?([]) }
            else if running { tick() }
        }
    }
    var onEvents: (([CalendarMeeting]) -> Void)?
    var onSynchronized: (() -> Void)?
    var loginHint: () -> String? = { nil }
    var accessAllowed: () -> Bool = { true }
    var upcomingMeetingCount: Int {
        Set(caches.values.flatMap { $0.meetings.values }.filter { $0.endsAt > Date() }.map(\.occurrenceKey)).count
    }

    private struct EventCache {
        var meetings: [String: CalendarMeeting] = [:]
        var syncToken: String?
        var fullSyncAt: Date = .distantPast
    }
    private let auth: any GoogleCalendarAuthorizing
    private let api: GoogleCalendarAPI
    private let defaults: UserDefaults
    private var calendarMap: [String: GoogleCalendarChoice] = [:]
    private var calendarSyncToken: String?
    private var caches: [String: EventCache] = [:]
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var job: Task<Void, Never>?
    private var connectionAttempt: UUID?
    private var generation = UUID()
    private var running = false
    private var nextSync: Date = .distantPast
    private var failures = 0

    init(auth: (any GoogleCalendarAuthorizing)? = nil, defaults: UserDefaults = .standard,
         request: GoogleCalendarAPI.Request? = nil) {
        let auth = auth ?? GoogleCalendarAuth()
        self.auth = auth; self.defaults = defaults
        api = GoogleCalendarAPI(auth: auth, request: request)
        enabled = defaults.object(forKey: "googleMeetingCalendarEnabled") as? Bool ?? true
    }

    func start() {
        guard accessAllowed(), !running else { return }
        running = true
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.nextSync = .distantPast; self?.tick() }
            }
    }

    func stop() {
        running = false
        timer?.invalidate(); timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        invalidate()
        onEvents?([])
    }

    func tick(now: Date = Date()) {
        guard accessAllowed(), running, enabled else { return }
        publish(now: now)
        guard !busy, !connecting, !needsConsent, now >= nextSync else { return }
        job = Task { [weak self] in await self?.refresh(now: now) }
    }

    func connect() async {
        guard accessAllowed(), !connecting else { return }
        invalidate()
        connecting = true
        let attempt = UUID()
        connectionAttempt = attempt
        let generation = self.generation
        // A settings change can invalidate the sync generation while consent is open.
        // Still release this attempt's UI, without clearing a newer connection attempt.
        defer {
            if connectionAttempt == attempt { connecting = false; connectionAttempt = nil }
        }
        do {
            let account = try await auth.connect(hint: loginHint())
            guard generation == self.generation else { return }
            applyAccount(account)
            needsConsent = false
            enabled = true
            await refresh()
        } catch {
            guard generation == self.generation else { return }
            status = Self.message(for: error)
        }
    }

    func disconnect() {
        invalidate()
        auth.disconnect()
        account = nil; calendars = []; selectedIDs = []
        calendarMap = [:]; calendarSyncToken = nil; caches = [:]
        lastSynced = nil; needsConsent = false; connecting = false
        connectionAttempt = nil
        status = "Connect Google Calendar to choose your calendars."
        onEvents?([])
    }

    func select(_ id: String, enabled: Bool) {
        guard calendars.contains(where: { $0.id == id }), let account else { return }
        if enabled { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
        defaults.set(selectedIDs.sorted(), forKey: selectionKey(account))
        invalidate()
        caches = caches.filter { selectedIDs.contains($0.key) }
        nextSync = .distantPast
        publish()
        if running { tick() }
    }

    /// One transaction per paginated resource. Tokens only advance after all pages succeed.
    func refresh(now: Date = Date()) async {
        guard accessAllowed(), enabled, !busy else { return }
        busy = true
        let generation = self.generation
        defer { if generation == self.generation { busy = false } }
        do {
            if account == nil {
                let restored = try await auth.restore()
                try check(generation)
                guard let restored else {
                    nextSync = now.addingTimeInterval(300)
                    return
                }
                applyAccount(restored)
            }
            guard let account else { return }
            var list: GoogleCalendarPage<GoogleCalendarChoice>
            var fullList = calendarSyncToken == nil
            do { list = try await api.calendars(syncToken: calendarSyncToken) }
            catch GoogleCalendarError.expiredSync {
                try check(generation)
                fullList = true
                list = try await api.calendars(syncToken: nil)
            }
            try check(generation)
            if fullList { calendarMap = [:] }
            for calendar in list.items ?? [] {
                calendarMap[calendar.id] = calendar.readable ? calendar : nil
            }
            calendarSyncToken = list.nextSyncToken
            calendars = calendarMap.values.sorted {
                if ($0.primary == true) != ($1.primary == true) { return $0.primary == true }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            if defaults.object(forKey: selectionKey(account)) == nil {
                // Initialize only after a complete successful calendarList. An explicit empty
                // selection remains empty, including after relaunch or a new shared calendar.
                selectedIDs = Set(calendars.filter { $0.primary == true }.map(\.id))
                defaults.set(selectedIDs.sorted(), forKey: selectionKey(account))
            }
            let active = selectedIDs.intersection(calendarMap.keys)
            caches = caches.filter { active.contains($0.key) }
            publish(now: now)
            for id in active.sorted() {
                var cache = caches[id] ?? EventCache()
                // Rebase the rolling seven-day horizon every six hours. A sync token alone
                // would miss unchanged events entering the window as time moves forward.
                var full = cache.syncToken == nil || now.timeIntervalSince(cache.fullSyncAt) >= 6 * 3600
                var page: GoogleCalendarPage<GoogleCalendarEvent>
                do { page = try await api.events(calendarID: id, syncToken: full ? nil : cache.syncToken, now: now) }
                catch GoogleCalendarError.expiredSync {
                    try check(generation)
                    full = true
                    page = try await api.events(calendarID: id, syncToken: nil, now: now)
                }
                try check(generation)
                if full { cache.meetings = [:]; cache.fullSyncAt = now }
                for event in page.items ?? [] {
                    // Cancelled/declined/all-day/removed-link updates remove prior suggestions.
                    let meeting = event.meeting(calendarID: id, email: account.email)
                    cache.meetings[event.id] = meeting.flatMap {
                        $0.endsAt > now && $0.startsAt < now.addingTimeInterval(7 * 86400) ? $0 : nil
                    }
                }
                cache.meetings = cache.meetings.filter { $0.value.endsAt > now }
                cache.syncToken = page.nextSyncToken
                caches[id] = cache
            }
            lastSynced = now; failures = 0; needsConsent = false
            nextSync = now.addingTimeInterval(300)
            status = active.isEmpty ? "Choose a calendar for meeting suggestions." : "Connected · checks for changes every five minutes."
            publish(now: now)
            onSynchronized?()
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            failures += 1
            nextSync = now.addingTimeInterval(min(900, 60 * pow(2, Double(min(failures - 1, 4)))))
            status = Self.message(for: error)
            if Self.requiresConsent(error) {
                needsConsent = true
                caches = [:]
            }
            publish(now: now)
        }
    }

    func matchRecording(_ recording: RecordingMetadata) async throws -> RecordingCalendarMatch {
        guard accessAllowed(), enabled, let account, !needsConsent, !selectedIDs.isEmpty else {
            throw GoogleCalendarError.consentRequired
        }
        guard let interval = RecordingCalendarMatcher.interval(recording) else {
            return RecordingCalendarMatch(status: "unknown_time")
        }
        let expected = generation
        let ids = selectedIDs.intersection(calendarMap.keys).sorted()
        guard !ids.isEmpty else { throw GoogleCalendarError.consentRequired }
        var events: [RecordingCalendarEvent] = []
        for id in ids {
            let page = try await api.recordingEvents(calendarID: id, start: interval.start, end: interval.end)
            try check(expected)
            guard accessAllowed(), enabled else { throw CancellationError() }
            events += page.compactMap { $0.recordingEvent(calendarID: id, email: account.email) }
        }
        return RecordingCalendarMatcher.match(recording, events: events)
    }

    private func applyAccount(_ account: GoogleCalendarAccount) {
        if self.account?.id != account.id {
            calendarMap = [:]; calendars = []; calendarSyncToken = nil; caches = [:]; lastSynced = nil
            selectedIDs = Set(defaults.stringArray(forKey: selectionKey(account)) ?? [])
        }
        self.account = account
    }

    private func selectionKey(_ account: GoogleCalendarAccount) -> String { "googleMeetingCalendars.\(account.id)" }
    private func invalidate() { generation = UUID(); job?.cancel(); job = nil; busy = false; nextSync = .distantPast }
    private func check(_ expected: UUID) throws {
        guard generation == expected, !Task.isCancelled else { throw CancellationError() }
    }

    private func publish(now: Date = Date()) {
        guard enabled, let lastSynced, now.timeIntervalSince(lastSynced) < 86400 else { onEvents?([]); return }
        let meetings = caches.filter { selectedIDs.contains($0.key) }.flatMap { $0.value.meetings.values }
            .filter { $0.endsAt > now }
        onEvents?(meetings)
    }

    static func message(for error: Error) -> String {
        if error is CancellationError { return "Connection cancelled. Your calendars were not changed." }
        if requiresConsent(error) { return "Reconnect Google Calendar to allow read-only access." }
        switch error as? GoogleCalendarError {
        case .notConfigured: return "Google Calendar setup is pending. Microphone detection is still available."
        case .consentRequired, .unauthorized: return "Reconnect Google Calendar to allow read-only access."
        case .apiDisabled: return "Google Calendar API needs to be enabled for this app."
        case .signInTimedOut: return "Google sign-in timed out. Choose Connect Google Calendar to try again."
        default:
            let ns = error as NSError
            if ns.domain == "com.google.GIDSignIn", ns.code == -5 { return "Connection cancelled. Your calendars were not changed." }
            return "Couldn’t sync. Recent meetings stay available on this Mac; we’ll retry automatically."
        }
    }

    private static func requiresConsent(_ error: Error) -> Bool {
        let ns = error as NSError
        return error as? GoogleCalendarError == .consentRequired || error as? GoogleCalendarError == .unauthorized ||
            ns.domain == "org.openid.appauth.oauth_token" || ns.domain == "org.openid.appauth.oauth_authorization"
    }
}
