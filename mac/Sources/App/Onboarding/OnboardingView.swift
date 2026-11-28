import SwiftUI
import DictationEngine

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var lang = UILanguageObserver.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let _ = lang.revision
        HStack(spacing: 0) {
            Rail(step: model.step, steps: model.visibleSteps)
                .frame(width: 196)
                .background(scheme == .dark ? Theme.ink.opacity(0.55) : Theme.surface.opacity(0.6))
            Rectangle().fill(Theme.rule(scheme)).frame(width: 1)
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: true) {
                    content.padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Footer(model: model)
            }
        }
        .frame(width: 760, height: 600)
        .background(Theme.ground(scheme))
        .foregroundStyle(Theme.text(scheme))
        .environment(\.locale, Locale(identifier: UILanguage.isKorean ? "ko" : "en"))
        // Step views get the same model on a language switch, so SwiftUI would skip them; a new identity redraws every string.
        .id(lang.revision)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .signIn:
            if model.auth.user != nil && model.auth.consentRequired { ConsentView(model: model) }
            else { SignInStep(model: model) }
        case .proUpgrade: ProUpgradeStep(model: model)
        case .permissions: PermissionsStep(model: model)
        case .mic: MicStep(model: model)
        case .keys: KeysStep(model: model)
        case .localModel: LocalModelStep(model: model)
        case .connect: ConnectStep(model: model)
        case .voice: VoiceStep(model: model)
        case .tryIt: TryStep(model: model)
        case .done: DoneStep(model: model)
        }
    }
}

// MARK: chrome

private struct Rail: View {
    let step: OnboardingStep
    let steps: [OnboardingStep]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: AppIdentity.name).font(Theme.display(19)).padding(.bottom, 4).padding(.leading, 8)
            Text(verbatim: L("ob.rail.setup").uppercased()).font(Theme.label(10.5)).foregroundStyle(Theme.muted(scheme))
                .padding(.bottom, 20).padding(.leading, 8)
            ForEach(steps) { s in
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(s.rawValue < step.rawValue ? Theme.approval : (s == step ? Theme.structure(scheme) : Color.clear))
                        Circle().strokeBorder(s.rawValue <= step.rawValue ? Color.clear : Theme.rule(scheme), lineWidth: 1.5)
                        if s.rawValue < step.rawValue {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.paper)
                        } else {
                            Text(verbatim: "\((steps.firstIndex(of: s) ?? 0) + 1)").font(Theme.label(10))
                                .foregroundStyle(s == step ? Theme.onStructure(scheme) : Theme.muted(scheme))
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(verbatim: L(s.railKey)).font(Theme.text(13.5, medium: s == step))
                        .foregroundStyle(s == step ? Theme.text(scheme) : Theme.muted(scheme))
                }
                .padding(.vertical, 6).padding(.horizontal, 8)
            }
            Spacer()
            ByLine().padding(.leading, 8).padding(.bottom, 22)
        }
        .padding(.horizontal, 12).padding(.top, 30)
    }
}

/// Sidebar sign-off on one line: "Built by" + the supplied wordmark (Ink on light / Paper on dark).
struct ByLine: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(verbatim: "Built by").font(Theme.text(12.5, medium: true)).foregroundStyle(Theme.muted(scheme))
            if let mark = Theme.wordmark(scheme) {
                Image(nsImage: mark).resizable().aspectRatio(contentMode: .fit).frame(width: 84).offset(y: 1)
            } else {
                Text(verbatim: "Sundayable").font(Theme.display(13))
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore).accessibilityLabel("Built by Sundayable")
    }
}

private struct Footer: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            if model.step != .signIn && model.step != .done {
                Button(L("ob.back")) { model.back() }.buttonStyle(GhostButton())
            }
            Spacer()
            if model.step.skippable && !model.canContinueStrict {
                Button(L("ob.skip")) { model.next() }.buttonStyle(GhostButton())
            }
            if model.step == .done {
                Button(L("ob.done.finish", AppIdentity.name)) { model.finish() }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
            } else if model.step == .signIn && model.auth.user == nil {
                Button(L("ob.welcome.startLocal")) { model.startFreeLocal() }
                    .buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
            } else if model.step != .signIn || model.facts.signedIn {
                Button(L("ob.continue")) { model.next() }
                    .buttonStyle(PrimaryButton()).disabled(!model.canContinue).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(Theme.ground(scheme))
        .overlay(alignment: .top) { Rectangle().fill(Theme.rule(scheme)).frame(height: 1) }
    }
}

