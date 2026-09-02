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

## Epic 1 — Foundations ✅ COMPLETE
- [x] Monorepo: `android/` kotlin module + flutter shell, CI (format, analyze, assemble debug, `network-permission grep` guard per G-01)
  - [x] Flutter shell + `android/` Kotlin module scaffolded (`dev.livelens.livelens`)
  - [x] CI pipeline: `.github/workflows/ci.yml` — dart format check · analyze --fatal-infos · test · G-01 privacy guard (INTERNET-permission grep + network-code grep). *Assemble-debug job deferred until Epic 2 adds native code worth compiling.*
- [x] Freeze platform-channel contract (§3.4) in `docs/contract.md` + typed Dart DTOs
  *(DONE — Chunk 1: wire-exact contract incl. closed error-code registry & deviation table; sealed Dart event model, defensive codec, typed control/events wrappers, DTOs; conformance tests passing)*
- [x] Repo hygiene: LICENSE (decision §2.9), README skeleton w/ compatibility-disclaimer (G-04)
  - [x] GPL-3.0 LICENSE (per §2.9 recommendation); README w/ honest compatibility table, latency expectations, status matrix
- [x] Design tokens implemented in Flutter theme (Part 4), fonts bundled incl. Noto JP/KR subsets
  - [x] Tokens + ThemeData (dark/light) + signature components (GlassCard, PrimaryAction, LangChip/ModeChip, ProgressRing w/ RTF thresholds, SpecSheetRow, SegmentRow) — Chunk 2
  - [x] WCAG contrast test suite (incl. documented light-teal ≈2.95:1 known measurement; onPrimary ink chosen per-theme for AA)
  - [x] Fonts bundled: Manrope + NotoSansJP (variable TTFs) + JetBrainsMono registered under PrismFontFamilies names

## Epic 2 — Service, permissions, capture (productionize spike)
*✅ COMPILE CHECK PASSED: `:app:compileDebugKotlin` + `assembleDebug` BUILD SUCCESSFUL (debug APK ~325 MB incl. bundled whisper-base + sherpa-onnx jniLibs), `flutter analyze` clean, all 85 Dart + Kotlin unit tests green. Fixes en route: MainActivity EventChannel sink → `EventEmitter.Sink` object (SAM inference), prefs via `context.getSharedPreferences`, `AudioAttributes.USAGE_*` constants. ⚠ machine-local: pub-cached `share_plus-12.0.2/android/build.gradle` classpath aligned to AGP 8.7.3/Kotlin 2.1.0 (its stock 8.12.1/Kotlin 2.2.0 deps unobtainable on this network); CI with normal networks unaffected. Kotlin daemon disabled on this machine (`kotlin.compiler.execution.strategy=in-process` in gradle.properties).*
*✅ BUILT-IN MODEL ENGINE WIRED: sherpa-onnx v1.13.6 (official prebuilt `.so` for arm64-v8a/x86_64 vendored into `app/src/main/jniLibs`, Kotlin API sources vendored under `com.k2fsa.sherpa.onnx`) + bundled `assets/sherpa-onnx-whisper-base/` (encoder/decoder int8 + tokens). `SherpaWhisperTranscriber` copies assets → `filesDir/models/whisper-base/` on first load, wraps `OfflineWhisperModelConfig`; `ModelRegistry` hot-load (idempotent, off-main-thread) implements contract §2.2 `loadModel` (codes `MODEL_MISSING`/`MODEL_LOAD_FAILED`) and `getCapabilities.models`; CaptureEngine injects registry engine, Noop fallback pre-load. Kotlin smoke compile + all suites green after wiring.*
- [x] Foreground service (`mediaProjection` type) lifecycle + crash-safe stops (A-01)
  *(CaptureService.kt — guarded onStartCommand with stopCleanly fallback, onTaskRemoved stops zombie capture, START_NOT_STICKY; A-03 usage filter {MEDIA,GAME,UNKNOWN} present in CaptureEngine config; CaptureFilterPrefs persists pkg block-list for the layers that can honor it)*
- [x] Headless result-activity → consent bridge (A-02)
  *(ProjectionActivity.kt — transparent consent → startForegroundService(ACTION_START), denial → `projectionDenied` event)*
- [x] Package exclusion filter + settings persistence (A-03)
  *(CaptureFilterPrefs.kt — SharedPreferences block-list; usage-type filter in AudioPlaybackCaptureConfiguration)*
