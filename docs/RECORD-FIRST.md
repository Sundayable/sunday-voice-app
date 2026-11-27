# Meetings: record first, transcribe after (0.3.16)

Since 0.3.16 a meeting is only **recorded** while it runs. The transcript, with speakers
separated, is written on the same Mac after the call. This replaces the earlier design that
decoded 20-second chunks live during the meeting. `IMPLEMENTATION.md` still describes detection,
capture recovery and calendars, which are unchanged.

## Why it changed

Measured on real Korean/English recordings on this Mac (Apple M4, 16 GB) on 2026-11-26:

- Live 20-second decoding detected the language per chunk. On a Korean talk with English terms,
  chunks were decoded as Japanese and about a third of the text was lost.
- Recording could not start until the 626 MB model had loaded (about 75 s cold), and stopped
  altogether when decoding fell more than 12 chunks behind (`backlogFull`).
- Audio was deleted chunk by chunk, so a poor transcript could never be redone, and chunks left
  by a quit stayed unprocessed.
- The model stayed in memory for the rest of the day, and dictation was blocked until the last
  chunk was decoded.
- "You" and "Meeting audio" were the only labels.

## Flow

1. **Capture** (`ScreenMeetingCapture`, `ResilientMeetingCapture`): unchanged. Microphone and Mac
   audio as private 20-second CAF files with a JSON description each, under
   `~/Library/Application Support/SundayVoice/MeetingCapture/<session>/`. A `Session.json`
   marker is written at the first second.
2. **While recording** (`LocalMeetingService.start`): no speech model is loaded or needed. The
   service only notes each file's timing. Starting takes as long as ScreenCaptureKit takes.
3. **Stop** (`MeetingSessionStore.finishRecording`): the recording is marked saved and the
   microphone goes back to dictation immediately.
4. **Offline pass** (`MeetingPostProcessor`), one recording at a time, also at the next launch
   for anything a quit or crash left behind:
   - `MeetingAudioAssembler` rebuilds each source on the meeting clock (silence fills capture gaps).
   - `WhisperMeetingTranscriber.recognize`: SpeakerKit separates the voices in the source, then
     `MeetingSpeechRegions` plans what to decode: only stretches where someone speaks, one voice
     per stretch, cut at pauses to fit one recognizer window. WhisperKit decodes the pieces four
     at a time. A piece detected as a language other than Korean or English is decoded again in
     the meeting's main language.
   - `MeetingTranscriptBuilder` drops microphone lines that are an echo of the call audio, names
     the voices and joins consecutive lines by one person.
5. **Result**: `Transcript.txt`, `Transcript.json` (version 3) and `RecordingMetadata.json` in
   `~/Library/Application Support/SundayVoice/Meetings/<date>_<id>/`. The raw capture folder is
   removed only after the transcript is on disk. Models are unloaded when no recording is waiting.

A new meeting can be recorded while an earlier one is being transcribed.

## Speaker labels

Voices are separated, never identified. One voice on the microphone is `You`; several real
voices on the microphone are `Room speaker N`; voices in the meeting audio are `Speaker N` in the
order they first speak; a meeting-audio voice heard for under four seconds is `Speaker ?`.
Calendar invitees stay metadata and are not mapped to voices.

## Models

| Purpose | Model | Size | License |
|---|---|---|---|
| Speech | `argmaxinc/whisperkit-coreml` `openai_whisper-large-v3-v20240930_626MB` (Whisper large-v3-turbo) | 627 MB | MIT |
| Voices | `argmaxinc/speakerkit-coreml` (pyannote segmentation, WeSpeaker embedding, VBx clustering) | 11 MB | CC BY 4.0 (attribution in ThirdPartyNotices) |

Both come from the already pinned `argmax-oss-swift` package (MIT). Downloads happen only from
the explicit setup action; everything else loads from disk. Without the voice models a transcript
is still written with source labels only.

## Failure handling

- Capture interruptions are retried as before; the gap is noted and the transcript is marked incomplete.
- A failed offline pass keeps the audio and is tried again at the next launch, three times at
  most. After that the audio moves to `Recovery Audio/` beside the transcript.
- A missing speech model is not a failure: recordings wait and are transcribed after setup.
- A recording cut short by a quit is transcribed up to the last closed file and marked incomplete.

## Keeping audio

Off by default: the audio is removed once the transcript exists. With **Keep meeting audio for
30 days** (`meetingKeepAudioEnabled`) each source is kept as a 16 kHz mono AAC file under
`Audio/` beside the transcript (about 14 MB per hour per source) and removed after 30 days.

## Handing a transcript to other tools

Nothing leaves the Mac from the app. A finished meeting is a folder whose `Transcript.json` has
`finishedAt` set. Tools that summarise meetings read:

- `Transcript.txt`: one line per turn, `[HH:MM:SS] Speaker: text`, with a header that explains the labels.
- `Transcript.json`: `segments[]` with `speaker`, `source`, `startSeconds`, `endSeconds`, `text`;
  `transcription` (models, languages, audio and processing seconds, speaker count); `recording`
  (start/end instants, time zone, meeting app and window, calendar match with invitees).

Sundayable's own hand-off to the meeting digest is a separate script outside this app (see
`cloud-ops`), run on the owner's Mac. It is not part of the distributed product.

## Diagnostics

```
swift run -c release meeting-engine-check --prepare
MEETING_ENGINE_TIMING=1 swift run -c release meeting-engine-check --microphone mic.m4a --system call.m4a
swift run -c release meeting-engine-check --resume
```

The tool prints counts and timings only, never audio or transcript text.