extension OnboardingModel {
    /// For skippable steps: whether the step's own goal was reached (hides "Skip").
    var canContinueStrict: Bool {
        switch step {
        case .localModel: return localModelReady
        case .connect: return anyConnected
        case .voice: return !savedCards.isEmpty
        case .tryIt: return !tryText.isEmpty
        case .mic: return micHeard
        default: return canContinue
        }
    }
}

/// Brand primary action: Ink button, 2px Ink border, 3px hard offset, Gabarito 600.
/// Keeps cornerRadius strictly below height/2 to avoid macOS 26 semicircle strokeBorder edge artifacts.
struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let pill = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return configuration.label.font(Theme.display(14.5, semibold: true))
            .padding(.horizontal, 22).frame(minHeight: 40)
            .foregroundStyle(Theme.onStructure(scheme))
            .background(pill.fill(Theme.structure(scheme)))
            .overlay(pill.strokeBorder(Theme.structure(scheme), lineWidth: 2))
            .background(pill.fill(Theme.structure(scheme).opacity(0.2)).offset(x: pressed ? 1 : 3, y: pressed ? 1 : 3))
            .offset(x: pressed ? 2 : 0, y: pressed ? 2 : 0)
            .padding(.trailing, 3).padding(.bottom, 3)
            .opacity(enabled ? 1 : 0.35)
            .contentShape(pill)
    }
}

/// Secondary action: outlined button, same geometry, no fill.
struct GhostButton: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        let pill = RoundedRectangle(cornerRadius: 11, style: .continuous)
        configuration.label.font(Theme.display(13.5, semibold: true))
            .padding(.horizontal, 18).frame(minHeight: 36)
            .foregroundStyle(Theme.text(scheme))
            .overlay(pill.strokeBorder(Theme.structure(scheme).opacity(configuration.isPressed ? 0.5 : 1), lineWidth: 2))
            .contentShape(pill)
    }
}

struct StepHeader: View {
    let title: String
    let body_: String
    @Environment(\.colorScheme) private var scheme
    init(_ title: String, _ body: String) { self.title = title; self.body_ = body }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title).font(Theme.display(30)).tracking(-0.5).lineSpacing(1).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: body_).font(Theme.text(15)).foregroundStyle(Theme.muted(scheme))
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 22)
    }
}

/// Interface card (12px radius, Line border); `highlighted` = proof card (2px Ink border + 4px hard offset).
struct Card<Content: View>: View {
    var highlighted = false
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        content.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(highlighted ? Theme.structure(scheme) : Theme.rule(scheme), lineWidth: highlighted ? 2 : 1))
            .background(RoundedRectangle(cornerRadius: 12).fill(highlighted ? (scheme == .dark ? Color.black.opacity(0.6) : Theme.ink) : Color.clear).offset(x: 4, y: 4))
    }
}

/// Compact status object (pill). Approval green only for a granted/connected state.
struct Chip: View {
    let text: String
    let ok: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark" : "circle.dotted").font(.system(size: 9.5, weight: .bold))
            Text(verbatim: text.uppercased()).font(Theme.label(10.5))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .foregroundStyle(ok ? Theme.paper : Theme.muted(scheme))
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(ok ? Theme.approval : Theme.well(scheme)))
    }
}

// MARK: 1 sign in

struct SignInStep: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(nsImage: AppIdentity.icon).resizable().frame(width: 52, height: 52)
                Spacer()
                LanguageSwitch()
            }
            .padding(.bottom, 14)
            StepHeader(L("ob.welcome.title"), L("ob.welcome.body"))
            if let user = model.auth.user {
                Card(highlighted: true) {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 22)).foregroundStyle(Theme.approval)
                        Text(verbatim: L("ob.welcome.signedIn", user.email)).font(Theme.text(14, medium: true))
                    }
                }.frame(maxWidth: 460)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Card(highlighted: true) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(verbatim: L("ob.welcome.local.title")).font(Theme.display(16))
                                Spacer(minLength: 4)
                                Chip(text: L("ob.welcome.local.badge"), ok: true)
                            }
                            Text(verbatim: L("ob.welcome.local.body"))
                                .font(Theme.text(12.5)).foregroundStyle(Theme.muted(scheme))
                                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(verbatim: L("ob.welcome.pro.title")).font(Theme.display(15))
                            Text(verbatim: L("ob.welcome.pro.body"))
                                .font(Theme.text(12.5)).foregroundStyle(Theme.muted(scheme))
                                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                            Button { model.signIn() } label: {
                                HStack(spacing: 10) {
                                    GoogleMark().frame(width: 17, height: 17)
                                    Text(verbatim: L("ob.welcome.pro.google")).font(.system(size: 13.5, weight: .semibold))
                                }
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .foregroundStyle(Color(white: 0.12))
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.black.opacity(0.14)))
                                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.auth.signingIn)
                            if model.auth.signingIn {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(verbatim: L("ob.welcome.signingIn")).font(Theme.text(12.5)) }
                                    HStack(spacing: 16) {
                                        if model.auth.browserRecoveryAvailable {
                                            Button(L("ob.welcome.openBrowser")) { model.auth.continueSignInInBrowser() }
                                        }
                                        Button(L("menu.cancel")) { model.auth.cancelSignIn() }.keyboardShortcut(.cancelAction)
                                    }
                                    .buttonStyle(.link).font(Theme.text(12.5))
                                }
                                .foregroundStyle(Theme.muted(scheme))
                            }
                            if let error = model.signInError {
                                Text(verbatim: error).font(Theme.text(12)).foregroundStyle(.red)
                            }
                        }
                    }
                }
                .frame(maxWidth: 492)
            }
            Text(verbatim: L("ob.welcome.fine")).font(Theme.text(12)).foregroundStyle(Theme.muted(scheme)).padding(.top, 14)
        }
    }
}

