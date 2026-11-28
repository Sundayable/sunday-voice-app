import AppKit
import SwiftUI
import DictationEngine

/// Settings › "음성으로 시작·전송 / Hands-free" (macOS 15+ Apple Silicon only; hidden on macOS 14 and Intel).
/// Guides users through Apple's built-in Vocal Shortcuts to start dictation at the current cursor
/// using the public `Start Dictation` App Intent or `<scheme>://wake/cursor` URL action, paired with
/// Sunday Voice's spoken "Send by voice" end phrases. No personal targets, no Pro lock.
struct HandsFreePane: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var bridge = HandsFreeCursorBridge.shared
    var onOpenKeys: (() -> Void)? = nil

    @State private var copiedPhrase: String?
    @State private var copiedURL = false
    @Environment(\.colorScheme) private var scheme

    private var openVocalShortcuts: () -> Void = {
        NSWorkspace.shared.open(SettingsLink.vocalShortcuts())
    }

    init(model: OnboardingModel, onOpenKeys: (() -> Void)? = nil, openVocalShortcuts: (() -> Void)? = nil) {
        self.model = model
        self.onOpenKeys = onOpenKeys
        if let openVocalShortcuts { self.openVocalShortcuts = openVocalShortcuts }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: L("handsfree.title")).font(Theme.display(26))
                ModeBadge(kind: .freeAndPro)
                Spacer(minLength: 8)
            }
            Text(verbatim: L("handsfree.subtitle"))
                .font(Theme.text(13.5)).foregroundStyle(Theme.muted(scheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)

            // Suggested phrases card ("Hey Sunday" / "헤이 선데이")
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: L("handsfree.phrases.title")).font(Theme.display(15.5))
                    Text(verbatim: L("handsfree.phrases.body"))
                        .font(Theme.text(12.5)).foregroundStyle(Theme.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        ForEach(HandsFreeSupport.suggestedPhrases, id: \.self) { phrase in
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(phrase, forType: .string)
                                copiedPhrase = phrase
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: copiedPhrase == phrase ? "checkmark.circle.fill" : "waveform")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(copiedPhrase == phrase ? Theme.approval : Theme.muted(scheme))
                                    Text(verbatim: phrase).font(Theme.text(13, medium: true))
                                }
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.well(scheme)))
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(
                                    copiedPhrase == phrase ? Theme.approval : Theme.rule(scheme), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                    if let copiedPhrase {
                        Text(verbatim: L("handsfree.phrases.copied", copiedPhrase))
                            .font(Theme.text(11.5, medium: true))
                            .foregroundStyle(Theme.approval)
                    }
                }
            }

            // Step-by-step setup guide with crisp visual macOS System Settings step illustrations
            Card(highlighted: true) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 10) {
                        Text(verbatim: L("handsfree.steps.title")).font(Theme.display(16))
                        Spacer()
                        Button(L("handsfree.openSettings")) {
                            openVocalShortcuts()
                        }
                        .buttonStyle(PrimaryButton())
                    }

                    HandsFreeStepRow(
                        number: "1",
                        title: L("handsfree.step1.title"),
                        bodyText: L("handsfree.step1.body"),
                        visual: .systemSettingsNav
                    )
                    Rectangle().fill(Theme.rule(scheme)).frame(height: 1)

                    HandsFreeStepRow(
                        number: "2",
                        title: L("handsfree.step2.title"),
                        bodyText: L("handsfree.step2.body"),
                        visual: .actionPicker
                    )

                    // Copyable public URL action fallback for Shortcuts.app users
                    HStack(spacing: 8) {
                        Text(verbatim: HandsFreeSupport.cursorWakeURLString)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.muted(scheme))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.well(scheme)))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.rule(scheme), lineWidth: 1))
                        Button(copiedURL ? L("handsfree.urlCopied") : L("handsfree.copyURL")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(HandsFreeSupport.cursorWakeURLString, forType: .string)
                            copiedURL = true
                        }
                        .buttonStyle(GhostButton())
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 30)

                    Rectangle().fill(Theme.rule(scheme)).frame(height: 1)

                    HandsFreeStepRow(
                        number: "3",
                        title: L("handsfree.step3.title"),
                        bodyText: L("handsfree.step3.body"),
                        visual: .phraseTraining
                    )
                    Rectangle().fill(Theme.rule(scheme)).frame(height: 1)

                    HandsFreeStepRow(
                        number: "4",
                        title: L("handsfree.step4.title"),
                        bodyText: L("handsfree.step4.body"),
                        visual: .sendByVoiceFlow
                    )
                }
            }

            // Live "Test it / 테스트하기" check card
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(verbatim: L("handsfree.test.title")).font(Theme.display(16))
                        Spacer()
                        if bridge.lastTriggeredAt != nil {
                            Chip(text: L("handsfree.test.received"), ok: true)
                        } else if bridge.isTestArmed {
                            Chip(text: L("handsfree.test.waiting"), ok: false)
                        }
                    }
                    Text(verbatim: L("handsfree.test.body"))
                        .font(Theme.text(12.5)).foregroundStyle(Theme.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)

                    TextEditor(text: $bridge.testTranscript)
                        .font(Theme.text(13))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(height: 82)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well(scheme)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(
                            bridge.lastTriggeredAt != nil ? Theme.approval : Theme.rule(scheme),
                            lineWidth: bridge.lastTriggeredAt != nil ? 1.5 : 1))
                        .overlay(alignment: .topLeading) {
                            if bridge.testTranscript.isEmpty {
                                Text(verbatim: L("handsfree.test.placeholder"))
                                    .font(Theme.text(12.5)).foregroundStyle(Theme.muted(scheme))
                                    .padding(.horizontal, 14).padding(.vertical, 12)
                                    .allowsHitTesting(false)
                            }
                        }

                    HStack(spacing: 10) {
                        Button(L("handsfree.test.button")) {
                            bridge.isTestArmed = true
                            bridge.trigger(source: "settings_test")
                        }
                        .buttonStyle(PrimaryButton())
                        if !bridge.testTranscript.isEmpty || bridge.lastTriggeredAt != nil {
                            Button(L("handsfree.test.clear")) {
                                bridge.resetTest()
                            }
                            .buttonStyle(GhostButton())
                        }
                        Spacer(minLength: 0)
                        if let onOpenKeys {
                            Button(L("handsfree.openSendByVoice")) {
                                onOpenKeys()
                            }
                            .buttonStyle(.link)
                            .font(Theme.text(12, medium: true))
                        }
                    }
                }
            }

            // Privacy & on-device reassurance note
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.approval)
                    .padding(.top, 1)
                Text(verbatim: L("handsfree.privacyNote"))
                    .font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .onAppear { bridge.isTestArmed = true }
        .onDisappear { bridge.isTestArmed = false }
    }
}

