import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:livelens/bridge.dart';

import '../data/models.dart';
import '../data/repositories.dart';

/// UI-facing live-session phase (mirrors native states from contract §3).
enum LivePhase { idle, starting, capturing, paused, stopped, error }

/// Central app controller: session FSM + wiring between the bridge, the
/// Hive repositories, and the screens. Screens rebuild via [AnimatedBuilder]
/// on this ChangeNotifier.
class AppController extends ChangeNotifier {
  AppController({
    required this.sessions,
    required this.segments,
    this.prefs,
    LivelensControl? control,
    LivelensEvents? events,
    Stream<LivelensEvent>? eventStream,
    Stream<ModelDownloadProgress>? modelEventStream,
  }) : _control = control ?? LivelensControl(),
       _events = events ?? LivelensEvents() {
    // eventStream lets tests inject a fake without touching the platform
    // channels; production always listens on the real EventChannel.
    _sub = (eventStream ?? _events.stream).listen(
      _onEvent,
      onError: (Object e) {
        if (phase != LivePhase.idle) {
          phase = LivePhase.error;
          phaseDetail = e.toString();
          notifyListeners();
        }
      },
    );
    // E-02: model-download progress arrives on its own additive channel;
    // injected stream lets tests drive it without a platform channel.
    _modelSub = (modelEventStream ?? LivelensModelEvents().stream).listen(
      _onModelEvent,
      onError: (Object e) {
        downloadError = e.toString();
        notifyListeners();
      },
    );
    final saved = prefs?.get('themeMode');
    final idx = int.tryParse(saved ?? '') ?? ThemeMode.system.index;
    themeMode = ThemeMode.values[idx.clamp(0, ThemeMode.values.length - 1)];
    _loadPersistedSettings();
    _recoverInterruptedSessions();
  }

  /// Crash resilience (D-03 / §3.7 "process killed" row): a session left
  /// running by a process death gets closed on relaunch. Duration falls
  /// back to the last segment's end (spool-recovered segments keep their
  /// session-timeline timestamps); a session with no segments reports 0 —
  /// honest, nothing was captured.
  void _recoverInterruptedSessions() {
    for (final s in sessions.all(newestFirst: false)) {
      if (s.startedAt == null || s.endedAt != null) continue;
      final segs = segments.forSession(s.id);
      final endMs = segs.isEmpty ? 0 : segs.last.t1Ms.toInt();
      sessions.markEnded(s.id, DateTime.now(), endMs);
    }
  }

  final SessionRepository sessions;
  final SegmentRepository segments;
  final Box<String>? prefs;
  final LivelensControl _control;
  final LivelensEvents _events;
  StreamSubscription<LivelensEvent>? _sub;
  StreamSubscription<ModelDownloadProgress>? _modelSub;

  // Live state ---------------------------------------------------------------
  LivePhase phase = LivePhase.idle;
  String? activeSessionId;
  String phaseDetail = '';
  String liveSrc = '';
  String liveEn = '';
  double? lastRtf;

  ThemeMode themeMode = ThemeMode.system;

  Session? get activeSession =>
      activeSessionId == null ? null : sessions.byId(activeSessionId!);

  void setThemeMode(ThemeMode mode) {
    themeMode = mode;
    prefs?.put('themeMode', mode.index.toString());
    notifyListeners();
  }

  // Settings live-push state (contract §2.2/§2.4) ----------------------------
  /// Overlay appearance pushed to native on every change (fire-and-forget;
  /// native also persists its own copy in `OverlayStore`).
  OverlayStyle overlayStyle = const OverlayStyle();

  /// Governor preferences pushed to native on every change (PRD B-07).
  GovernorPrefs governorPrefs = const GovernorPrefs();

  /// Source language preselected on the Dashboard start action (F-01 v1).
  String defaultSrcLang = 'auto';

  /// F-02 task mode: 'translate' (default) or 'transcribe'. Persisted and
  /// sent as the session's taskId + stored session metadata.
  String taskMode = 'translate';

  // Model management (Epic 6: E-01/E-02/E-03/E-04) ---------------------------
  /// Last `getCapabilities` reply (registry + active model). Null until the
  /// first successful refresh.
  Capabilities? capabilities;
  String? capabilitiesError;
  bool loadingCapabilities = false;

  /// Latest download progress (E-02), null until a message arrives.
  ModelDownloadProgress? downloadProgress;
  String? downloadError;

