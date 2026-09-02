/// Closed registry of native error codes — docs/contract.md §4.
///
/// Wire strings are UPPER_SNAKE. Parsing an unrecognized code yields
/// [unknown] rather than throwing, so newer natives remain compatible
/// with older Dart receivers (additive-change rule, contract §0).
enum LivelensErrorCode {
  /// User stopped projection (cast-stop) mid-session.
  captureRevoked('CAPTURE_REVOKED'),

  /// MediaProjection consent dialog denied/cancelled.
  projectionDenied('PROJECTION_DENIED'),

  /// AudioPlaybackCapture setup failed.
  captureInitFailed('CAPTURE_INIT_FAILED'),

  /// Mic-fallback record init failed.
  audioRecordFailed('AUDIO_RECORD_FAILED'),

  /// Referenced model not installed.
  modelMissing('MODEL_MISSING'),

  /// sherpa-onnx init failed (corrupt archive / OOM).
  modelLoadFailed('MODEL_LOAD_FAILED'),

  /// Severe thermal; auto-resume after hysteresis (§3.7).
  thermalPause('THERMAL_PAUSE'),

  /// Battery-low governor pause.
  batteryPause('BATTERY_PAUSE'),

  /// Governor gave up downgrading; paused with warning chip.
  queueOverloadPaused('QUEUE_OVERLOAD_PAUSED'),

  /// Unexpected native failure (detail required).
  internalError('INTERNAL_ERROR'),

  /// Receiver-side fallback for unrecognized codes. Never sent on the wire.
  unknown('unknown');

  const LivelensErrorCode(this.wireName);

  /// Exact string used on the platform-channel wire.
  final String wireName;

  /// Parses a wire code; unrecognized values map to [unknown].
  static LivelensErrorCode fromWire(Object? code) {
    if (code is! String) return unknown;
    for (final value in values) {
      if (value != unknown && value.wireName == code) return value;
    }
    return unknown;
  }
}
