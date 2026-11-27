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
        case account, keys, voice, words, meetings, general
        var id: String { rawValue }
        var titleKey: String { "settings.\(rawValue)" }
        var symbol: String {
            switch self {
            case .account: return "person.crop.circle"
            case .keys: return "keyboard"
            case .voice: return "text.quote"
            case .words: return "character.book.closed"
            case .meetings: return "waveform.badge.mic"
            case .general: return "gearshape"
            }
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
                ForEach(Pane.allCases) { p in
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
                                   onOpenAccount: { navigation.pane = .account }).padding(32)
                } else {
                    ScrollView {
                        Group {
                            switch pane {
                            case .account: AccountPane(model: model, onSignOut: onSignOut)
                            case .keys: KeysStep(model: model)
                            case .voice: VoicePane(model: model, onOpenAccount: { navigation.pane = .account })
                            case .words: EmptyView()
                            case .meetings:
                                if let meetings { MeetingSettingsView(coordinator: meetings, isGuest: model.isGuest) }
                                else { Text("Meeting transcription stays on this Mac.") }
                            case .general: GeneralPane(isSignedIn: model.auth.isSignedIn,
                                                       onSoundsChange: model.engine.updateSoundsEnabled,
                                                       onRecentContextChange: model.engine.updateRecentContextEnabled,
                                                       onScreenContextChange: model.engine.updateScreenContextEnabled,
                                                       onLocalDictationChange: { on in
                                                           model.engine.updateLocalDictationEnabled(on)
                                                           onLocalDictationToggled?(on)
                                                       },
                                                       localModelReady: model.engine.localTranscriber?.isReady ?? (meetings?.modelReady ?? false),
                                                       onOpenMeetings: { navigation.pane = .meetings },
                                                       onOpenAccount: { navigation.pane = .account },
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
        .onAppear { Task { await model.loadVoice() } }
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
                Text(verbatim: L("settings.connections").uppercased()).font(Theme.label(10.5)).foregroundStyle(Theme.muted(scheme)).padding(.top, 6)
                if model.isGuest {
                    Text(verbatim: L("settings.guestNoConnections")).font(Theme.text(12.5)).foregroundStyle(Theme.muted(scheme)).frame(maxWidth: 520, alignment: .leading)
                } else {
                    VStack(spacing: 10) {
                        ConnectRow(symbol: "envelope.fill", title: L("ob.connect.gmail"), status: model.connections["gmail"] ?? "not_connected", disconnect: { model.disconnect("gmail") }, disconnecting: model.disconnecting.contains("gmail")) { model.connect("gmail") }
                        ConnectRow(symbol: "number", title: L("ob.connect.slack"), status: model.connections["slack"] ?? "not_connected", disconnect: { model.disconnect("slack") }, disconnecting: model.disconnecting.contains("slack")) { model.connect("slack") }
                    }
                    .frame(maxWidth: 520)
                }
                if let error = model.connectionError { Text(verbatim: error).font(Theme.text(12)).foregroundStyle(.red) }
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
        }
    }
}

private struct VoicePane: View {
    @ObservedObject var model: OnboardingModel
    var onOpenAccount: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(L("ob.voice.title"), L("ob.voice.body"))
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

/// Consistent full-width macOS settings toggle row with flush-right switch alignment.
struct SettingsToggleRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var onChange: ((Bool) -> Void)? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                Text(verbatim: title)
                    .font(Theme.text(13.5, medium: true))
                    .fixedSize(horizontal: false, vertical: true)
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
    var isSignedIn: Bool
    var onSoundsChange: (Bool) -> Void
    var onRecentContextChange: (Bool) -> Void
    var onScreenContextChange: (Bool) -> Void
    var onLocalDictationChange: (Bool) -> Void
    var localModelReady: Bool
    var onOpenMeetings: () -> Void
    var onOpenAccount: () -> Void
    var onClipboardChange: (Bool) -> Void
    @State private var keepOnClipboard = Prefs.keepTranscriptOnClipboard
    @State private var sounds = Prefs.soundsEnabled
    @State private var recentContext = Prefs.useRecentContext
    @State private var screenContext = Prefs.useScreenContext
    @State private var localDictation = Prefs.localDictationEnabled
    @State private var openAtLogin = Prefs.openAtLogin
    @State private var language = UILanguage.choice
    @Environment(\.colorScheme) private var scheme

    private var versionFooter: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? "\(AppIdentity.name) \(short)" : "\(AppIdentity.name) \(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(L("settings.general"), L("settings.general.body"))
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
                    SettingsToggleRow(title: L("settings.recentContext"), detail: L("settings.recentContext.body"), isOn: $recentContext) { on in
                        Prefs.useRecentContext = on; onRecentContextChange(on)
                    }
                    SettingsToggleRow(title: L("settings.screenContext"), detail: L("settings.screenContext.body"), isOn: $screenContext) { on in
                        Prefs.useScreenContext = on; onScreenContextChange(on)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        SettingsToggleRow(title: L("settings.localDictation"),
                                          detail: isSignedIn ? L("settings.localDictation.body") : L("settings.localDictation.signedOutBody"),
                                          isOn: isSignedIn ? $localDictation : .constant(true)) { on in
                            guard isSignedIn else { return }
                            Prefs.localDictationEnabled = on; onLocalDictationChange(on)
                        }
                        .disabled(!isSignedIn)
                        if !isSignedIn {
                            Button(L("settings.proFeature.openAccount"), action: onOpenAccount)
                                .buttonStyle(.link).font(Theme.text(11.5))
                        }
                        if !isSignedIn || localDictation {
                            if localModelReady {
                                Label {
                                    Text(verbatim: UILanguage.isKorean
                                         ? "로컬 음성 모델 준비됨 · Whisper large-v3-turbo"
                                         : "Local speech model ready · Whisper large-v3-turbo")
                                        .font(Theme.text(11.5, medium: true))
                                } icon: {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                                .foregroundStyle(Theme.approval)
                            } else {
                                Button(L("settings.localDictation.setup"), action: onOpenMeetings)
                                    .buttonStyle(.link).font(Theme.text(11.5))
                            }
                        }
                    }
                    Rectangle().fill(Theme.rule(scheme)).frame(height: 1).padding(.vertical, 2)
                    HStack {
                        Text(verbatim: L("menu.language")).font(Theme.text(13.5, medium: true))
                        Spacer()
                        Picker("", selection: $language) {
                            Text(verbatim: L("menu.language.system")).tag("system")
                            Text(verbatim: "한국어").tag("ko")
                            Text(verbatim: "English").tag("en")
                        }
                        .labelsHidden().frame(width: 160)
                        .onChange(of: language) { _, v in UILanguage.choice = v }
                    }
                }
            }
            .frame(maxWidth: 520)
            Text(verbatim: versionFooter)
                .font(Theme.label(10.5)).foregroundStyle(Theme.muted(scheme))
        }
    }
}
