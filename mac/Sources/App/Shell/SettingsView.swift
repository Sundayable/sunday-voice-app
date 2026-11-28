import AppKit
import ServiceManagement
import SwiftUI
import DictationEngine

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var pane: SettingsView.Pane
    init(pane: SettingsView.Pane = .account) { self.pane = pane }
}

/// One settings window in the brand system: Account, Keys, Voice, My words, General.
/// Reuses the onboarding building blocks so every surface looks and behaves the same.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case account, keys, handsFree, voice, words, meetings, general
        var id: String { rawValue }
        var titleKey: String { "settings.\(rawValue)" }
        var symbol: String {
            switch self {
            case .account: return "person.crop.circle"
            case .keys: return "keyboard"
            case .handsFree: return "waveform.and.mic"
            case .voice: return "text.quote"
            case .words: return "character.book.closed"
            case .meetings: return "waveform.badge.mic"
            case .general: return "gearshape"
            }
        }

        /// Hides macOS 15+ Apple Silicon-only Hands-free pane on macOS 14 and Intel Macs.
        static func visibleCases(handsFreeAvailable: Bool = HandsFreeSupport.isAvailable()) -> [Pane] {
            handsFreeAvailable ? allCases : allCases.filter { $0 != .handsFree }
        }
    }

    @ObservedObject var model: OnboardingModel
    @ObservedObject var words: VocabularyModel
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var lang = UILanguageObserver.shared
    private var pane: Pane { navigation.pane }
    var meetings: MeetingCoordinator? = nil
    var onSignOut: () -> Void
    var onLocalDictationToggled: ((Bool) -> Void)? = nil
    @Environment(\.colorScheme) private var scheme

    init(model: OnboardingModel, words: VocabularyModel, pane: Pane = .account,
         meetings: MeetingCoordinator? = nil, navigation: SettingsNavigation? = nil,
         onSignOut: @escaping () -> Void, onLocalDictationToggled: ((Bool) -> Void)? = nil) {
        self.model = model; self.words = words; self.meetings = meetings
        self.navigation = navigation ?? SettingsNavigation(pane: pane)
        self.onSignOut = onSignOut
        self.onLocalDictationToggled = onLocalDictationToggled
    }

    var body: some View {
        let _ = lang.revision
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: AppIdentity.name).font(Theme.display(19)).padding(.leading, 8).padding(.bottom, 18)
                ForEach(Pane.visibleCases()) { p in
                    Button { navigation.pane = p } label: {
                        HStack(spacing: 10) {
                            Image(systemName: p.symbol).font(.system(size: 13, weight: .medium)).frame(width: 18)
                            Text(verbatim: L(p.titleKey)).font(Theme.text(13.5, medium: pane == p))
                            Spacer()
                        }
                        .padding(.vertical, 7).padding(.horizontal, 10)
                        .foregroundStyle(pane == p ? Theme.onStructure(scheme) : Theme.text(scheme))
                        .background(RoundedRectangle(cornerRadius: 8).fill(pane == p ? Theme.structure(scheme) : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(pane == p ? .isSelected : [])
                }
                Spacer()
                ByLine().padding(.leading, 8).padding(.bottom, 22)
            }
            .padding(.horizontal, 12).padding(.top, 30)
            .frame(width: 200)
            .background(scheme == .dark ? Theme.ink.opacity(0.55) : Theme.surface.opacity(0.6))
            Rectangle().fill(Theme.rule(scheme)).frame(width: 1)
            Group {
                if pane == .words {
                    // Has its own scrolling list; give it the pane's exact size so it can never widen the window.
                    VocabularyView(model: words, embedded: true, isGuest: model.isGuest, isSignedOut: model.isLocalOnly,
                                   isLocalMode: model.effectiveLocalDictation,
                                   onOpenAccount: { navigation.pane = .account }).padding(32)
                } else {
                    ScrollView {
                        Group {
                            switch pane {
                            case .account: AccountPane(model: model, onSignOut: onSignOut)
                            case .keys: KeysStep(model: model, context: .settings)
                            case .handsFree: HandsFreePane(model: model, onOpenKeys: { navigation.pane = .keys })
                            case .voice: VoicePane(model: model, onOpenAccount: { navigation.pane = .account })
                            case .words: EmptyView()
                            case .meetings:
                                if let meetings {
                                    MeetingSettingsView(coordinator: meetings, isGuest: model.isGuest,
                                                        googleCalendarAllowed: model.googleCalendarAllowed)
                                } else { Text("Meeting transcription stays on this Mac.") }
                            case .general: GeneralPane(model: model,
                                                       onSoundsChange: model.engine.updateSoundsEnabled,
                                                       onRecentContextChange: model.engine.updateRecentContextEnabled,
                                                       onScreenContextChange: model.engine.updateScreenContextEnabled,
                                                       onLocalDictationChange: { on in
                                                           model.engine.updateLocalDictationEnabled(on)
                                                           onLocalDictationToggled?(on)
                                                       },
                                                       localModelReady: model.localModelReady || (model.engine.localTranscriber?.isReady ?? (meetings?.modelReady ?? false)),
                                                       onOpenMeetings: { navigation.pane = .meetings },
                                                       onClipboardChange: model.engine.updateKeepTranscriptOnClipboard)
                            }
                        }
                        .padding(32).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 600)
        .background(Theme.ground(scheme))
        .foregroundStyle(Theme.text(scheme))
        // Panes get the same models on a language switch, so SwiftUI would skip them; a new identity redraws every string.
        .id(lang.revision)
        .onAppear { Task { await model.loadVoice(); await model.loadBilling() } }
    }
}

private struct AccountPane: View {
    @ObservedObject var model: OnboardingModel
    var onSignOut: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(L("settings.account"), L("settings.account.body"))
            if let user = model.auth.user {
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 30)).foregroundStyle(Theme.muted(scheme))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: user.name ?? "—").font(Theme.display(16))
                            Text(verbatim: user.email).font(Theme.text(13)).foregroundStyle(Theme.muted(scheme))
                        }
                        Spacer()
                        Button(L("menu.signOut"), action: onSignOut).buttonStyle(GhostButton())
                    }
                }
                .frame(maxWidth: 520)
                SubscriptionCard(model: model)
                    .frame(maxWidth: 520)
                if !model.isGuest {
                    Text(verbatim: L("settings.connections").uppercased()).font(Theme.label(10.5)).foregroundStyle(Theme.muted(scheme)).padding(.top, 6)
                    VStack(spacing: 10) {
                        ConnectRow(symbol: "envelope.fill", title: L("ob.connect.gmail"), status: model.connections["gmail"] ?? "not_connected", disconnect: { model.disconnect("gmail") }, disconnecting: model.disconnecting.contains("gmail")) { model.connect("gmail") }
                        ConnectRow(symbol: "number", title: L("ob.connect.slack"), status: model.connections["slack"] ?? "not_connected", disconnect: { model.disconnect("slack") }, disconnecting: model.disconnecting.contains("slack")) { model.connect("slack") }
                    }
                    .frame(maxWidth: 520)
                    if let error = model.connectionError { Text(verbatim: error).font(Theme.text(12)).foregroundStyle(.red) }
                }
            } else {
                Card(highlighted: true) {
                    HStack(spacing: 12) {
                        Image(systemName: "laptopcomputer").font(.system(size: 24)).foregroundStyle(Theme.approval)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: L("settings.account.localTitle")).font(Theme.display(16))
                            Text(verbatim: L("settings.account.localBody")).font(Theme.text(12.5)).foregroundStyle(Theme.muted(scheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Chip(text: L("ob.welcome.local.badge"), ok: true)
                    }
                }
                .frame(maxWidth: 520)
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: L("ob.welcome.pro.title")).font(Theme.display(16))
                            Text(verbatim: L("ob.welcome.pro.badge").uppercased()).font(Theme.label(10)).foregroundStyle(Theme.muted(scheme))
                        }
                        Text(verbatim: L("ob.welcome.pro.body"))
                            .font(Theme.text(12.5)).foregroundStyle(Theme.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
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
                .frame(maxWidth: 520)
            }
            UpcomingProSection()
                .frame(maxWidth: 520)
            ProductUpdatesCard(source: .settingsAccount)
                .frame(maxWidth: 520)
        }
    }
}

