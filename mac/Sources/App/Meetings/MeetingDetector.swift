import AppKit
import ApplicationServices
import CoreAudio
import OSLog

/// A detected call. Window context is saved only if an authorized recording starts.
struct MeetingCandidate: Equatable, Sendable {
    let appName: String
    let bundleID: String
    var windowTitle: String? = nil
}

struct MeetingObservation: Equatable, Sendable {
    let candidate: MeetingCandidate
    /// An in-memory app/process/window identity. Never a log field.
    let callID: String
    let microphoneOwnerID: String
}

struct MeetingDetectionSnapshot: Sendable {
    var observations: [MeetingObservation] = []
    var activeMicrophoneOwners: Set<String> = []
    /// Corroborated calls eligible to arm a recording's end policy.
    var activeCallOwners: Set<String> = []
    /// Audio that can continue an already identified call through tab/window changes. This must
    /// never arm a new call on its own. Browser playback alone is excluded.
    var activeAudioOwners: Set<String> = []
}

/// CoreAudio metadata only; never contains audio, titles, or document text.
struct MeetingAudioActivity: Sendable {
    let bundleID: String
    let processID: pid_t
    let input: Bool
    let output: Bool
}

/// Pure policy for the end of a recorded call. Arms only after a call has been seen during this
/// recording, so an in-person meeting with no call app is never stopped. Fires once after `grace`
/// seconds without the recorded call. Other apps cannot extend this recording or cancel its stop.
struct MeetingEndPolicy {
    var grace: TimeInterval = 45
    private(set) var armed = false
    private(set) var recordedCallOwners: Set<String> = []
    private var quietSince: TimeInterval?

    func recordedCallIsActive(in owners: Set<String>) -> Bool {
        !recordedCallOwners.isDisjoint(with: owners)
    }

    mutating func observe(activeCallOwners: Set<String>, now: TimeInterval) -> Bool {
        // Manual recordings bind to the first corroborated call, while detected starts may
        // supply the originating app. Do not grow this set as other apps begin using audio.
        if recordedCallOwners.isEmpty { recordedCallOwners = activeCallOwners }
        if recordedCallIsActive(in: activeCallOwners) { armed = true; quietSince = nil; return false }
        guard armed else { return false }
        let since = quietSince ?? now
        quietSince = since
        guard now - since >= grace else { return false }
        armed = false; quietSince = nil
        return true
    }

    mutating func reset(tracking owners: Set<String> = []) {
        armed = false; quietSince = nil; recordedCallOwners = owners
    }
}

/// Pure policy: two consecutive observations, then one suggestion per call. A dismissed call
/// is eligible again only after its microphone owner has been quiet for thirty seconds.
struct MeetingDetectionPolicy {
    var quietInterval: TimeInterval = 30
    private var consecutive: [String: Int] = [:]
    private var offered: [String: String] = [:] // call ID -> microphone owner
    private var quietSince: [String: TimeInterval] = [:]

    mutating func observe(_ snapshot: MeetingDetectionSnapshot, now: TimeInterval) -> MeetingObservation? {
        for owner in Set(offered.values) {
            if snapshot.activeMicrophoneOwners.contains(owner) {
                quietSince[owner] = nil
            } else {
                if quietSince[owner] == nil { quietSince[owner] = now }
                if now - (quietSince[owner] ?? now) >= quietInterval {
                    offered = offered.filter { $0.value != owner }
                    quietSince[owner] = nil
                }
            }
        }
        let observations = Dictionary(snapshot.observations.map { ($0.callID, $0) }, uniquingKeysWith: { first, _ in first })
        consecutive = Dictionary(uniqueKeysWithValues: observations.keys.map { ($0, (consecutive[$0] ?? 0) + 1) })
        guard let next = observations.values.sorted(by: { $0.callID < $1.callID }).first(where: {
            (consecutive[$0.callID] ?? 0) >= 2 && offered[$0.callID] == nil
        }) else { return nil }
        offered[next.callID] = next.microphoneOwnerID
        return next
    }

    mutating func dismiss(_ observation: MeetingObservation) {
        offered[observation.callID] = observation.microphoneOwnerID
    }

    mutating func reset() { consecutive = [:]; offered = [:]; quietSince = [:] }
}

enum MeetingAppKind: Equatable, Sendable {
    case zoom, teams, slack, faceTime, browser
}

struct MeetingAppIdentity: Equatable, Sendable {
    let candidate: MeetingCandidate
    let kind: MeetingAppKind

