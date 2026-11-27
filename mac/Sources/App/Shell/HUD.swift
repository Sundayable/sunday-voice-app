import AppKit
import SwiftUI

/// What the recording pill shows. Idle states never show a pill.
enum HUDState: Equatable {
    case hidden
    case preparing(mode: String, connecting: Bool)
    case listening(mode: String, meter: Bool)
    case processing(mode: String)
    case done
    case copied
    case pending
    case error(String, HUDAction)
    /// Tidy clipboard: working, done (with Undo), already tidy, original restored.
    case tidying
    case tidied
    case tidyUnchanged
    case tidyRestored
}

enum HUDAction: Equatable { case close, reconnect, microphoneSettings, accessibilitySettings, retryTranscription, openAccount }

/// Branded recording pill. Near-solid brand surface (not system material) so it stays legible
/// over any app: light = Card + 2px Ink border + hard offset; dark = Night + Paper type.
/// Sits on the LEFT edge of the screen under the pointer, vertically centred.
@MainActor
final class HUD {
    var levelProvider: () -> Float = { 0 }
    var onPaste: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onUndo: () -> Void = {}
    var onAction: (HUDAction) -> Void = { _ in }
    /// Gallery/screenshot use only.
    var forcedAppearance: NSAppearance?

    private(set) var state: HUDState = .hidden
    private var panel: NSPanel?
    private let model = HUDModel()
    private var levelTimer: Timer?
    private var hideWork: DispatchWorkItem?

    static let edgeInset: CGFloat = 12
    /// Transparent margin inside the panel so the soft shadow isn't clipped.
    static let shadowRoom: CGFloat = 16

    func setRecordingNotice(_ text: String?) {
        model.notice = text
        if let panel { position(panel) }
    }

    /// Pre-build the floating panel and SwiftUI host off-screen so the first dictation shows immediately.
    func prepare() {
        let p = ensurePanel()
        p.alphaValue = 0
        p.contentView?.layoutSubtreeIfNeeded()
    }

    func show(_ next: HUDState) {
        hideWork?.cancel(); hideWork = nil
        state = next
        model.state = next
        levelTimer?.invalidate(); levelTimer = nil
        if next == .hidden { fade(); return }
        let p = ensurePanel()
        p.appearance = forcedAppearance
        p.ignoresMouseEvents = !next.hasButtons
        if case .listening = next {
            levelTimer = Timer.scheduledTimer(withTimeInterval: 1 / 24, repeats: true) { [weak self] _ in
                Task { @MainActor in guard let self else { return }; self.model.push(self.levelProvider()) }
            }
        }
        position(p)
        p.alphaValue = 1
        p.orderFrontRegardless()
        switch next {
        case .done: schedule(0.6) { [weak self] in self?.show(.hidden) }
        case .copied: schedule(1.2) { [weak self] in if self?.state == .copied { self?.show(.hidden) } }
        case .error: schedule(5) { [weak self] in if case .error = self?.state { self?.show(.hidden) } }
        // Long enough to reach Undo; the result is on the clipboard either way.
        case .tidied: schedule(5) { [weak self] in if self?.state == .tidied { self?.show(.hidden) } }
        case .tidyUnchanged, .tidyRestored: schedule(1.8) { [weak self] in if self?.state == next { self?.show(.hidden) } }
        default: break
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 64), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false // brand: hard offset drawn in the view, no diffuse shadow
        let root = HUDView(model: model, onPaste: { [weak self] in self?.onPaste(); self?.show(.hidden) },
                           onDiscard: { [weak self] in self?.onDiscard(); self?.show(.hidden) },
                           onAction: { [weak self] action in self?.onAction(action); self?.show(.hidden) },
                           onUndo: { [weak self] in self?.onUndo() })
        p.contentView = NSHostingView(rootView: root)
        panel = p
        return p
    }

    /// Left edge of the screen that holds the pointer, vertically centred in its visible frame.
    static func origin(for size: NSSize, on screen: NSRect) -> NSPoint {
        NSPoint(x: screen.minX + edgeInset - shadowRoom, y: (screen.midY - size.height / 2).rounded())
    }