/// Visible to Free and Pro users alike; never links to an unfinished 503 endpoint.
private struct UpcomingProSection: View {
    @State private var notifyWatch = Prefs.notifyAppleWatch
    @State private var notifyMCP = Prefs.notifyPersonalMCP
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: L("settings.upcoming.section").uppercased())
                .font(Theme.label(10.5))
                .foregroundStyle(Theme.muted(scheme))
                .padding(.top, 6)
            upcomingCard(symbol: "applewatch",
                         title: L("settings.upcoming.watch.title"),
                         detail: L("settings.upcoming.watch.body"),
                         notify: $notifyWatch) { Prefs.notifyAppleWatch = $0 }
            upcomingCard(symbol: "point.3.connected.trianglepath.dotted",
                         title: L("settings.upcoming.mcp.title"),
                         detail: L("settings.upcoming.mcp.body"),
                         notify: $notifyMCP) { Prefs.notifyPersonalMCP = $0 }
        }
    }

    private func upcomingCard(symbol: String, title: String, detail: String, notify: Binding<Bool>, onSave: @escaping (Bool) -> Void) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).frame(width: 28, height: 28)
                        .background(Theme.well(scheme), in: RoundedRectangle(cornerRadius: 7))
                    Text(verbatim: title).font(Theme.display(15))
                    ModeBadge(kind: .proComingSoon)
                    Spacer(minLength: 4)
                }
                Text(verbatim: detail)
                    .font(Theme.text(12.5)).foregroundStyle(Theme.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: notify) {
                    Text(verbatim: L("settings.upcoming.notify")).font(Theme.text(12, medium: true))
                }
                .toggleStyle(.checkbox)
                .onChange(of: notify.wrappedValue) { _, on in onSave(on) }
                if notify.wrappedValue {
                    Text(verbatim: L("settings.upcoming.notified"))
                        .font(Theme.text(11)).foregroundStyle(Theme.approval)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct SubscriptionCard: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFallback = ISO8601DateFormatter()

    private func formattedDate(_ iso: String?) -> String? {
        guard let iso else { return nil }
        guard let date = Self.isoFormatter.date(from: iso) ?? Self.isoFallback.date(from: iso) else { return nil }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        df.locale = Locale(identifier: UILanguage.isKorean ? "ko_KR" : "en_US")
        return df.string(from: date)
    }

    var body: some View {
        let billing = model.billing
        let status = billing?.status ?? "none"
        let isPro = status == "active" || status == "trialing"
        let isTeam = billing?.plan == "team"
        let isPastDue = status == "past_due" || status == "unpaid"
        let price = billing?.price_usd_monthly ?? 19

        Card(highlighted: isPro) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Text(verbatim: L("billing.sectionTitle")).font(Theme.label(10.5)).foregroundStyle(Theme.muted(scheme))
                    Spacer()
                    if isPro {
                        Chip(text: L("billing.badge.pro"), ok: true)
                    } else if isTeam {
                        Chip(text: L("billing.badge.team"), ok: true)
                    } else if isPastDue {
                        Chip(text: L("billing.badge.pastDue"), ok: false)
                    } else {
                        Chip(text: L("billing.badge.free"), ok: false)
                    }
                }

                if isPro {
                    Text(verbatim: L("billing.pro.activeTitle", "\(price)")).font(Theme.display(16))
                    if let periodText = formattedDate(billing?.current_period_end) {
                        Text(verbatim: billing?.cancel_at_period_end == true
                             ? L("billing.pro.cancelsOn", periodText)
                             : L("billing.pro.renewsOn", periodText))
                            .font(Theme.text(12.5)).foregroundStyle(Theme.muted(scheme))
                    } else {
                        Text(verbatim: L("billing.pro.activeBody")).font(Theme.text(12.5)).foregroundStyle(Theme.muted(scheme))
                    }
                    HStack(spacing: 10) {
                        if billing?.has_customer == true {
                            Button(L("billing.manage")) { model.manageSubscription() }
                                .buttonStyle(GhostButton())
                                .disabled(model.billingActionPending)
                        }
                        Button(L("billing.refresh")) { Task { await model.loadBilling() } }
                            .buttonStyle(.link).font(Theme.text(12))
                            .disabled(model.loadingBilling)
                    }
                } else if isTeam {
                    Text(verbatim: L("billing.team.title")).font(Theme.display(16))
                    Text(verbatim: L("billing.team.body")).font(Theme.text(12.5)).foregroundStyle(Theme.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(verbatim: isPastDue ? L("billing.pastDue.title") : L("billing.upgrade.title", "\(price)"))
                        .font(Theme.display(16))
                    Text(verbatim: isPastDue ? L("billing.pastDue.body") : L("billing.upgrade.body"))
                        .font(Theme.text(12.5)).foregroundStyle(isPastDue ? .red : Theme.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        if isPastDue && billing?.has_customer == true {
                            Button(L("billing.updatePayment")) { model.manageSubscription() }
                                .buttonStyle(PrimaryButton())
                                .disabled(model.billingActionPending)
                        } else {
                            Button(L("billing.upgradeButton", "\(price)")) { model.upgradeToPro() }
                                .buttonStyle(PrimaryButton())
                                .disabled(model.billingActionPending)
                        }
                        if billing?.has_customer == true && !isPastDue {
                            Button(L("billing.manage")) { model.manageSubscription() }
                                .buttonStyle(GhostButton())
                                .disabled(model.billingActionPending)
                        }
                        Button(L("billing.refresh")) { Task { await model.loadBilling() } }
                            .buttonStyle(.link).font(Theme.text(12))
                            .disabled(model.loadingBilling)
                    }
                    Text(verbatim: L("billing.freeLocalReadyNote"))
                        .font(Theme.text(11.5)).foregroundStyle(Theme.approval)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = model.billingError {
                    Text(verbatim: error).font(Theme.text(12)).foregroundStyle(.red)
                }
            }
        }
    }
}