    static func recognize(_ bundleID: String) -> MeetingAppIdentity? {
        let known: [(String, String, MeetingAppKind)] = [
            ("us.zoom.xos", "Zoom", .zoom),
            ("com.microsoft.teams2", "Microsoft Teams", .teams),
            ("com.microsoft.teams", "Microsoft Teams", .teams),
            ("com.tinyspeck.slackmacgap", "Slack", .slack),
            ("com.apple.FaceTime", "FaceTime", .faceTime),
            ("com.google.Chrome", "Google Chrome", .browser),
            ("com.microsoft.edgemac", "Microsoft Edge", .browser),
            ("org.mozilla.firefox", "Firefox", .browser),
            ("com.apple.Safari", "Safari", .browser),
            ("com.brave.Browser", "Brave", .browser),
            ("company.thebrowser.Browser", "Arc", .browser),
            ("at.studio.AsideBrowser", "Aside", .browser),
            ("com.vivaldi.Vivaldi", "Vivaldi", .browser),
        ]
        let value = bundleID.lowercased()
        guard let entry = known.first(where: { value == $0.0.lowercased() || value.hasPrefix($0.0.lowercased() + ".") }) else { return nil }
        return MeetingAppIdentity(candidate: MeetingCandidate(appName: entry.1, bundleID: entry.0), kind: entry.2)
    }

    /// Window titles corroborate the call and become owner-local recording context on start.
    static func hasCallWindow(title: String, kind: MeetingAppKind) -> Bool {
        let title = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .zoom, .teams: return true
        case .slack:
            return title == "huddle" || title.hasPrefix("huddle with ") || title.hasPrefix("huddle - ") ||
                title.hasSuffix(" - huddle") || title.contains("허들")
        case .faceTime:
            return title.contains("facetime") && ["audio", "video", "call", "통화"].contains(where: title.contains)
        case .browser:
            if hasMeetRoomTitle(title) { return true }
            if isNonCallGooglePage(title) { return false }
            if title.contains("google meet") && hasBrowserMediaIndicator(title) { return true }
            return title.contains("microsoft teams") || title.contains("zoom meeting") ||
                title.contains("zoom workplace") || title.contains("webex")
        }
    }

    /// Background browser tab corroboration (only checked while the browser holds the microphone).
    /// Excludes an idle "Google Meet" home tab, Calendar, and Meet settings so unrelated browser mic use does not false-trigger.
    static func hasCallTab(title: String) -> Bool {
        let title = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if hasMeetRoomTitle(title) { return true }
        if isNonCallGooglePage(title) { return false }
        if title.contains("google meet") && hasBrowserMediaIndicator(title) { return true }
        return title.contains("microsoft teams") || title.contains("zoom meeting") ||
            title.contains("zoom workplace") || title.contains("webex")
    }

    private static func hasBrowserMediaIndicator(_ lowercased: String) -> Bool {
        ["recording", "microphone", "camera", "audio", "녹화", "마이크", "카메라"].contains(where: lowercased.contains)
    }

    private static func isNonCallGooglePage(_ lowercased: String) -> Bool {
        if lowercased.contains("google calendar") { return true }
        if lowercased.contains("google meet") && (lowercased.contains("settings") || lowercased.contains("설정")) {
            return true
        }
        return false
    }

    /// Chromium/Aside PWA web app shim corroboration (only checked while the parent browser holds the mic).
    static func isCallWebApp(name: String?, bundleID: String) -> Bool {
        let bid = bundleID.lowercased()
        // Canonical Google Meet Chromium/Aside Web App CRX ID (kjgfgldnnfoeklkmfkjfagphfepbbdan).
        if bid.hasSuffix(".app.kjgfgldnnfoeklkmfkjfagphfepbbdan") { return true }
        guard let name else { return false }
        let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower == "google meet" || lower.contains("google meet") ||
            lower.contains("microsoft teams") || lower == "zoom" ||
            lower.contains("zoom meeting") || lower.contains("zoom workplace") ||
            lower.contains("webex")
    }

    private static func hasMeetRoomTitle(_ lowercased: String) -> Bool {
        let prefixes = ["meet - ", "meet – ", "meet — "]
        if prefixes.contains(where: lowercased.hasPrefix) { return true }
        let infixMarkers = [" · meet - ", " ⋅ meet - ", " - meet - ", " · meet – ", " ⋅ meet – ", " · meet — ", " ⋅ meet — "]
        return infixMarkers.contains(where: lowercased.contains)
    }
}

