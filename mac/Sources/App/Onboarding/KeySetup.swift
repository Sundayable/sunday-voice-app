import AppKit
import DictationEngine

/// What the macOS "Press 🌐 key to" setting does. Anything but `.nothing` also fires when someone holds
/// 🌐 Fn to dictate (switches the input source, opens the emoji picker or starts Apple dictation).
enum FnKeyUsage: Int, Equatable {
    case nothing = 0, inputSource = 1, emoji = 2, dictation = 3

    var conflictKey: String? {
        switch self {
        case .nothing: return nil
        case .inputSource: return "keys.fn.conflict.input"
        case .emoji: return "keys.fn.conflict.emoji"
        case .dictation: return "keys.fn.conflict.dictation"
        }
    }
}

/// Reads the system's own preference (com.apple.HIToolbox › AppleFnUsageType). Read-only: the app never
/// changes another app's settings; the guided fix opens System Settings › Keyboard instead.
enum FnKeySetting {
    static let domain = "com.apple.HIToolbox" as CFString

    /// Injected in tests.
    static var readValue: () -> Int? = {
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? NSNumber)?.intValue
    }
    static var enabledInputSourceCount: () -> Int = {
        CFPreferencesAppSynchronize(domain)
        let sources = CFPreferencesCopyAppValue("AppleEnabledInputSources" as CFString, domain) as? [[String: Any]] ?? []
        return sources.filter { ($0["InputSourceKind"] as? String).map { $0 == "Keyboard Layout" || $0 == "Input Mode" } ?? false }.count
    }

    /// With no stored value macOS uses Change Input Source when more than one keyboard is enabled, else Show Emoji.
    static func current() -> FnKeyUsage {
        if let raw = readValue() { return FnKeyUsage(rawValue: raw) ?? .emoji }
        return enabledInputSourceCount() > 1 ? .inputSource : .emoji
    }

    static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
}

/// A captured key that another action already uses; the user decides whether to move it.
struct PendingKeyMove: Equatable {
    let trigger: TriggerKind
    let mode: DictationMode
    let replacing: TriggerKind?
    let from: DictationMode
}

/// The live key check on the key step. `listening` stays true across re-arms; results persist on screen.
struct KeyTestState: Equatable {
    var listening = false
    var ok = false
    /// A different key the user pressed (offer to use it).
    var other: TriggerKind?
    /// 🌐 Fn is the dictation key but none arrived: likely an external keyboard without it.
    var missedFn = false
}

extension DictationMode {
    var nameKey: String { self == .bilingual ? "mode.dictate.name" : "mode.english.name" }
}

extension OnboardingModel {
    // MARK: primary + extra keys

    /// The key shown on an action's card. Others are "extra keys" in the advanced section.
    func primaryTrigger(for mode: DictationMode) -> TriggerKind? { triggers(for: mode).first }
    func extraTriggers(for mode: DictationMode) -> [TriggerKind] { Array(triggers(for: mode).dropFirst()) }
    var primaryTidyKey: TidyShortcut? { tidyKeys.first }
    var extraTidyKeys: [TidyShortcut] { Array(tidyKeys.dropFirst()) }

    var usesFnKey: Bool { triggers.contains(where: Self.usesFn) }
    var fnConflict: FnKeyUsage? { usesFnKey && fnUsage != .nothing ? fnUsage : nil }

    static func usesFn(_ t: TriggerKind) -> Bool {
        if case .modifierHold(let keys, _, _) = t { return keys.contains(.fn) }
        return false
    }

    /// Every dictation input is held to talk (keys, combos and mouse buttons alike).
    static func verbKey(_ t: TriggerKind) -> String { "keys.hold" }

    func refreshFnUsage() {
        guard !isPreview else { return }
        let now = FnKeySetting.current()
        if now != fnUsage { fnUsage = now }
    }

    /// Opens Keyboard settings with the floating 3-step card; the card ticks and leaves once 🌐 is Do Nothing.
    func fixFnKey() {
        NSWorkspace.shared.open(FnKeySetting.keyboardSettingsURL)
        PermissionCoach.shared.showFnKeyFix { [weak self] in
            guard let self else { return true }
            self.refreshFnUsage()
            return self.fnUsage == .nothing
        }
    }

