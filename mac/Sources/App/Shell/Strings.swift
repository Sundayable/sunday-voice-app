import Foundation

extension Notification.Name {
    static let uiLanguageDidChange = Notification.Name("SundayVoice.UILanguageDidChange")
}

/// Publishes language changes so open SwiftUI windows and the menu bar update immediately without restart.
@MainActor
final class UILanguageObserver: ObservableObject {
    static let shared = UILanguageObserver()
    @Published private(set) var revision = 0
    func bump() { revision &+= 1 }
}

/// UI language: "system" follows macOS; "ko" / "en" pin the app. Stored in the app's
/// own defaults so the worker's config.json stays untouched.
enum UILanguage {
    static let key = "uiLanguage"
    static var choice: String {
        get { UserDefaults.standard.string(forKey: key) ?? "system" }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            lock.lock(); cached = nil; lock.unlock()
            Task { @MainActor in
                UILanguageObserver.shared.bump()
                NotificationCenter.default.post(name: .uiLanguageDidChange, object: nil)
            }
        }
    }
    private static let lock = NSLock()
    private static var cached: Bundle?
    private static var tables: [String: [String: String]] = [:]

    /// Overridable in tests so "system" (unset uiLanguage) can be verified for both macOS Korean and English.
    static var systemPreferredLanguages: () -> [String] = { Locale.preferredLanguages }

    /// "ko" or "en": the pinned choice, or the Mac's preferred language among the app's localizations.
    static var code: String {
        let raw: String
        if choice == "system" {
            raw = Bundle.preferredLocalizations(from: ["en", "ko"], forPreferences: systemPreferredLanguages()).first
                ?? Bundle.main.preferredLocalizations.first
                ?? "en"
        } else {
            raw = choice
        }
        return raw.hasPrefix("ko") ? "ko" : "en"
    }
    static var bundle: Bundle {
        lock.lock(); defer { lock.unlock() }
        if let b = cached { return b }
        let b = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? Bundle.main
        cached = b; return b
    }
    static var isKorean: Bool { code == "ko" }

    /// The compiled String Catalog table of one language, read directly. `Bundle(path: "ko.lproj")` still
    /// resolves through the Mac's preferred languages when the app is launched normally, so an English Mac
    /// kept showing English after picking 한국어 (0.3.23). Reading the file avoids that lookup.
    static func table(_ code: String) -> [String: String]? {
        lock.lock(); defer { lock.unlock() }
        if let t = tables[code] { return t }
        guard let url = Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: code),
              let t = NSDictionary(contentsOf: url) as? [String: String] else { return nil }
        tables[code] = t
        return t
    }
}

/// Look up a String Catalog key in the chosen language; falls back to the key itself.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = UILanguage.table(UILanguage.code)?[key]
        ?? UILanguage.bundle.localizedString(forKey: key, value: key, table: "Localizable")
    return args.isEmpty ? format : String(format: format, arguments: args)
}
