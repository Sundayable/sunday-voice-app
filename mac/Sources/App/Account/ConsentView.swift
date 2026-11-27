import SwiftUI

struct ConsentView: View {
    @ObservedObject var model: OnboardingModel
    @State private var working = false
    @State private var error: String?
    @Environment(\.colorScheme) private var scheme
    private var ko: Bool { UILanguage.isKorean }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ko ? "대표님, 시작 전에 확인해 주세요" : "Before you start").font(Theme.display(23))
            Text(ko ? "받아쓰기 음성은 90일 보관해요. 원문과 다듬은 글, 확인 가능한 수정 내용, 직접 보낸 버그 신고는 1년 동안 보관해요. 사용 기록과 자동 오류 보고는 90일 보관하며, 담당 관리자만 문제 확인을 위해 볼 수 있어요." : "We retain dictation audio for 90 days; transcripts, rewritten text, detected edits and bug reports for one year; usage events and automatic error reports for 90 days. Authorized owners/admins can review them to provide and troubleshoot the service.").font(Theme.text(13)).lineSpacing(3)
            Text(ko ? "대표님의 음성이나 글을 AI 학습에 사용하지 않아요." : "We do not use your data to train AI models.").font(Theme.text(14, medium: true))
            Text(ko ? "음성 인식은 OpenAI, 글 다듬기는 OpenAI와 OpenRouter/Groq에서 처리해요. 미팅 녹음은 이 Mac에만 남아요. 삭제 요청: dan@sundayable.com" : "Speech: OpenAI. Rewriting: OpenAI and OpenRouter/Groq. Meeting recordings stay on your Mac. Request deletion: dan@sundayable.com").font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
            HStack(spacing: 16) {
                Link(destination: (model.auth.baseURL ?? URL(string: "https://voice.sundayable.com")!).appendingPathComponent("terms")) {
                    HStack(spacing: 4) {
                        Text(ko ? "이용약관 전문" : "Full Terms").underline()
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(Theme.text(13, medium: true))
                    .foregroundStyle(Theme.text(scheme))
                }
                Link(destination: (model.auth.baseURL ?? URL(string: "https://voice.sundayable.com")!).appendingPathComponent("privacy")) {
                    HStack(spacing: 4) {
                        Text(ko ? "개인정보 처리방침" : "Privacy notice").underline()
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(Theme.text(13, medium: true))
                    .foregroundStyle(Theme.text(scheme))
                }
            }
            Text(ko ? "아래 버튼을 누르면 약관과 안내한 정보 수집에 동의하게 돼요. 동의하지 않으시면 창을 닫아 주세요." : "Clicking below accepts the Terms and the collection described in Privacy. Close this window to decline.").font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
            Button(working ? (ko ? "확인 중…" : "Checking…") : (ko ? "동의하고 시작하기" : "Agree and continue")) {
                working = true; error = nil
                Task {
                    do { try await model.auth.agreeToTerms(); model.didSignIn() }
                    catch { try? await model.auth.refreshConsent(); self.error = ko ? "동의를 저장하지 못했어요. 연결을 확인한 뒤 다시 눌러 주세요." : "Could not save consent. Check your connection and try again." }
                    working = false
                }
            }.buttonStyle(PrimaryButton()).disabled(working || model.auth.consentVersion == nil)
            if let error { Text(error).font(Theme.text(12)).foregroundStyle(.red) }
        }.task {
            guard !model.isPreview else { return }
            do { try await model.auth.refreshConsent(); if model.auth.isSignedIn { model.didSignIn() } }
            catch { self.error = ko ? "약관을 불러오지 못했어요. 창을 다시 열어 주세요." : "Could not load the current terms. Reopen this window to retry." }
        }
    }
}