    // MARK: changing keys

    /// "Change" (replacing a key) or "+ Add" (replacing nil): the next key, combo or mouse button.
    func captureKey(for mode: DictationMode, replacing: TriggerKind? = nil) {
        if mode == .english && proActionsLocked { return }
        beginCapture()
        capturingMode = mode; capturingReplacement = replacing
        let token = captureToken
        engine.captureNextTrigger(timeout: 10) { [weak self] raw in
            guard let self, token == self.captureToken else { return }
            self.endCapture()
            guard let raw else { self.keyMessage = L("keys.capture.timeout"); self.resumeKeyTest(); return }
            if Self.isEscape(raw) { self.resumeKeyTest(); return }
            self.apply(raw.with(mode: mode), to: mode, replacing: replacing)
            if self.keyMessage != nil || self.pendingMove != nil { self.resumeKeyTest() }
        }
    }

    /// Validates and saves a captured dictation key. A key another action owns asks before it moves.
    func apply(_ trigger: TriggerKind, to mode: DictationMode, replacing: TriggerKind?, confirmedMove: Bool = false) {
        if mode == .english && proActionsLocked { return }
        if let problem = Self.problem(with: trigger) { keyMessage = problem; return }
        if let key = TidyShortcut(trigger: trigger), tidyKeys.contains(key) {
            keyMessage = L("ob.keys.usedForTidy", Self.describe(trigger)); return
        }
        if let clash = triggers.first(where: { $0.inputKey == trigger.inputKey }) {
            if clash.mode == mode {
                if let replacing, replacing.inputKey == trigger.inputKey {
                    let name = Self.describe(trigger)
                    captured = name
                    capturedConfirmation = L("keys.capture.confirmedHold", name)
                    keyMessage = nil
                    return
                }
                keyMessage = L("ob.keys.already", Self.describe(trigger)); return
            }
            guard confirmedMove else {
                pendingMove = PendingKeyMove(trigger: trigger, mode: mode, replacing: replacing, from: clash.mode)
                keyMessage = nil
                return
            }
            triggers.removeAll { $0 == clash }
        }
        if let replacing, let index = triggers.firstIndex(of: replacing) {
            triggers[index] = trigger
        } else if replacing != nil, let index = triggers.firstIndex(where: { $0.mode == mode }) {
            triggers.insert(trigger, at: index)
        } else {
            triggers.append(trigger)
        }
        pendingMove = nil
        saveTriggers()
        let name = Self.describe(trigger)
        captured = name
        capturedConfirmation = L("keys.capture.confirmedHold", name)
        keyTest = KeyTestState()
        resumeKeyTest()
    }

    func confirmPendingMove() {
        guard let move = pendingMove else { return }
        apply(move.trigger, to: move.mode, replacing: move.replacing, confirmedMove: true)
    }

    func dismissPendingMove() { pendingMove = nil }

    /// Onboarding keeps the live check running on the key step; Settings runs it only on request.
    func resumeKeyTest() {
        guard keyTestAuto, !capturing, !keyTest.ok else { return }
        startKeyTest(rounds: 60)
    }

    /// Polish (tidy) key: keys and key combos only (system hot keys); mouse buttons and holds belong to dictation.
    func captureTidyKey(replacing: TidyShortcut? = nil) {
        if proActionsLocked { return }
        beginCapture()
        capturingTidy = true
        _ = applyTidyKeys([]) // the current tidy keys must reach the recorder, not start a tidy
        let token = captureToken
        engine.captureNextTrigger(timeout: 10) { [weak self] raw in
            guard let self, token == self.captureToken else { return }
            self.endCapture()
            guard let raw else { self.keyMessage = L("keys.capture.timeout"); return }
            if Self.isEscape(raw) { return }
            let others = self.tidyKeys.filter { $0 != replacing }
            self.keyMessage = Self.tidyProblem(raw, tidyKeys: others, triggers: self.triggers)
            guard self.keyMessage == nil, let key = TidyShortcut(trigger: raw) else { return }
            if let replacing, let index = self.tidyKeys.firstIndex(of: replacing) { self.tidyKeys[index] = key }
            else if !self.tidyKeys.contains(key) { self.tidyKeys.append(key) }
            let name = Self.describe(raw)
            self.captured = name
            self.capturedConfirmation = L("keys.capture.confirmedPress", name)
            self.saveTidyKeys()
        }
    }

