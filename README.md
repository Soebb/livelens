# LiveLens

![Platform](https://img.shields.io/badge/platform-Android%2010%2B-3DDC84?logo=android&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-3.32%2B-02569B?logo=flutter&logoColor=white)
![License](https://img.shields.io/badge/license-GPL--3.0-blue)
![Status](https://img.shields.io/badge/status-pre--alpha-orange)

**Real-time, system-wide translated subtitles for Android — fully on-device.**

LiveLens captures media audio via `AudioPlaybackCapture`, transcribes and
translates it with an on-device Whisper model (sherpa-onnx), and renders
draggable glassmorphism subtitle overlays over any app. Sessions persist as
searchable bilingual transcripts you can edit and export.

<p align="center">
  <img width="32%" alt="LiveLens screenshot 1" src="https://github.com/user-attachments/assets/51f8290f-cb51-461b-a0d2-24c4daadc7db" />
  <img width="32%" alt="LiveLens screenshot 2" src="https://github.com/user-attachments/assets/bd8390f0-536b-4be9-8d41-ce70b21afcb2" />
  <img width="32%" alt="LiveLens screenshot 3" src="https://github.com/user-attachments/assets/c4aaa976-b663-4938-bb0d-fecc18ad0901" />
</p>
<p align="center">
  <img width="49%" alt="LiveLens screenshot 4" src="https://github.com/user-attachments/assets/605424e1-85d3-4b97-83d5-78a31add5781" />
  <img width="49%" alt="LiveLens screenshot 5" src="https://github.com/user-attachments/assets/6c0d5c8f-70d0-4370-b871-73e4038e6a7d" />
</p>



> 🔒 **Privacy by architecture** — no accounts, no cloud, no telemetry. The
> only network access is the one-time model download from HuggingFace
> (SHA-256-verified before install).

## Features

- **Live translated subtitles** — Whisper int8 tiers (tiny/base/small),
  hot-swappable at runtime from a RAM-gated, SHA-256-verified registry.
- **Transcribe mode** — same-language captions, plus auto language detection
  with hysteresis smoothing to avoid flapping between similar languages.
- **Session transcripts** — bilingual segments with full-text search,
  editing, and export via the system share sheet.
- **Adaptive overlay** — draggable, styleable glass captions governed by a
  battery/thermal governor that adapts inference cadence under load.
- **Built-in benchmark** — one-tap latency (p50/p90), RTF, and memory
  measurement per model on your device.

## ⚠️ Model accuracy

> The bundled engine is **Whisper `base` (int8)**, sized for real-time
> decoding on phone hardware. **Non-English transcription and translation
> are limited and not fault-free** — this is a model-size property, not a
> code bug. For better results, switch to a larger tier on-device, or run
> **Whisper `large-v3` on a VPS** and stream audio to it over a WebSocket
> (trading the on-device privacy guarantee for quality). English is where
> the bundled model performs best.

## Compatibility

Android's playback-capture API requires Android 10+, and **apps may opt
out**. DRM streams are impossible by design. This table is evidence-based —
it will never claim "works with everything."

| App | Capturable | Notes |
|---|---|---|
| YouTube | ✅ | Primary target; verified |
| TikTok / Instagram Reels | ✅ | Expected to work |
| VLC / MX Player | ✅ | Local files & streams |
| Chrome browser media | ❌ | Opted out of capture |
| Netflix / Prime Video / Disney+ | ❌ | Widevine DRM |
| Spotify | ❌ | Opts out of capture |

A microphone-based **Degraded mode** exists for blocked apps — explicitly
badged in the UI as lower quality. Subtitles trail speech by ~2–6 s
depending on device class (flagships ≈ 2–3 s).

## Getting started

**Requirements:** Android 10+ (64-bit ARM), 4 GB RAM min, ~200–500 MB
storage for models. To build: Flutter 3.32+, Android SDK 35, NDK r27.

```bash
git clone https://github.com/<you>/livelens.git
cd livelens
flutter pub get
flutter run
```

### Model assets

The bundled engine (`assets/sherpa-onnx-whisper-base/`,
`assets/sherpa-onnx-silero-vad/`) is **gitignored to keep the repo light**.
A fresh clone builds, but first launch needs the assets in place — download
the files listed in
[`ModelCatalog.kt`](android/app/src/main/kotlin/dev/livelens/livelens/core/ModelCatalog.kt)
from `huggingface.co/csukuangfj/sherpa-onnx-whisper-base` (plus the Silero
VAD model from the sherpa-onnx releases) and place them in those folders.
Other tiers download on demand from inside the app.

## Testing

```bash
flutter analyze                                   # static analysis
flutter test                                      # Dart/widget tests
cd android && ./gradlew :app:testDebugUnitTest    # Kotlin unit tests
```

## Documentation

| Doc | Contents |
|---|---|
| [`docs/contract.md`](docs/contract.md) | Frozen platform-channel contract v1 |
| [`Documentation/architecture.md`](Documentation/architecture.md) | System design, threading, data schema |
| [`Documentation/PRD.md`](Documentation/PRD.md) | Requirements & priorities |
| [`Documentation/checklist.md`](Documentation/checklist.md) | Execution plan & progress |
| [`Documentation/github.md`](Documentation/github.md) | Publishing this repo |

## License

GPL-3.0 — chosen deliberately: for a consumer privacy app, copyleft prevents
forks from stripping privacy guarantees while shipping them to users.
Bundled fonts are under their respective open licenses (OFL).

---

**Status:** 🚧 Pre-alpha, under active development. Contributions welcome —
run the test suites above before submitting; wire-format changes must stay
additive.
