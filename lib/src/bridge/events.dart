import 'error_codes.dart';

/// Base type for every payload arriving on EventChannel `livelens/events`.
///
/// Wire format: a single JSON map per message carrying `"type"` and `"v": 1`
/// (docs/contract.md §0, §3). Unknown event *types* are skipped by the codec;
/// known types with malformed shapes throw [MalformedEventException] — that
/// indicates an implementation bug, not bad data.
sealed class LivelensEvent {
  const LivelensEvent();

  /// Contract major version this library understands.
  static const int contractVersion = 1;

  /// Discriminator used in the `"type"` wire key.
  String get wireType;

  /// Serializes back to the exact wire shape (round-trip safe).
  Map<Object?, Object?> toWire();
}

/// Thrown when an event has a recognized `type` but fails shape validation.
///
/// Per contract §3 this is treated as a native-side bug: it must surface
/// loudly during development rather than being swallowed.
class MalformedEventException implements Exception {
  const MalformedEventException(this.message, this.payload);

  /// Human-readable explanation of which invariant failed.
  final String message;

  /// The offending raw payload, preserved for diagnostics.
  final Object? payload;

  @override
  String toString() => 'MalformedEventException: $message (payload: $payload)';
}

// ---------------------------------------------------------------------------
// state
// ---------------------------------------------------------------------------

/// Lifecycle states reported by the native pipeline (contract §3).
enum SessionState {
  capturing('capturing'),
  paused('paused'),
  stopped('stopped'),
  error('error');

  const SessionState(this.wireName);
  final String wireName;

  static SessionState fromWire(Object? value) {
    if (value is String) {
      for (final s in values) {
        if (s.wireName == value) return s;
      }
    }
    throw const _UnknownWireValue('state.value', [
      'capturing',
      'paused',
      'stopped',
      'error',
    ]);
  }
}

class _UnknownWireValue implements Exception {
  const _UnknownWireValue(this.field, this.allowed);
  final String field;
  final List<String> allowed;

  @override
  String toString() =>
      'Unknown value for "$field"; expected one of ${allowed.join('|')}';
}

/// `{"type":"state","value":"capturing|paused|stopped|error","detail":"..."}`
class StateEvent extends LivelensEvent {
  const StateEvent({required this.state, required this.detail});

  final SessionState state;

  /// Free-form human-readable context; may be empty but never null on the wire.
  final String detail;

  @override
  String get wireType => 'state';

  @override
  Map<Object?, Object?> toWire() => <Object?, Object?>{
    'type': wireType,
    'v': LivelensEvent.contractVersion,
    'value': state.wireName,
    'detail': detail,
  };
}

// ---------------------------------------------------------------------------
// projectionGranted / projectionDenied
// ---------------------------------------------------------------------------

/// Out-of-band MediaProjection consent result — granted (contract §5).
class ProjectionGrantedEvent extends LivelensEvent {
  const ProjectionGrantedEvent();

  @override
  String get wireType => 'projectionGranted';

  @override
  Map<Object?, Object?> toWire() => <Object?, Object?>{
    'type': wireType,
    'v': LivelensEvent.contractVersion,
  };
}

/// Out-of-band MediaProjection consent result — denied/cancelled (§5).
class ProjectionDeniedEvent extends LivelensEvent {
  const ProjectionDeniedEvent();

  @override
  String get wireType => 'projectionDenied';

  @override
  Map<Object?, Object?> toWire() => <Object?, Object?>{
    'type': wireType,
    'v': LivelensEvent.contractVersion,
  };
}

// ---------------------------------------------------------------------------
// partial
// ---------------------------------------------------------------------------

/// Utterance N is decoding; overlay keeps showing N−1 plus typing dots.
///
/// Deliberately carries NO text (B-05 honest UX): streaming Whisper partials
/// are unreliable, so the contract forbids them at the type level too.
class PartialEvent extends LivelensEvent {
  const PartialEvent({
    required this.sessionId,
    required this.segmentId,
    required this.showHint,
  });

  final String sessionId;
  final String segmentId;

  /// Whether the overlay should render the typing-dots hint now.
  final bool showHint;

