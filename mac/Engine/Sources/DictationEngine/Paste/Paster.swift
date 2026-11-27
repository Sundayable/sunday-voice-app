import AppKit
import ApplicationServices

/// Pastes into the field that was focused when the dictation started, through the clipboard. When the
/// paste is confirmed it restores every clipboard item type (unless the user copied something newer);
/// when it can't be confirmed or fails, the transcript stays on the clipboard. Never sends Enter.
/// Refuses password fields. Holds the result if focus moved or the focused item isn't a text field.
@MainActor
final class Paster {
    enum Outcome: Equatable { case pasted, held(reason: String), secureField, ownWindow }

    struct Target {
        let app: NSRunningApplication?
        let element: AXUIElement?
        var bundleID: String? { app?.bundleIdentifier }
        /// Our own window was frontmost (e.g. onboarding "Try it"): the app inserts the text itself.
        var isOwnApp: Bool { app?.processIdentifier == ProcessInfo.processInfo.processIdentifier }
    }

    /// Where the last external paste landed (element, UTF-16 offset, exact inserted text), so the
    /// engine can later notice an in-place correction. Holds no field content.
    struct Insertion { let element: AXUIElement; let location: Int; let text: String }
    private(set) var lastInsertion: Insertion?

    func captureTarget() -> Target {
        let app = NSWorkspace.shared.frontmostApplication
        // Accessibility calls into our own process from the main thread stall until they time out
        // (and the stalled event tap gets disabled), so our own windows are never queried.
        if app?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return Target(app: app, element: nil) }
        var value: CFTypeRef?
        if let pid = app?.processIdentifier,
           AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return Target(app: app, element: (value as! AXUIElement))
        }
        return Target(app: app, element: nil)
    }

    /// Whether a paste is known to have landed (read back from the field), could not be checked
    /// (no focused element, value not readable), or did not land.
    enum Check: Equatable { case confirmed, unconfirmed, failed }

    /// Focused element roles that can never take typed text (a list, table, window…): pasting there fails.
    static let nonTextRoles: Set<String> = ["AXOutline", "AXTable", "AXList", "AXWindow", "AXButton", "AXBrowser", "AXRow", "AXCell",
                                            "AXMenu", "AXMenuItem", "AXImage", "AXSplitGroup", "AXToolbar", "AXCheckBox", "AXRadioButton",
                                            "AXPopUpButton", "AXSlider", "AXTabGroup", "AXDisclosureTriangle"]

    /// Paste through the clipboard. `checked` reports, ~0.15–0.7 s later, whether the text landed:
    /// confirmed → the previous clipboard is restored; unconfirmed or failed → the transcript stays on
    /// the clipboard (unless the user copied something newer) so it is never lost.
    func paste(_ text: String, into target: Target, checked: @escaping @MainActor (Check) -> Void = { _ in }) -> Outcome {
        // Our own window needs neither Accessibility nor the clipboard: the app inserts the text itself.
        if target.isOwnApp, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return .ownWindow }
        guard AXIsProcessTrusted(), let app = target.app,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return .held(reason: "focus_or_accessibility")
        }
        var current: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute as CFString, &current)
        if let expected = target.element, let actual = current, !CFEqual(expected, actual) { return .held(reason: "field_changed") }
        var insertion = text
        lastInsertion = nil
        var before: String?
        if let element = target.element {
            var subrole: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            if (subrole as? String) == (kAXSecureTextFieldSubrole as String) { return .secureField }
            var role: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if let role = role as? String, Self.nonTextRoles.contains(role) { return .held(reason: "not_text_field") }
            // Only inspect context for the same, currently focused, non-secure target.
            // It stays local to this paste; never capture, retain or log the field's value.
            if let actual = current, CFEqual(element, actual) {
                let (spaced, location) = textForInsertion(text, in: element)
                insertion = spaced
                if let location { lastInsertion = Insertion(element: element, location: location, text: spaced) }
                before = Self.currentValue(of: element, timeout: 0.3)
            }
        }
        let board = NSPasteboard.general
        let saved = Self.snapshot(board)
        board.clearContents()
        board.setString(insertion, forType: .string)
        let change = board.changeCount
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap); up?.post(tap: .cgSessionEventTap)
        let element = before == nil ? nil : target.element
        verify(element: element, before: before ?? "", inserted: insertion, delays: verifyDelays) { check in
            if board.changeCount != change {
                Log.paste.info("clipboard_new_content_preserved")
            } else if check == .confirmed && !self.keepTranscriptOnClipboard {
                board.clearContents()
                let items = saved.map { values -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { board.writeObjects(items) }
                Log.paste.info("clipboard_restored verified=\(Self.snapshot(board) == saved, privacy: .public)")
            } else {
                // Keep the transcript itself (without the separator spaces) for ⌘V. Plain string only:
                // no transient/concealed markers, so clipboard managers see it like any copy.
                board.clearContents(); board.setString(text, forType: .string)
                Log.paste.info("paste_check=\(check == .confirmed ? "confirmed" : check == .failed ? "failed" : "unconfirmed", privacy: .public) transcript_kept_on_clipboard")
            }
            checked(check)
        }
        return .pasted
    }

    /// Dan (2026-10-06): the latest transcript stays on the clipboard after every dictation, so ⌘V
    /// always recovers it. Off = restore the previous clipboard when the paste is confirmed.
    var keepTranscriptOnClipboard = true

    /// Read-back schedule after ⌘V (apps apply a paste asynchronously).
    var verifyDelays: [TimeInterval] = [0.15, 0.35, 0.7]

    private func verify(element: AXUIElement?, before: String, inserted: String, delays: [TimeInterval], done: @escaping @MainActor (Check) -> Void) {
        guard let element, let delay = delays.first else {
            // Nothing readable to check against: report after the first delay so the paste has happened.
            DispatchQueue.main.asyncAfter(deadline: .now() + (delays.first ?? 0.15)) { MainActor.assumeIsolated { done(element == nil ? .unconfirmed : .failed) } }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                guard let after = Self.currentValue(of: element, timeout: 0.3) else { done(.unconfirmed); return }
                if Self.pasteLanded(before: before, after: after, inserted: inserted) { done(.confirmed); return }
                if delays.count == 1 { done(.failed); return }
                self.verify(element: element, before: before, inserted: inserted, delays: Array(delays.dropFirst()), done: done)
            }
        }
    }

    /// The pasted text appears once more than before (whitespace-insensitive, for fields that
    /// normalise spaces or line breaks).
    nonisolated static func pasteLanded(before: String, after: String, inserted: String) -> Bool {
        func squash(_ s: String) -> String { s.filter { !$0.isWhitespace } }
        let core = squash(inserted)
        guard !core.isEmpty else { return true }
        func count(_ haystack: String) -> Int { haystack.isEmpty ? 0 : squash(haystack).components(separatedBy: core).count - 1 }
        return count(after) > count(before)
    }

    /// Put a transcript on the clipboard when it could not be pasted (held, secure field, …).
    /// Hands-free delivery: type the text as Unicode key events into the frontmost app. Chat apps route
    /// typed characters to their message field even when the list has keyboard focus, which a Cmd-V does not
    /// get. Newlines become spaces so a chat never sends early. No clipboard, no read-back.
    static func typeUnicode(_ text: String) {
        let units = Array(text.replacingOccurrences(of: "\n", with: " ").utf16)
        var i = 0
        while i < units.count {
            var end = min(i + 16, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            var chunk = Array(units[i..<end])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                e.post(tap: .cgSessionEventTap)
            }
            usleep(6000)
            i = end
        }
    }

    /// Hands-free delivery for apps whose field we focused through Accessibility (e.g. Electron):
    /// clipboard + Cmd-V, no read-back. Unicode key events break there while a Korean input method is active.
    func pasteRaw(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents(); board.setString(text.replacingOccurrences(of: "\n", with: " "), forType: .string)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cgSessionEventTap)
        }
    }

    func copyToClipboard(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents(); board.setString(text, forType: .string)
    }

    /// The text to insert and, when the caret position is known, its UTF-16 offset.
    private func textForInsertion(_ text: String, in element: AXUIElement) -> (String, Int?) {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return (text, nil) }
        let axRange = rangeValue as! AXValue
        var selection = CFRange()
        guard AXValueGetType(axRange) == .cfRange, AXValueGetValue(axRange, .cfRange, &selection),
              selection.length == 0, selection.location >= 0 else { return (text, nil) }
        var fieldValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &fieldValue) == .success,
              let value = fieldValue as? String else { return (text, nil) }
        return (Self.textForInsertion(text, in: value, selection: selection), selection.location)
    }

    /// The field's current value, for the correction check only. Not retained by the caller.
    static func currentValue(of element: AXUIElement, timeout: Float = 0.3) -> String? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var subrole: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if (subrole as? String) == (kAXSecureTextFieldSubrole as String) { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Add separators only at unambiguous prose boundaries. AX offsets are UTF-16, not
    /// Character counts. Selections, positions within a grapheme/token and unknown context
    /// keep the exact dictated text. Existing and explicit whitespace is never rewritten.
    nonisolated static func textForInsertion(_ text: String, in value: String, selection: CFRange) -> String {
        guard !text.isEmpty, selection.length == 0, selection.location >= 0,
              selection.location <= value.utf16.count else { return text }
        let offset = value.utf16.index(value.utf16.startIndex, offsetBy: selection.location)
        guard let caret = String.Index(offset, within: value) else { return text }
        let before = caret == value.startIndex ? nil : value[value.index(before: caret)]
        let after = caret == value.endIndex ? nil : value[caret]
        // With text on both sides and no whitespace, this could be a word, URL, number,
        // or a Korean suffix. Do not guess how to separate an insertion inside it.
        if let before, let after, !before.isWhitespace, !after.isWhitespace { return text }
        var insertion = text
        if let before, let first = text.first, needsSeparator(between: before, and: first) { insertion = " " + insertion }
        if let after, let last = text.last, needsSeparator(between: last, and: after) { insertion += " " }
        return insertion
    }

    private nonisolated static func needsSeparator(between left: Character, and right: Character) -> Bool {
        // Closing punctuation may end a phrase; opening punctuation may start one.
        // Apostrophes, hyphens, slashes and other ambiguous symbols stay attached.
        let endsPhrase = left.isLetter || left.isNumber || ".,!?;:…)]}”".contains(left)
        let startsPhrase = right.isLetter || right.isNumber || "([{“".contains(right)
        return endsPhrase && startsPhrase
    }

    static func snapshot(_ board: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (board.pasteboardItems ?? []).map { item in
            var values = [NSPasteboard.PasteboardType: Data]()
            for type in item.types { if let data = item.data(forType: type) { values[type] = data } }
            return values
        }
    }
}
