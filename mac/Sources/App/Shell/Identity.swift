import AppKit

/// Everything name-like comes from the bundle (generated from identity.env); nothing is hard-coded.
enum AppIdentity {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
    }
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "app" }
    static var urlScheme: String { Bundle.main.object(forInfoDictionaryKey: "SVURLScheme") as? String ?? bundleID }

    /// Debug builds may override the API with `defaults write <bundle id> apiBaseURL <url>`.
    static var apiBaseURL: URL? {
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: "apiBaseURL"), let url = URL(string: override) { return url }
        #endif
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SVAPIBaseURL") as? String, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    static var icon: NSImage { NSApp?.applicationIconImage ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath) }
}

/// Seconds since boot, the clock the HUD and engine share.
func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
