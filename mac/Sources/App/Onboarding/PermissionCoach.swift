import AppKit
import SwiftUI

/// Sunday Voice's own companion for the trip into System Settings: a small checklist card in the
/// top-right corner of the screen that follows what the user has actually done. It reads only the
/// permission state this app already polls; it never inspects or positions another app's window.
@MainActor
final class PermissionCoach {
    static let shared = PermissionCoach()
    private var panel: NSPanel?
    private var timer: Timer?
    private var shownAt = Date()
    private let model = PermissionCoachModel()
    private let size = NSSize(width: 328, height: 196)
    /// Supplied by the permission monitor so the card ticks itself and leaves when the switch is on.
    var isGranted: (Permission) -> Bool = { _ in false }

    func show(for permission: Permission) {
        shownAt = Date()
        model.permission = permission
        model.stage = .waiting
        if panel == nil {
            let created = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            created.level = .floating
            created.isFloatingPanel = true
            created.hidesOnDeactivate = false
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            created.backgroundColor = .clear
            created.isOpaque = false
            created.hasShadow = true
            created.contentView = NSHostingView(rootView: PermissionCoachCard(model: model, onHide: { [weak self] in self?.hide() }))
            panel = created
        }
        place()
        panel?.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil)
    }

    /// Top-right of the screen the pointer is on, clear of the menu bar.
    private func place() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel?.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 18, y: visible.maxY - size.height - 18))
    }

    private func tick() {
        guard let permission = model.permission else { hide(); return }
        if isGranted(permission) {
            if model.stage != .done {
                model.stage = .done
                shownAt = Date()
            } else if Date().timeIntervalSince(shownAt) > 2.5 {
                hide()
            }
            return
        }
        // Ten quiet minutes means the user moved on; do not linger on their screen.
        if Date().timeIntervalSince(shownAt) > 600 { hide() }
    }
}

@MainActor
final class PermissionCoachModel: ObservableObject {
    enum Stage { case waiting, done }
    @Published var permission: Permission?
    @Published var stage: Stage = .waiting
}

private struct PermissionCoachCard: View {
    @ObservedObject var model: PermissionCoachModel
    var onHide: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(nsImage: AppIdentity.icon).resizable().frame(width: 22, height: 22)
                Text(verbatim: L(model.permission == .inputMonitoring ? "ob.perm.im.title" : "ob.perm.ax.title"))
                    .font(Theme.display(15, semibold: true))
                Spacer()
                Button(L("ob.coach.hide"), action: onHide).buttonStyle(.plain)
                    .font(Theme.label(10)).foregroundStyle(Theme.muted(scheme))
            }
            step(1, L("ob.coach.find", AppIdentity.name), done: model.stage == .done)
            step(2, L("ob.coach.switch"), done: model.stage == .done)
            if model.stage == .done {
                Text(verbatim: L("ob.coach.done")).font(Theme.text(12, medium: true)).foregroundStyle(Theme.approval)
            } else {
                // If macOS did not list the app, the user adds it with the + button; show them the file to pick.
                Button(L("ob.coach.missing")) { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                    .buttonStyle(.plain).font(Theme.text(11)).underline().foregroundStyle(Theme.muted(scheme))
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .foregroundStyle(Theme.text(scheme))
        .background(Theme.panel(scheme), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.rule(scheme), lineWidth: 1))
        .padding(4)
    }

    private func step(_ number: Int, _ text: String, done: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            ZStack {
                Circle().fill(done ? Theme.approval : Theme.rule(scheme)).frame(width: 18, height: 18)
                if done { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.onStructure(scheme)) }
                else { Text(verbatim: "\(number)").font(Theme.label(10)) }
            }
            Text(verbatim: text).font(Theme.text(12.5)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
