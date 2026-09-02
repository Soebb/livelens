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