  @override
  String get wireType => 'partial';

  @override
  Map<Object?, Object?> toWire() => <Object?, Object?>{
    'type': wireType,
    'v': LivelensEvent.contractVersion,
    'sessionId': sessionId,
    'segId': segmentId,
    'showHint': showHint,
  };
}

// ---------------------------------------------------------------------------
// final
// ---------------------------------------------------------------------------

/// A finalized bilingual segment (contract §3 sample reproduced verbatim).
///
/// Wire keys `src` and `en` are frozen names. In transcription mode `en`
/// duplicates `src`; storage mirrors that deliberately (architecture §3.5).
class FinalEvent extends LivelensEvent {
  const FinalEvent({
    required this.sessionId,
    required this.segmentId,
    required this.t0Ms,
    required this.t1Ms,
    required this.sourceLang,
    required this.sourceText,
    required this.translatedText,
    required this.confidence,
  });

  final String sessionId;
  final String segmentId;

  /// Session-timeline timestamps in milliseconds (B-06 normalization).
  final double t0Ms;
  final double t1Ms;

  /// Detected or forced source language short code, e.g. `ja`.
  final String sourceLang;
  final String sourceText;
  final String translatedText;

  /// Model-reported confidence, 0..1.
  final double confidence;

  @override
  String get wireType => 'final';

  @override
  Map<Object?, Object?> toWire() => <Object?, Object?>{
    'type': wireType,
    'v': LivelensEvent.contractVersion,
    'sessionId': sessionId,
    'segId': segmentId,
    't0': t0Ms,
    't1': t1Ms,
    'srcLang': sourceLang,
    'src': sourceText,
    'en': translatedText,
    'conf': confidence,
  };
}

// ---------------------------------------------------------------------------
// perf
// ---------------------------------------------------------------------------

/// Governor/performance telemetry (B-07), emitted at a low cadence.
class PerfEvent extends LivelensEvent {
  const PerfEvent({
    required this.rtfMsPerSec,
    required this.queueDepth,
    required this.rssMb,
    required this.batteryPctDropLastPeriod,
  });

  /// Milliseconds of inference spent per second of audio (RTF × 1000).
  final int rtfMsPerSec;
  final int queueDepth;
  final double rssMb;
  final double batteryPctDropLastPeriod;

  @override
  String get wireType => 'perf';

  @override
  Map<Object?, Object?> toWire() => <Object?, Object?>{
    'type': wireType,
    'v': LivelensEvent.contractVersion,
    'rtfMsPerSec': rtfMsPerSec,
    'queueDepth': queueDepth,
    'rssMb': rssMb,
    'batteryPctDropLastPeriod': batteryPctDropLastPeriod,
  };

  /// Real-time factor derived from [rtfMsPerSec] (ms-per-sec ÷ 1000).
  double get rtf => rtfMsPerSec / 1000.0;
}

// ---------------------------------------------------------------------------
// spoolPending
// ---------------------------------------------------------------------------

/// Crash-relaunch recovery prompt: N segments await import from the spool
/// (D-03 reconciliation). Emitted once per launch when a spool file exists.
class SpoolPendingEvent extends LivelensEvent {
  const SpoolPendingEvent({required this.count});

  final int count;

  @override
  String get wireType => 'spoolPending';

  @override
  Map<Object?, Object?> toWire() => <Object?, Object?>{
    'type': wireType,
    'v': LivelensEvent.contractVersion,
    'count': count,
  };
}

// ---------------------------------------------------------------------------
// error
// ---------------------------------------------------------------------------

/// Native error report using the closed registry (contract §4).
///
/// Unrecognized codes parse to [LivelensErrorCode.unknown] instead of
/// throwing — additive-change rule, so older builds survive newer natives.
class ErrorEvent extends LivelensEvent {
  const ErrorEvent({required this.code, required this.detail});

  final LivelensErrorCode code;
  final String detail;

  @override
  String get wireType => 'error';

  @override
  Map<Object?, Object?> toWire() => <Object?, Object?>{
    'type': wireType,
    'v': LivelensEvent.contractVersion,
    'code': code.wireName,
    'detail': detail,
  };
}