/// Google "G" drawn from four arcs and the bar (no bitmap asset).
struct GoogleMark: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, lw = w * 0.2
            let blue = Color(red: 0.26, green: 0.52, blue: 0.96)
            ZStack {
                seg(0.0, 0.13, blue, lw)
                seg(0.13, 0.38, Color(red: 0.20, green: 0.66, blue: 0.33), lw)
                seg(0.38, 0.62, Color(red: 0.98, green: 0.74, blue: 0.02), lw)
                seg(0.62, 0.87, Color(red: 0.92, green: 0.26, blue: 0.21), lw)
                Rectangle().fill(blue).frame(width: w * 0.42, height: lw).offset(x: w * 0.2)
            }
        }
    }
    private func seg(_ a: CGFloat, _ b: CGFloat, _ c: Color, _ lw: CGFloat) -> some View {
        Circle().trim(from: a, to: b).stroke(c, style: StrokeStyle(lineWidth: lw)).padding(lw / 2)
    }
}

// MARK: 1b pro upgrade

struct ProUpgradeStep: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(L("ob.pro.title"), L("ob.pro.body"))
            SubscriptionCard(model: model)
                .frame(maxWidth: 492)
            if model.isProEntitled {
                Label { Text(verbatim: L("ob.pro.ready")).font(Theme.text(13, medium: true)) } icon: { Image(systemName: "checkmark.seal.fill") }
                    .foregroundStyle(Theme.approval)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Button(L("ob.pro.useLocal")) { model.switchToFreeLocalMode() }
                        .buttonStyle(GhostButton())
                    Text(verbatim: L("billing.freeLocalReadyNote"))
                        .font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: 2 permissions

struct PermissionsStep: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(L("ob.perm.title"), L("ob.perm.body"))
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 12) {
                    ForEach(model.permissions.required, id: \.self) { p in
                        PermissionCard(permission: p, granted: model.permissions.granted(p),
                                       focused: model.permissions.nextMissing == p,
                                       requested: model.monitor.waitingSince[p] != nil,
                                       retry: model.retryVisible.contains(p), action: { model.request(p) },
                                       retryAction: { model.monitor.openSettings(p) })
                    }
                    if model.permissions.allGranted {
                        Label { Text(verbatim: L("ob.perm.allSet")).font(Theme.text(13, medium: true)) } icon: { Image(systemName: "checkmark.seal.fill") }
                            .foregroundStyle(Theme.approval).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity)
                PermissionSteps(permission: model.permissions.nextMissing ?? .accessibility, done: model.permissions.allGranted)
                    .frame(width: 176, height: 236)
            }
        }
    }
}

struct PermissionCard: View {
    let permission: Permission
    let granted: Bool
    let focused: Bool
    /// "Waiting for you…" only after the user asked macOS for this permission.
    var requested = true
    let retry: Bool
    let action: () -> Void
    let retryAction: () -> Void
    @Environment(\.colorScheme) private var scheme

    var title: String { L(permission == .microphone ? "ob.perm.mic.title" : permission == .accessibility ? "ob.perm.ax.title" : "ob.perm.im.title") }
    var why: String { L(permission == .microphone ? "ob.perm.mic.why" : permission == .accessibility ? "ob.perm.ax.why" : "ob.perm.im.why") }
    var buttonTitle: String { L(permission == .microphone ? "ob.perm.mic.button" : permission == .accessibility ? "ob.perm.ax.button" : "ob.perm.im.button") }
    var symbol: String { permission == .microphone ? "mic.fill" : permission == .accessibility ? "accessibility" : "keyboard" }