    /// Esc, Cancel, leaving the step: forget the running capture and hand the input back.
    func cancelCapture() {
        guard capturing else { return }
        captureToken += 1
        endCapture()
        engine.captureNextTrigger(timeout: 0.01) { _ in } // replaces (and so drops) the pending capture
        resumeKeyTest()
    }

    private func beginCapture() {
        stopKeyTest()
        captureToken += 1
        capturing = true; captured = nil; capturedConfirmation = nil; keyMessage = nil; pendingMove = nil; confirmingReset = false
    }

    private func endCapture() {
        let wasTidy = capturingTidy
        capturing = false; capturingMode = nil; capturingReplacement = nil; capturingTidy = false
        if wasTidy { _ = applyTidyKeys(tidyKeys) }
    }

    static func isEscape(_ t: TriggerKind) -> Bool {
        if case .key(53, 0, _) = t { return true }
        return false
    }

    /// One-click switch for keyboards without a 🌐 key: hold Right ⌥ Option instead (English: + ⇧ Shift).
    func useRightOption() {
        let locked = proActionsLocked
        let swap: (TriggerKind) -> TriggerKind = { t in
            if locked && t.mode != .bilingual { return t }
            guard case .modifierHold(let keys, let mode, let ms) = t, keys.contains(.fn) else { return t }
            let replaced = keys.map { $0 == .fn ? ModifierKey.rightOption : $0 }
            return .modifierHold(keys: ModifierKey.allCases.filter(replaced.contains), mode: mode, holdMilliseconds: ms)
        }
        var seen = Set<String>()
        triggers = triggers.map(swap).filter { seen.insert($0.inputKey).inserted }
        saveTriggers()
        captured = primaryTrigger(for: .bilingual).map(Self.describe)
        if let name = captured { capturedConfirmation = L("keys.capture.confirmedHold", name) }
        keyTest = KeyTestState()
        resumeKeyTest()
    }

    // MARK: live key test

    /// Listens for the next key without dictating, re-arming until the key is seen or the step is left.
    /// `rounds` bounds the re-arms (Settings runs one round; onboarding keeps listening on the step).
    func startKeyTest(rounds: Int = 1) {
        guard !isPreview, !capturing, primaryTrigger(for: .bilingual) != nil, rounds > 0 else { return }
        keyTestToken += 1
        let token = keyTestToken
        keyTest.listening = true
        let started = Date()
        engine.captureNextTrigger(timeout: 8) { [weak self] seen in
            guard let self, token == self.keyTestToken else { return }
            self.keyTest.listening = false
            guard let seen else {
                // An immediate nil means the engine is not running (permissions); say nothing.
                guard Date().timeIntervalSince(started) > 1 else { return }
                if let primary = self.primaryTrigger(for: .bilingual), Self.usesFn(primary), !self.keyTest.ok { self.keyTest.missedFn = true }
                self.startKeyTest(rounds: rounds - 1)
                return
            }
            if Self.isEscape(seen) { return }
            if self.triggers.contains(where: { $0.inputKey == seen.inputKey }) {
                self.keyTest = KeyTestState(listening: false, ok: true, other: nil, missedFn: false)
            } else {
                self.keyTest.other = Self.problem(with: seen) == nil ? seen : nil
                self.keyTest.ok = false
                self.startKeyTest(rounds: rounds - 1)
            }
        }
    }

    func stopKeyTest() {
        keyTestToken += 1
        if keyTest.listening && !capturing { engine.captureNextTrigger(timeout: 0.01) { _ in } }
        keyTest.listening = false
    }

    /// "Use ⌥ Option instead" from the live test.
    func useTestedKey() {
        guard let other = keyTest.other else { return }
        keyTest.other = nil
        apply(other.with(mode: .bilingual), to: .bilingual, replacing: primaryTrigger(for: .bilingual))
    }
}
