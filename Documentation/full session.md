# LiveLens — Validation, PRD, Architecture, Design System & Execution Checklist

You've already done better-than-average homework (correctly identifying sherpa-onnx, AudioPlaybackCapture, VAD chunking, and that the *pipeline* is the hard part). So my job as your senior reviewer is not to agree with you enthusiastically — it's to stress-test the idea, tell you where it hurts, and hand you the artifacts you asked for. Here we go.

---

# PART 1 — IDEA VALIDATION (Is this worth your time?)

## 1.1 Scorecard

| Dimension | Score | Notes |
|---|---|---|
| Problem severity | ★★★★★ | Foreign-language media consumption is massive; existing tools are fragmented |
| Timing | ★★★★★ | On-device Whisper became practical only recently; window is NOW, before Google/Apple close the gap |
| Technical feasibility | ★★★★☆ | Proven on-device inference; main risk is capture compatibility + mid-tier device latency |
| Differentiation | ★★★★☆ | Only "local, private, system-wide, session-based" combination — real moat today |
| Community/distribution | ★★★★☆ | Strong FOSS appeal (GitHub/F-Droid/r/Android community loves this category) |
| Monetization (near-term) | ★★☆☆☆ | Essentially zero near-term revenue; treat as portfolio/product bet, not income |
| Scope risk | ★★★☆☆ | Your feature list screams "scope creep." Discipline required |

**Verdict: GO — with conditions.** Build it as your flagship open-source project. Do not expect money; do expect portfolio gravity, contributors, and real users.

---

## 1.2 Who actually wants this (real audiences, not hypothetical)

1. **Language learners** consuming Japanese/Korean/Spanish/Turkish content — the vocabulary/bilingual features make this sticky.
2. **Immigrants & diaspora** watching home-country content who need translation, not captions.
3. **Deaf/HoH users** for videos lacking *any* captions (your transcription mode alone serves this — underrated).
4. **Privacy-conscious Android users** who refuse cloud-transcription apps.
5. **Researchers/journalists** needing timestamped transcripts of watched media.

That's four distinct communities, each reachable (r/languagelearning, r/deaf, F-Droid audience, privacy Twitter). You don't need mass-market scale for this to be successful as an OSS project.

## 1.3 Competitive landscape (honest version)

| Solution | Gap you exploit |
|---|---|
| Google Live Caption / Live Translate | Device-limited (Pixel/Samsung class), same-language captions by default, weak translation coverage, no transcript archive, no export, no learning features, closed |
| Samsung Galaxy AI Live Translate | Samsung-flagship only, call-centric |
| Cloud dubbing/translation apps (ElevenLabs etc.) | Online-only, subscription, privacy-hostile, no overlay |
| Screen-OCR translator apps (Mi, Screen Translate) | Read screen *text*, not *speech* — fail on burned-in video audio |
| Lingvotube-type extensions | Desktop, online, Chrome-only |

**Your defensible wedge:** offline + private + system-wide + persistent sessions/exports + model choice + open source. When Gemini Nano improves, some of this collapses — but Nano is still vendor-gated, so you have a genuine 18–24 month window to establish the project.

## 1.4 The hard truths (this is why you pay a senior reviewer)

These six realities shape the whole PRD. Read twice.

**HT-1 — Capture compatibility is your #1 product risk.**
`AudioPlaybackCaptureConfiguration` requires **Android 10+**, and apps can opt out via `allowAudioPlaybackCapture="false"`. Most serious apps do: Chrome, Netflix, Amazon Prime, Spotify, and anything DRM/Widevine-bound block capture. Reality: **YouTube, TikTok, Instagram, VLC, MX Player and most social/video feeds remain capturable. Premium DRM streaming does not.** Consequences:
- Marketing copy must never say "works with everything."
- Ship a **Compatibility Self-Check** in-app (detect the active capturable streams via `AudioManager.getActivePlaybackConfigurations()` and show pass/fail upfront).
- Provide a **microphone-mode fallback** (worse quality, still useful) documented as degraded.

**HT-2 — Latency is physics, not marketing.**
Order-of-magnitude expectations (verify in the spike): Whisper tiny/base INT8 achieves real-time-factor ≈ 0.1–0.35 on Snapdragon 8-series, and **≈ 0.6–1.2 on mid-tier SoCs** (Helio G95/SD 695 class). Meaning: a 6-second speech chunk may finalize in 3–8s on mid-range hardware. Subtitles will trail speech. Mitigations belong in the architecture (below): small chunks + VAD cuts, partial-result proxy, adaptive model tiering. Set user-facing expectations in UI ("~2–6s behind live").

**HT-3 — Whisper only translates X → English.**
Whisper's `task=translate` outputs **English only**. Your concept says "target language selector" — for V1 that means **Source selector × {Auto, ja, ko, tr, es…} → English**, plus **Transcription Mode** (source → source). Arbitrary target languages require cascading a second on-device MT model (NLLB-distilled / M2M100-small) — that's V2. **Do not put a fake Japanese→French button in V1.**

**HT-4 — Resource envelope.**
Base-multilingual INT8 ≈ 140–180 MB download, expect **300–500 MB peak RSS** during inference, sustained high-core CPU load → **thermal throttling after ~15–30 min** on metal-body phones. You must design adaptive degradation (skip frames on low battery, cool-down pauses on thermal warnings, pause-on-screen-off option). Minimum sensible spec: **Android 11, 4 GB RAM (6 GB recommended), 64-bit ARM**. Test floor: a SD 720G device.