    var body: some View {
        Card(highlighted: focused && !granted) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 30, height: 30)
                        .background(Theme.well(scheme), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: title).font(Theme.display(16))
                        Text(verbatim: why).font(Theme.text(12.5)).foregroundStyle(Theme.muted(scheme)).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    if granted { Chip(text: L("ob.perm.granted"), ok: true) }
                }
                if !granted {
                    Button(buttonTitle, action: action).buttonStyle(PrimaryButton())
                    if retry {
                        Button(L("ob.perm.retry"), action: retryAction).buttonStyle(.link).font(Theme.text(12))
                    } else if focused && requested {
                        Text(verbatim: L("ob.perm.waiting")).font(Theme.text(11.5)).foregroundStyle(Theme.muted(scheme))
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: granted)
    }
}

/// What happens next, in three plain steps. Sunday Voice's own illustration: it tells the user
/// what to do rather than imitating another window.
struct PermissionSteps: View {
    let permission: Permission
    let done: Bool
    @State private var active = 0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: L("ob.steps.header").uppercased())
                    .font(Theme.label(9.5)).foregroundStyle(Theme.muted(scheme))
                Text(verbatim: L(permission == .microphone ? "ob.perm.mic.title" : permission == .accessibility ? "ob.perm.ax.title" : "ob.perm.im.title"))
                    .font(Theme.display(13.5, semibold: true)).foregroundStyle(Theme.text(scheme))
            }
            step(0, "gearshape", L("ob.steps.open"))
            step(1, "magnifyingglass", L("ob.steps.find", AppIdentity.name))
            step(2, "switch.2", L("ob.steps.on"))
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.well(scheme), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.rule(scheme), lineWidth: 1))
        .task(id: done) {
            guard !done else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_400_000_000) } catch { return }
                withAnimation(.easeInOut(duration: 0.3)) { active = (active + 1) % 3 }
            }
        }
    }

    private func step(_ index: Int, _ symbol: String, _ text: String) -> some View {
        let current = !done && active == index
        return HStack(alignment: .top, spacing: 9) {
            ZStack {
                Circle().fill(done ? Theme.approval : current ? Theme.structure(scheme) : Theme.rule(scheme)).frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Theme.onStructure(scheme))
                } else {
                    Text(verbatim: "\(index + 1)").font(Theme.label(10))
                        .foregroundStyle(current ? Theme.onStructure(scheme) : Theme.muted(scheme))
                }
            }
            Text(verbatim: text).font(Theme.text(11.5, medium: current)).foregroundStyle(current || done ? Theme.text(scheme) : Theme.muted(scheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }
}

// MARK: 3 mic

struct MicStep: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(L("ob.mic.title"), L("ob.mic.body"))
            Card(highlighted: model.micHeard) {
                VStack(alignment: .leading, spacing: 14) {
                    LevelBars(level: model.micLevel).frame(height: 56)
                    HStack(spacing: 8) {
                        Image(systemName: model.micHeard ? "checkmark.circle.fill" : "waveform").foregroundStyle(model.micHeard ? Theme.approval : Theme.muted(scheme))
                        Text(verbatim: L(model.micHeard ? "ob.mic.heard" : "ob.mic.quiet")).font(Theme.text(13.5, medium: true))
                        Spacer()
                        if !model.micHeard { Button(L("ob.mic.soundSettings")) { NSWorkspace.shared.open(SettingsLink.soundInput) }.buttonStyle(.link).font(Theme.text(12.5)) }
                    }
                }
            }
            .frame(maxWidth: 460)
        }
    }
}

struct LevelBars: View {
    let level: Float
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { g in
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<28, id: \.self) { i in
                    let shape = 0.35 + 0.65 * abs(sin(Double(i) * 0.7))
                    let h = max(4, CGFloat(min(1, Double(level) * shape)) * g.size.height)
                    Capsule().fill(Theme.text(scheme).opacity(level > 0.15 ? 1 : 0.3)).frame(width: 5, height: h)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.08), value: level)
        }
    }
}

// MARK: 4 keys — see KeysView.swift

/// Wraps chips onto the next line when they don't fit.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 500
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing; line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y + (line > 0 ? 0 : 0)), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}

/// A physical key: fixed height, room for its bottom edge, label in the text face (not mono).
struct Keycap: View {
    let label: String
    var lit = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text(verbatim: label)
            .font(Theme.text(12.5, medium: true))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 11)
            .frame(minWidth: 44, minHeight: 28)
            .foregroundStyle(lit ? Theme.onStructure(scheme) : Theme.text(scheme))
            .background(
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 7).fill(Theme.structure(scheme).opacity(scheme == .dark ? 0.35 : 0.22)).offset(y: 2)
                    RoundedRectangle(cornerRadius: 7).fill(lit ? Theme.structure(scheme) : Theme.panel(scheme))
                    RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.structure(scheme).opacity(0.55), lineWidth: 1)
                }
            )
            .padding(.bottom, 2) // keep the key's bottom edge inside the layout (was clipped)
    }
}

