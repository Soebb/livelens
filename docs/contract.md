# LiveLens Platform-Channel Contract (FROZEN — v1)

> **Status:** Frozen per Epic 1. This file is the single source of truth for the
> Kotlin ⇄ Dart seam. Any change requires bumping the contract version and
> updating both implementations *and* their conformance tests in the same commit.
>
> Source of authority: `Documentation/architecture.md` §3.4. This document
> restates it in wire-exact form and closes previously-open details (casing,
> error registry, capability schema). Deviations are listed in §7.

## 0. Versioning

- Every **event** payload carries `"v": 1` (integer, major version only).
- Receivers MUST ignore (skip, never crash) events whose `v` they do not
  understand, and SHOULD log them at debug level.
- Additive changes within v1: new optional keys, new event types (receivers
  skip unknown types), new error codes (parse to `UNKNOWN`).
- Breaking changes ⇒ `v: 2`, shipped behind a capability handshake.

## 1. Channels

| Channel | Kind | Direction |
|---|---|---|
| `livelens/control` | MethodChannel | Flutter → Kotlin |
| `livelens/events` | EventChannel | Kotlin → Flutter |
| `livelens/overlay` | MethodChannel | **RESERVED — unused in v1** |

`livelens/overlay` appears in the architecture diagram but not in §3.4's
method list. Decision: all overlay operations (style, position) travel on
`livelens/control` exactly as §3.4 specifies. The overlay channel stays
reserved until a concrete need (e.g. overlay→Flutter RPC) is demonstrated.
Do not register a handler for it in v1.

## 2. MethodChannel `livelens/control`

Method names on the wire are **lowerCamelCase** (§3.4 signatures are
prose-style; casing is pinned here). All argument envelopes are JSON maps.
Errors are signalled with `PlatformException(code: <ERROR_CODE>)` using the
registry in §4; success returns the documented value.

### 2.1 Session lifecycle

```text
startSession
  args: { "sourceLang": String|null,      // BCP-47-ish short code or null = auto
          "taskId": "translate"|"transcribe",
          "sessionId": String }           // Dart pre-creates the session row
  returns: void
  errors: MODEL_MISSING, CAPTURE_INIT_FAILED, INTERNAL_ERROR

pause    args: {}  returns: void
resume   args: {}  returns: void
stopSession args: {}  returns: void
```

Semantics (B-08): `pause` drains VAD then flushes the inference queue before
acknowledging; session clock excludes paused spans. MediaProjection consent is
NOT requested by `startSession` itself — see §5 out-of-band flow.

### 2.2 Models & capabilities

```text
getCapabilities
  args: {}
  returns: {
    "activeModelId": String|null,
    "downloadPath": String,
    "availableModels": [ {
      "id": String,             // stable slug, e.g. "whisper-tiny-int8"
      "label": String,          // display name
      "tier": "fast"|"balanced"|"quality",
      "sizeBytes": int,
      "installed": bool
    }, ... ]
  }
  // Additive-only: new optional keys may appear inside this object.

loadModel
  args: { "modelId": String }
  returns: void                       // Result<Unit> => success or PlatformException
  errors: MODEL_MISSING, MODEL_LOAD_FAILED, INTERNAL_ERROR

setGovernorPrefs
  args: { "screenOffAutoPause": bool,
          "batteryLowThresholdPct": int,     // 0..100
          "thermalHysteresisMs": int,
          "inferenceQueueDepth": int }       // bounded-queue depth, default 3
  returns: void
  // Extensible map: unknown keys are ignored by native (forward compat).
```

### 2.3 Permissions & compatibility

```text
requestOverlayPermission
  args: {}
  returns: bool   // CURRENT grant state (Settings.canDrawOverlays).
                  // If not granted, native deep-links to the Settings page;
                  // the user's eventual grant/deny is observed by re-querying,
                  // not by this return value. Honest sync semantics.

isBatteryExemptionGranted
  args: {}
  returns: bool   // PowerManager.isIgnoringBatteryOptimizations(packageName)

performCompatCheck
  args: {}
  returns: [ { "pkg": String, "label": String, "capturableLikely": bool }, ... ]
```

### 2.4 Overlay configuration

```text
setOverlayStyle
  args: { "fontSizeSp": double,             // default 18
          "backgroundOpacity": double,      // 0..1, default 0.82 (surface.glass)
          "maxLines": int,                  // default 2
          "textAlign": "left"|"center"|"right",   // default "center"
          "cornerRadiusPx": double,         // default 20 (radius md)
          "textShadowArgb": int,            // default 0xFF000000
          "theme": "glass"|"solid",         // default "glass"; solid = a11y
          "showBilingual": bool,            // default false (data always stored)
          "idleCollapseSeconds": int,       // 0..10, default 3
          "maxWidthFraction": double }      // 0..1 of display width, default 0.78
  returns: void   // applied live to a running overlay; safe when idle

saveOverlayPosition
  args: { "x": double, "y": double, "w": double, "h": double }  // px, clamped
  returns: void   // persisted by native; throttle ≤ 1 call / 500 ms (caller-side)
```

