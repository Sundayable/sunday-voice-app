import SwiftUI
import DictationEngine

/// Key setup, shared by onboarding (step 4) and Settings › Keys.
/// One key per action on its card, a live check for the dictation key, the 🌐 Fn conflict fix,
/// and extra keys / mouse buttons tucked into an advanced section.
struct KeysStep: View {
    enum Context { case onboarding, settings }
    @ObservedObject var model: OnboardingModel
    var context: Context = .onboarding
    @State private var showAdvanced = false
    @Environment(\.colorScheme) private var scheme

    private var proLocked: Bool { model.proActionsLocked }
    private var proNoteOnly: Bool { !proLocked && model.effectiveLocalDictation }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(L(context == .onboarding ? "keys.title.onboarding" : "keys.title.settings"),
                       L(context == .onboarding ? "keys.body.onboarding" : "keys.body.settings"))
            if let conflict = model.fnConflict, let key = conflict.conflictKey {
                FnConflictBanner(text: L(key)) { model.fixFnKey() }
                    .padding(.bottom, 12)
            }
            VStack(spacing: 10) {
                ActionKeyCard(model: model, mode: .bilingual, showsTest: true, context: context)
                ActionKeyCard(model: model, mode: .english, locked: proLocked, proOnly: proNoteOnly, context: context)
                PolishKeyCard(model: model, locked: proLocked, proOnly: proNoteOnly)
                SendByVoiceCard(model: model, context: context)
            }
            KeyStatusLine(model: model).padding(.top, 10)
            AdvancedKeys(model: model, expanded: $showAdvanced).padding(.top, 14)
            RestoreDefaultsRow(model: model).padding(.top, 10)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .onAppear {
            model.refreshFnUsage()
            model.keyTestAuto = context == .onboarding
            if context == .onboarding { model.startKeyTest(rounds: 60) }
            if model.triggers.count > 2 || model.tidyKeys.count > 1 { showAdvanced = context == .settings }
        }
        .onDisappear { model.keyTestAuto = false; model.stopKeyTest(); model.cancelCapture(); model.dismissPendingMove(); model.confirmingReset = false }
        .task(id: model.usesFnKey) {
            // Ticks the conflict away the moment System Settings changes (no relaunch, no button).
            while model.usesFnKey && !Task.isCancelled {
                model.refreshFnUsage()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

/// "Hold [🌐 Fn]" — the verb is part of the chip, not tiny text beside it.
struct KeyChip: View {
    let verb: String
    let key: String
    var lit = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 7) {
            Text(verbatim: verb).font(Theme.text(12.5, medium: true)).foregroundStyle(Theme.muted(scheme))
            Keycap(label: key, lit: lit)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Mode availability badge shared across Keys, General, Voice, Words, Account, and Meetings.
struct ModeBadge: View {
    enum Kind { case freeAndPro, proCloudOnly, proOnly, proComingSoon }
    let kind: Kind
    @Environment(\.colorScheme) private var scheme

    private var text: String {
        switch kind {
        case .freeAndPro: return L("badge.freeAndPro")
        case .proCloudOnly: return L("badge.proCloudOnly")
        case .proOnly: return L("badge.proOnly")
        case .proComingSoon: return L("badge.proComingSoon")
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if kind == .proOnly {
                Image(systemName: "lock.fill").font(.system(size: 8.5, weight: .semibold))
            }
            Text(verbatim: text)
                .font(Theme.label(9.5))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .foregroundStyle(kind == .freeAndPro ? Theme.approval : (kind == .proOnly ? Theme.text(scheme) : Theme.muted(scheme)))
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(
            kind == .freeAndPro ? Theme.approval.opacity(0.45) : (kind == .proOnly ? Theme.structure(scheme).opacity(0.45) : Theme.rule(scheme)), lineWidth: 1))
    }
}

struct ProBadge: View {
    var body: some View { ModeBadge(kind: .proCloudOnly) }
}

/// While a new key is being recorded: large dashed capture area + plain hint + Cancel.
struct CapturePrompt: View {
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Circle().fill(Theme.approval).frame(width: 8, height: 8)
                Text(verbatim: L("keys.capture.prompt"))
                    .font(Theme.text(13.5, medium: true))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(L("keys.capture.cancel"), action: onCancel)
                    .buttonStyle(.link).font(Theme.text(12.5, medium: true))
            }
            Text(verbatim: L("keys.capture.subhint"))
                .font(Theme.text(11.5))
                .foregroundStyle(Theme.muted(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.well(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.structure(scheme), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
    }
}

/// Interactive "press what you want" box shown inside each action card when not actively capturing.
struct ShortcutCaptureBox: View {
    let verb: String
    let keyName: String?
    let locationHint: String?
    var lit = false
    var disabled = false
    let onStartCapture: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: onStartCapture) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    if let keyName {
                        KeyChip(verb: verb, key: keyName, lit: lit)
                        if let locationHint {
                            Text(verbatim: locationHint)
                                .font(Theme.text(11))
                                .foregroundStyle(Theme.muted(scheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(verbatim: L("keys.capture.boxIdle"))
                            .font(Theme.text(12.5, medium: true))
                            .foregroundStyle(Theme.muted(scheme))
                    }
                }
                Spacer(minLength: 8)
                Text(verbatim: L(keyName == nil ? "keys.add" : "keys.change"))
                    .font(Theme.text(12.5, medium: true))
                    .foregroundStyle(Theme.text(scheme))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel(scheme)))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.rule(scheme), lineWidth: 1))
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.well(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(lit ? Theme.approval : Theme.rule(scheme), lineWidth: lit ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityHint(L("keys.capture.boxIdle"))
    }
}

/// Name and mode badge on one line; what it does and an optional example underneath, full width.
private struct CardTitle: View {
    let name: String
    let detail: String
    let example: String?
    let badge: ModeBadge.Kind
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 8) {
                Text(verbatim: name).font(Theme.display(16))
                ModeBadge(kind: badge)
                Spacer(minLength: 8)
            }
            .padding(.bottom, 2)
            Text(verbatim: detail).font(Theme.text(12.5)).foregroundStyle(Theme.text(scheme).opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            if let example {
                Text(verbatim: example).font(Theme.text(11.5)).foregroundStyle(Theme.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Compact Ink primary button for inline Pro conversion CTAs inside cards.
private struct CompactPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let pill = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return configuration.label.font(Theme.display(13, semibold: true))
            .padding(.horizontal, 14).frame(minHeight: 34)
            .foregroundStyle(Theme.onStructure(scheme))
            .background(pill.fill(Theme.structure(scheme)))
            .overlay(pill.strokeBorder(Theme.structure(scheme), lineWidth: 1.5))
            .background(pill.fill(Theme.structure(scheme).opacity(0.2)).offset(x: pressed ? 1 : 2, y: pressed ? 1 : 2))
            .offset(x: pressed ? 1 : 0, y: pressed ? 1 : 0)
            .padding(.trailing, 2).padding(.bottom, 2)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(pill)
    }
}

/// Small before/after conversion preview inside locked Pro shortcut cards.
private struct ConversionPreviewBox: View {
    let input: String
    let output: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: L("keys.locked.previewLabel").uppercased())
                .font(Theme.label(9.5))
                .foregroundStyle(Theme.muted(scheme))
            Text(verbatim: input)
                .font(Theme.text(11.5))
                .foregroundStyle(Theme.muted(scheme))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.approval)
                Text(verbatim: output)
                    .font(Theme.text(12.5, medium: true))
                    .foregroundStyle(Theme.text(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.rule(scheme), lineWidth: 1))
    }
}

/// Non-interactive, disabled shortcut preview for locked Pro actions (never triggers key capture).
private struct LockedShortcutBox: View {
    let verb: String
    let keyName: String?
    let locationHint: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted(scheme))
                VStack(alignment: .leading, spacing: 2) {
                    if let keyName {
                        KeyChip(verb: verb, key: keyName)
                            .opacity(0.62)
                        if let locationHint {
                            Text(verbatim: locationHint)
                                .font(Theme.text(11))
                                .foregroundStyle(Theme.muted(scheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(verbatim: L("keys.locked.noKey"))
                            .font(Theme.text(12, medium: true))
                            .foregroundStyle(Theme.muted(scheme))
                    }
                }
                Spacer(minLength: 8)
                if keyName != nil {
                    Text(verbatim: L("keys.locked.inactiveTag"))
                        .font(Theme.label(9.5))
                        .foregroundStyle(Theme.muted(scheme))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.panel(scheme)))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.rule(scheme), lineWidth: 1))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well(scheme).opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.rule(scheme), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)

            if keyName != nil {
                Text(verbatim: L("keys.locked.storedInactive"))
                    .font(Theme.text(11.5))
                    .foregroundStyle(Theme.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Shared body for locked Pro-only shortcut cards: result preview, disabled shortcut display, and upgrade CTA.
private struct LockedProActionBody: View {
    @ObservedObject var model: OnboardingModel
    let verb: String
    let keyName: String?
    let locationHint: String?
    let previewInput: String
    let previewOutput: String
    @Environment(\.colorScheme) private var scheme

    private var price: Int { model.billing?.price_usd_monthly ?? 19 }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ConversionPreviewBox(input: previewInput, output: previewOutput)
            LockedShortcutBox(verb: verb, keyName: keyName, locationHint: locationHint)
            HStack(alignment: .center, spacing: 10) {
                Button(L("billing.upgradeButton", "\(price)")) {
                    model.startProUpgradeFlow()
                }
                .buttonStyle(CompactPrimaryButton())
                .disabled(model.billingActionPending || model.auth.signingIn)
                if model.auth.user == nil {
                    Text(verbatim: L("keys.locked.signInNote"))
                        .font(Theme.text(11.5))
                        .foregroundStyle(Theme.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if model.auth.signingIn && model.pendingProUpgradeAfterSignIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: L("ob.welcome.signingIn")).font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
                    Button(L("menu.cancel")) {
                        model.pendingProUpgradeAfterSignIn = false
                        model.auth.cancelSignIn()
                    }
                    .buttonStyle(.link).font(Theme.text(12))
                }
            }
            if let error = model.billingError ?? model.signInError {
                Text(verbatim: error).font(Theme.text(11.5)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ActionKeyCard: View {
    @ObservedObject var model: OnboardingModel
    let mode: DictationMode
    var locked = false
    var proOnly = false
    var showsTest = false
    var context: KeysStep.Context = .onboarding
    @Environment(\.colorScheme) private var scheme

    private var names: (String, String, String) {
        mode == .bilingual
            ? (L("mode.dictate.name"), L("mode.dictate.detail"), L("mode.dictate.example"))
            : (L("mode.english.name"), L("mode.english.detail"), L("mode.english.example"))
    }
    private var primary: TriggerKind? { model.primaryTrigger(for: mode) }
    private var capturingHere: Bool { !locked && model.capturingMode == mode && (model.capturingReplacement != nil || primary == nil) }

    var body: some View {
        Card(highlighted: showsTest && context == .onboarding) {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(name: names.0, detail: names.1, example: locked ? nil : names.2,
                          badge: mode == .bilingual ? .freeAndPro : (locked ? .proOnly : .proCloudOnly))
                if locked {
                    LockedProActionBody(
                        model: model,
                        verb: primary.map { L(OnboardingModel.verbKey($0)) } ?? L("keys.hold"),
                        keyName: primary.map(OnboardingModel.describe),
                        locationHint: primary.flatMap(OnboardingModel.locationHint),
                        previewInput: L("keys.locked.english.input"),
                        previewOutput: L("keys.locked.english.output")
                    )
                } else {
                    if capturingHere {
                        CapturePrompt { model.cancelCapture() }
                    } else {
                        ShortcutCaptureBox(
                            verb: primary.map { L(OnboardingModel.verbKey($0)) } ?? L("keys.hold"),
                            keyName: primary.map(OnboardingModel.describe),
                            locationHint: primary.flatMap(OnboardingModel.locationHint),
                            lit: showsTest && model.keyTest.ok,
                            disabled: model.capturing,
                            onStartCapture: { model.captureKey(for: mode, replacing: primary) }
                        )
                    }
                    if proOnly {
                        Text(verbatim: L("keys.pro.note")).font(Theme.text(11.5)).foregroundStyle(Theme.muted(scheme))
                    }
                    AutoEnterOptionRow(model: model, mode: mode)
                    if showsTest && !capturingHere { KeyTestRow(model: model, context: context) }
                }
            }
        }
    }
}

/// Per-action optional "Press Enter after pasting" toggle (default OFF), with safe chat-app scope
/// and explicit warning that email/document apps are automatically blocked.
struct AutoEnterOptionRow: View {
    @ObservedObject var model: OnboardingModel
    let mode: DictationMode
    @Environment(\.colorScheme) private var scheme

    private var isOn: Binding<Bool> {
        Binding(
            get: { model.autoEnterEnabled(for: mode) },
            set: { model.setAutoEnter($0, for: mode) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: isOn) {
                Text(verbatim: L("keys.autoEnter.toggle"))
                    .font(Theme.text(12.5, medium: true))
            }
            .toggleStyle(.checkbox)
            if model.autoEnterEnabled(for: mode) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: L("keys.autoEnter.chatOnlyHint"))
                        .font(Theme.text(11.5))
                        .foregroundStyle(Theme.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.top, 2)
                        Text(verbatim: L("keys.autoEnter.emailDocsWarning"))
                            .font(Theme.text(11.5))
                            .foregroundStyle(Theme.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.top, 2)
    }
}

/// The live check under the dictation card.
struct KeyTestRow: View {
    @ObservedObject var model: OnboardingModel
    let context: KeysStep.Context
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let test = model.keyTest
        let hasContent = test.ok || test.other != nil || test.listening || test.missedFn || context == .settings
        VStack(alignment: .leading, spacing: 8) {
            if hasContent { Rectangle().fill(Theme.rule(scheme)).frame(height: 1) }
            if test.ok {
                Label { Text(verbatim: L("keys.test.ok")).font(Theme.text(12.5, medium: true)) } icon: { Image(systemName: "checkmark.circle.fill") }
                    .foregroundStyle(Theme.approval)
            } else if let other = test.other {
                HStack(spacing: 10) {
                    Text(verbatim: L("keys.test.other", OnboardingModel.describe(other))).font(Theme.text(12.5, medium: true))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button(L("keys.test.useOther", OnboardingModel.describe(other))) { model.useTestedKey() }.buttonStyle(GhostButton())
                }
            } else if test.listening {
                HStack(spacing: 8) {
                    Circle().fill(Theme.approval).frame(width: 7, height: 7).opacity(0.85)
                    Text(verbatim: L("keys.test.prompt")).font(Theme.text(12.5, medium: true))
                }
            } else if context == .settings {
                Button(L("keys.test.start")) { model.startKeyTest() }.buttonStyle(.link).font(Theme.text(12.5, medium: true))
            }
            if test.missedFn && !test.ok {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: L("keys.noFn.title")).font(Theme.text(12.5, medium: true))
                    Text(verbatim: L("keys.noFn.body")).font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("keys.noFn.button")) { model.useRightOption() }.buttonStyle(GhostButton())
                }
                .padding(.top, 2)
            }
        }
    }
}