  /// E-03 self-reported benchmark of the loaded model, null until run.
  BenchmarkResult? lastBenchmark;
  bool benchmarking = false;
  String? benchmarkError;

  /// Registry list, or an empty list before the first capability refresh.
  List<ModelInfo> get models => capabilities?.availableModels ?? const [];

  /// The currently hot-loaded model entry (null when none / not found).
  ModelInfo? get activeModel {
    final id = capabilities?.activeModelId;
    if (id == null) return null;
    for (final m in models) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Refreshes the model registry + active-model state from native (E-01).
  /// Never throws; failures land in [capabilitiesError].
  Future<void> refreshCapabilities() async {
    if (loadingCapabilities) return;
    loadingCapabilities = true;
    capabilitiesError = null;
    notifyListeners();
    try {
      capabilities = await _control.getCapabilities();
    } catch (e) {
      capabilitiesError = e.toString();
    }
    loadingCapabilities = false;
    notifyListeners();
  }

  /// Last load/unload failure, surfaced as a banner on the Models screen.
  /// Cleared on success; null when the last operation succeeded.
  String? lastModelError;

  /// E-04: hot-loads (or hot-swaps to) [modelId], then re-reads capabilities
  /// so the active-model badge follows. Errors surface in the returned
  /// string (null on success) so screens can show a banner.
  Future<String?> loadModel(String modelId) async {
    try {
      await _control.loadModel(modelId: modelId);
      lastModelError = null;
      await refreshCapabilities();
      return null;
    } catch (e) {
      // Persist the failure so the Models screen can show WHY the load
      // did nothing (RAM gate / missing files / JNI init) instead of
      // silently swallowing it.
      lastModelError = e.toString();
      notifyListeners();
      return lastModelError;
    }
  }

  /// E-04: frees the loaded engine (memory pressure / model switch prep).
  Future<String?> unloadModel() async {
    try {
      await _control.unloadModel();
      lastModelError = null;
      await refreshCapabilities();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// E-02: starts (or resumes) the download for [modelId]. Returns an error
  /// string, or null when the transfer started (or was already running).
  Future<String?> downloadModel(String modelId) async {
    downloadError = null;
    try {
      final started = await _control.downloadModel(modelId: modelId);
      if (!started) {
        // Bundled (nothing to download) or another download already runs;
        // re-read state so the UI reflects reality.
        await refreshCapabilities();
      }
    } catch (e) {
      downloadError = e.toString();
    }
    notifyListeners();
    return downloadError;
  }

  /// E-02: cooperative pause of the running download.
  Future<void> pauseDownload(String modelId) async {
    try {
      await _control.pauseModelDownload(modelId: modelId);
    } catch (_) {}
    notifyListeners();
  }

  /// E-02: cancels the download and clears the staging dir.
  Future<void> cancelDownload(String modelId) async {
    try {
      await _control.cancelModelDownload(modelId: modelId);
    } catch (_) {}
    notifyListeners();
  }

  /// E-03: runs the scripted benchmark against the loaded model. Returns an
  /// error string, or null when [lastBenchmark] was populated.
  Future<String?> runBenchmark() async {
    if (benchmarking) return null;
    benchmarking = true;
    benchmarkError = null;
    notifyListeners();
    try {
      lastBenchmark = await _control.runBenchmark();
    } catch (e) {
      benchmarkError = e.toString();
    }
    benchmarking = false;
    notifyListeners();
    return benchmarkError;
  }

  /// E-02: latest progress for [modelId], or null when nothing has arrived
  /// for it (the screens read this while rendering a downloading row).
  ModelDownloadProgress? downloadProgressFor(String modelId) {
    final p = downloadProgress;
    return p != null && p.modelId == modelId ? p : null;
  }

  void _onModelEvent(ModelDownloadProgress p) {
    downloadProgress = p;
    if (p.state == DownloadPhase.failed) {
      downloadError = p.error;
    } else if (p.state == DownloadPhase.done || p.state == DownloadPhase.idle) {
      downloadError = null;
      // A completed install changes `installed` in the registry.
      if (p.state == DownloadPhase.done) unawaited(refreshCapabilities());
    }
    notifyListeners();
  }

  /// F-01: the language can start when some INSTALLED model transcribes it.
  /// `auto` is always offered (the loaded model decides at decode time).
  bool langSupported(String lang) {
    if (lang == 'auto') return true;
    return models.any((m) => m.installed && m.supportsLanguage(lang));
  }

  /// F-02: switches the task mode used by the next session start.
  void setTaskMode(String mode) {
    if (mode != 'translate' && mode != 'transcribe') return;
    taskMode = mode;
    prefs?.put('taskMode', mode);
    notifyListeners();
  }

  // Preflight state (G-02) ----------------------------------------------------
  /// Null = not yet checked. Overlay: null until the user taps Check/Grant
  /// (the underlying wire call deep-links to Settings when ungranted, so it
  /// must never run automatically).
  bool? overlayPermissionGranted;
  bool? batteryExemptionGranted;
  bool preflightChecking = false;
  List<CompatEntry> compatRows = const [];
  String? preflightError;

  void _loadPersistedSettings() {
    final box = prefs;
    if (box == null) return;
    try {
      final styleJson = box.get('overlayStyle');
      if (styleJson != null) {
        overlayStyle = OverlayStyle.fromWire(
          jsonDecode(styleJson) as Map<dynamic, dynamic>,
        );
      }
      final govJson = box.get('governorPrefs');
      if (govJson != null) {
        final m = jsonDecode(govJson) as Map<dynamic, dynamic>;
        governorPrefs = GovernorPrefs(
          screenOffAutoPause: m['screenOffAutoPause'] is bool
              ? m['screenOffAutoPause'] as bool
              : false,
          batteryLowThresholdPct: m['batteryLowThresholdPct'] is int
              ? m['batteryLowThresholdPct'] as int
              : 15,
          thermalHysteresisMs: m['thermalHysteresisMs'] is int
              ? m['thermalHysteresisMs'] as int
              : 60000,
          inferenceQueueDepth: m['inferenceQueueDepth'] is int
              ? m['inferenceQueueDepth'] as int
              : 3,
        );
      }
      defaultSrcLang = box.get('srcLang') ?? 'auto';
      final mode = box.get('taskMode');
      if (mode is String && (mode == 'translate' || mode == 'transcribe')) {
        taskMode = mode;
      }
    } catch (_) {
      // Corrupt prefs must never block startup — defaults already applied.
    }
  }

  /// Updates overlay appearance, persists it, and pushes it live to the
  /// native overlay (§2.4: applied immediately, safe when idle).
  void updateOverlayStyle(OverlayStyle style) {
    overlayStyle = style;
    prefs?.put('overlayStyle', jsonEncode(style.toWire()));
    // Push is best-effort: native may be absent (tests) or the process dead.
    unawaited(_control.setOverlayStyle(style).catchError((Object _) {}));
    notifyListeners();
  }

  /// Updates governor preferences, persists them, and pushes to native (B-07).
  void updateGovernorPrefs(GovernorPrefs value) {
    governorPrefs = value;
    prefs?.put('governorPrefs', jsonEncode(value.toWire()));
    unawaited(_control.setGovernorPrefs(value).catchError((Object _) {}));
    notifyListeners();
  }

  void setDefaultSrcLang(String lang) {
    defaultSrcLang = lang;
    prefs?.put('srcLang', lang);
    notifyListeners();
  }

  // Preflight (G-02) ----------------------------------------------------------

  /// Runs the passive part of the permissions pre-flight: battery-exemption
  /// probe + app-compatibility rows. Never throws — failures land in
  /// [preflightError] and the strip shows "unknown" states.
  Future<void> runPreflight() async {
    if (preflightChecking) return;
    preflightChecking = true;
    preflightError = null;
    notifyListeners();
    try {
      final results = await Future.wait([
        _control.isBatteryExemptionGranted(),
        _control.performCompatCheck(),
      ]);
      batteryExemptionGranted = results[0] as bool;
      compatRows = results[1] as List<CompatEntry>;
    } catch (e) {
      preflightError = e.toString();
    }
    preflightChecking = false;
    notifyListeners();
  }

  /// Checks (and, when missing, deep-links to) the overlay-permission screen.
  /// Returns true only when the permission is already granted; false means
  /// the user was sent to Settings (contract §2.2 semantics).
  Future<bool> checkOverlayPermission() async {
    try {
      final granted = await _control.requestOverlayPermission();
      overlayPermissionGranted = granted;
      notifyListeners();
      return granted;
    } catch (e) {
      preflightError = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// G-02 battery helper: deep-links to the ignore-battery-optimizations
  /// list, then re-probes the exemption state.
  Future<void> openBatteryExemptionSettings() async {
    try {
      await _control.openBatterySettings();
      batteryExemptionGranted = await _control.isBatteryExemptionGranted();
    } catch (e) {
      preflightError = e.toString();
    }
    notifyListeners();
  }

  // Session-list mutations (D-04) — notifying wrappers so the Sessions
  // screen rebuilds after every repository change.

  /// Deletes a session and all its segments (cascade), then rebuilds.
  void deleteSession(String id) {
    sessions.deleteCascade(id, segments);
    notifyListeners();
  }

  /// Duplicates a session (metadata only, no segments); returns the new row.
  Session duplicateSession(String id) {
    final copy = sessions.duplicate(id);
    notifyListeners();
    return copy;
  }

  void toggleFavorite(String id) {
    final s = sessions.byId(id);
    if (s != null) {
      sessions.setFavorite(id, !s.favorite);
      notifyListeners();
    }
  }

  void renameSession(String id, String title) {
    sessions.rename(id, title);
    notifyListeners();
  }

  Future<void> start({String? srcLang, bool micFallback = false}) async {
    if (phase == LivePhase.capturing || phase == LivePhase.starting) return;
    phase = LivePhase.starting;
    phaseDetail = '';
    notifyListeners();

    final lang = srcLang ?? defaultSrcLang;
    final now = DateTime.now();
    final mode = taskMode;
    final session = sessions.create(
      title: 'Session ${now.hour}:${now.minute.toString().padLeft(2, '0')}',
      srcLang: lang,
      // F-02: transcription mode has no translation target (equal to source);
      // translate mode targets English (HT-3).
      tgtLang: mode == 'transcribe' ? lang : 'en',
      mode: mode,
    );
    sessions.markStarted(session.id, now);
    activeSessionId = session.id;
    liveSrc = '';
    liveEn = '';
    try {
      await _control.startSession(
        sourceLang: lang == 'auto' ? null : lang,
        taskId: mode == 'transcribe'
            ? LivelensTask.transcribe
            : LivelensTask.translate,
        sessionId: session.id,
        micFallback: micFallback,
      );
      phase = LivePhase.capturing;
    } catch (e) {
      phase = LivePhase.error;
      phaseDetail = e.toString();
    }
    notifyListeners();
  }

  Future<void> pause() async {
    try {
      await _control.pause();
      phase = LivePhase.paused;
    } catch (e) {
      phase = LivePhase.error;
      phaseDetail = e.toString();
    }
    notifyListeners();
  }

  Future<void> resume() async {
    try {
      await _control.resume();
      phase = LivePhase.capturing;
    } catch (e) {
      phase = LivePhase.error;
      phaseDetail = e.toString();
    }
    notifyListeners();
  }

  Future<void> stop() async {
    try {
      await _control.stopSession();
      phase = LivePhase.stopped;
    } catch (e) {
      phase = LivePhase.error;
      phaseDetail = e.toString();
    }
    final s = activeSession;
    if (s != null) sessions.markEnded(s.id, DateTime.now(), _liveElapsed);
    notifyListeners();
  }

  int get _liveElapsed {
    final s = activeSession;
    if (s == null || s.startedAt == null) return 0;
    return DateTime.now().difference(s.startedAt!).inMilliseconds;
  }

  void _onEvent(LivelensEvent event) {
    switch (event) {
      case StateEvent(state: final v, detail: final d):
        phase = switch (v) {
          SessionState.capturing => LivePhase.capturing,
          SessionState.paused => LivePhase.paused,
          SessionState.stopped => LivePhase.stopped,
          SessionState.error => LivePhase.error,
        };
        phaseDetail = d;
      case FinalEvent(
        sourceLang: final lang,
        sourceText: final src,
        translatedText: final en,
        t0Ms: final t0,
        t1Ms: final t1,
      ):
        liveSrc = src;
        liveEn = en;
        final sid = activeSessionId;
        if (sid != null) {
          segments.append(
            sessionId: sid,
            sourceText: src,
            translatedText: en,
            t0Ms: t0,
            t1Ms: t1,
            srcLang: lang,
          );
        }
      case PerfEvent(:final rtf):
        lastRtf = rtf;
      case _:
        break;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _modelSub?.cancel();
    super.dispose();
  }
}