// MARK: 4b local speech model

struct LocalModelStep: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    private var progressLabel: String {
        if model.localModelProgress >= 0.94 { return L("ob.localModel.preparing") }
        let pct = "\(Int((min(1, max(0, model.localModelProgress)) * 100).rounded()))"
        return L("ob.localModel.downloading", pct)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(L("ob.localModel.title"), L("ob.localModel.body"))
            Card(highlighted: model.localModelReady) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: model.localModelReady ? "checkmark.circle.fill" : "arrow.down.circle")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(model.localModelReady ? Theme.approval : Theme.text(scheme))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: L(model.localModelReady ? "ob.localModel.readyTitle" : "ob.localModel.cardTitle"))
                                .font(Theme.display(16))
                            Text(verbatim: L(model.localModelReady ? "ob.localModel.readyBody" : "ob.localModel.cardBody"))
                                .font(Theme.text(12.5)).foregroundStyle(Theme.muted(scheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                    }
                    if model.localModelDownloading {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: model.localModelProgress > 0 ? min(1, model.localModelProgress) : nil)
                                .tint(Theme.approval)
                            Text(verbatim: progressLabel)
                                .font(Theme.text(12.5, medium: true))
                                .foregroundStyle(Theme.muted(scheme))
                                .monospacedDigit()
                        }
                    } else if !model.localModelReady {
                        Button(L(model.localModelError == nil ? "ob.localModel.download" : "ob.localModel.retry")) {
                            model.downloadLocalModel()
                        }
                        .buttonStyle(PrimaryButton())
                    }
                    if let error = model.localModelError {
                        Text(verbatim: error)
                            .font(Theme.text(12)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: 492)
        }
    }
}

// MARK: 5 connect

struct ConnectStep: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(L("ob.connect.title"), L("ob.connect.body"))
            VStack(spacing: 10) {
                ConnectRow(symbol: "envelope.fill", title: L("ob.connect.gmail"), status: model.connections["gmail"] ?? "not_connected") { model.connect("gmail") }
                ConnectRow(symbol: "number", title: L("ob.connect.slack"), status: model.connections["slack"] ?? "not_connected") { model.connect("slack") }
            }
            .frame(maxWidth: 520)
            if let error = model.connectionError { Text(verbatim: error).font(Theme.text(12)).foregroundStyle(.red).padding(.top, 8) }
            Label { Text(verbatim: L("ob.connect.readonly")).font(Theme.text(12.5)) } icon: { Image(systemName: "lock.fill") }
                .foregroundStyle(Theme.muted(scheme)).padding(.top, 14)
        }
    }
}

struct ConnectRow: View {
    let symbol: String
    let title: String
    let status: String
    var disconnect: (() -> Void)? = nil
    var disconnecting = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 32, height: 32)
                    .background(Theme.well(scheme), in: RoundedRectangle(cornerRadius: 8))
                Text(verbatim: title).font(Theme.text(14, medium: true))
                Spacer()
                switch status {
                case "active":
                    VStack(alignment: .trailing, spacing: 6) {
                        Chip(text: L("ob.connect.connected"), ok: true)
                        if let disconnect {
                            Button(L(disconnecting ? "settings.disconnecting" : "settings.disconnect"), action: disconnect)
                                .buttonStyle(GhostButton()).disabled(disconnecting)
                        }
                    }
                case "pending":
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(verbatim: L("ob.connect.pending")).font(Theme.text(12)) }
                        .foregroundStyle(Theme.muted(scheme))
                default:
                    if status == "error" { Text(verbatim: L("ob.connect.error")).font(Theme.text(12)).foregroundStyle(.red) }
                    Button(L("ob.connect.button"), action: action).buttonStyle(PrimaryButton())
                }
            }
        }
    }
}

// MARK: 6 voice