struct PolishKeyCard: View {
    @ObservedObject var model: OnboardingModel
    var locked = false
    var proOnly = false
    @Environment(\.colorScheme) private var scheme
    private var capturingHere: Bool { !locked && model.capturingTidy && model.tidyCaptureReplacesPrimary }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(name: L("mode.polish.name"), detail: L("mode.polish.detail"), example: locked ? nil : L("mode.polish.example"),
                          badge: locked ? .proOnly : .proCloudOnly)
                if locked {
                    LockedProActionBody(
                        model: model,
                        verb: L("keys.press"),
                        keyName: model.primaryTidyKey.map { OnboardingModel.describe($0.trigger) },
                        locationHint: model.primaryTidyKey.flatMap { OnboardingModel.locationHint($0.trigger) },
                        previewInput: L("keys.locked.polish.input"),
                        previewOutput: L("keys.locked.polish.output")
                    )
                } else {
                    if capturingHere {
                        CapturePrompt { model.cancelCapture() }
                    } else {
                        ShortcutCaptureBox(
                            verb: L("keys.press"),
                            keyName: model.primaryTidyKey.map { OnboardingModel.describe($0.trigger) },
                            locationHint: model.primaryTidyKey.flatMap { OnboardingModel.locationHint($0.trigger) },
                            disabled: model.capturing,
                            onStartCapture: {
                                model.tidyCaptureReplacesPrimary = true
                                model.captureTidyKey(replacing: model.primaryTidyKey)
                            }
                        )
                    }
                    if proOnly {
                        Text(verbatim: L("keys.pro.note")).font(Theme.text(11.5)).foregroundStyle(Theme.muted(scheme))
                    }
                }
            }
        }
    }
}