private struct VoicePane: View {
    @ObservedObject var model: OnboardingModel
    var onOpenAccount: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                ModeBadge(kind: .proCloudOnly)
                StepHeader(L("ob.voice.title"), L("ob.voice.body"))
            }
            if model.isLocalOnly {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: L("settings.proFeature.voiceTitle")).font(Theme.display(16))
                        Text(verbatim: L("settings.proFeature.voiceBody"))
                            .font(Theme.text(13)).foregroundStyle(Theme.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L("settings.proFeature.openAccount"), action: onOpenAccount).buttonStyle(GhostButton())
                    }
                }
                .frame(maxWidth: 520)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    CardEditor(model: model, lang: "ko", title: L("ob.voice.ko"))
                    CardEditor(model: model, lang: "en", title: L("ob.voice.en"))
                }
                if let error = model.voiceError { Text(verbatim: error).font(Theme.text(12)).foregroundStyle(.red) }
                HStack(spacing: 12) {
                    if !model.isGuest {
                        Button(model.buildingVoice ? L("ob.voice.building") : L("vocab.refresh")) { model.buildVoice() }
                            .buttonStyle(GhostButton()).disabled(model.buildingVoice)
                    }
                    if let s = model.voiceStats {
                        Text(verbatim: L("ob.voice.stats", "\(s.gmail_messages)", "\(s.slack_messages)")).font(Theme.label(10.5))
                    }
                }
            }
        }
    }
}

