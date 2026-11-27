import AppKit
import ApplicationServices

/// Owns a dedicated run loop so Core Audio startup or a slow target app can never stall the
/// system event callback. Only copies and routes events in the callback. The tap is an active
/// (`.defaultTap`) session tap, which runs under the Accessibility grant — no Input Monitoring.
final class InputTapRouter: @unchecked Sendable {
    /// Mouse buttons used as triggers are swallowed (down + matching up) so apps don't act on them.
    let mouseButtons: Locked<Set<Int>>
    let deliver: (CGEventType, CGEvent) -> Void
    private(set) var tap: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var captured: Int? // Accessed only by the dedicated input thread.

    init(mouseButtons: Set<Int>, deliver: @escaping (CGEventType, CGEvent) -> Void) {
        self.mouseButtons = Locked(mouseButtons); self.deliver = deliver
    }

    func install(mask: CGEventMask) -> CFMachPort? {
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let router = Unmanaged<InputTapRouter>.fromOpaque(context).takeUnretainedValue()
            return router.route(type, event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: opaque) else { return nil }
        tap = created
        let worker = Thread { [weak self] in
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            self?.runLoop = CFRunLoopGetCurrent()
            CGEvent.tapEnable(tap: created, enable: true)
            CFRunLoopRun()
        }
        worker.name = "Sunday Voice input events"; worker.qualityOfService = .userInteractive
        thread = worker; worker.start()
        return created
    }

    func uninstall() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil; runLoop = nil; thread = nil
    }

    func route(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            captured = nil; if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
        if let copy = event.copy() { DispatchQueue.main.async { self.deliver(type, copy) } }
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        guard type == .otherMouseDown || type == .otherMouseUp, mouseButtons.get.contains(button) else { return false }
        let modified = !event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift, .maskSecondaryFn]).isEmpty
        if type == .otherMouseDown && !modified { captured = button; return true }
        if type == .otherMouseUp && captured == button { captured = nil; return true }
        return false
    }
}