/// Spoken "Send by voice" card (default ON, works in Free Local Mode and Pro).
/// Strips exact final command phrase ("입력완료", "엔터", "보내기", "send it", "press enter", "enter"),
/// pastes, and presses Return once in allowed chat apps.
struct SendByVoiceCard: View {
    @ObservedObject var model: OnboardingModel
    let context: KeysStep.Context
    @Environment(\.colorScheme) private var scheme

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { model.sendByVoiceEnabled },
            set: { model.setSendByVoiceEnabled($0) }
        )
    }

    private var phrasesBinding: Binding<String> {
        Binding(
            get: { model.sendByVoicePhrasesText },
            set: { model.setSendByVoicePhrasesText($0) }
        )
    }

    private var allAppsBinding: Binding<Bool> {
        Binding(
            get: { model.sendByVoiceAllApps },
            set: { model.setSendByVoiceAllApps($0) }
        )
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(
                    name: L("keys.sendByVoice.title"),
                    detail: L("keys.sendByVoice.body"),
                    example: L("keys.sendByVoice.example"),
                    badge: .freeAndPro
                )
                Toggle(isOn: enabledBinding) {
                    Text(verbatim: L("keys.sendByVoice.toggle"))
                        .font(Theme.text(13, medium: true))
                }
                .toggleStyle(.checkbox)

                if model.sendByVoiceEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        if context == .settings {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(verbatim: L("keys.sendByVoice.phrasesLabel"))
                                        .font(Theme.text(11.5, medium: true))
                                        .foregroundStyle(Theme.muted(scheme))
                                    Spacer()
                                    if model.sendByVoicePhrasesText != EndPhrase.defaultSendPhrasesText {
                                        Button(L("keys.sendByVoice.reset")) {
                                            model.resetSendByVoicePhrases()
                                        }
                                        .buttonStyle(.link)
                                        .font(Theme.text(11.5))
                                    }
                                }
                                TextField(EndPhrase.defaultSendPhrasesText, text: phrasesBinding)
                                    .textFieldStyle(.roundedBorder)
                                    .font(Theme.text(12))
                            }
                            Toggle(isOn: allAppsBinding) {
                                Text(verbatim: L("keys.sendByVoice.allowOtherApps"))
                                    .font(Theme.text(12))
                            }
                            .toggleStyle(.checkbox)
                        }
                        Text(verbatim: L("keys.autoEnter.chatOnlyHint"))
                            .font(Theme.text(11.5))
                            .foregroundStyle(Theme.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.orange)
                                .padding(.top, 2)
                            Text(verbatim: L("keys.sendByVoice.emailDocsWarning"))
                                .font(Theme.text(11.5))
                                .foregroundStyle(Theme.muted(scheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.leading, 20)
                }
            }
        }
    }
}

