import AppKit
import Carbon.HIToolbox
import DictationEngine

/// A global shortcut: virtual key code + Carbon modifier mask (cmdKey, optionKey, controlKey, shiftKey).
struct TidyShortcut: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// ⌃⌥T, next to ⌃⌥V (copy latest transcript): Sunday Voice's clipboard keys share ⌃⌥.
    static let `default` = TidyShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey))
    /// ⌃⌥V is "copy latest transcript" (main.swift).
    static let copyLatest = TidyShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey))

    init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }

    /// From a key press in the recorder. Nil without ⌃/⌥/⌘ (a bare letter or ⇧+letter would fire while typing).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        guard mask != 0 else { return nil }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mask)
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    /// The key's character on the current layout, for menus ("t") and labels ("T").
    var keyCharacter: String {
        if let named = Self.named[Int(keyCode)] { return named }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var dead: UInt32 = 0, length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        return status == noErr && length > 0 ? String(utf16CodeUnits: chars, count: length) : "?"
    }

    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    ]

    /// "⌃⌥T" in the standard macOS order.
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyCharacter.uppercased()
    }

    /// A key press captured by the keys step (the engine reports keys with Carbon masks); nil for holds/mouse buttons.
    init?(trigger: TriggerKind) {
        guard case .key(let code, let mods, _) = trigger else { return nil }
        self.init(keyCode: UInt32(code), modifiers: mods)
    }

    /// The same key as a dictation trigger, for chip labels and conflict checks.
    var trigger: TriggerKind { .key(keyCode: UInt16(keyCode), modifiers: modifiers, mode: .bilingual) }

    /// Shortcuts Sunday Voice itself already uses: ⌃⌥V and any dictation trigger on a key.
    func conflicts(with triggers: [TriggerKind]) -> Bool {
        if self == Self.copyLatest { return true }
        return triggers.contains { $0.inputKey == trigger.inputKey }
    }

    /// Letters, digits and other typing keys need ⌃, ⌥ or ⌘ (⇧ alone still types); F-keys and the like may stand alone.
    @MainActor var needsModifier: Bool {
        let typing = OnboardingModel.problem(with: .key(keyCode: UInt16(keyCode), modifiers: 0, mode: .bilingual)) != nil
        return typing && modifiers & UInt32(controlKey | optionKey | cmdKey) == 0
    }
}

extension Prefs {
    /// Tidy clipboard keys, shown as the third card of "Pick your keys" (onboarding and Settings › Keys).
    /// Empty = no key (the menu item still works). Migrates 0.2.16's single `tidyShortcut` / `tidyShortcutOff`.
    static var tidyShortcuts: [TidyShortcut] {
        get {
            let d = UserDefaults.standard
            if let data = d.data(forKey: "tidyShortcuts"), let list = try? JSONDecoder().decode([TidyShortcut].self, from: data) { return list }
            if d.bool(forKey: "tidyShortcutOff") { return [] }
            if let data = d.data(forKey: "tidyShortcut"), let one = try? JSONDecoder().decode(TidyShortcut.self, from: data) { return [one] }
            return [.default]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "tidyShortcuts") }
    }
}

/// System-wide hot keys through Carbon `RegisterEventHotKey`: the key press is consumed (the front app
/// never sees ⌃⌥T) and it needs no permission beyond what the app has.
/// Handler and keys live on the event *dispatcher* target, which sees the hot-key event before any
/// application-target handler. 0.2.16/0.2.17 used the application target: registration succeeded but the
/// press never reached us in the real app (a later-installed framework handler took it first), so ⌃⌥T did
/// nothing while the menu item worked (Dan, 2026-10-09).
@MainActor
final class GlobalHotKey {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var action: () -> Void = {}
    nonisolated static let signature: OSType = 0x53_56_54_44 // "SVTD"

    /// Replaces any previous registration. Returns the shortcuts another app already owns (not registered).
    @discardableResult func register(_ shortcuts: [TidyShortcut], action: @escaping () -> Void) -> [TidyShortcut] {
        unregister()
        self.action = action
        guard !shortcuts.isEmpty else { return [] }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let me = Unmanaged.passUnretained(self).toOpaque()
            let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                             MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard read == noErr, id.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { MainActor.assumeIsolated { NSLog("tidy_hotkey_pressed id=%u", id.id); hotKey.action() } }
                return noErr
            }, 1, &spec, me, &handler)
            NSLog("tidy_hotkey_handler status=%d", status)
        }
        var failed: [TidyShortcut] = []
        for (i, shortcut) in shortcuts.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(i + 1))
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { failed.append(shortcut) }
            NSLog("tidy_hotkey_register key=%u mods=%u status=%d", shortcut.keyCode, shortcut.modifiers, status)
        }
        return failed
    }

    func unregister() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
    }
}