## 3. EventChannel `livelens/events`

JSON maps, one per message, always carrying `"type"` and `"v": 1`.
The exact §3.4 samples are reproduced verbatim in the conformance tests
(`test/bridge/event_codec_test.dart`) and MUST continue to decode.

```text
{ "type":"state", "v":1, "value":"capturing|paused|stopped|error", "detail":"..." }

{ "type":"projectionGranted", "v":1 }        // out-of-band MediaProjection result
{ "type":"projectionDenied",  "v":1 }

{ "type":"partial", "v":1, "sessionId":"…", "segId":"…", "showHint":true }
// "partial" means: utterance N is decoding; overlay keeps showing N−1 plus a
// typing-dots hint (B-05 honest UX). It carries NO text by design.

{ "type":"final", "v":1, "sessionId":"…", "segId":"…",
  "t0":1234.5, "t1":5678.0,                 // ms, session timeline (B-06)
  "srcLang":"ja",
  "src":"そろそろ出発したほうがいいと思います。",
  "en":"I think we should leave soon.",
  "conf":0.87 }
// Key "en" is the frozen wire name for the translated text. In transcription
// mode "en" duplicates "src" (storage mirrors this deliberately, §3.5).

{ "type":"perf", "v":1, "rtfMsPerSec":310, "queueDepth":0,
  "rssMb":380.0, "batteryPctDropLastPeriod":1.2 }

{ "type":"spoolPending", "v":1, "count":N }  // crash-relaunch recovery prompt (D-03)

{ "type":"error", "v":1, "code":"CAPTURE_REVOKED", "detail":"…" }
```

Unknown `type` ⇒ receiver skips silently (debug-log). Known `type` with a
malformed shape ⇒ receiver throws `MalformedEventException` (bug, not data).

## 4. Error-code registry (closed for v1)

Wire strings are UPPER_SNAKE. Dart parses unknown codes to `unknown`.

| Wire code | Meaning | Raised by |
|---|---|---|
| `CAPTURE_REVOKED` | User stopped projection (cast-stop) mid-session | events |
| `PROJECTION_DENIED` | Consent dialog denied/cancelled | events |
| `CAPTURE_INIT_FAILED` | AudioPlaybackCapture setup failed | startSession, events |
| `AUDIO_RECORD_FAILED` | Mic-fallback record init failed | startSession, events |
| `MODEL_MISSING` | Referenced model not installed | startSession, loadModel |
| `MODEL_LOAD_FAILED` | sherpa-onnx init failed (corrupt/OOM) | loadModel, events |
| `THERMAL_PAUSE` | Severe thermal; auto-resume after hysteresis | events |
| `BATTERY_PAUSE` | Battery-low governor pause | events |
| `QUEUE_OVERLOAD_PAUSED` | Governor gave up downgrading; paused w/ chip | events |
| `INTERNAL_ERROR` | Unexpected native failure (detail required) | everywhere |
| `unknown` | Receiver-side fallback for unrecognized codes | (Dart only) |

## 5. MediaProjection flow (out-of-band, per §3.4)

1. Flutter calls `startSession`.
2. Native launches the transparent consent activity if no active projection.
3. Result arrives via activity callback → native emits
   `projectionGranted` / `projectionDenied` **on `livelens/events`**, never as a
   method-call return.
4. On granted: FGS starts, `state:"capturing"` follows.
5. On denied: `state:"error"` + `error.code=PROJECTION_DENIED`; session row is
   finalized by Dart as failed-empty.

## 6. Conformance

- Dart side: `test/bridge/*` — every §3.4 sample decodes; round-trips hold;
  malformed shapes throw; control channel emits exact method/arg pairs.
- Kotlin side (Epic 2): a mirror suite asserting the same fixtures.
- CI greps for `android.permission.INTERNET` outside the model-downloader
  module (G-01 privacy guard).

## 7. Deliberate deviations / closures vs §3.4 prose

| Item | §3.4 said | Frozen decision |
|---|---|---|
| Method casing | unspecified | lowerCamelCase wire names |
| Error codes | `"CAPTURE_REVOKED\|MODEL_LOAD_FAILED\|THERMAL_PAUSE\|…"` open-ended | Closed registry above; unknown→`unknown` |
| `GetCapabilities` models[] | unspecified shape | Schema in §2.2, additive-only |
| `RequestOverlayPermission(): Result<Boolean>` | ambiguous async | Returns current grant state; deep-links if absent (§2.3) |
| `SetGovernorPrefs(json)` | free-form json | Typed map, unknown keys ignored |
| `livelens/overlay` channel | in diagram, not in §3.4 | Reserved, unregistered in v1 |
| `partial` payload | `"showHint":true` shown, text implied | Text explicitly excluded (B-05 honesty) |
| Projection result | "out of band" | Pinned to named events on `livelens/events` (§5) |