/// Errors, "Saved", and the move-it question, right under the cards.
struct KeyStatusLine: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if let move = model.pendingMove {
            HStack(spacing: 10) {
                Label { Text(verbatim: L("keys.conflict.move", OnboardingModel.describe(move.trigger), L(move.from.nameKey)))
                    .font(Theme.text(12.5, medium: true)).fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "arrow.left.arrow.right.circle") }
                Spacer(minLength: 6)
                Button(L("keys.conflict.moveButton")) { model.confirmPendingMove() }.buttonStyle(GhostButton())
                Button(L("keys.cancel")) { model.dismissPendingMove() }.buttonStyle(.link).font(Theme.text(12.5))
            }
        } else if let message = model.keyMessage {
            Label { Text(verbatim: message).font(Theme.text(12.5, medium: true)).fixedSize(horizontal: false, vertical: true) }
                icon: { Image(systemName: "exclamationmark.circle") }
                .foregroundStyle(Theme.text(scheme))
        } else if let confirmation = model.capturedConfirmation {
            Label { Text(verbatim: confirmation).font(Theme.text(12.5, medium: true)).fixedSize(horizontal: false, vertical: true) }
                icon: { Image(systemName: "checkmark.circle.fill") }
                .foregroundStyle(Theme.approval)
        } else if let captured = model.captured {
            Label { Text(verbatim: L("keys.capture.saved", captured)).font(Theme.text(12.5, medium: true)) }
                icon: { Image(systemName: "checkmark.circle.fill") }
                .foregroundStyle(Theme.approval)
        }
    }
}

