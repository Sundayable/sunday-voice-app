# Sunday Voice

**Fast macOS dictation and private on-device meeting transcription, built by [Sundayable](https://sundayable.com).**

Hold a key, speak naturally in Korean, English, or both, and release — text lands right where your cursor is. **Starts free and 100% local on your Mac by default** with Apple Silicon speech models (no sign-in required), with optional **Sunday Voice Pro ($19/mo, Google sign-in)** for low-latency cloud streaming and personal voice rewriting.

> **[Download Sunday Voice v0.3.20 for macOS (Apple Silicon)](https://github.com/Sundayable/sunday-voice-app/releases/tag/v0.3.20)** — Apple Developer ID signed & notarized.

---

## Features

- **Free Local Mode by Default (No Sign-In Required)**
  - Starts in **Free Local Mode** out of the box when signed out — zero account wall, zero API keys, and zero external cloud calls.
  - Transcribes directly on your Mac using `Whisper large-v3-turbo` (Core ML via [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)) + your local replacement dictionary (`~/Library/Application Support/SundayVoice/local-replacements.json`).
  - Shares the same cached speech model as Meetings (0 MB extra download).
- **Focused English & Korean Recognition**
  - Speech recognition across Free Local Mode, local meetings, and Pro cloud dictation is scoped to English (`en`) and Korean (`ko`) via a unified allowlist to prevent cross-language hallucinations.
- **Instant Push-to-Talk Dictation**
  - Bind any keyboard shortcut, modifier hold (e.g., `Fn` or `Control`), or mouse button (`Button 4`/`5`) for **Bilingual (as spoken)** or **Natural English** output.
  - **Optional Screen Term Hints (Opt-in):** Reads only proper nouns and Latin tokens from the active window title and cursor neighborhood (`±300` chars) to improve spelling of names and technical terms. Always skips password/secure fields and never logs screen text.
  - **Spoken Self-Correction:** Handles mid-sentence corrections naturally (*"내일 3시 말고 모레 4시로"*, *"John, wait no, Lauren"*).
- **Local Meeting Recording & Speaker Separation**
  - **Record-First Architecture:** Captures microphone + Mac system audio straight to private local files with zero model lag during the call, then frees your microphone immediately when you hit Stop. See [docs/RECORD-FIRST.md](docs/RECORD-FIRST.md).
  - **On-Device Speaker Labels:** Separates voices locally (`You`, `Speaker 1`, `Speaker 2`) with [SpeakerKit](https://huggingface.co/argmaxinc/speakerkit-coreml) — audio and transcripts never leave your Mac.
  - **Live Progress & ETA:** Determinate progress bar (`processed / total` audio), live smoothed time remaining, and background transcription status in the menu bar even after closing the panel.
  - **Automatic Call Detection:** Detects active calls in Google Meet (Chrome/Safari/Aside/Arc/Brave/Edge + Meet PWAs), Zoom, Microsoft Teams, Slack Huddles, and FaceTime, with optional auto-start, auto-stop, and optional Google Calendar / macOS Calendar integration.
- **Optional Sunday Voice Pro ($19/mo · Google Sign-In)**
  - Upgrade anytime in onboarding or **Settings → Account** for ultra-low-latency cloud dictation, AI rewrite in your personal writing style, and Gmail/Slack vocabulary sync. Signed-in Pro users keep cloud mode by default and can still toggle offline local mode anytime.
- **Native macOS Experience**
  - Full Korean & English UI with instant language switching (no restart), Light & Dark mode, and Apple Silicon Neural Engine acceleration.

---

## Requirements

- **Mac with Apple Silicon** (M1 / M2 / M3 / M4; 16 GB RAM recommended for local Whisper + speaker separation)
- **macOS 14.0 (Sonoma) or later** for dictation
- **macOS 15.0 (Sequoia) or later** for local system-audio meeting capture (ScreenCaptureKit audio)

---

## Download & Install

1. Download **`Sunday-Voice-0.3.20-macOS-arm64.zip`** from [Releases → v0.3.20](https://github.com/Sundayable/sunday-voice-app/releases/tag/v0.3.20).
2. *(Optional)* Verify the SHA-256 checksum against `SHA256SUMS.txt`:
   ```bash
   shasum -a 256 -c SHA256SUMS.txt
   ```
3. Unzip and drag **`Sunday Voice.app`** into `/Applications` (or `~/Applications`), then open it.
4. Click **Start free (Local Mode)** (no sign-in needed) and grant **Microphone** and **Accessibility** permissions (plus **Screen & System Audio Recording** if you use local meeting recording).
5. Open **Settings → Meetings** to download the on-device speech models once (~660 MB) for offline dictation and local meeting transcripts. Sign in with Google under **Settings → Account** only if you want **Sunday Voice Pro** cloud features.

---

## Privacy

| Mode | What stays on your Mac | What is sent over the network |
|---|---|---|
| **Free Local Mode** *(default when signed out)* | Audio, transcription, screen-term hints, personal replacements, and recent history — 100% local | **Nothing** (zero cloud calls after the one-time public model download from Hugging Face) |
| **Local Meetings** *(all users)* | Microphone + Mac audio capture, Whisper transcription, SpeakerKit voice separation, `Transcript.txt` / `Transcript.json` | **Nothing.** Raw audio is deleted automatically once the transcript is written unless you enable 30-day retention |
| **Sunday Voice Pro** *(optional $19/mo, Google sign-in)* | Local recovery buffer, preferences, and recent transcripts | When signed in with offline local mode off: dictated speech audio for streaming transcription, plus optional short context/screen-term hints if enabled, to rewrite in your personal voice. Audio and text are **never used to train AI models**. |

---

## Build from Source

Requires **Xcode 16+** and **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** (`brew install xcodegen`).

```bash
# 1. Configure your own app identity (required for forks per TRADEMARK.md)
cp identity.env.example identity.env
# Edit identity.env with your own display name, bundle ID, URL scheme, and team ID
bash scripts/sync-identity.sh

# 2. Generate the Xcode project
cd mac && xcodegen generate

# 3. Run unit tests
(cd Engine && swift test)
(cd MeetingEngine && swift test)
xcodebuild -project SundayVoice.xcodeproj -scheme SundayVoice -destination 'platform=macOS,arch=arm64' test

# 4. Build & run in Xcode
open SundayVoice.xcodeproj
```

> **Note:** This open-core repository contains the complete macOS desktop client (`mac/Sources`), local dictation engine (`mac/Engine`), and local meeting + speaker separation engine (`mac/MeetingEngine`). Sundayable's hosted Pro cloud backend (`voice.sundayable.com`) is separate and proprietary.

---

## License & Trademark

- **Source Code:** Licensed under the **GNU Affero General Public License v3.0 or later (`AGPL-3.0-or-later`)** — see [LICENSE](LICENSE).
- **Third-Party Notices:** Bundled open-source libraries, speech/speaker models, and fonts are documented in [ThirdPartyNotices.txt](ThirdPartyNotices.txt).
- **Trademarks:** **Sundayable**, **Sunday Voice**, `ca.sundayable.*`, and the app icons/wordmarks are trademarks of **Sundayable Inc.** Redistributed forks must rebrand via `identity.env` — see [TRADEMARK.md](TRADEMARK.md).

Built by **[Sundayable](https://sundayable.com)**.

---

## 한국어 안내

**Sunday Voice**는 [Sundayable](https://sundayable.com)이 만든 macOS용 빠른 받아쓰기·로컬 미팅 전사 앱이에요.

- **로그인 없이 바로 쓰는 무료 로컬 모드(기본):** 앱을 열면 로그인 화면에 막히지 않고 바로 **무료 로컬 모드**로 시작해요. 이 Mac의 Apple Silicon(`Whisper large-v3-turbo`)으로 외부 API 호출 없이 무료로 받아쓸 수 있어요.
- **한국어·영어 전용 음성 인식:** 클라우드 받아쓰기, 무료 로컬 모드, 로컬 미팅 전사 전반에서 한국어(`ko`)와 영어(`en`)만 인식하도록 제한해 타언어 오인식·환각을 줄였어요.
- **선택형 Pro (월 $19 · Google 로그인):** 더 빠른 클라우드 받아쓰기, 내 말투 맞춤 AI 다듬기, Gmail·Slack 단어 학습이 필요할 때만 온보딩이나 **설정 → 계정**에서 Google로 로그인해 업그레이드하면 돼요.
- **한·영 빠른 받아쓰기:** 단축키나 마우스 버튼을 누른 채 한국어·영어를 섞어 말하면 커서 위치에 바로 입력돼요. 화면 용어 힌트(선택)와 발화 중 자가 수정(*“내일 3시 말고 모레 4시로”*)을 지원해요.
- **로컬 미팅 녹음 + 화자 분리:** 녹음 중에는 모델 부하 없이 안정적으로 저장하고, 미팅이 끝나면 이 Mac에서 화자별로(`You`, `Speaker 1`, `Speaker 2`) 전사해요. 진행률과 남은 시간(ETA)을 실시간으로 확인할 수 있고, 창을 닫아도 백그라운드에서 계속 저장돼요. Google 캘린더 연결도 선택 사항이에요.
- **설치 방법:** [GitHub Releases v0.3.20](https://github.com/Sundayable/sunday-voice-app/releases/tag/v0.3.20)에서 공증된 `Sunday-Voice-0.3.20-macOS-arm64.zip`을 받아 압축을 풀고 `응용 프로그램` 폴더에 옮겨 실행해 주세요. (Apple Silicon Mac · macOS 14+, 미팅 시스템 오디오 녹음은 macOS 15+ 필요)
- **라이선스:** macOS 앱 및 로컬 엔진 코드는 `AGPL-3.0-or-later`로 공개되며, Sundayable/Sunday Voice 상표 및 로고는 [TRADEMARK.md](TRADEMARK.md) 기준을 따라요.