/// Selection first, clipboard fallback. Successful English output always goes on the clipboard.
@MainActor
final class ClipboardTidy {
    typealias Rewrite = (String?) async throws -> TidyResult
    let hud: HUD
    let board: NSPasteboard
    /// nil while signed out.
    var makeTidier: () -> Rewrite?
    private(set) var busy = false
    private(set) var task: Task<Void, Never>?
    var readSelection: (() async throws -> String?)?
    private var saved: (items: [[NSPasteboard.PasteboardType: Data]], changeCount: Int)?

    init(hud: HUD, board: NSPasteboard = .general, makeTidier: @escaping () -> Rewrite?) {
        self.hud = hud; self.board = board; self.makeTidier = makeTidier
    }

    func run() {
        NSLog("tidy_invoked busy=%d", busy ? 1 : 0)
        // A second press while working re-shows the working pill instead of doing nothing.
        guard !busy else { hud.show(.tidying); return }
        let board = self.board
        guard let tidy = makeTidier() else { NSLog("tidy_result error=signed_out"); hud.show(.error(L("tidy.error.signIn"), .close)); return }
        let previous = Self.snapshot(board)
        let selectionReader = readSelection
        busy = true
        hud.show(.tidying)
        task = Task {
            defer { busy = false }
            do {
                let selected = try await selectionReader?()
                let raw = try TidyText.prepare(selected ?? Self.copiedText(board))
                let count = board.changeCount
                let result = try await tidy(raw)
                guard board.changeCount == count else {
                    hud.show(.error(L("tidy.error.changed"), .close)); return
                }
                // Already-tidy selections must also be copied: the clipboard can contain unrelated text.
                if !result.changed && selected == nil {
                    hud.show(.tidyUnchanged); return
                }
                board.clearContents()
                guard board.setString(result.text, forType: .string) else { throw SelectedTextReader.Failure.copyFailed }
                saved = (previous, board.changeCount)
                NSLog("tidy_result ok chars=%d->%d", raw.count, result.text.count)
                hud.show(.tidied)
            } catch {
                // Copy fallback can leave the source selection on the clipboard. Never replace it on failure.
                if let failure = error as? SelectedTextReader.Failure {
                    let key: String
                    switch failure {
                    case .permission: key = "tidy.error.permission"
                    case .secureField: key = "tidy.error.secure"
                    case .focusChanged: key = "tidy.error.focus"
                    case .copyFailed: key = "tidy.error.copy"
                    }
                    hud.show(.error(L(key), failure == .permission ? .accessibilitySettings : .close))
                } else {
                    hud.show(.error(Self.message(error), Self.action(error)))
                }
                NSLog("tidy_result failed")
            }
        }
    }

    /// Puts the original back, unless something else was copied since.
    func undo() {
        guard let saved, board.changeCount == saved.changeCount else { hud.show(.hidden); return }
        board.clearContents()
        let items = saved.items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
        self.saved = nil
        hud.show(.tidyRestored)
    }

    /// Plain text only: files, images and other copies without text count as nothing to tidy.
    static func copiedText(_ board: NSPasteboard) -> String? {
        let types = board.types ?? []
        if types.contains(.fileURL) { return nil }
        return board.string(forType: .string)
    }

    static func message(_ error: Error) -> String {
        switch error as? TidyError {
        case .empty: return L("tidy.error.empty")
        case .tooLong(let limit): return L("tidy.error.tooLong", limit.formatted())
        case .notSignedIn: return L("tidy.error.signIn")
        case .quotaExceeded: return L("error.quota")
        case .subscriptionRequired: return L("tidy.error.subscriptionRequired")
        case .serverOutdated: return L("tidy.error.outdated")
        case .unsafe: return L("tidy.error.unsafe")
        case .failed(let code): return L("tidy.error.failedReason", reason(code))
        default: return L("tidy.error.failed")
        }
    }

    static func action(_ error: Error) -> HUDAction {
        switch error as? TidyError {
        case .subscriptionRequired: return .openAccount
        default: return .close
        }
    }

    /// Short, human reason for "Couldn't tidy: …".
    static func reason(_ code: String) -> String {
        if code == "timeout" { return L("tidy.reason.timeout") }
        if code.hasPrefix("network_") || code == "connection_lost" { return L("tidy.reason.network") }
        if code == "rate_limited" { return L("tidy.reason.busy") }
        return L("tidy.reason.server")
    }

    static func snapshot(_ board: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (board.pasteboardItems ?? []).map { item in
            var values = [NSPasteboard.PasteboardType: Data]()
            for type in item.types { if let data = item.data(forType: type) { values[type] = data } }
            return values
        }
    }
}
