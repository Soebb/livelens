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