/// One numbered step with a compact crisp visual screenshot mockup of macOS Vocal Shortcuts.
private struct HandsFreeStepRow: View {
    enum Visual {
        case systemSettingsNav
        case actionPicker
        case phraseTraining
        case sendByVoiceFlow
    }

    let number: String
    let title: String
    let bodyText: String
    let visual: Visual
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: number)
                .font(Theme.label(11))
                .foregroundStyle(Theme.onStructure(scheme))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.structure(scheme)))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title).font(Theme.text(13.5, medium: true))
                    Text(verbatim: bodyText)
                        .font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                stepScreenshot
            }
        }
    }

    @ViewBuilder
    private var stepScreenshot: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Subtle macOS window chrome header
            HStack(spacing: 5) {
                Circle().fill(Color.primary.opacity(0.18)).frame(width: 6, height: 6)
                Circle().fill(Color.primary.opacity(0.18)).frame(width: 6, height: 6)
                Circle().fill(Color.primary.opacity(0.18)).frame(width: 6, height: 6)
                Spacer()
                Text(verbatim: windowCaption)
                    .font(Theme.label(9))
                    .foregroundStyle(Theme.muted(scheme))
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.panel(scheme))
            Rectangle().fill(Theme.rule(scheme)).frame(height: 1)

            Group {
                switch visual {
                case .systemSettingsNav:
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "accessibility")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.blue))
                            Text(verbatim: L("handsfree.visual.accessibility"))
                                .font(Theme.text(11.5, medium: true))
                        }
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted(scheme))
                        Text(verbatim: L("handsfree.visual.speech"))
                            .font(Theme.text(11.5)).foregroundStyle(Theme.muted(scheme))
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted(scheme))
                        Text(verbatim: L("handsfree.visual.vocalShortcuts"))
                            .font(Theme.text(11.5, medium: true))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.structure(scheme)))
                            .foregroundStyle(Theme.onStructure(scheme))
                        Spacer(minLength: 0)
                    }
                case .actionPicker:
                    HStack(spacing: 10) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.onStructure(scheme))
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.structure(scheme)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: "\(AppIdentity.name) · \(L("handsfree.visual.startAction"))")
                                .font(Theme.text(12, medium: true))
                            Text(verbatim: L("handsfree.visual.orURLAction"))
                                .font(Theme.text(10.5)).foregroundStyle(Theme.muted(scheme))
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.approval)
                    }
                case .phraseTraining:
                    HStack(spacing: 10) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.approval)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\"Hey Sunday\"  /  \"헤이 선데이\"")
                                .font(Theme.text(12, medium: true))
                            Text(verbatim: L("handsfree.visual.repeatThreeTimes"))
                                .font(Theme.text(10.5)).foregroundStyle(Theme.muted(scheme))
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 4) {
                            ForEach(0..<3, id: \.self) { _ in
                                Circle().fill(Theme.approval).frame(width: 7, height: 7)
                            }
                        }
                    }
                case .sendByVoiceFlow:
                    HStack(spacing: 8) {
                        Text(verbatim: L("handsfree.visual.flowStart"))
                            .font(Theme.text(11, medium: true))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel(scheme)))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.rule(scheme), lineWidth: 1))
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted(scheme))
                        Text(verbatim: L("handsfree.visual.flowSpeak"))
                            .font(Theme.text(11))
                            .foregroundStyle(Theme.muted(scheme))
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted(scheme))
                        Text(verbatim: L("handsfree.visual.flowSend"))
                            .font(Theme.text(11, medium: true))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.approval.opacity(0.14)))
                            .foregroundStyle(Theme.approval)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.well(scheme))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.rule(scheme), lineWidth: 1))
    }

    private var windowCaption: String {
        switch visual {
        case .systemSettingsNav, .actionPicker, .phraseTraining:
            return L("handsfree.visual.systemSettings")
        case .sendByVoiceFlow:
            return AppIdentity.name
        }
    }
}

/// Optional onboarding card on `DoneStep` (shown ONLY on macOS 15+ Apple Silicon).
struct HandsFreeOnboardingCard: View {
    var onOpenSetup: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.approval)
                    .frame(width: 34, height: 34)
                    .background(Theme.well(scheme), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: L("handsfree.onboarding.title")).font(Theme.display(15))
                        ModeBadge(kind: .freeAndPro)
                    }
                    Text(verbatim: L("handsfree.onboarding.body"))
                        .font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(L("handsfree.onboarding.button"), action: onOpenSetup)
                    .buttonStyle(GhostButton())
            }
        }
    }
}
