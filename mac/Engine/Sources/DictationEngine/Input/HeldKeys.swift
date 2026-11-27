import CoreGraphics

/// Physical modifier keys (by key code) and other keys currently held, as seen through the event tap.
/// The tap misses key-ups: the lock screen and password fields (secure input) swallow them, a disabled
/// tap drops them. A key left "held" used to block every Fn / mouse trigger until a relaunch, so each
/// event's modifier flags are the truth for which groups are down, and other keys expire.
struct HeldKeys {
    static let modifierGroups: [Int64: (ModifierKey, CGEventFlags)] = [
        59: (.control, .maskControl), 62: (.control, .maskControl), 58: (.option, .maskAlternate), 61: (.option, .maskAlternate),
        55: (.command, .maskCommand), 54: (.command, .maskCommand), 56: (.shift, .maskShift), 60: (.shift, .maskShift), 63: (.fn, .maskSecondaryFn),
    ]
    /// A key with no keyDown (auto-repeat refreshes it) for this long is taken as released.
    static let keyStaleAfter = 10.0

    private(set) var modifiers = Set<Int64>()
    private var keys: [Int64: Double] = [:] // key code → last keyDown (uptime)

    /// Held modifiers as trigger keys: groups plus side-specific Right Option / Right Command.
    var held: Set<ModifierKey> {
        var held = Set(modifiers.compactMap { Self.modifierGroups[$0]?.0 })
        if modifiers.contains(61) { held.insert(.rightOption) }
        if modifiers.contains(54) { held.insert(.rightCommand) }
        return held
    }

    /// A modifier key went down or up. Flags don't say which side, so the key toggles; then the flags
    /// win: a group whose flag is set has this key down if none of its keys is recorded.
    mutating func flagsChanged(code: Int64, flags: CGEventFlags) {
        if let (_, flag) = Self.modifierGroups[code] {
            if modifiers.contains(code) { modifiers.remove(code) } else { modifiers.insert(code) }
            if flags.contains(flag), !modifiers.contains(where: { Self.modifierGroups[$0]?.1 == flag }) { modifiers.insert(code) }
        }
        resync(flags: flags)
    }

    /// Drop modifiers whose group flag is not set. Any keyboard or mouse event's flags are the current
    /// modifier state. Returns how many stale keys were dropped.
    @discardableResult mutating func resync(flags: CGEventFlags) -> Int {
        let before = modifiers.count
        modifiers = modifiers.filter { Self.modifierGroups[$0].map { flags.contains($0.1) } ?? false }
        return before - modifiers.count
    }

    mutating func keyDown(_ code: Int64, at: Double) { keys[code] = at }
    mutating func keyUp(_ code: Int64) { keys[code] = nil }

    /// A non-modifier key is held (a chord with it blocks a modifier trigger). Expired keys are ignored.
    func anyKeyDown(now: Double) -> Bool { keys.values.contains { now - $0 < Self.keyStaleAfter } }

    mutating func expireKeys(now: Double) { keys = keys.filter { now - $0.value < Self.keyStaleAfter } }
    mutating func reset() { modifiers.removeAll(); keys.removeAll() }
}