/// Consistent full-width macOS settings toggle row with flush-right switch alignment and optional mode badge.
struct SettingsToggleRow: View {
    let title: String
    var detail: String? = nil
    var badge: ModeBadge.Kind? = nil
    @Binding var isOn: Bool
    var onChange: ((Bool) -> Void)? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Text(verbatim: title)
                        .font(Theme.text(13.5, medium: true))
                        .fixedSize(horizontal: false, vertical: true)
                    if let badge { ModeBadge(kind: badge) }
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel(title)
                    .onChange(of: isOn) { _, on in onChange?(on) }
            }
            if let detail {
                Text(verbatim: detail)
                    .font(Theme.text(11.5))
                    .foregroundStyle(Theme.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct GeneralPane: View {
    @ObservedObject var model: OnboardingModel
    var onSoundsChange: (Bool) -> Void
    var onRecentContextChange: (Bool) -> Void
    var onScreenContextChange: (Bool) -> Void
    var onLocalDictationChange: (Bool) -> Void
    var localModelReady: Bool
    var onOpenMeetings: () -> Void
    var onClipboardChange: (Bool) -> Void
    @State private var keepOnClipboard = Prefs.keepTranscriptOnClipboard
    @State private var sounds = Prefs.soundsEnabled
    @State private var recentContext = Prefs.useRecentContext
    @State private var screenContext = Prefs.useScreenContext
    @State private var openAtLogin = Prefs.openAtLogin
    @State private var language = UILanguage.choice
    @Environment(\.colorScheme) private var scheme

    private var inLocalMode: Bool { model.effectiveLocalDictation }
    private var modelReady: Bool { localModelReady || model.localModelReady }
    private var price: Int { model.billing?.price_usd_monthly ?? 19 }

    private var versionFooter: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? "\(AppIdentity.name) \(short)" : "\(AppIdentity.name) \(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(L("settings.general"), L("settings.general.body"))

            // 1. Dictation mode (top-level obvious switcher: Free Local <-> Pro Cloud)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(verbatim: L("settings.general.sectionMode").uppercased())
                        .font(Theme.label(10.5)).foregroundStyle(Theme.muted(scheme))
                    Chip(text: inLocalMode ? L("mode.status.freeLocal") : L("mode.status.proCloud"), ok: inLocalMode || model.isProEntitled)
                }
                Card(highlighted: !model.isProEntitled) {
                    VStack(alignment: .leading, spacing: 11) {
                        HStack(spacing: 0) {
                            modeSegment(title: L("mode.picker.local"), selected: inLocalMode) {
                                model.switchToFreeLocalMode()
                                onLocalDictationChange(true)
                            }
                            modeSegment(title: L("mode.picker.pro"), selected: !inLocalMode, locked: !model.isProEntitled) {
                                if model.isProEntitled {
                                    model.switchToCloudProMode()
                                    onLocalDictationChange(false)
                                } else {
                                    model.startProUpgradeFlow()
                                }
                            }
                        }
                        .padding(3)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well(scheme)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.rule(scheme), lineWidth: 1))

                        Text(verbatim: !model.isProEntitled
                             ? L("mode.general.freeLocalNote")
                             : (inLocalMode ? L("mode.general.proLocalNote") : L("mode.general.proCloudNote")))
                            .font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)

                        if !model.isProEntitled {
                            HStack(alignment: .center, spacing: 10) {
                                Button(L("billing.upgradeButton", "\(price)")) {
                                    model.startProUpgradeFlow()
                                }
                                .buttonStyle(PrimaryButton())
                                .disabled(model.billingActionPending || model.auth.signingIn)
                                if model.auth.user == nil {
                                    Text(verbatim: L("keys.locked.signInNote"))
                                        .font(Theme.text(11.5)).foregroundStyle(Theme.muted(scheme))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            if let error = model.billingError ?? model.signInError {
                                Text(verbatim: error).font(Theme.text(11.5)).foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if inLocalMode {
                            Rectangle().fill(Theme.rule(scheme)).frame(height: 1)
                            if modelReady {
                                Label {
                                    Text(verbatim: UILanguage.isKorean
                                         ? "로컬 음성 모델 준비됨 · Whisper large-v3-turbo"
                                         : "Local speech model ready · Whisper large-v3-turbo")
                                        .font(Theme.text(11.5, medium: true))
                                } icon: {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                                .foregroundStyle(Theme.approval)
                            } else if model.localModelDownloading {
                                VStack(alignment: .leading, spacing: 5) {
                                    ProgressView(value: min(1, max(0, model.localModelProgress)))
                                        .progressViewStyle(.linear)
                                    Text(verbatim: L("mode.general.downloadingModel", Int((model.localModelProgress * 100).rounded())))
                                        .font(Theme.text(11.5, medium: true)).foregroundStyle(Theme.muted(scheme))
                                }
                            } else {
                                HStack(spacing: 10) {
                                    Button(L("mode.general.downloadModel")) { model.downloadLocalModel() }
                                        .buttonStyle(GhostButton())
                                    Button(L("settings.localDictation.setup"), action: onOpenMeetings)
                                        .buttonStyle(.link).font(Theme.text(11.5))
                                }
                            }
                            if let error = model.localModelError {
                                Text(verbatim: error).font(Theme.text(11.5)).foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 540)

            // 2. App & Mac (works everywhere: Free Local & Pro)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(verbatim: L("settings.general.sectionApp").uppercased())
                        .font(Theme.label(10.5)).foregroundStyle(Theme.muted(scheme))
                    ModeBadge(kind: .freeAndPro)
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsToggleRow(title: L("settings.openAtLogin"), isOn: $openAtLogin) { on in
                            Prefs.openAtLogin = on
                            try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        }
                        SettingsToggleRow(title: L("settings.sounds"), isOn: $sounds) { on in
                            Prefs.soundsEnabled = on; onSoundsChange(on)
                        }
                        SettingsToggleRow(title: L("settings.keepOnClipboard"), isOn: $keepOnClipboard) { on in
                            Prefs.keepTranscriptOnClipboard = on; onClipboardChange(on)
                        }
                        Rectangle().fill(Theme.rule(scheme)).frame(height: 1).padding(.vertical, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(verbatim: L("settings.language.title")).font(Theme.text(13.5, medium: true))
                                Spacer()
                                Picker("", selection: $language) {
                                    Text(verbatim: L("menu.language.system")).tag("system")
                                    Text(verbatim: "한국어").tag("ko")
                                    Text(verbatim: "English").tag("en")
                                }
                                .labelsHidden().frame(width: 160)
                                .onChange(of: language) { _, v in UILanguage.choice = v }
                            }
                            Text(verbatim: L("settings.language.note"))
                                .font(Theme.text(11.5)).foregroundStyle(Theme.muted(scheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: 540)

            // 3. Dictation accuracy (mode-badged per option)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: L("settings.general.sectionAccuracy").uppercased())
                    .font(Theme.label(10.5)).foregroundStyle(Theme.muted(scheme))
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SettingsToggleRow(title: L("settings.screenContext"),
                                          detail: L("settings.screenContext.body"),
                                          badge: .freeAndPro,
                                          isOn: $screenContext) { on in
                            Prefs.useScreenContext = on; onScreenContextChange(on)
                        }
                        Rectangle().fill(Theme.rule(scheme)).frame(height: 1)
                        VStack(alignment: .leading, spacing: 5) {
                            SettingsToggleRow(title: L("settings.recentContext"),
                                              detail: L("settings.recentContext.body"),
                                              badge: .proCloudOnly,
                                              isOn: inLocalMode ? .constant(false) : $recentContext) { on in
                                guard !inLocalMode else { return }
                                Prefs.useRecentContext = on; onRecentContextChange(on)
                            }
                            .disabled(inLocalMode)
                            .opacity(inLocalMode ? 0.65 : 1)
                            if inLocalMode {
                                Text(verbatim: L("settings.recentContext.localDisabled"))
                                    .font(Theme.text(11.5, medium: true))
                                    .foregroundStyle(Theme.muted(scheme))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 540)

            // 4. Opt-in anonymous usage stats (default OFF)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: L("stats.sectionTitle").uppercased())
                    .font(Theme.label(10.5)).foregroundStyle(Theme.muted(scheme))
                AnonymousStatsCard(compact: false, localMode: model.effectiveLocalDictation)
            }
            .frame(maxWidth: 540)

            Text(verbatim: versionFooter)
                .font(Theme.label(10.5)).foregroundStyle(Theme.muted(scheme))
        }
    }

    private func modeSegment(title: String, selected: Bool, locked: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if locked {
                    Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold))
                }
                Text(verbatim: title).font(Theme.text(13, medium: true))
            }
            .frame(maxWidth: .infinity).frame(height: 32)
            .foregroundStyle(selected ? Theme.onStructure(scheme) : Theme.text(scheme))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.structure(scheme) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
