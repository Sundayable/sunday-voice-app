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
            cached = nil
            Task { @MainActor in
                UILanguageObserver.shared.bump()
                NotificationCenter.default.post(name: .uiLanguageDidChange, object: nil)
            }
        }
    }
    private static var cached: Bundle?
    static var bundle: Bundle {
        if let b = cached { return b }
        let code = choice == "system" ? (Bundle.main.preferredLocalizations.first ?? "en") : choice
        let b = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? Bundle.main
        cached = b; return b
    }
    static var isKorean: Bool { bundle.bundlePath.hasSuffix("ko.lproj") }
}

/// Look up a String Catalog key in the chosen language; falls back to the key itself.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = UILanguage.bundle.localizedString(forKey: key, value: key, table: "Localizable")
    return args.isEmpty ? format : String(format: format, arguments: args)
}