/// 🌐 Fn conflict with macOS "Press 🌐 key to": detected, explained, one button to the guided fix.
struct FnConflictBanner: View {
    let text: String
    let onFix: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "globe").font(.system(size: 18, weight: .medium))
            Text(verbatim: text).font(Theme.text(12.5, medium: true)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button(L("keys.fn.fix"), action: onFix).buttonStyle(PrimaryButton())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.well(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.structure(scheme), lineWidth: 1.5))
    }
}

/// Extra keys and mouse side buttons per action. Collapsed by default.
struct AdvancedKeys: View {
    @ObservedObject var model: OnboardingModel
    @Binding var expanded: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(verbatim: L("keys.advanced")).font(Theme.text(13, medium: true))
                    let extras = model.extraTriggers(for: .bilingual).count + model.extraTriggers(for: .english).count + model.extraTidyKeys.count
                    if extras > 0 && !expanded { Text(verbatim: "· \(extras)").font(Theme.text(12.5)).foregroundStyle(Theme.muted(scheme)) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: L("keys.advanced.body")).font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
                    extraRow(L("mode.dictate.name"), mode: .bilingual)
                    if model.proActionsLocked {
                        lockedExtraRow(L("mode.english.name"),
                                       chips: model.extraTriggers(for: .english).map { (L(OnboardingModel.verbKey($0)), OnboardingModel.describe($0)) })
                        lockedExtraRow(L("mode.polish.name"),
                                       chips: model.extraTidyKeys.map { (L("keys.press"), OnboardingModel.describe($0.trigger)) })
                        Text(verbatim: L("keys.advanced.proLockedNote"))
                            .font(Theme.text(11.5)).foregroundStyle(Theme.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        extraRow(L("mode.english.name"), mode: .english)
                        tidyRow
                    }
                }
                .padding(.leading, 16)
            }
        }
    }

    private func extraRow(_ title: String, mode: DictationMode) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(verbatim: title).font(Theme.text(12.5, medium: true)).frame(width: 150, alignment: .leading)
            FlowRow(spacing: 8) {
                ForEach(model.extraTriggers(for: mode), id: \.self) { t in
                    removable(KeyChip(verb: L(OnboardingModel.verbKey(t)), key: OnboardingModel.describe(t)), label: OnboardingModel.describe(t)) { model.removeTrigger(t) }
                }
                if model.capturingMode == mode && model.capturingReplacement == nil && model.primaryTrigger(for: mode) != nil {
                    CapturePrompt { model.cancelCapture() }
                } else {
                    addButton { model.captureKey(for: mode) }
                }
            }
        }
    }

    private var tidyRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(verbatim: L("mode.polish.name")).font(Theme.text(12.5, medium: true)).frame(width: 150, alignment: .leading)
            FlowRow(spacing: 8) {
                ForEach(model.extraTidyKeys, id: \.self) { key in
                    removable(KeyChip(verb: L("keys.press"), key: OnboardingModel.describe(key.trigger)), label: OnboardingModel.describe(key.trigger)) { model.removeTidyKey(key) }
                }
                if model.capturingTidy && !model.tidyCaptureReplacesPrimary {
                    CapturePrompt { model.cancelCapture() }
                } else {
                    addButton { model.tidyCaptureReplacesPrimary = false; model.captureTidyKey() }
                }
            }
        }
    }

    private func lockedExtraRow(_ title: String, chips: [(String, String)]) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(verbatim: title).font(Theme.text(12.5, medium: true)).foregroundStyle(Theme.muted(scheme)).frame(width: 150, alignment: .leading)
            FlowRow(spacing: 8) {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, item in
                    KeyChip(verb: item.0, key: item.1).opacity(0.6)
                }
                ModeBadge(kind: .proOnly)
            }
        }
        .allowsHitTesting(false)
    }

    private func removable<V: View>(_ chip: V, label: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            chip
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.borderless).foregroundStyle(Theme.muted(scheme))
                .accessibilityLabel("\(L("keys.remove")) \(label)").help(L("keys.remove"))
        }
    }

    private func addButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: L("keys.add")).font(Theme.text(12.5, medium: true))
                .padding(.horizontal, 12).frame(height: 30)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.rule(scheme), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
        }
        .buttonStyle(.plain).disabled(model.capturing)
    }
}

/// "Restore defaults" asks first and says what changes.
struct RestoreDefaultsRow: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if model.confirmingReset {
            HStack(spacing: 10) {
                Text(verbatim: L("keys.restore.confirm")).font(Theme.text(12.5)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button(L("keys.restore.confirmButton")) { model.resetTriggers() }.buttonStyle(GhostButton())
                Button(L("keys.cancel")) { model.confirmingReset = false }.buttonStyle(.link).font(Theme.text(12.5))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.well(scheme)))
        } else {
            Button(L("keys.restore")) { model.cancelCapture(); model.confirmingReset = true }
                .buttonStyle(.link).font(Theme.text(12.5))
        }
    }
}