struct VoiceStep: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(L("ob.voice.title"), L("ob.voice.body"))
            if model.cards.isEmpty && !model.anyConnected {
                Text(verbatim: L("ob.voice.presets")).font(Theme.text(13, medium: true)).padding(.bottom, 10)
                HStack(alignment: .top, spacing: 12) {
                    PresetColumn(model: model, lang: "ko", title: L("ob.voice.ko"))
                    PresetColumn(model: model, lang: "en", title: L("ob.voice.en"))
                }
            } else if model.cards.isEmpty || model.buildingVoice {
                HStack(spacing: 12) {
                    Button(L("ob.voice.build")) { model.buildVoice() }.buttonStyle(PrimaryButton()).disabled(model.buildingVoice)
                    if model.buildingVoice { ProgressView().controlSize(.small); Text(verbatim: L("ob.voice.building")).font(Theme.text(13)).foregroundStyle(Theme.muted(scheme)) }
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    CardEditor(model: model, lang: "ko", title: L("ob.voice.ko"))
                    CardEditor(model: model, lang: "en", title: L("ob.voice.en"))
                }
                if let s = model.voiceStats {
                    Text(verbatim: L("ob.voice.stats", "\(s.gmail_messages)", "\(s.slack_messages)")).font(Theme.label(11)).foregroundStyle(Theme.muted(scheme)).padding(.top, 10)
                    if let n = s.vocab_terms, n > 0 {
                        HStack(spacing: 10) {
                            Text(verbatim: L("ob.voice.words", "\(n)")).font(Theme.text(13, medium: true))
                            Button(L("ob.voice.wordsLink")) { model.openWords?() }.buttonStyle(.link).font(Theme.text(13))
                        }.padding(.top, 6)
                    }
                }
            }
            if let e = model.voiceError { Text(verbatim: e).font(Theme.text(12)).foregroundStyle(.red).padding(.top, 8) }
        }
    }
}

struct CardEditor: View {
    @ObservedObject var model: OnboardingModel
    let lang: String
    let title: String
    @State private var confirmingDelete = false
    @Environment(\.colorScheme) private var scheme

    private var hasContent: Bool {
        let current = (model.cards[lang] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = (model.savedCards[lang] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !current.isEmpty || !saved.isEmpty
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(verbatim: title).font(Theme.display(15))
                    Spacer()
                    if model.cards[lang] != model.savedCards[lang],
                       !(model.cards[lang] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(L("ob.voice.save")) { model.saveCard(lang) }.buttonStyle(.link).font(Theme.text(12, medium: true))
                    }
                    if hasContent && !confirmingDelete {
                        Button(L("voice.delete")) { confirmingDelete = true }
                            .buttonStyle(.link).font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
                    }
                }
                if confirmingDelete {
                    HStack(spacing: 8) {
                        Text(verbatim: L("voice.delete.confirm")).font(Theme.text(11.5)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button(L("voice.delete.confirmButton")) {
                            confirmingDelete = false
                            model.deleteCard(lang)
                        }.buttonStyle(GhostButton())
                        Button(L("keys.cancel")) { confirmingDelete = false }.buttonStyle(.link).font(Theme.text(12))
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well(scheme)))
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: Binding(get: { model.cards[lang] ?? "" }, set: { model.cards[lang] = $0 }))
                        .font(Theme.text(12.5)).scrollContentBackground(.hidden).scrollIndicators(.never)
                        .frame(height: 210)
                        .padding(6).background(Theme.ground(scheme), in: RoundedRectangle(cornerRadius: 8))
                    if (model.cards[lang] ?? "").isEmpty {
                        Text(verbatim: L("voice.emptyCard"))
                            .font(Theme.text(12))
                            .foregroundStyle(Theme.muted(scheme).opacity(0.75))
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }
}

struct PresetColumn: View {
    @ObservedObject var model: OnboardingModel
    let lang: String
    let title: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: title).font(Theme.display(15))
                ForEach(OnboardingModel.presets[lang] ?? [], id: \.key) { preset in
                    let chosen = model.cards[lang] == preset.text
                    Button { model.applyPreset(lang, preset.text) } label: {
                        HStack {
                            Text(verbatim: L(preset.key)).font(Theme.text(13, medium: chosen))
                            Spacer()
                            if chosen { Image(systemName: "checkmark") }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(chosen ? Theme.well(scheme) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: 7 try

struct TryStep: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(L("ob.try.title"), L(model.effectiveLocalDictation ? "ob.try.body.local" : "ob.try.body"))
            if model.effectiveLocalDictation && !model.localModelReady {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.down.circle").foregroundStyle(Theme.muted(scheme))
                            Text(verbatim: L("ob.localModel.tryBanner")).font(Theme.text(12.5, medium: true))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            if !model.localModelDownloading {
                                Button(L("ob.localModel.tryDownload")) { model.downloadLocalModel() }
                                    .buttonStyle(GhostButton())
                            }
                        }
                        if model.localModelDownloading {
                            ProgressView(value: model.localModelProgress > 0 ? min(1, model.localModelProgress) : nil)
                                .tint(Theme.approval)
                        }
                        if let error = model.localModelError {
                            Text(verbatim: error).font(Theme.text(12)).foregroundStyle(.red)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.tryText).font(Theme.text(15)).scrollContentBackground(.hidden).scrollIndicators(.never).padding(10)
                if model.tryText.isEmpty {
                    Text(verbatim: L("ob.try.placeholder")).font(Theme.text(15)).foregroundStyle(Theme.muted(scheme).opacity(0.7)).padding(15).allowsHitTesting(false)
                }
            }
            .frame(height: model.effectiveLocalDictation && !model.localModelReady ? 110 : 150)
            .background(Theme.panel(scheme), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.text(scheme), lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: L("ob.try.keysLabel").uppercased()).font(Theme.label(10)).foregroundStyle(Theme.muted(scheme))
                HStack(spacing: 16) {
                    ForEach([DictationMode.bilingual, .english], id: \.self) { mode in
                        if let t = model.primaryTrigger(for: mode), mode == .bilingual || !model.effectiveLocalDictation {
                            HStack(spacing: 7) {
                                KeyChip(verb: L("keys.hold"), key: OnboardingModel.describe(t))
                                Text(verbatim: "→ " + L(mode.nameKey)).font(Theme.text(12.5)).foregroundStyle(Theme.muted(scheme))
                            }
                        }
                    }
                }
            }
            .padding(.top, 14)
            if !model.tryText.isEmpty {
                Label { Text(verbatim: L("ob.try.success")).font(Theme.text(13.5, medium: true)) } icon: { Image(systemName: "sparkles") }
                    .foregroundStyle(Theme.approval).padding(.top, 12)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: L("ob.try.fallback")).font(Theme.text(12.5)).foregroundStyle(Theme.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("ob.try.openKeys")) { model.go(to: .keys) }.buttonStyle(.link).font(Theme.text(12.5, medium: true))
                }
                .padding(.top, 12)
            }
        }
    }
}