- [x] Production resampler with property-based tests (A-04)
  *(LinearResampler.kt — stateful chunk-linear; bit-exact chunked==single-shot; identity passthrough; 5 unit tests)*
- [x] Persistent session notification + actions (G-03)
  *(CaptureService.kt — low-importance FGS channel, pause/resume + stop PendingIntents, paused-state text, setOnlyAlertOnce)*
- [x] Permissions pre-flight VM + Settings deep-links (G-02), battery-exemption helper (OEM guide screen)
  *(Dart VM done: AppController `runPreflight` (passive: `isBatteryExemptionGranted` probe + `performCompatCheck` → compatRows, errors land in `preflightError`, never fatal) + user-initiated `checkOverlayPermission`/`openBatteryExemptionSettings` (both deep-link to system Settings when ungranted — contract §2.2 "never auto-prompt"); Dashboard `PreflightStrip`/`_PreflightRow` rows with fix actions; wired into `MainActivity` handlers. NOTE: battery "OEM guide screen" v1 = direct ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS deep-link; richer per-OEM instructions screen deferred)*
- [x] Error taxonomy implemented (§4 registry fully coded; §3.7 governor matrix wired)
  *(CaptureEngine emits only registry codes — `CAPTURE_REVOKED`, `INTERNAL_ERROR`, `QUEUE_OVERLOAD_PAUSED`, `THERMAL_PAUSE`, `BATTERY_PAUSE`, `CAPTURE_INIT_FAILED`/`AUDIO_RECORD_FAILED` split by capture mode; shared `handleDecision()` + `governorPaused` latch with `RESUME_FROM_THERMAL` auto-resume after hysteresis; manual pause clears the latch)*
