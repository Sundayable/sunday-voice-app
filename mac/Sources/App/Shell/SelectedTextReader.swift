import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Reads without replacing source text. Uses bounded, targeted Copy only when AX cannot read it.
@MainActor
final class SelectedTextReader {
    enum Failure: Error { case permission, secureField, focusChanged, copyFailed }
    private var prompted = false

    func read(from app: NSRunningApplication?, board: NSPasteboard) async throws -> String? {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        guard AXIsProcessTrusted() else {
            if !prompted {
                prompted = true
                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                throw Failure.permission
            }
            guard ClipboardTidy.copiedText(board) != nil else { throw Failure.permission }
            return nil
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw Failure.focusChanged }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let field = focused as! AXUIElement
            if string(field, kAXSubroleAttribute) == kAXSecureTextFieldSubrole { throw Failure.secureField }
            if let selected = string(field, kAXSelectedTextAttribute), !selected.isEmpty { return selected }
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXValueGetTypeID() {
                var range = CFRange()
                if AXValueGetValue(value as! AXValue, .cfRange, &range) {
                    if range.length == 0 { return nil } // Some editors copy the whole line at an empty caret.
                    var selected: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString, value, &selected) == .success,
                       let text = selected as? String, !text.isEmpty { return text }
                }
            }
        }
        guard !IsSecureEventInputEnabled() else { throw Failure.secureField }
        // Let the triggering modifiers go before Cmd+C; never copy in a newly focused app.
        for _ in 0..<40 {
            if CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else { throw Failure.focusChanged }
        let count = board.changeCount
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) else { throw Failure.copyFailed }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(app.processIdentifier); up.postToPid(app.processIdentifier)
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 25_000_000)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw Failure.focusChanged }
            if board.changeCount != count {
                guard let text = ClipboardTidy.copiedText(board), !text.isEmpty else { throw Failure.copyFailed }
                return text
            }
        }
        return nil
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