    private func position(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame, let content = p.contentView else { return }
        let size = content.fittingSize
        p.setContentSize(size)
        p.setFrameOrigin(Self.origin(for: size, on: frame))
    }

    private func fade() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; panel.animator().alphaValue = 0 }) {
            Task { @MainActor in if self.state == .hidden { panel.orderOut(nil) } }
        }
    }

    private func schedule(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        let work = DispatchWorkItem { MainActor.assumeIsolated { body() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Renders a pill state to PNG (gallery / plan page), light or dark.
    static func snapshot(_ state: HUDState, dark: Bool, level: [Float] = []) -> NSBitmapImageRep? {
        let model = HUDModel(); model.state = state
        if !level.isEmpty { model.levels = level }
        // Rendered over a neutral app-like backdrop so the hairline and shadow read as they would on screen.
        let backdrop = dark ? Color(red: 0.13, green: 0.13, blue: 0.15) : Color(red: 0.93, green: 0.93, blue: 0.94)
        let host = NSHostingView(rootView: HUDView(model: model, onPaste: {}, onDiscard: {}, onAction: { _ in }, onUndo: {}).background(backdrop))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .clear
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
}

extension HUDState {
    /// Tidy pills belong to the clipboard action, not to dictation: engine idle/reconnect must not hide them.
    var isTidy: Bool {
        switch self { case .tidying, .tidied, .tidyUnchanged, .tidyRestored: return true; default: return false }
    }
    var hasButtons: Bool {
        switch self { case .pending, .tidied: return true; case .error(_, let a): return a != .close; default: return false }
    }
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var notice: String?
    @Published var state: HUDState = .hidden
    @Published var levels: [Float] = Array(repeating: 0, count: 14)
    func push(_ level: Float) { levels.removeFirst(); levels.append(level) }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel
    let onPaste: () -> Void
    let onDiscard: () -> Void
    let onAction: (HUDAction) -> Void
    var onUndo: () -> Void = {}
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Near-solid brand surface (Card / Ink) with a hairline and a soft lift: legible over any app,
    // quiet enough to flash on and off all day.
    private var dark: Bool { scheme == .dark }
    private var surface: Color { dark ? Theme.ink : Theme.card }
    private var hairline: Color { dark ? Theme.paper.opacity(0.12) : Theme.ink.opacity(0.10) }
    private var fg: Color { Theme.text(scheme) }
    private var quiet: Color { Theme.muted(scheme) }

    var body: some View {
        let pill = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 9) { content }
            .padding(.leading, 11).padding(.trailing, 12)
            .frame(height: 32)
            .background(pill.fill(surface.opacity(0.97)))
            .overlay(pill.strokeBorder(hairline, lineWidth: 1))
            .shadow(color: .black.opacity(dark ? 0.45 : 0.14), radius: dark ? 14 : 12, y: 4)
            .shadow(color: .black.opacity(dark ? 0.25 : 0.06), radius: 1.5, y: 1)
            .foregroundStyle(fg)
            .fixedSize()
            .padding(HUD.shadowRoom)
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .hidden:
            EmptyView()
        case .preparing(let mode, let connecting):
            Spinner(color: quiet).frame(width: 13, height: 13)
            Text(verbatim: model.notice ?? L(connecting ? "hud.connecting" : "hud.preparing")).font(Theme.text(13, medium: true)).foregroundStyle(quiet)
            modeTag(mode)
        case .listening(let mode, _):
            PillBars(levels: model.levels, color: fg, still: reduceMotion)
            Text(verbatim: model.notice ?? L("hud.speak")).font(Theme.text(13, medium: true))
            modeTag(mode)
        case .processing(let mode):
            Dots(animate: !reduceMotion, color: quiet).frame(width: 18)
            Text(verbatim: model.notice ?? L("hud.processing")).font(Theme.text(13, medium: true))
            modeTag(mode)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 11.5, weight: .bold)).foregroundStyle(Theme.approval)
            Text(verbatim: L("hud.done")).font(Theme.text(13, medium: true))
        case .copied:
            Image(systemName: "doc.on.clipboard").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.approval)
            Text(verbatim: L("hud.copied")).font(Theme.text(13, medium: true))
        case .pending:
            Image(systemName: "doc.on.clipboard").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(quiet)
            Text(verbatim: L("hud.pending")).font(Theme.text(13, medium: true))
            pillButton(L("hud.button.paste"), primary: true, action: onPaste)
            pillButton(L("hud.button.discard"), primary: false, action: onDiscard)
        case .tidying:
            Dots(animate: !reduceMotion, color: quiet).frame(width: 18)
            Text(verbatim: L("hud.tidying")).font(Theme.text(13, medium: true))
        case .tidied:
            Image(systemName: "checkmark").font(.system(size: 11.5, weight: .bold)).foregroundStyle(Theme.approval)
            Text(verbatim: L("hud.tidied")).font(Theme.text(13, medium: true))
            pillButton(L("hud.button.undo"), primary: false, action: onUndo)
        case .tidyUnchanged:
            Image(systemName: "checkmark").font(.system(size: 11.5, weight: .bold)).foregroundStyle(quiet)
            Text(verbatim: L("hud.tidyUnchanged")).font(Theme.text(13, medium: true))
        case .tidyRestored:
            Image(systemName: "arrow.uturn.backward").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(quiet)
            Text(verbatim: L("hud.tidyRestored")).font(Theme.text(13, medium: true))
        case .error(let message, let action):
            Image(systemName: "exclamationmark.circle").font(.system(size: 12.5, weight: .medium)).foregroundStyle(quiet)
            Text(verbatim: message).font(Theme.text(13, medium: true)).lineLimit(1)
            if action != .close {
                pillButton(L(actionTitleKey(action)), primary: action == .openAccount) { onAction(action) }
            }
        }
    }

    private func actionTitleKey(_ action: HUDAction) -> String {
        switch action {
        case .retryTranscription: return "hud.button.retryTranscription"
        case .reconnect: return "hud.button.reconnect"
        case .openAccount: return "hud.button.upgradePro"
        default: return "hud.button.openSettings"
        }
    }

    /// Mode as a quiet tinted label (no outline, no capitals).
    private func modeTag(_ mode: String) -> some View {
        Text(verbatim: mode == "bilingual" ? L("hud.mode.bilingual") : L("hud.mode.english"))
            .font(Theme.text(11, medium: true))
            .foregroundStyle(quiet)
            .padding(.horizontal, 6).frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(fg.opacity(dark ? 0.10 : 0.06)))
    }

    private func pillButton(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        let pill = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return Button(action: action) {
            Text(verbatim: title).font(Theme.text(12, medium: true))
                .padding(.horizontal, 10).frame(height: 22)
                .foregroundStyle(primary ? Theme.onStructure(scheme) : fg)
                .background(pill.fill(primary ? fg : fg.opacity(dark ? 0.12 : 0.07)))
        }
        .buttonStyle(.plain)
    }
}