// MARK: 8 done

struct DoneStep: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme
    private var cheat: String {
        func names(_ m: DictationMode) -> String { model.triggers(for: m).map(OnboardingModel.describe).joined(separator: " / ") }
        let proLocked = model.proActionsLocked || model.effectiveLocalDictation
        let englishSuffix = proLocked ? " (\(L("badge.proOnly")))" : ""
        let polish = model.primaryTidyKey.map { "   ·   \(OnboardingModel.describe($0.trigger)) → \(L("mode.polish.name"))" } ?? ""
        let polishSuffix = proLocked ? " (\(L("badge.proOnly")))" : ""
        return "\(names(.bilingual)) → \(L("mode.dictate.name"))   ·   \(names(.english)) → \(L("mode.english.name"))\(englishSuffix)\(polish)\(polish.isEmpty ? "" : polishSuffix)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(L("ob.done.title"), L("ob.done.body", AppIdentity.name))
            // Menu bar sketch with our item highlighted.
            HStack(spacing: 14) {
                Spacer()
                Image(systemName: "wifi"); Image(systemName: "battery.75percent")
                Group { if let mark = MenuStyle.statusImage { Image(nsImage: mark).renderingMode(.template) } }
                    .padding(5).background(Theme.text(scheme).opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(alignment: .bottom) { Image(systemName: "arrowtriangle.up.fill").font(.system(size: 9)).foregroundStyle(Theme.text(scheme)).offset(y: 14) }
                Text(verbatim: "Fri 9:41").font(.system(size: 12, weight: .medium))
            }
            .font(.system(size: 13)).padding(.horizontal, 14).frame(height: 30)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            .frame(maxWidth: 520)
            Text(verbatim: cheat).font(Theme.text(12.5, medium: true)).foregroundStyle(Theme.muted(scheme)).padding(.top, 20)

            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: L("ob.done.optionalSection").uppercased())
                    .font(Theme.label(10.5)).foregroundStyle(Theme.muted(scheme))
                    .padding(.top, 20)
                if HandsFreeSupport.isAvailable() {
                    HandsFreeOnboardingCard {
                        model.openHandsFreeSettings?()
                    }
                }
                AnonymousStatsCard(compact: true, localMode: model.effectiveLocalDictation)
                ProductUpdatesCard(source: .onboardingDone)
            }
            .frame(maxWidth: 520)
        }
    }
}

/// Opt-in anonymous usage stats card (default OFF; asked once on onboarding Done + configurable in Settings → General).
struct AnonymousStatsCard: View {
    var compact = false
    var localMode = true
    @State private var enabled = Prefs.anonymousStatsEnabled
    @State private var resetConfirmed = false
    @Environment(\.colorScheme) private var scheme