- [x] Mic-fallback capture mode (A-05) + §3.7 thermal/silence governor inputs
  *(CaptureEngine `CaptureMode{PROJECTION,MIC}` — mic path builds `AudioRecord` from mic source; `GovernorInputs.kt` — `ThermalLevels` (PowerManager status → governor level) + `SilenceWatch` (10-min single-shot hint, re-armed by speech, `reset()`); engine `applyPrefs()` reads `GovernorPrefsStore` (queue depth, hysteresis, battery threshold, screenOffAutoPause) and `applyGovernorTick()` samples thermal/battery/screen ~every 30 s (GOVERNOR_TICK_HOPS=120); CaptureService `EXTRA_MIC_MODE` + FGS type `mediaProjection|microphone` on API 34+, `onSilenceHint` updates the FGS notification ("Still listening?" nudge — no new §3 event, frozen set); manifest `RECORD_AUDIO` + `FOREGROUND_SERVICE_MICROPHONE` (mic-only, still no INTERNET); MainActivity `mode:"mic"` startSession bypasses consent with RECORD_AUDIO runtime-permission flow (`AUDIO_RECORD_FAILED` on denial) and reuses the Dart FSM's granted transition (documented deviation); Dart: `startSession(micFallback:)` additive param + `openBatterySettings()`)*

*✅ CHUNK (A-05/G-02/§3.7/§4) VERIFIED: `:app:compileDebugKotlin` + `:app:assembleDebug` BUILD SUCCESSFUL, `dart analyze` clean, all 85 `flutter test` green. This chunk aligned native error emissions to the §4 registry, added mic fallback end-to-end (native + bridge), §3.7 governor inputs, silence nudge, and fixed `getCapabilities` to the §2.2 frozen shape (`{activeModelId, downloadPath, availableModels}` — additive extras kept).*

## Epic 3 — Pipeline (production)
- [x] Ring buffer + backpressure metrics (B-01)
  *(PcmRingBuffer.kt — drop-oldest, droppedSamples governor metric; 6 unit tests)*
- [x] VAD worker + utterance assembler + hangover logic (B-02)
  *(Silero VAD bundled: `assets/sherpa-onnx-silero-vad/silero_vad.onnx` (629 KB, byte-verified vs official release) + vendored `Vad.kt`; VadWorker.kt — 512-sample framing, threshold 0.5, min speech 200 ms, minSilence 350 ms (hangover), 100 ms pad via pure-Kotlin UtteranceAssembler.kt (pre/post pad, stream-start clamp, silence pre-roll trim, absolute-sample origins; 6 unit tests); engine pipeline thread now VAD-driven instead of fixed 4 s windows)*
- [x] 12 s splitter + primer-overlap (B-03)
  *(UtteranceSplitter.kt — hard-split @12s, 320ms primer carried into continuations, origin includes primer for honest B-06 mapping; 5 tests)*
- [x] Inference executor, mutex, bounded queue, shutdown-drain (B-04)
  *(InferenceExecutor.kt — single worker thread (sherpa thread-confinement), capacity-2 bounded queue, drop-newest + droppedChunks counter, warm-up-before-decode, shutdown-drain with interrupt fallback; Governor now fed real queueDepth; 4 unit tests)*
- [x] Pause/Resume draining semantics + duration-clock correctness (B-08)
  *(SessionClock.kt — segment model excludes paused spans, idempotent pause/resume/stop, stop-while-paused ends at pause point; 7 tests)*
- [x] Subtitle line-builder + segment merge/clear rules w/ golden tests (C-01)
  *(SubtitleLineBuilder.kt — 240ms/84-char merge, punctuation-aware incl. CJK terminals, 4s clear; 9 golden tests)*
- [x] Timestamp normalization to session timeline (B-06)
  *(ChunkTimeline.kt — absolute mapping `origin+rel` with clamping AND length-proportional interpolation fallback for OpenQ 1; 4 tests)*
- [x] Hallucination/silence guards (B-04b)
  *(HallucinationGuard.kt — silence skip (<15% speech AND <700ms), repetition ladder 4→suspicious / 8→suppress+chip; 7 tests)*
- [x] Governor: RTF monitor, thermal listener, battery listener, policy table (B-07)
  *(Governor.kt — thermal SEVERE latch w/ 60s hysteresis, battery latch w/ auto-recover, overload→downgrade→pause ladder, strain→shorten-window, screen-off pref; 8 tests)*
- [x] Disk spool JSONL + recovery emitter (feeds D-03)
  *(SegmentSpool.kt — append-only JSONL matching contract §3 `final` shape, torn-line tolerance, markImported truncation, pendingCount for spoolPending event; 8 tests)*

## Epic 4 — Overlay
- [x] Overlay view tree, style ingestion from Dart (C-02,C-04)
  *(OverlayController.kt hosted by CaptureService — glass card (GradientDrawable #16181F@opacity, 1px hairline stroke, radius from style), chips row + source line + main line; OverlayStyle.kt parses §2.4 wire with contract defaults, OverlayStore persists style/position in SharedPreferences; `setOverlayStyle`/`saveOverlayPosition` handlers live in MainActivity, applied live + safe when idle; `solid` theme = high-contrast a11y backing)*
- [x] Gesture engine: drag/tap/distinct-times, clamping, pos persistence (C-02)
  *(touch-slop-gated drag moves the TYPE_APPLICATION_OVERLAY window, clamped to display metrics (R+ maximumWindowMetrics); position persisted ≤1 write/500ms plus final save on release (§2.4 throttle); restored on re-attach; tap toggles states; window stays NOT_FOCUSABLE)*
- [x] Minimal/Expanded states + 3 s idle collapse timer (C-03)
  *(idleCollapseSeconds from §2.4 (0 = off); Handler timer resets on every line update/tap; collapse = 300 ms fade+scale .98 per visual.md §4.4; new text auto-expands)*
- [x] Status chips (paused/thermal/battery) rendering
  *(warn-tinted pills top-left: ⏸ Paused / 🌡 Cooling down / 🔋 Low battery; CaptureEngine gained additive onOverlayChip callback — manual/overload→"paused", THERMAL_PAUSE→"thermal", BATTERY_PAUSE→"battery", resume clears)*
- [x] Long-press action sheet v1 (copy current line) (C-06)
  *(600 ms long-press → current on-screen line to ClipboardManager + Toast "Line copied"; no focusable dialog needed since window stays NOT_FOCUSABLE; feed via engine onOverlayText → SubtitleLineBuilder merge rules C-01; hidden when SYSTEM_ALERT_WINDOW not granted — session continues)*

## Epic 5 — Flutter app & sessions
- [x] Routing + navigation shell
  *(Done — inline nav shell in `main.dart`: IndexedStack Dashboard/Sessions/Search/Settings with Prism-styled NavigationBar; go_router deliberately deferred — 4 flat tabs don't justify the dependency, EditorScreen pushed via Navigator)*
- [x] Hive adapters, repositories, migrations policy (D-01/D-02)
  *(models.dart §3.5 schema + searchIndex; SessionRepository CRUD/rename/favorite/duplicate; SegmentRepository append/upsert/updateText/search; 13 tests)*
- [x] EventChannel → StreamController façade, reconciliation importer (D-03)
  *(events_channel.dart façade from Chunk 1; ReconciliationImporter replays spool JSONL via EventCodec, idempotent upsert by segId, malformed counted not fatal)*
- [x] Session lifecycle FSM mirrored in Dart state
  *(AppController: LivePhase enum {idle,starting,capturing,paused,stopped,error} + phaseDetail, wired to typed events via injectable `eventStream` — start/pause/resume/stop call LivelensControl, final/partial events update live caption state)*
- [x] Dashboard screen per wireframe
  *(DashboardScreen: live phase chip, bilingual live-caption GlassCard, PrimaryAction, PreflightStrip w/ G-02 checks + fix actions; start action uses the persisted default source language)*
- [x] Session browser: list/delete/favorite (D-04)
  *(SessionsScreen: newest-first cards, favorite toggle, delete w/ confirm, All/Favorites filter chips; duplicate in SessionRepository)*
- [x] Editor: inline edit, rename, favorite (D-05)
  *(EditorScreen: editable bilingual SegmentRows saved on change, tap-to-rename title, export entry, per-segment overflow menu — merge with next (repository `mergeWithNext`) and split at midpoint (`splitSegment`))*
- [x] Global search incl. index maintenance (D-06)
  *(SearchScreen: live prefix search across source+translated via SegmentRepository.search on searchIndex; ⚠ full index-rebuild maintenance routine still TODO)*
- [x] Manual-session creator + naive parser (D-07)
  *(ManualSessionParser — blank-line paragraph split, sentence subdivision >200 chars at CJK/Latin terminators, synthetic reading-pace timestamps w/ 1.5 s floor; ManualSessionCreator — mode:'manual' row, translated==source convention, complete-at-creation lifecycle; 12 tests incl. export-to-SRT integration)*
- [x] Export writers (TXT/MD/JSON/SRT/VTT) + SRT regression fixtures (D-08)
  *(SessionExporter — pure functions, time-ordered always, include-timestamps toggle for TXT/MD, SRT/VTT spec-compliant (comma vs dot ms), JSON full structure; 8 tests incl. SRT regression fixtures)*
- [x] Share intents (D-09)
  *(EditorScreen export sheet: "SHARE" uses share_plus `SharePlus.instance.share(ShareParams(text, subject))` with rendered TXT/MD/SRT/VTT/JSON output; copy-to-clipboard fallback)*
- [x] Settings: appearance/overlay/langs/governor bindings live-push to native
  *(appearance — themeMode light/dark/system — persisted; `_OverlaySettingsCard` (font size/opacity/idle-collapse sliders, maxLines & theme SegmentedButtons, bilingual switch), `_GovernorSettingsCard` (screenOffAutoPause, battery %, queue depth), `_LangsSettingsCard` (source-language dropdown → default for Dashboard start; HT-3 target fixed en). Every change: persist in Hive prefs (corrupt-safe reload via `OverlayStyle.fromWire`) + fire-and-forget `setOverlayStyle`/`setGovernorPrefs` push so a running overlay restyles live (C-04); native persists its own copy in `OverlayStore`)*

*✅ CHUNK (G-02 preflight strip + Settings live-push) VERIFIED: `dart analyze` clean, all 103 `flutter test` green (18 new: wire-parse defaults/round-trip, preflight VM push/probe/error paths, persistence reload, strip + cards widget behavior). FIX: hive 2.2.3 cannot serialize DateTime natively — added `DateTimeAdapter` (typeId 30) registered in `main.dart` + tests; Session rows with createdAt/startedAt previously failed to persist silently (writes were unawaited).*

## Epic 6 — Models
- [x] Registry format + built-in catalog entries (E-01)
  *(ModelCatalog: bundled whisper-base int8 + on-demand tiny/small with per-file sizes + upstream SHA-256, task/language capability matrix, min-RAM tiers; ModelRegistry.availableModels exposes the additive capability fields over getCapabilities)*
- [x] Download manager: resume, sha256, atomic swap, space-guard (E-02)
  *(ModelDownloadManager: StatFs space-guard, HTTP Range resume with retry/backoff, pause/cancel flags at buffer boundaries, SHA-256 verify before install, staging-dir rename = atomic install; progress streamed on additive `livelens/model_events` EventChannel; control methods downloadModel/pauseModelDownload/cancelModelDownload)*
- [x] Load/unload + validation banner (capabilities matrix per model)
  *(loadModel catalog-aware + idempotent, unloadModel frees ONNX memory; ModelsScreen renders install/download state, RAM/langs/tasks matrix, F-01 warning when no installed model covers the preselected language)*
- [x] Benchmark-lite: scripted harness + Results tab (E-03)
  *(ModelBenchmark: deterministic 5 s formant signal, N-round decode, p50/p90 latency, RTF, PSS RAM, battery %/min estimate; refused during an active session; `_BenchmarkCard` Results section on the Models tab)*
- [x] Hot-swap path (E-04)
  *(ModelRegistry.load builds the replacement recognizer before closing the old one; CaptureEngine reads transcriberProvider per decode — no service restart; active-model indicator + Load buttons per card)*

## Epic 7 — Language features
- [x] Source selector UI respecting model capability + HT-3 copy (F-01)
  *(SessionSetupCard on the Dashboard: unsupported languages disabled against the installed-model capability matrix, auto always valid, active-model line; AppController.langSupported/refreshCapabilities)*
- [x] Transcription mode end-to-end incl. session metadata (F-02)
  *(taskMode translate/transcribe persisted in prefs, segmented selector, start() creates the row with mode/tgtLang (transcribe → tgt=src) and passes taskId=transcribe natively; CaptureEngine already honored task + F-03 forced lang)*
- [x] Auto-detect smoothing + confidences persisted (F-03)
  *(LangSmoother majority window with short-utterance prior reuse + forced-lang override resolves each final segment's srcLang; model conf stored on Segment.confidence via FinalEvent)*

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



## Device-test feedback round 1 (fixed 2026-08-31)
- [x] #1 Crash/empty sessions: auto-load bundled model at startup (was NoopTranscriber ? zero output); ProjectionActivity FGS-start guarded; LivelensApplication crash-log writer + Settings ? Diagnostics viewer; relaunch reconciliation closes interrupted sessions (D-03)
- [x] #2 Benchmark MODEL_MISSING: bundled asset model now materialized to filesDir on load (ensureMaterialized) + startup hot-load
- [x] #3 Status-bar overlap: SafeArea added to app shell
- [x] #4 Downloads failed: INTERNET permission added (G-01 scoped allowlist, CI guard updated)


## Device-test feedback round 2 (instrumented 2026-09-01)
- [x] Silent death ~5 s after "Start Translation" (empty crash-log.txt): breadcrumb journal added — `Breadcrumbs.kt` appends timestamped marks to `filesDir/diagnostics-log.txt` (160 KB capped, thread-safe, all IO wrapped so diagnostics can never be the crash). Wired across the death window: `LivelensApplication` (app.start + Java-crash marks), `CaptureService` (service.create/stop), `CaptureEngine` (session.begin, pipeline.begin, decode.first), `VadWorker.create` (vad.create.begin/ok), `ModelRegistry.load` (model.load.begin/ok/fail incl. RAM-gate reason), MainActivity warm-up (model.warmup.fail). Journal concatenated into `getCrashLog` (Settings → Diagnostics) — the last breadcrumb before a silent death localizes the native call (JNI/ONNX abort or LMK kill; neither reaches the Java crash handler, which is why crash-log.txt was empty).
- [x] VAD init made non-fatal: `CaptureEngine` wraps `VadWorker.create` in try/catch — a JNI failure there now degrades to a `VAD_INIT_FAILED` error event + clean stop instead of an unguarded throw on the pipeline thread.
- [x] Load buttons doing nothing: root cause was double-swallowed errors (warm-up `catch (_: Throwable)`, and the Models Load button discarding `loadModel`'s returned error string). `AppController.lastModelError` now persists the failure and the Models screen shows a "Load failed: …" banner — RAM-gate (minTotalRamMb), missing-file, and JNI-init failures are all visible.
- [x] Stale "no model loaded" banner: startup warm-up now pushes a `done` `modelDownload` event when the background hot-load finishes, so Dart re-reads capabilities without a screen re-visit (Dashboard initState only fired once).
- [x] Marshaling ruled out: bundled sherpa-onnx `.so` is v1.13.6; vendored `Vad.kt`/`OfflineRecognizer.kt` field layouts verified against the v1.13.6 JNI sources — match (extra Kotlin fields are ignored by JNI, the safe direction).
- [ ] Root cause of the silent death: needs breadcrumb output from the user's device after this instrumented rebuild (read the tail of diagnostics-log.txt via Settings → Diagnostics).