/// Five live bars driven by the real input level (smoothed, quiet-mic friendly), not a dotted line.
private struct PillBars: View {
    let levels: [Float]
    let color: Color
    let still: Bool
    private let weights: [CGFloat] = [0.55, 0.85, 1.0, 0.8, 0.6]

    var body: some View {
        let recent = Array(levels.suffix(4))
        let level = CGFloat(OnboardingModel.displayLevel(recent.max() ?? 0))
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let jitter = CGFloat(OnboardingModel.displayLevel(levels.count > i ? levels[levels.count - 1 - i] : 0))
                let h = still ? 8 : max(3, min(14, 3 + 11 * max(level * weights[i], jitter * 0.8)))
                Capsule().fill(color).frame(width: 2.5, height: h)
            }
        }
        .frame(width: 20, height: 16)
        .animation(.easeOut(duration: 0.09), value: levels)
    }
}

private struct Spinner: View {
    let color: Color
    @State private var spin = false
    var body: some View {
        Circle().trim(from: 0.15, to: 1).stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true } }
    }
}

private struct Dots: View {
    let animate: Bool
    let color: Color
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle().fill(color).frame(width: 5, height: 5)
                    .opacity(animate ? 0.25 + 0.75 * max(0, sin((phase - Double(i) * 0.6))) : 0.7)
            }
        }
        .onAppear {
            guard animate else { return }
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi * 2 }
        }
    }
}