    private var baseURL: URL { AppIdentity.apiBaseURL ?? URL(string: "https://voice.sundayable.com")! }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    Text(verbatim: L("stats.toggleTitle"))
                        .font(Theme.text(13.5, medium: true))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 10)
                    Toggle("", isOn: $enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel(L("stats.toggleTitle"))
                        .onChange(of: enabled) { _, on in
                            Prefs.anonymousStatsEnabled = on
                            if on { AnonymousStats.shared.recordFirstLaunchIfNeeded(localMode: localMode) }
                        }
                }
                Text(verbatim: L("stats.toggleBody"))
                    .font(Theme.text(11.5)).foregroundStyle(Theme.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: L("stats.neverSent"))
                    .font(Theme.text(11.5, medium: true)).foregroundStyle(Theme.text(scheme).opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: L("stats.localHonestNote"))
                    .font(Theme.text(11.5)).foregroundStyle(Theme.approval)
                    .fixedSize(horizontal: false, vertical: true)

                if !compact {
                    Rectangle().fill(Theme.rule(scheme)).frame(height: 1).padding(.vertical, 2)
                    HStack(spacing: 14) {
                        Button(L("stats.resetID")) {
                            Prefs.resetAnonymousStatsInstallID()
                            resetConfirmed = true
                        }
                        .buttonStyle(GhostButton())
                        if resetConfirmed {
                            Text(verbatim: L("stats.resetIDDone"))
                                .font(Theme.text(11.5, medium: true))
                                .foregroundStyle(Theme.approval)
                        }
                        Spacer(minLength: 0)
                        Link(L("stats.privacyLink"), destination: baseURL.appendingPathComponent("privacy"))
                            .font(Theme.text(11.5, medium: true))
                        Link(L("stats.termsLink"), destination: baseURL.appendingPathComponent("terms"))
                            .font(Theme.text(11.5, medium: true))
                    }
                }
            }
        }
    }
}

/// Optional CASL-compliant product updates signup card (unchecked by default; never auto-subscribed).
struct ProductUpdatesCard: View {
    let source: ProductUpdatesClient.Source
    @State private var email = ""
    @State private var consent = false
    @State private var submitting = false
    @State private var subscribed = Prefs.productUpdatesSubscribed
    @State private var error: String?
    @Environment(\.colorScheme) private var scheme

    private var canSubmit: Bool {
        consent && ProductUpdatesClient.isValidEmail(email) && !submitting
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                Text(verbatim: L("updates.title")).font(Theme.display(15))
                Text(verbatim: L("updates.body"))
                    .font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                if subscribed {
                    Label {
                        Text(verbatim: L("updates.subscribed"))
                            .font(Theme.text(12, medium: true))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .foregroundStyle(Theme.approval)
                } else {
                    HStack(spacing: 8) {
                        TextField(L("updates.emailPlaceholder"), text: $email)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.text(13))
                        Button(submitting ? L("updates.submitting") : L("updates.submit")) {
                            submitting = true; error = nil
                            Task {
                                do {
                                    try await ProductUpdatesClient.shared.subscribe(email: email, consent: consent, source: source)
                                    Prefs.productUpdatesSubscribed = true
                                    subscribed = true
                                } catch {
                                    self.error = L("updates.error")
                                }
                                submitting = false
                            }
                        }
                        .buttonStyle(GhostButton())
                        .disabled(!canSubmit)
                    }
                    Toggle(isOn: $consent) {
                        Text(verbatim: L("updates.consentCheckbox"))
                            .font(Theme.text(11.5)).foregroundStyle(Theme.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)
                    if let error {
                        Text(verbatim: error).font(Theme.text(11.5)).foregroundStyle(.red)
                    }
                }
            }
        }
    }
}

/// First-screen language switch (한국어 / English). Starts on the Mac's language; changes the whole app at once.
/// Language names are shown in their own language, so they never need translating.
struct LanguageSwitch: View {
    @ObservedObject private var lang = UILanguageObserver.shared
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let _ = lang.revision
        let korean = UILanguage.isKorean
        HStack(spacing: 8) {
            Image(systemName: "globe").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted(scheme))
                .accessibilityLabel(L("lang.label"))
            HStack(spacing: 0) {
                option("한국어", code: "ko", selected: korean)
                option("English", code: "en", selected: !korean)
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.well(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.rule(scheme), lineWidth: 1))
        }
    }

    private func option(_ name: String, code: String, selected: Bool) -> some View {
        Button { if !selected { UILanguage.choice = code } } label: {
            Text(verbatim: name).font(Theme.text(12.5, medium: true))
                .padding(.horizontal, 11).frame(height: 26)
                .foregroundStyle(selected ? Theme.onStructure(scheme) : Theme.text(scheme))
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Theme.structure(scheme) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