**HT-5 — Permissions choreography is clumsy and non-negotiable.**
Full chain: Overlay permission (Settings page) → notification permission (Android 13+) → disable battery optimization (per-OEM dialogs — MIUI/HyperOS kill services aggressively) → **MediaProjection consent dialog shown EVERY session** (a casting-like prompt). This cannot be removed, only made understandable. Your onboarding wizard must pre-flight everything so runtime friction becomes one dialog.

**HT-6 — Licensing/policy fine print.**
Open-source (e.g., Apache-2.0 for code; check model licenses — OpenAI Whisper weights are MIT, but confirm sherpa-onnx exported artifacts' terms). If you ever ship to Play Store: MediaProjection use-case declarations, on-device-data disclosure, FGS-type declarations — doable, tedious. Start on **GitHub releases + F-Droid**, defer Play Store.

## 1.5 Effort estimate (solo senior dev, evenings included)

| Phase | Duration |
|---|---|
| Phase-0 risk-retirement spike | 1–2 weeks |
| Core native pipeline (capture→inference→log) | 4–6 weeks |
| Overlay + Flutter app + sessions | 4–6 weeks |
| Polish, docs, release | 2–3 weeks |
| **Total to a shippable V1** | **≈ 3.5–4.5 months** |

## 1.6 Phase-0 Go/No-Go Gate (DO THIS BEFORE WRITING FLUTTER)

Build the ugliest possible **pure-Kotlin PoC**: MediaProjection capture of YouTube → 16 kHz downsample → Silero VAD chunks → sherpa-onnx Whisper base INT8 → print translations to Logcat. Run 20 minutes on two devices (one flagship, one mid-tier). **Proceed to the app only if ALL of these pass:**

- [ ] Real-time-factor ≤ 0.5 on the mid-tier device (≤ 0.25 flagship)
- [ ] End-to-end latency ≤ 6 s p50 from speech-end to final text
- [ ] 20-min session: no crash, no unrecoverable memory growth (< 150 MB growth)
- [ ] Battery drain ≤ 12% over 30 min of continuous use (flagship, charged state reporting)
- [ ] Peak RSS ≤ 550 MB with base model loaded
- [ ] VAD correctly segments ≥ 9/10 sentence boundaries on a Japanese test clip

If mid-tier fails RTF badly → gate V1 to "Fast model only" (tiny INT8) and adjust positioning. If capture of target apps fails on your test devices → revisit the entire premise before investing further.

---

# PART 2 — PRODUCT REQUIREMENTS DOCUMENT (PRD)

## 2.1 Summary

**LiveLens** — an open-source, offline-first Android app providing real-time system-wide translated subtitles via on-device Whisper (sherpa-onnx), with persistent searchable transcripts. No accounts, no cloud, no telemetry by default.

## 2.2 Vision statement

*A local AI comprehension layer for Android media.* V1 = translate. Later versions add learn (vocabulary, TTS, bilingual study) and optional sync.

## 2.3 Goals / Non-goals (V1)

| Goals (V1) | Non-goals (V1) |
|---|---|
| Real-time J→E speech translation overlay (plus transcription mode + other source langs from model capability) | Any target language other than English for translation |
| Works on Android 10+ (11+ recommended), offline after model download | iOS, desktop, Wear |
| Floating draggable glassmorphism subtitle widget with remembered position | Video-sync/offset tooling |
| Sessions with timestamped bilingual segments, editing, export | Cloud sync, collaboration, accounts |
| Model Manager (Fast/Balanced/Quality, download-on-demand) | Bundling large models in APK |
| Auto source-language detection (best-effort) | Continuous speaker diarization |

## 2.4 Success metrics (V1 exit criteria)

| Metric | Target |
|---|---|
| p50 speech-end→final-subtitle latency | ≤ 6 s (mid-tier), ≤ 3 s (flagship) |
| 30-min session stability | Zero crashes, memory growth < 150 MB |
| Battery | ≤ 12% / 30 min continuous |
| Compat rate on advertised apps (YouTube/TikTok/IG/VLC) | ≥ 3 of 4 pass self-check |
| Whisper-base J→E qualitative accuracy on 20-clip test set | "Comprehensible" rating on ≥ 85% of sentences (human spot-check rubric, not BLEU theater) |

## 2.5 Key user flows

**F1 — First run:** Launch → Privacy pitch card → Permissions wizard (overlay → notifications → battery-optimization exemption) → Model Manager prompts download of Fast model (~X MB, checksum-verified) → Optional guided test on a sample YouTube link → Dashboard.

**F2 — Standard session (your spec, formalized):** Dashboard → "Start Translation" → MediaProjection consent → FGS starts + notification (“Japanese → English”) → user leaves app → overlay appears on idle-anchor position → speech → partial subtitle shows → refines to final → 3 s idle collapses controls → user stops via notification or overlay ✕ → session saved → transcript view.

**F3 — Manual session:** Dashboard → "+" → title + paste clipboard/typed text → editable plain segment list.

## 2.6 Functional requirements

Priorities: **P0** = V1 blocker · **P1** = V1 stretch/first patch · **P2** = V2 · **P3** = later.

### Module A — Service & capture (native)

| ID | Requirement | Pri |
|---|---|---|
| A-01 | Foreground service with `mediaProjection` type (manifest-declared; Android 14 compliant), lifecycle managed start/stop/crash-safe | P0 |
| A-02 | MediaProjection consent bridge via a headless/transparent result Activity, forwarded to service | P0 |
| A-03 | Audio playback capture filtered to `{USAGE_MEDIA, USAGE_GAME, USAGE_UNKNOWN}`; configurable exclusions by package (block-list UI) | P0 |
| A-04 | Downmix/mux to **16 kHz mono PCM16** (chunk-linear resampler, no JNI roundtrips per sample) | P0 |
| A-05 | Mic-fallback capture mode (explicit "Degraded mode" badge in overlay) | P1 |
| A-06 | Compatibility self-check: report currently-playing capturable configurations & likely blockers | P1 |
| A-07 | Robust handling: projection revoked / other app steals capture → clean teardown + user-visible error event | P0 |

### Module B — Processing pipeline (native)

| ID | Requirement | Pri |
|---|---|---|
| B-01 | Lock-free/queued ring buffer (≥ 10 s capacity), drop-oldest with backpressure metric emission | P0 |
| B-02 | Silero VAD (bundled via sherpa-onnx) framing @ 512-sample/16 kHz, threshold 0.5, min speech 200 ms, pad 100 ms, hangover 350 ms | P0 |
| B-03 | Utterance chunking: max 12 s forced split, overlap ≥ 320 ms carried as context-primer | P0 |
| B-04 | sherpa-onnx `OfflineRecognizer` wrapper: model hot-load/unload, task=`translate|transcribe`, language fixed or auto, single-instance mutex + bounded work queue | P0 |
| B-05 | Partial-result behavior: while decoding utterance N, overlay keeps displaying utterance N−1 (stabilized); **true streaming partials from Whisper are not reliable — provide "typing dots + previous line" UX instead**; document deviation from spec honestly | P0 |
| B-06 | Segment timestamps mapped to session timeline (chunk-start offset + per-segment Whisper offsets where available; interpolated otherwise) | P0 |
| B-07 | Adaptive governor: monitor RTF & queue depth → on overload: shorten window budget, downgrade hot model if loaded, or pause with warning chip; battery-low & thermal listeners trigger/cooldown | P1 |
| B-08 | Pause/resume semantics: capture paused → VAD drained → inference queue flushed, session clock accounting excludes pause | P0 |

### Module C — Subtitle engine & overlay (native + shared config)

| ID | Requirement | Pri |
|---|---|---|
| C-01 | Line builder: merge model segments into caption lines (≤ 2 lines × ~42 chars guideline), punctuation-aware, carry partial→final reconciliation by segment id | P0 |
| C-02 | Overlay: `TYPE_APPLICATION_OVERLAY`, FLAG_NOT_FOCUSABLE, drag anywhere, clamp on-screen, persisted position/size | P0 |
| C-03 | Two-state widget: MINIMAL (text only, translucent glass look) ↔ EXPANDED (controls: play/pause, source lang, mode toggle, settings shortcut, stop). Expand on tap; auto-collapse after 3 s inactivity | P0 |
| C-04 | Display styles: font size, opacity, max-lines, alignment, corner radius, text shadow/stroke color (see Part 4 tokens). True cross-window blur is unavailable — emulated glass only; expose "solid backing" accessibility option | P0 |
| C-05 | Bilingual display layout (source above translation) — data always stored; toggle [ships with renderer even if styled minimally] | P1 |
| C-06 | Tap-hold on current subtitle → action sheet: copy, open session at this timestamp | P1 |

### Module D — Sessions & data (Flutter-owned)

| ID | Requirement | Pri |
|---|---|---|
| D-01 | Session entity per §3.5 schema; auto-created on start; title auto-generated (date + languages + first-words heuristic); rename anytime | P0 |
| D-02 | Segments: id, t0/t1, source text, translated text, confidence, language tags; append-only during live, editable after | P0 |
| D-03 | Crash resilience: native-side disk spool (JSONL cache) flushes pending segments to Flutter; reconciliation on relaunch (idempotent upsert by segment id) | P0 |
| D-04 | Session browser: list, sort, filter (lang, date), delete w/ confirm, duplicate, favorite | P0 |
| D-05 | Editor: inline segment editing, merge/split adjacent segments, delete, re-order lock (timestamps preserved) | P1 |
| D-06 | Global search: across sessions, source+translated fields, prefix substring matching, jump-to-context | P1 |
| D-07 | Manual session: title + pasted/typed raw text parsed heuristically into segments (paragraph → segment) | P1 |
| D-08 | Export: TXT, Markdown, JSON, **SRT, VTT** (timestamp-mapped) | P1 |
| D-09 | Share: system share-sheet plain-text/full-file | P1 |
| D-10 | Retention controls: manual delete-all, storage usage meter | P2 |

### Module E — Models

| ID | Requirement | Pri |
|---|---|---|
| E-01 | Registry of curated models (tiny/base int8 default; small for Balanced; medium "Quality" gated with RAM/warning pre-checks) | P0 |
| E-02 | Download with progress, pause/resume, SHA-256 verify, atomic install into `filesDir/models/`; delete/free-space guard | P0 |
| E-03 | Benchmark-lite tab: measured RTF, latency p50, RAM, est. battery/min on THIS device, per model (self-reported stats only, aggregate later opt-in) | P1 |
| E-04 | Hot-swap between downloaded models without service restart | P1 |

### Module F — Languages & modes

| ID | Requirement | Pri |
|---|---|---|
| F-01 | Source selector: Auto + model-supported languages; translation task constrained to English output in V1 (UI copy reflects HT-3) | P0 |
| F-02 | Transcription Mode (source→source captions) | P0 *(cheap, hugely valuable — treat as core)* |
| F-03 | Auto-detect: rely on Whisper per-utterance detection; guardrail = majority-vote smoothing across recent utterances, fallback to last confident lang; if utterance < 1.5 s reuse prior lang | P1 |
| F-04 | Force-source improves reliability banner hint when Auto misfires twice consecutively | P2 |

### Module G — Platform/compliance

| ID | Requirement | Pri |
|---|---|---|
| G-01 | Privacy: zero network egress except model CDN + OS TTS engine; no analytics/crash reporting in OSS builds (opt-in third-party fork pattern documented) | P0 |
| G-02 | Permission pre-flight screen with per-permission state, deep-links to Settings | P0 |
| G-03 | Notification: persistent session notification w/ languages, elapsed time, pause/stop actions; non-spammy updates (≥ 30 s cadence) | P0 |
| G-04 | README honest-compatibility table (apps known blocking capture) — publish early, update with evidence | P0 |

## 2.7 Non-functional requirements

| Area | Requirement |
|---|---|
| Performance | Flagship: RTF ≤ 0.25 · Mid-tier: RTF ≤ 0.6 with Fast model · Queue overflow → governed degradation, never unbounded growth |
| Reliability | Service survives app-process death? — Explicitly **no**: service+engine coexist; on death, safe-save & notify. (Document choice.) |
| RAM | Base-model steady-state ≤ 450 MB; Overlay process cost negligible (single process app) |
| Battery | Governed idle (VAD-only)功耗 negligible; offer "screen-off auto-pause" toggle |
| Privacy | Local-only processing; network allowlist constant reviewed in CI grep |
| Accessibility | WCAG-minded contrast tokens, TalkBack labels on controls, large-font support |
| i18n UI | App strings en/ja/tr/ko scaffolded from day 1 (community translations later) |
| Testing | Golden-audio fixtures (public-domain clips, incl. ja/tr/ko) drive pipeline integration tests; PerfHarness intent for reproducible benchmark runs |

## 2.8 Risks & mitigations (top 6)

| Risk | Sev | Mitigation |
|---|---|---|
| Target apps block capture | High | Compat checker, honest docs, mic fallback, focus marketing on supported apps |
| Mid-tier latency unacceptable | High | Default to tiny/base int8; extenders: schedule workload budget; publish benchmark table per device class |
| Thermal shutdown mid-video | Med | Governor pauses w/ cooldown chip, resume automatically |
| OEM background killing | Med | Battery-exemption wizard, per-OEM instructions (don'tkillmyapp.com references) |
| Whisper hallucination loops on music/noise | Med | VAD gating, max-length guard, repetition-break heuristic, confidence threshold |
| Scope creep toward V2 features | High (you specifically 😄) | This checklist; P2/P3 quarantined to backlog file |

## 2.9 Open questions register

1. Exact Whisper segment-timestamp availability in your pinned sherpa-onnx version → verify in Phase-0.
2. Position persistence: per-display-size buckets or float px? → decide Week 3.
3. Database: Hive-now vs Drift-now → decision rule in §3.5; revisit after perf tests with 5k segments.
4. License final: GPL-3.0 (fights forks-that-strip-privacy) vs Apache-2.0 (max adoption). Recommendation: **GPL-3.0** for consumer privacy app; decide before publishing.

---

# PART 3 — ARCHITECTURE

## 3.1 System overview

```
┌───────────────────────────────────────────────────────────────────────┐
│ ANDROID PROCESS (single app, single Flutter engine)                   │
│                                                                       │
│  ┌─────────────── FLUTTER / DART ───────────────┐                     │
│  │ Dashboard · Sessions · Editor · Search       │                     │
│  │ Model Manager · Settings · Exports           │                     │
│  │ Data layer: Hive/Drift REPOSITORY (owner)    │◄── reconciliation ─┐│
│  └──────▲───────────────────────┬───────────────┘                    ││
│         │ Events (segments,     │ Commands                           ││
│         │ state, perf, errors)  │                                    ││
│  ┌──────┴───────────────────────▼───────────────────────┐            ││
│  │ PLATFORM BRIDGE                                      │            ││
│  │ EventChannel livelens/events                         │            ││
│  │ MethodChannel livelens/control                       │            ││
│  │ MethodChannel livelens/overlay                       │            ││
│  └──────▲───────────────────────────────────▲───────────┘            ││
│         │                                   │                        ││
│  ┌──────┴──────────── KOTLIN CORE ───────────┴─────────────────┐      ││
│  │                                                             │      ││
│  │  ProjectionActivity ─► ProjectionForegroundService          │      ││
│  │        │                       │                            │      ││
│  │        ▼                       ▼                            │      ││
│  │  MediaProjection     CaptureReader (16k mono PCM)           │      ││
│  │                               │                             │      ││
│  │                          RING BUFFER                         │      ││
│  │                               │                              │     ││
│  │                     VAD worker (Silero onnx)                │      ││
│  │                               │ utterances                   │     ││
│  │                    INFERENCE EXECUTOR (mutex, 1 slot)        │     ││
│  │                     sherpa-onnx Whisper (offline)            │     ││
│  │                               │ final segments               │     ││
│  │                      SUBTITLE ENGINE (line builder)          │     ││
│  │                          │             │                      │     ││
│  │                  EventEmitter       DISK SPOOL ──────────────┼─────┘│
│  │              (EventChannel JSONL)   (crash-resilient cache)  │      ││
│  │                                                              │     ││
│  │  OverlayController ◄────────────────────────────────────────┐│      ││
│  │  WindowManager: TYPE_APPLICATION_OVERLAY view tree           │      ││
│  │  NotificationManager (persistent session notification)      │      ││
│  └──────────────────────────────────────────────────────────────┴──────┘│
└───────────────────────────────────────────────────────────────────────┘
        Model files: {filesDir}/models/*.onnx  (download-on-demand, SHA-checked)
```

Key architectural decisions and why:

| Decision | Rationale |
|---|---|
| **Single process** (service hosts inference, Flutter engine lives in same process) | Removes binder/IPCF overhead per segment, simplifies hot-swap; acceptable trade: Flutter UI reload on process death (mitigated by spool reconciliation D-03) |
| **Flutter owns the database; Kotlin owns the audio truth** | One writer per store; Kotlin never depends on Hive; spool is the crash seam |
| **OfflineRecognizer (not streaming) Whisper** | Streaming Whisper via sherpa yields unstable partials; honest UX = previous-line + progress indicator until final (spec deviation consciously accepted — see B-05) |
| **Silero VAD inside sherpa-onnx** | Same runtime dep, better accuracy than WebRTC VAD at music/noise rejection |
| **Governor as separate component** | All degradation policy in ONE place (thermal, battery, RTF, queue depth) — testable independently |

## 3.2 Threading model

```
Thread                    Role                                  Backpressure policy
──────────────────────────────────────────────────────────────────────────────────
main                      Service/UI/events dispatch            n/a
capture-thread(1)         AudioRecord.read → resample → ring    none (producer)
vad-thread(1)             frame scan, utterance assembly        drops oldest if ring full (metric++)
infer-thread(1..2)        sherpa decode, guarded by mutex       bounded queue (depth 3);
                                                                governor reacts when >75% occupancy
spool-writer(1)           serialize pendings to JSONL           coalesce
```

## 3.3 Pipeline details worth locking early

**Resampler:** capture runs at whatever rate AudioRecord gives (typically 48 k). Cheap polyphase-less linear resampler to 16 k is adequate post-VAD; reject any offer to run VAD on 48 k.

**Chunk lifecycle (timeline math):**
```
utterance window: [t_start_pad .. t_end_hangover]
if len > 12s: hard-split at 12s (continuity: carry trailing 320ms primer audio,
                        dedupe on recognition is a P2 nicety — accept rare dupes in V1)
absolute timestamps: seg.t0 = chunk.audioOriginMs + seg.t0_rel
```

**Hallucination guards:** skip inference when VAD speech ratio < 15% and duration < 700 ms; if decoded text appears ≥ 4 times consecutively → mark suspicious, suppress after 8, raise "silent content" hint chip.

**Subtitle Engine rules (deterministic, unit-testable):**
- Merge model micro-segments when gap < 240 ms and combined chars ≤ 84.
- Max dwell: a final line replaces on-screen partials immediately upon arrival.
- Inter-segment gap > 4 s ⇒ clear screen rather than stale subtitle lingering.

## 3.4 Platform-channel contract (implement exactly this — freeze it)

```kotlin
// ---- Methods: MethodChannel("livelens.control") Flutter -> Kotlin ----
StartSession(sourceLang: String?, taskId: "translate"|"transcribe",
             sessionId: String)             // Dart pre-creates session row
Pause(), Resume(), StopSession()
GetCapabilities(): {availableModels[], activeModelId, downloadPath}
LoadModel(modelId): Result<Unit>
RequestOverlayPermission(): Result<Boolean>
IsBatteryExemptionGranted(): Boolean
SetOverlayStyle(style: OverlayStyleJson)    // tokens, live-updated
SaveOverlayPosition(x,y,w,h)
PerformCompatCheck(): [{pkg,label,capturableLikely}]
SetGovernorPrefs(json)
// MediaProjection result arrives OUT OF BAND via activity result ->
// emitted as event ProjectionGranted | ProjectionDenied

// ---- Events: EventChannel("livelens.events") Kotlin -> Flutter ----
{"type":"state","value":"capturing|paused|stopped|error","detail":"..."}
{"type":"partial","sessionId":..,"segId":..,"showHint":true}
{"type":"final","sessionId":..,"segId":..,"t0":..,"t1":..,
 "srcLang":"ja","src":"そろそろ出発したほうがいいと思います。",
 "en":"I think we should leave soon.","conf":0.87}
{"type":"perf","rtfMsPerSec":310,"queueDepth":0,"rssMb":380,
 "batteryPctDropLastPeriod":1.2}
{"type":"spoolPending","count":N}          // after crash relaunch
{"type":"error","code":"CAPTURE_REVOKED|MODEL_LOAD_FAILED|THERMAL_PAUSE|..."}
```

Version the payload: every event carries `"v":1`. Cheap insurance against future-you.

## 3.5 Data schema

```dart
// Session
class Session {
  late String id;            // uuid v7-ish (sortable)
  String title;
  DateTime createdAt;
  DateTime? startedAt, endedAt;
  int durationMsLive;        // excludes pauses
  String srcLang;            // 'auto' resolved -> dominant detected
  String tgtLang;            // 'en' in V1 or equals srcLang for transcription
  String mode;               // 'translate' | 'transcribe'
  bool favorite;
}

// Segment
class Segment {
  late String id;            // stable across reconciliation!
  String sessionId;
  double t0Ms, t1Ms;
  String sourceText;
  String translatedText;     // == sourceText in transcription mode (storage
                             //   duplicates deliberately: keeps editor simple)
  double? confidence;
  String srcLang;
}
```

**Storage decision rule (write this into the repo wiki):**

- **Ship V1 on Hive** with a derived lowercase search index field per segment (tokenized prefix index rebuilt lazily).
- **Trigger to migrate to Drift/SQLite** when ANY of: (a) cumulative segments > 20k, (b) global search p95 > 150 ms, (c) any relational requirement emerges (tagging, linking). Migration exporter stays maintained from day 1 precisely so this swap is cheap.

## 3.6 Overlay implementation notes

- Window: `TYPE_APPLICATION_OVERLAY`, flags `NOT_FOCUSABLE | LAYOUT_NO_LIMITS | WATCH_OUTSIDE_TOUCH`.
- Gestures: pointer-down starts timer; move > touchSlop ⇒ drag mode (persist throttle 500 ms); up-without-drag within 250 ms ⇒ toggle EXPANDED.
- Visual honesty: real background blur of underlying apps is **not possible** from an overlay — emulate “glass” with layered rounded rect: translucent charcoal fill + 1px inner light stroke + subtle vertical white sheen gradient + text shadow. Provide high-contrast "Solid" theme for accessibility.
- Secure flags ignore DRM surfaces: video underneath can render black rectangles for protected layers — document as cosmetic known issue.

## 3.7 Fault-handling matrix

| Failure | Detection | Behavior |
|---|---|---|
| Capture revoked (user taps cast-stop) | `projection.stop` callback | Finalize session cleanly → notification "Session ended – captured until hh:mm" |
| Model OOM mid-session | OutOfMemoryError hook | Switch to smallest loaded model; else paused-state with recoverable banner |
| Thermal severe | PowerManager thermal callback | THERMAL_PAUSE event; auto-resume on return-to-normal (hysteresis 60 s) |
| Process killed | next launch sees spool file | Offer "Recover interrupted session (n segments)" dialog |
| Silence forever | No speech > 10 min | Quiet notification action hint: "Still listening?" (avoids zombie-battery) |

---

# PART 4 — VISUAL TEMPLATE (Design System "Prism")

## 4.1 Direction

Dark-first, glassmorphism accents, engineered calm. The overlay borrows from broadcast subtitles; the app interior feels like a precision instrument, not a toy. Light theme derived (rare but must exist for accessibility).

## 4.2 Color tokens

| Token | Dark | Light | Usage |
|---|---|---|---|
| `bg.canvas` | #0B0C10 | #F7F8FA | Screens |
| `surface.glass` | #16181F @ 82% | #FFFFFF @ 88% | Cards, sheets |
| `surface.glassStroke` | #FFFFFF @ 10% | #000000 @ 6% | Hairlines |
| `accent.primary` | #7C6BFF | #5B48F5 | CTAs, active nav |
| `accent.teal` | #38E1D4 | #0FA396 | Secondary accent, chips |
| `text.primary` | #F2F4F8 | #101216 | Body |
| `text.secondary` | #A6ADBB | #55607A | Meta |
| `semantic.warn` | #FFB65C | #B25E00 | Degraded-mode chips |
| `semantic.danger` | #FF5C77 | #C21833 | Stop actions |
| `overlay.scrim` | #000000 @ 55% | — | Behind modal sheets |

Accent pair (#7C6BFF→#38E1D4) reserved for gradients: primary CTA border, onboarding hero, model-progress rings. Nothing else gradients — restraint sells the glass.

## 4.3 Typography

- Family: **Manrope** (latin) with **Noto Sans JP/KR** fallback — non-negotiable for your ja/ko content screens; Turkish = latin ext.
- Scale: Display 32/40 · H1 24/32 · H2 20/28 · Body 15/22 · Meta 12/16 Medium caps · Code/mono: JetBrains Mono (timestamps only).

## 4.4 Shape & motion

Radius: xs 8 · sm 14 · md 20 · xl 28 · pill 999. Spacing 4-pt grid. Motion: 150 ms ease-out (chips/controls), 260 ms emphasized (sheets), overlay collapse after 3 s idle = 300 ms fade+scale .98.

## 4.5 Signature components

- **GlassCard** — surface.glass fill, stroke hairline, top-edge 1px sheen highlight, corner md.
- **PrimaryAction** — filled accent, subtle outer glow `0 0 24 primary@25%`, label semibold.
- **LangChip / ModeChip** — pill outline; active = teal tint.
- **ProgressRing** — model download & RTF gauge reuse (RTF ring: green<0.4 amber<0.8 red).
- **SpecSheet row** (settings) — icon, title, meta-right value, chevron.
- **SegmentRow** (editor/list) — leading timestamp mono chip, stacked text with hierarchy via weight not color-only (a11y).

## 4.6 Wireframes

**Dashboard**
```
┌──────────────────────────────┐
│ LiveLens          ⚙ 🔍       │  ← appbar, ghost buttons
│  ▢ Ready for Japanese media? │
│  ● ● Permission & model OK   │  ← preflight strip: green checks /
│                               │    amber links to wizard
│      ╭──────────────────╮    │
│      │  ▶ START TRANSLATION │   │  ← hero CTA (gradient border)
│      ╰──────────────────╯    │
│  Source: JA  Mode: Translate │  ← quick chips (persistent defaults)
│  Model: Base · Fast  ▪▪▪▫▫ 96fps-test │
│ ─ Recent sessions ──────────  │
│ ▸ NHK Evening News · Apr 12   │
│ ▸ Reels marathon · Apr 12     │
│ [ + Manual session ]          │
└──────────────────────────────┘
```

**Onboarding wizard (swipe pages):** hero illustration → “Why local?” privacy manifesto card → step list (Overlay / Notifications / Battery exemption / Projection explained as “appears like casting — normal, one-time-ish”)

**Model manager**
```
MODEL MANAGER            Storage used 0.6 GB
● Whispertiny — FAST      158 MB · installed [ACTIVE]
   ja·ko·tr·es … → en   RTF on this device 0.21
● Whisper base — BALANCED 182 MB [ Download ▸ 64%  ◖◖◖◻◻ ]
● Whisper small — QUALITY  480 MB · needs ~1.2 GB RAM ⚠ View device check
```

**Session detail (viewer/editor)** — session header (title, lang pair, duration, export icon menu) → sticky search bar → virtualized segmented list:
```
│ 00:31.2 ─────── JA → EN ───────────── ⋮ │
│ そろそろ出発したほうがいいと思います。        │
│ I think we should leave soon.             │
│───────────────────────────────────────────│
```
Tap segment → bottom sheet: Edit / Copy source / Copy translation / Merge ↑ / Split / Delete / Jump replay marker (future).

**Export sheet:** tabs TXT MD SRT VTT JSON · filename preview · include-timestamps toggle · Share | Save-to-Files.

**Settings groups:** Appearance / Overlay behaviour (idle timeout slider 0–10 s) / Languages & defaults / Models / Battery & thermal (governor prefs) / Privacy statement card / About-Licenses.

**Overlay widget (the crown jewel)**
```
MINIMAL (idle >3s)            EXPANDED (active)
┌───────────────────────┐     ┌────────────────────────────────────┐
│ I think we should go  │     │ ...we should go tomorrow.      ▪ Drag handle
│ tomorrow.             │     └──[⏸][JA▾][TR↦EN][⚙][✕]─────────────┘
└───────────────────────┘      controls fade-in only when touched
   translucent glass fill, 1px stroke, 20px radius, max-width 78%
```
States chips overlay-top-left: `⏸ Paused` · `🌡 Cooling down` · `🔋 Low battery mode`.

---

# PART 5 — EXECUTION CHECKLIST (Phased)

Legend: `[S]` = riskiest assumptions, retire FIRST · everything else executes in order.

## Phase 0 — Technical spike & gates (Weeks 1–2)
- [ ] [S] Standalone Kotlin repo: MediaProjection consent → capture wiring (A-01,A-02)
- [ ] [S] Playback capture from YouTube/VLC → raw dump sanity (A-03)
- [ ] [S] Resample to 16k mono path verified by writing WAV and spectrogram-eye-check (A-04)
- [ ] [S] sherpa-onnx loads tiny+base int8; decode a 10 s WAV via task=translate (ja) & transcribe
- [ ] [S] Silero VAD wired; tune params on 5 golden clips (en/ja/tr/ko/music)
- [ ] [S] Measure & log RTF / RSS / battery on flagship + mid-tier → compare vs Gate (§1.6)
- [ ] [S] Confirm timestamp extraction ability in pinned sherpa-onnx build; else adopt interpolation plan (OpenQ 1 resolved)
- [ ] Write spike findings into `docs/spike-report.md` → **GO / NO-GO decision recorded**

## Epic 1 — Foundations
- [ ] Monorepo: `android/` kotlin module + flutter shell, CI (format, analyze, assemble debug, `network-permission grep` guard per G-01)
- [ ] Freeze platform-channel contract (§3.4) in `docs/contract.md` + typed Dart DTOs
- [ ] Repo hygiene: LICENSE (decision §2.9), README skeleton w/ compatibility-disclaimer (G-04)
- [ ] Design tokens implemented in Flutter theme (Part 4), fonts bundled incl. Noto JP/KR subsets

## Epic 2 — Service, permissions, capture (productionize spike)
- [ ] Foreground service (`mediaProjection` type) lifecycle + crash-safe stops (A-01)
- [ ] Headless result-activity → consent bridge (A-02)
- [ ] Package exclusion filter + settings persistence (A-03)
- [ ] Production resampler with property-based tests (A-04)
- [ ] Persistent session notification + actions (G-03)
- [ ] Permissions pre-flight VM + Settings deep-links (G-02), battery-exemption helper (OEM guide screen)
- [ ] Error taxonomy implemented (§3.7 matrix fully coded)

## Epic 3 — Pipeline (production)
- [ ] Ring buffer + backpressure metrics (B-01)
- [ ] VAD worker + utterance assembler + hangover logic (B-02)
- [ ] 12 s splitter + primer-overlap (B-03)
- [ ] Inference executor, mutex, bounded queue, shutdown-drain (B-04)
- [ ] Pause/Resume draining semantics + duration-clock correctness (B-08)
- [ ] Subtitle line-builder + segment merge/clear rules w/ golden tests (C-01)
- [ ] Timestamp normalization to session timeline (B-06)
- [ ] Hallucination/silence guards (B-04b)
- [ ] Governor: RTF monitor, thermal listener, battery listener, policy table (B-07)
- [ ] Disk spool JSONL + recovery emitter (feeds D-03)

## Epic 4 — Overlay
- [ ] Overlay view tree, style ingestion from Dart (C-02,C-04)
- [ ] Gesture engine: drag/tap/distinct-times, clamping, pos persistence (C-02)
- [ ] Minimal/Expanded states + 3 s idle collapse timer (C-03)
- [ ] Status chips (paused/thermal/battery) rendering
- [ ] Long-press action sheet v1 (copy current line) (C-06)

## Epic 5 — Flutter app & sessions
- [ ] Routing + navigation shell (go_router)
- [ ] Hive adapters, repositories, migrations policy (D-01/D-02)
- [ ] EventChannel → StreamController façade, reconciliation importer (D-03)
- [ ] Session lifecycle FSM mirrored in Dart state
- [ ] Dashboard screen per wireframe, preflight strip binding
- [ ] Session browser: list/filter/delete/duplicate/favorite (D-04)
- [ ] Editor: inline edit, merge/split, delete (D-05)
- [ ] Global search incl. index rebuild maintenance (D-06)
- [ ] Manual-session creator + naive parser (D-07)
- [ ] Export writers (TXT/MD/JSON/SRT/VTT) + SRT regression fixtures (D-08)
- [ ] Share intents (D-09)
- [ ] Settings: appearance/overlay/langs/governor bindings live-push to native

## Epic 6 — Models
- [ ] Registry format + built-in catalog entries (E-01)
- [ ] Download manager: resume, sha256, atomic swap, space-guard (E-02)
- [ ] Load/unload + validation banner (capabilities matrix per model)
- [ ] Benchmark-lite: scripted harness + Results tab (E-03)
- [ ] Hot-swap path (E-04)

## Epic 7 — Language features
- [ ] Source selector UI respecting model capability + HT-3 copy (F-01)
- [ ] Transcription mode end-to-end incl. session metadata (F-02)
- [ ] Auto-detect smoothing + confidences persisted (F-03)

## Epic 8 — QA & release engineering
- [ ] Golden-audio integration suite (CI on emulator w/ SD-855 profile; nightly)
- [ ] Perf instrumentation dashboards (firebase-free: local logs → markdown diff job)
- [ ] Device matrix passes: Pixel6 (13), S10 (12), Redmi Note 9 (11), +1 unknown OEM runner-up (HT-5 soak: 45-min session each)
- [ ] Accessibility audit: TalkBack traversal, contrast tokens, "Solid" overlay theme
- [ ] Demo script + GIF/screenrecording assets for README
- [ ] Docs: privacy.md (data-flow diagram §3.1 reused!), troubleshooting (OEM killer steps), contributing.md
- [ ] Signed release workflow, GitHub Releases w/ APK + checksums; F-Droid metadata draft

## Post-V1 backlog stubs (quarantined, do-not-touch yet 🙂)
- [ ] V2: bilingual renderer upgrade, TTS, vocab extractor, local MT cascade for non-en targets, streaming-zipformer partial-proxy mode, aggregate anonymous benchmarks (opt-in telemetry = opt-in binary flavor)

---

# Your next two weeks (concrete)

| Days | Work |
|---|---|
| 1–2 | Repo setup, license decision, channel contract frozen |
| 3–7 | Phase-0 spike: capture + resample + WAV dump proof |
| 8–12 | sherpa integration in spike; VAD tuning; collect golden clips |
| 13–14 | Run gates, write `spike-report.md`, make the GO call publicly (GitHub Discussion post — good early-community move) |

If the gate numbers hold, everything downstream is mostly disciplined grinding; if they don't, you've spent two weeks saving yourself four months.

---

Want me to follow up with the actual starter code? Natural next increments: **(1)** the Phase-0 Kotlin spike (service + capture + WAV dump, ~300 LOC), **(2)** the frozen channel-contract + typed Dart DTO scaffolding, or **(3)** the Hive schema + repositories with the recovery-importer. Say which and I'll generate it production-grade, commented, CI-ready.