# Sunday Voice

**Fast macOS dictation and private on-device meeting transcription, built by [Sundayable](https://sundayable.com).**

Hold a key, speak naturally in Korean, English, or both, and release — text lands right where your cursor is. Run completely free and offline on your Mac with Apple Silicon speech models, or connect optional Sunday Voice Cloud (Pro) for ultra-low-latency streaming and personal voice rewriting.

> **[Download Sunday Voice v0.3.18 for macOS (Apple Silicon)](https://github.com/Sundayable/sunday-voice-app/releases/tag/v0.3.18)** — Apple Developer ID signed & notarized.

---

## Features

- **Instant Push-to-Talk Dictation**
  - Bind any keyboard shortcut, modifier hold (e.g., `Fn` or `Control`), or mouse button (`Button 4`/`5`) for **Bilingual (as spoken)** or **Natural English** output.
  - **Optional Screen Term Hints (Opt-in):** Reads only proper nouns and Latin tokens from the active window title and cursor neighborhood (`±300` chars) to improve spelling of names and technical terms. Always skips password/secure fields and never logs screen text.
  - **Spoken Self-Correction:** Handles mid-sentence corrections naturally (*"내일 3시 말고 모레 4시로"*, *"John, wait no, Lauren"*).
- **Free Local Mode (100% Offline, Zero Cloud APIs)**
  - Toggle **Settings → General → Offline local dictation (Free, no cloud APIs)** to transcribe directly on your Mac using `Whisper large-v3-turbo` (Core ML via [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)) + your local replacement dictionary (`~/Library/Application Support/SundayVoice/local-replacements.json`).
  - No account, API key, or internet connection required. Shares the same cached speech model as Meetings (0 MB extra download).
- **Local Meeting Recording & Speaker Separation**
  - **Record-First Architecture:** Captures microphone + Mac system audio straight to private local files with zero model lag during the call, then frees your microphone immediately when you hit Stop. See [docs/RECORD-FIRST.md](docs/RECORD-FIRST.md).
  - **On-Device Speaker Labels:** Separates voices locally (`You`, `Speaker 1`, `Speaker 2`) with [SpeakerKit](https://huggingface.co/argmaxinc/speakerkit-coreml) — audio and transcripts never leave your Mac.
  - **Live Progress & ETA:** Determinate progress bar (`processed / total` audio), live smoothed time remaining, and background transcription status in the menu bar even after closing the panel.
  - **Automatic Call Detection:** Detects active calls in Google Meet (Chrome/Safari/Aside/Arc/Brave/Edge + Meet PWAs), Zoom, Microsoft Teams, Slack Huddles, and FaceTime, with optional auto-start and auto-stop.
- **Native macOS Experience**
  - Full Korean & English UI with instant language switching (no restart), Light & Dark mode, and Apple Silicon Neural Engine acceleration.

---

## Requirements

- **Mac with Apple Silicon** (M1 / M2 / M3 / M4; 16 GB RAM recommended for local Whisper + speaker separation)
- **macOS 14.0 (Sonoma) or later** for dictation
- **macOS 15.0 (Sequoia) or later** for local system-audio meeting capture (ScreenCaptureKit audio)

---

## Download & Install

1. Download **`Sunday-Voice-0.3.18-macOS-arm64.zip`** from [Releases → v0.3.18](https://github.com/Sundayable/sunday-voice-app/releases/tag/v0.3.18).
2. *(Optional)* Verify the SHA-256 checksum against `SHA256SUMS.txt`:
   ```bash
   shasum -a 256 -c SHA256SUMS.txt
   ```
3. Unzip and drag **`Sunday Voice.app`** into `/Applications` (or `~/Applications`), then open it.
4. Grant **Microphone** and **Accessibility** permissions when prompted (and **Screen & System Audio Recording** if you use local meeting recording).
5. To use **Free Local Mode** without signing in: open **Settings → Meetings** to download the on-device speech models once (~660 MB), then turn on **Settings → General → Offline local dictation**.

---

## Privacy

| Mode | What stays on your Mac | What is sent over the network |
|---|---|---|
| **Free Local Mode** *(offline dictation)* | Audio, transcription, screen-term hints, personal replacements, and recent history — 100% local | **Nothing** (zero cloud calls after the one-time public model download from Hugging Face) |
| **Local Meetings** *(all users)* | Microphone + Mac audio capture, Whisper transcription, SpeakerKit voice separation, `Transcript.txt` / `Transcript.json` | **Nothing.** Raw audio is deleted automatically once the transcript is written unless you enable 30-day retention |
| **Sunday Voice Cloud (Pro, optional)** | Local recovery buffer, preferences, and recent transcripts | When signed in with Free Local Mode off: dictated speech audio for streaming transcription, plus optional short context/screen-term hints if enabled, to rewrite in your personal voice. Audio and text are **never used to train AI models**. |

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

> **Note:** This open-core repository contains the complete macOS desktop client (`mac/Sources`), local dictation engine (`mac/Engine`), and local meeting + speaker separation engine (`mac/MeetingEngine`). Sundayable's hosted Cloud backend (`voice.sundayable.com`) is separate and proprietary.

---

## Known Issues

- **Returning-user relaunch onboarding flash (v0.3.18):** If you are already signed in to Cloud mode and relaunch the app, the onboarding window may briefly open before the startup consent check finishes (~300 ms), while the menu bar transitions normally to `Ready`. Closing the window leaves dictation ready as normal; a fix is queued for the next patch release.

---

## License & Trademark

- **Source Code:** Licensed under the **GNU Affero General Public License v3.0 or later (`AGPL-3.0-or-later`)** — see [LICENSE](LICENSE).
- **Third-Party Notices:** Bundled open-source libraries, speech/speaker models, and fonts are documented in [ThirdPartyNotices.txt](ThirdPartyNotices.txt).
- **Trademarks:** **Sundayable**, **Sunday Voice**, `ca.sundayable.*`, and the app icons/wordmarks are trademarks of **Sundayable Inc.** Redistributed forks must rebrand via `identity.env` — see [TRADEMARK.md](TRADEMARK.md).

Built by **[Sundayable](https://sundayable.com)**.

---

## 한국어 안내

**Sunday Voice**는 [Sundayable](https://sundayable.com)이 만든 macOS용 빠른 받아쓰기·로컬 미팅 전사 앱이에요.

- **한·영 빠른 받아쓰기:** 단축키나 마우스 버튼을 누른 채 한국어·영어를 섞어 말하면 커서 위치에 바로 입력돼요. 화면 용어 힌트(선택)와 발화 중 자가 수정(*“내일 3시 말고 모레 4시로”*)을 지원해요.
- **무료 오프라인 로컬 모드:** 로그인이나 외부 API 없이 이 Mac의 Apple Silicon(`Whisper large-v3-turbo`)만으로 무료로 받아쓸 수 있어요. (**설정 → 일반 → 오프라인 로컬 받아쓰기**)
- **로컬 미팅 녹음 + 화자 분리:** 녹음 중에는 모델 부하 없이 안정적으로 저장하고, 미팅이 끝나면 이 Mac에서 화자별로(`You`, `Speaker 1`, `Speaker 2`) 전사해요. 진행률과 남은 시간(ETA)을 실시간으로 확인할 수 있고, 창을 닫아도 백그라운드에서 계속 저장돼요.
- **설치 방법:** [GitHub Releases v0.3.18](https://github.com/Sundayable/sunday-voice-app/releases/tag/v0.3.18)에서 공증된 `Sunday-Voice-0.3.18-macOS-arm64.zip`을 받아 압축을 풀고 `응용 프로그램` 폴더에 옮겨 실행해 주세요. (Apple Silicon Mac · macOS 14+, 미팅 시스템 오디오 녹음은 macOS 15+ 필요)
- **라이선스:** macOS 앱 및 로컬 엔진 코드는 `AGPL-3.0-or-later`로 공개되며, Sundayable/Sunday Voice 상표 및 로고는 [TRADEMARK.md](TRADEMARK.md) 기준을 따라요.
