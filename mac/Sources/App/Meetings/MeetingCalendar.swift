import AppKit
import EventKit
import Foundation

struct CalendarMeeting: Equatable {
    let id: String
    let title: String
    let attendees: [String]
    let startsAt: Date
    let endsAt: Date
    let videoURL: URL

    /// Match the same occurrence across Google and the optional EventKit fallback.
    var occurrenceKey: String { "\(videoURL.host?.lowercased() ?? "")\(videoURL.path):\(Int(startsAt.timeIntervalSince1970))" }

    static func videoLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, url.scheme == "https", let host = url.host?.lowercased() else { continue }
            let providers = ["meet.google.com", "zoom.us", "zoom.com", "teams.microsoft.com", "teams.live.com", "webex.com", "facetime.apple.com"]
            if providers.contains(where: { host == $0 || host.hasSuffix("." + $0) }), url.path.count > 1 { return url }
        }
        return nil
    }
}

struct CalendarMeetingPolicy {
    private var dismissed: [String: Date] = [:]

    mutating func next(_ events: [CalendarMeeting], now: Date) -> CalendarMeeting? {
        dismissed = dismissed.filter { $0.value > now }
        return events.filter {
            $0.startsAt <= now.addingTimeInterval(120) && $0.startsAt >= now.addingTimeInterval(-120) &&
            $0.endsAt > now && dismissed[$0.occurrenceKey] == nil
        }.sorted { $0.startsAt < $1.startsAt }.first
    }

    mutating func dismiss(_ event: CalendarMeeting) { dismissed[event.occurrenceKey] = event.endsAt }
}

@MainActor
protocol MeetingCalendarProviding: AnyObject {
    var onEvents: (([CalendarMeeting]) -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    func start()
    func stop()
    func requestAccess() async
}

/// Reads the Mac's synchronized calendars (including Google) without a server, OAuth secret,
/// network upload or event writes. Titles/attendees remain in memory and are never logged.
@MainActor
final class MeetingCalendar: MeetingCalendarProviding {
    var onEvents: (([CalendarMeeting]) -> Void)?
    var onStatus: ((String) -> Void)?
    private let store = EKEventStore()
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        store.reset()
        onEvents?([])
    }

    func requestAccess() async {
        do {
            _ = try await store.requestFullAccessToEvents()
            refresh()
        } catch { onStatus?("Calendar access was not granted. Microphone detection still works.") }
    }

    private func refresh() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            onStatus?("Allow calendar access to see meetings two minutes before they start.")
            onEvents?([])
            return
        }
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else {
            onStatus?("Add your Google account in macOS Calendar and turn on Calendars.")
            onEvents?([])
            return
        }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-120), end: now.addingTimeInterval(24 * 3600), calendars: calendars)
        let meetings = store.events(matching: predicate).compactMap { event -> CalendarMeeting? in
            let participants: [EKParticipant] = event.attendees ?? []
            guard !event.isAllDay, event.status != .canceled,
                  !participants.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }),
                  let start = event.startDate, let end = event.endDate,
                  let video = CalendarMeeting.videoLink(in: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: "\n")) else { return nil }
            return CalendarMeeting(id: "\(event.calendarItemIdentifier):\(start.timeIntervalSince1970)",
                title: event.title?.isEmpty == false ? event.title! : "Scheduled meeting",
                attendees: participants.filter { $0.participantStatus != .declined }.map { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") },
                startsAt: start, endsAt: end, videoURL: video)
        }
        onStatus?("Calendar connected · Google calendars must be synced in macOS Calendar.")
        onEvents?(meetings)
    }
}