struct BrowserPWAApp: Equatable, Sendable {
    let bundleID: String
    let localizedName: String?
    let processID: pid_t
    let windowTitles: [String]
    let tabTitles: [String]
    let hasOpenWindow: Bool
}

/// Passive CoreAudio process inspection. All CoreAudio and AX reads run on one utility queue.
/// No microphone, calendar, browser URL, text field, model or transcription access occurs here.
protocol MeetingDetecting: AnyObject {
    var onCandidate: (@MainActor (MeetingCandidate) -> Void)? { get set }
    /// Every poll: corroborated calls and per-app audio activity. Never logged.
    var onPresence: (@MainActor (MeetingDetectionSnapshot) -> Void)? { get set }
    func start()
    func stop()
    func dismissCurrentCandidate()
}

final class MeetingDetector: MeetingDetecting, @unchecked Sendable {
    var onCandidate: (@MainActor (MeetingCandidate) -> Void)?
    var onPresence: (@MainActor (MeetingDetectionSnapshot) -> Void)?
    private let log = Logger(subsystem: "ca.sundayable.sunday-voice", category: "meetings")
    private let queue = DispatchQueue(label: "ca.sundayable.meeting-detection", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var policy = MeetingDetectionPolicy()
    private var latest: MeetingObservation?
    private var generation = 0
    private var lastLoggedCorroboration: [String: String] = [:]

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.generation += 1
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 3, leeway: .milliseconds(300))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.timer?.cancel(); self.timer = nil
            self.policy.reset(); self.latest = nil
        }
    }

    func dismissCurrentCandidate() {
        queue.async { [weak self] in
            guard let self, let latest = self.latest else { return }
            self.policy.dismiss(latest)
        }
    }

    private func poll() {
        guard #available(macOS 14.2, *), timer != nil else { return }
        guard let snapshot = collectSnapshot() else { return }
        deliver { [weak self] in self?.onPresence?(snapshot) }
        guard let observation = policy.observe(snapshot, now: ProcessInfo.processInfo.systemUptime) else { return }
        latest = observation
        deliver { [weak self] in self?.onCandidate?(observation.candidate) }
    }

    private func deliver(_ body: @escaping @MainActor () -> Void) {
        let generation = self.generation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Stop/start invalidation is checked on the serial owner before delivering on main.
            self.queue.async { [weak self] in
                guard let self, self.timer != nil, self.generation == generation else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
            }
        }
    }

    @available(macOS 14.2, *)
    private func collectSnapshot() -> MeetingDetectionSnapshot? {
        guard let objects = processObjects() else { return nil }
        var activities: [MeetingAudioActivity] = []
        for object in objects {
            let input = scalar(object, selector: kAudioProcessPropertyIsRunningInput, initial: UInt32(0)) == 1
            let output = scalar(object, selector: kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) == 1
            guard input || output,
                  let pid = scalar(object, selector: kAudioProcessPropertyPID, initial: pid_t(0)),
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let rawBundleID = processBundleID(object) else { continue }
            activities.append(MeetingAudioActivity(bundleID: rawBundleID, processID: pid, input: input, output: output))
        }
        var ownerByPID: [pid_t: String] = [:]
        var windows: [pid_t: (id: String, title: String)] = [:]
        var snapshot = Self.snapshot(from: activities, applicationPID: { owner in
            guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: owner).first?.processIdentifier else { return nil }
            ownerByPID[pid] = owner
            return pid
        }, callWindow: { pid, kind in
            let owner = ownerByPID[pid] ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            let window = self.corroboratingWindow(processID: pid, bundleID: owner, kind: kind)
            windows[pid] = window
            return window?.id
        })
        snapshot.observations = snapshot.observations.map { observation in
            var candidate = observation.candidate
            if let pid = NSRunningApplication.runningApplications(withBundleIdentifier: candidate.bundleID).first?.processIdentifier,
               let kind = MeetingAppIdentity.recognize(candidate.bundleID)?.kind {
                candidate.windowTitle = (windows[pid] ?? self.corroboratingWindow(processID: pid, bundleID: candidate.bundleID, kind: kind))?.title
            }
            return MeetingObservation(candidate: candidate, callID: observation.callID, microphoneOwnerID: observation.microphoneOwnerID)
        }
        return snapshot
    }

    /// Shared by live polling and regression tests. Aggregate helper processes first so a
    /// browser audio-service process cannot bypass the same call-window check as its parent.
    static func snapshot(from activities: [MeetingAudioActivity],
                         applicationPID: (String) -> pid_t?,
                         callWindow: (pid_t, MeetingAppKind) -> String?) -> MeetingDetectionSnapshot {
        var result = MeetingDetectionSnapshot()
        var owners: [String: (identity: MeetingAppIdentity, pid: pid_t, input: Bool, output: Bool)] = [:]
        for activity in activities where activity.input || activity.output {
            guard let identity = MeetingAppIdentity.recognize(activity.bundleID) else { continue }
            let owner = identity.candidate.bundleID
            let previous = owners[owner]
            owners[owner] = (identity, previous?.pid ?? activity.processID,
                             activity.input || previous?.input == true, activity.output || previous?.output == true)
        }
        for owner in owners.keys.sorted() {
            guard let activity = owners[owner] else { continue }
            let identity = activity.identity
            if activity.input { result.activeMicrophoneOwners.insert(owner) }
            // Browser playback may continue on Meet's post-call page and is never presence.
            guard activity.input || identity.kind != .browser else { continue }
            result.activeAudioOwners.insert(owner)
            let pid = applicationPID(owner) ?? activity.pid
            let needsWindow = identity.kind == .browser || identity.kind == .slack || identity.kind == .faceTime
            let windowToken = needsWindow ? callWindow(pid, identity.kind) : nil
            // Previously activeCallOwners was populated BEFORE this check. An unrelated
            // browser/Slack voice message kept the end timer alive even without a call window.
            guard !needsWindow || windowToken != nil else { continue }
            result.activeCallOwners.insert(owner)
            guard activity.input else { continue }
            if let windowToken {
                result.observations.append(MeetingObservation(candidate: identity.candidate,
                    callID: "\(owner):\(pid):\(windowToken)", microphoneOwnerID: owner))
            } else {
                result.observations.append(MeetingObservation(candidate: identity.candidate,
                    callID: "\(owner):\(pid)", microphoneOwnerID: owner))
            }
        }
        return result
    }

    static func corroboratingTitle(windowTitle: String?, tabTitles: [String], kind: MeetingAppKind) -> (title: String, source: String)? {
        if let windowTitle, MeetingAppIdentity.hasCallWindow(title: windowTitle, kind: kind) {
            return (String(windowTitle.prefix(2048)), "window")
        }
        if kind == .browser, let tab = tabTitles.first(where: MeetingAppIdentity.hasCallTab(title:)) {
            return (String(tab.prefix(2048)), "tab")
        }
        return nil
    }

    static func corroboratingPWA(ownerBundleID: String, apps: [BrowserPWAApp]) -> (id: String, title: String)? {
        let prefix = ownerBundleID.lowercased() + ".app."
        let matchingShims = apps.filter { $0.hasOpenWindow && $0.bundleID.lowercased().hasPrefix(prefix) }
        for app in matchingShims {
            for title in app.windowTitles {
                if let matched = corroboratingTitle(windowTitle: title, tabTitles: [], kind: .browser) {
                    return ("pwa:\(app.processID)", matched.title)
                }
            }
            if let matched = corroboratingTitle(windowTitle: nil, tabTitles: app.tabTitles, kind: .browser) {
                return ("pwa:\(app.processID)", matched.title)
            }
        }
        for app in matchingShims where MeetingAppIdentity.isCallWebApp(name: app.localizedName, bundleID: app.bundleID) {
            let nonEmptyTitle = app.windowTitles.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            let label = nonEmptyTitle ?? app.localizedName ?? "Web Call"
            return ("pwa:\(app.processID)", String(label.prefix(2048)))
        }
        return nil
    }

    private func corroboratingWindow(processID: pid_t, bundleID: String?, kind: MeetingAppKind) -> (id: String, title: String)? {
        let key = "\(processID):\(kind)"
        let normalizedOwner = bundleID.flatMap { MeetingAppIdentity.recognize($0)?.candidate.bundleID ?? $0 }
        let trusted = AXIsProcessTrusted()
        var inspected: [AXUIElement] = []
        if trusted {
            let app = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(app, 0.15)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
               let windows = value as? [AXUIElement] {
                inspected = Array(windows.prefix(8))
            }
            for window in inspected {
                AXUIElementSetMessagingTimeout(window, 0.15)
                var titleValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                      let title = titleValue as? String,
                      MeetingAppIdentity.hasCallWindow(title: title, kind: kind) else { continue }
                // Window identity remains stable when participant names or connection text changes.
                // Title stays local and is never written to detection logs.
                logCorroboration(key: key, state: "matched_window")
                return (String(CFHash(window)), String(title.prefix(2048)))
            }
            // Chromium/Aside windows only expose the active tab in kAXTitleAttribute. When the browser
            // holds the microphone while the user views another tab, scan bounded chrome AXTabButtons.
            if kind == .browser {
                for window in inspected {
                    let tabs = browserTabTitles(in: window)
                    if let matched = Self.corroboratingTitle(windowTitle: nil, tabTitles: tabs, kind: kind) {
                        logCorroboration(key: key, state: "matched_tab")
                        return (String(CFHash(window)), matched.title)
                    }
                }
            }
        }
        // Chromium/Aside PWA web apps (e.g. Google Meet.app = at.studio.AsideBrowser.app.<crx_id>)
        // run as separate app_mode_loader processes while the parent browser helper holds the mic,
        // and their AXWindow title may be empty. Check running PWA shims belonging to this browser.
        if kind == .browser, let owner = normalizedOwner {
            let pwaApps = runningBrowserPWAs(ownerBundleID: owner, axTrusted: trusted)
            if let matched = Self.corroboratingPWA(ownerBundleID: owner, apps: pwaApps) {
                logCorroboration(key: key, state: "matched_pwa")
                return matched
            }
        }
        if !trusted {
            logCorroboration(key: key, state: "ax_untrusted")
        } else if inspected.isEmpty {
            logCorroboration(key: key, state: "ax_windows_unavailable")
        } else {
            logCorroboration(key: key, state: "no_match_windows_\(inspected.count)")
        }
        return nil
    }

    private func runningBrowserPWAs(ownerBundleID: String, axTrusted: Bool) -> [BrowserPWAApp] {
        let prefix = ownerBundleID.lowercased() + ".app."
        let shims = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && ($0.bundleIdentifier?.lowercased().hasPrefix(prefix) == true)
        }
        guard !shims.isEmpty else { return [] }
        let cgWindowInfo = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return shims.compactMap { shim in
            guard let bid = shim.bundleIdentifier else { return nil }
            let pid = shim.processIdentifier
            var windowTitles: [String] = []
            var tabTitles: [String] = []
            var axWindowCount = 0
            if axTrusted {
                let axApp = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(axApp, 0.15)
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                   let windows = value as? [AXUIElement] {
                    let bounded = Array(windows.prefix(8))
                    axWindowCount = bounded.count
                    for window in bounded {
                        AXUIElementSetMessagingTimeout(window, 0.15)
                        var titleValue: CFTypeRef?
                        if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                           let title = titleValue as? String, !title.isEmpty {
                            windowTitles.append(title)
                        }
                        tabTitles.append(contentsOf: browserTabTitles(in: window))
                    }
                }
            }
            let hasCGWindow = cgWindowInfo.contains { info in
                (info[kCGWindowOwnerPID as String] as? pid_t) == pid &&
                (info[kCGWindowLayer as String] as? Int ?? -1) == 0
            }
            return BrowserPWAApp(
                bundleID: bid,
                localizedName: shim.localizedName,
                processID: pid,
                windowTitles: windowTitles,
                tabTitles: tabTitles,
                hasOpenWindow: axWindowCount > 0 || hasCGWindow
            )
        }
    }

    private func logCorroboration(key: String, state: String) {
        guard lastLoggedCorroboration[key] != state else { return }
        lastLoggedCorroboration[key] = state
        log.notice("corroboration key=\(key, privacy: .public) state=\(state, privacy: .public)")
    }

    private func browserTabTitles(in window: AXUIElement) -> [String] {
        var titles: [String] = []
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) {
            if depth > 18 || visited >= 300 || titles.count >= 64 { return }
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.08)
            var roleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
                  let role = roleValue as? String else { return }
            if role == "AXWebArea" { return }
            if role == "AXRadioButton" {
                var subroleValue: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
                if (subroleValue as? String) == "AXTabButton" {
                    var titleValue: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success,
                       let title = titleValue as? String, !title.isEmpty {
                        titles.append(title)
                    }
                }
                return
            }
            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let children = childrenValue as? [AXUIElement] else { return }
            for child in children.prefix(60) {
                walk(child, depth: depth + 1)
                if visited >= 300 || titles.count >= 64 { return }
            }
        }
        walk(window, depth: 0)
        return titles
    }

    @available(macOS 14.2, *)
    private func processObjects() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size <= 1_048_576 else { return nil }
        guard size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = objects.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size)) : nil
    }

    private func scalar<T>(_ object: AudioObjectID, selector: AudioObjectPropertySelector, initial: T) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    @available(macOS 14.2, *)
    private func processBundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
