import 'package:flutter/services.dart';

import 'dtos.dart';

/// Typed wrapper for MethodChannel `livelens/control` (docs/contract.md §2).
///
/// Every method maps 1:1 onto a frozen wire method; argument envelopes are
/// built here so call sites never touch raw maps. Errors arrive as
/// [PlatformException] whose `code` is a contract §4 registry string.
class LivelensControl {
  /// Creates a control-channel client. [methodChannel] is injectable for
  /// tests; production uses the const default.
  LivelensControl({MethodChannel? methodChannel})
    : _channel = methodChannel ?? const MethodChannel('livelens/control');

  final MethodChannel _channel;

  // -- session lifecycle (§2.1) ---------------------------------------------

  /// Starts a capture session. Dart pre-creates the session row and passes
  /// its id; consent is requested out-of-band (contract §5).
  ///
  /// [micFallback] opts into the A-05 degraded mode: native skips the
  /// projection consent flow entirely and starts capture with
  /// `RECORD_AUDIO` (requesting the runtime permission if missing).
  /// Additive key — older natives ignore it (projection path).
  Future<void> startSession({
    String? sourceLang,
    required LivelensTask taskId,
    required String sessionId,
    bool micFallback = false,
  }) => _channel.invokeMethod<void>('startSession', <Object?, Object?>{
    'sourceLang': sourceLang,
    'taskId': taskId.wireName,
    'sessionId': sessionId,
    if (micFallback) 'mode': 'mic',
  });

  /// Drains VAD + flushes inference queue before acknowledging (B-08).
  Future<void> pause() => _channel.invokeMethod<void>('pause');

  /// Resumes capture after [pause].
  Future<void> resume() => _channel.invokeMethod<void>('resume');

  /// Stops capture, finalizes the session natively, flushes the spool.
  Future<void> stopSession() => _channel.invokeMethod<void>('stopSession');

  // -- models & capabilities (§2.2) ------------------------------------------

  Future<Capabilities> getCapabilities() async {
    final raw = await _channel.invokeMethod<Object?>('getCapabilities');
    return Capabilities.fromWire(raw);
  }

  /// Hot-loads a model. Throws [PlatformException] with codes
  /// `MODEL_MISSING` / `MODEL_LOAD_FAILED` on failure.
  Future<void> loadModel({required String modelId}) => _channel
      .invokeMethod<void>('loadModel', <Object?, Object?>{'modelId': modelId});

  /// Pushes governor preferences; native ignores unknown keys (forward compat).
  Future<void> setGovernorPrefs(GovernorPrefs prefs) =>
      _channel.invokeMethod<void>('setGovernorPrefs', prefs.toWire());

  // -- permissions & compatibility (§2.3) ------------------------------------

  /// Returns the CURRENT overlay-permission grant state. When not granted,
  /// native deep-links to the Settings page; re-query to observe the result.
  Future<bool> requestOverlayPermission() async {
    final raw = await _channel.invokeMethod<Object?>(
      'requestOverlayPermission',
    );
    return raw == true;
  }

  Future<bool> isBatteryExemptionGranted() async {
    final raw = await _channel.invokeMethod<Object?>(
      'isBatteryExemptionGranted',
    );
    return raw == true;
  }

  /// G-02: deep-links to the battery-optimization Settings screen
  /// (no special permission needed, unlike the direct opt-in dialog).
  Future<void> openBatterySettings() =>
      _channel.invokeMethod<void>('openBatterySettings');

  Future<List<CompatEntry>> performCompatCheck() async {
    final raw = await _channel.invokeMethod<Object?>('performCompatCheck');
    if (raw is! List) {
      throw const _ControlShapeError('performCompatCheck must return a list');
    }
    return raw.map(CompatEntry.fromWire).toList(growable: false);
  }

  /// Hot-unloads the active model (E-04 counterpart: memory pressure or
  /// user action). Safe when nothing is loaded.
  Future<void> unloadModel() => _channel.invokeMethod<void>('unloadModel');

  /// E-02: starts (or resumes) the download for [modelId]. Returns true only
  /// when the transfer actually started; false means bundled (nothing to
  /// download) or another download is already running. Progress arrives on
  /// the `livelens/model_events` channel ([LivelensModelEvents]).
  Future<bool> downloadModel({required String modelId}) async {
    final raw = await _channel.invokeMethod<Object?>(
      'downloadModel',
      <Object?, Object?>{'modelId': modelId},
    );
    return raw == true;
  }

  /// E-02: cooperative pause; the worker stops at the next buffer boundary.
  Future<void> pauseModelDownload({required String modelId}) =>
      _channel.invokeMethod<void>('pauseModelDownload', <Object?, Object?>{
        'modelId': modelId,
      });

  /// E-02: cancels the download and clears the staging dir (state resets).
  Future<void> cancelModelDownload({required String modelId}) =>
      _channel.invokeMethod<void>('cancelModelDownload', <Object?, Object?>{
        'modelId': modelId,
      });

  /// E-03: runs the scripted benchmark against the loaded model. Throws
  /// [PlatformException] `MODEL_MISSING` when no model is loaded, or
  /// `INVALID_ARGUMENT` when a session is active (the recognizer is
  /// thread-confined during capture).
  Future<BenchmarkResult> runBenchmark({int? rounds}) async {
    final raw = await _channel.invokeMethod<Object?>(
      'runBenchmark',
      <Object?, Object?>{if (rounds != null) 'rounds': rounds},
    );
    return BenchmarkResult.fromWire(raw);
  }

  // -- overlay configuration (§2.4) -------------------------------------------

  /// Applies overlay style live; safe when no overlay is showing.
  Future<void> setOverlayStyle(OverlayStyle style) =>
      _channel.invokeMethod<void>('setOverlayStyle', style.toWire());

  /// Persists overlay position. Caller throttles ≤ 1 call / 500 ms
  /// (architecture §3.6 gesture engine owns the throttle).
  Future<void> saveOverlayPosition({
    required double x,
    required double y,
    required double w,
    required double h,
  }) => _channel.invokeMethod<void>('saveOverlayPosition', <Object?, Object?>{
    'x': x,
    'y': y,
    'w': w,
    'h': h,
  });

  /// Reads the on-device crash log (empty string when no crash recorded).
  /// Diagnostics-only; additive control method outside the frozen §2 set.
  Future<String> crashLog() async {
    final v = await _channel.invokeMethod<Object?>('getCrashLog');
    return v is String ? v : '';
  }
}

/// Thrown when native returns a payload violating the frozen reply shape.
class _ControlShapeError implements Exception {
  const _ControlShapeError(this.message);
  final String message;

  @override
  String toString() => '_ControlShapeError: $message';
}
