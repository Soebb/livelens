import 'error_codes.dart';
import 'events.dart';

/// Decodes raw EventChannel payloads into typed [LivelensEvent]s.
///
/// Contract rules enforced here (docs/contract.md §0, §3):
/// - Payloads must be JSON maps carrying a recognized `"type"` and `"v": 1`.
/// - Unknown `type` → returns `null` (receiver skips; debug-log upstream).
/// - Future major version (`v` > 1) → returns `null` (skip, never crash).
/// - Known `type` with wrong shape → throws [MalformedEventException].
class EventCodec {
  const EventCodec();

  /// The only event types this codec recognizes.
  static const Set<String> knownTypes = {
    'state',
    'projectionGranted',
    'projectionDenied',
    'partial',
    'final',
    'perf',
    'spoolPending',
    'error',
  };

  /// Decodes one raw platform message.
  ///
  /// Returns `null` for anything that must be skipped per contract:
  /// non-map payloads, missing/unknown `type`, or a future major version.
  LivelensEvent? decode(Object? message) {
    if (message is! Map) return null;

    final type = message['type'];
    if (type is! String) return null;
    if (!knownTypes.contains(type)) return null; // additive-change rule

    final v = message['v'];
    if (v is! int) {
      throw MalformedEventException(
        'event "$type" missing integer "v"',
        message,
      );
    }
    if (v > LivelensEvent.contractVersion) return null; // future major

    switch (type) {
      case 'state':
        return _decodeState(message);
      case 'projectionGranted':
        return const ProjectionGrantedEvent();
      case 'projectionDenied':
        return const ProjectionDeniedEvent();
      case 'partial':
        return _decodePartial(message);
      case 'final':
        return _decodeFinal(message);
      case 'perf':
        return _decodePerf(message);
      case 'spoolPending':
        return _decodeSpoolPending(message);
      case 'error':
        return _decodeError(message);
    }
    // Exhaustive over knownTypes; unreachable.
    return null;
  }

  // -- per-type shape validation -------------------------------------------

  StateEvent _decodeState(Map<Object?, Object?> m) {
    final value = m['value'];
    if (value is! String) {
      throw MalformedEventException('state.value must be a string', m);
    }
    final detail = m['detail'];
    if (detail is! String) {
      throw MalformedEventException('state.detail must be a string', m);
    }
    final state = sessionStateFromWireOrNull(value);
    if (state == null) {
      throw MalformedEventException(
        'state.value "$value" not in capturing|paused|stopped|error',
        m,
      );
    }
    return StateEvent(state: state, detail: detail);
  }

  PartialEvent _decodePartial(Map<Object?, Object?> m) {
    final sessionId = m['sessionId'];
    final segId = m['segId'];
    final showHint = m['showHint'];
    if (sessionId is! String || segId is! String || showHint is! bool) {
      throw MalformedEventException(
        'partial requires {sessionId:String, segId:String, showHint:bool}',
        m,
      );
    }
    return PartialEvent(
      sessionId: sessionId,
      segmentId: segId,
      showHint: showHint,
    );
  }

  FinalEvent _decodeFinal(Map<Object?, Object?> m) {
    final sessionId = m['sessionId'];
    final segId = m['segId'];
    final t0 = m['t0'];
    final t1 = m['t1'];
    final srcLang = m['srcLang'];
    final src = m['src'];
    final en = m['en'];
    final conf = m['conf'];

    if (sessionId is! String ||
        segId is! String ||
        srcLang is! String ||
        src is! String ||
        en is! String) {
      throw MalformedEventException(
        'final requires string sessionId/segId/srcLang/src/en',
        m,
      );
    }
    if (t0 is! num || t1 is! num) {
      throw MalformedEventException(
        'final.t0/t1 must be numeric milliseconds',
        m,
      );
    }
    if (t1 < t0) {
      throw MalformedEventException('final.t1 < t0', m);
    }
    if (conf is! num || conf < 0 || conf > 1) {
      throw MalformedEventException('final.conf must be within 0..1', m);
    }

    return FinalEvent(
      sessionId: sessionId,
      segmentId: segId,
      t0Ms: t0.toDouble(),
      t1Ms: t1.toDouble(),
      sourceLang: srcLang,
      sourceText: src,
      translatedText: en,
      confidence: conf.toDouble(),
    );
  }

  PerfEvent _decodePerf(Map<Object?, Object?> m) {
    final rtfMsPerSec = m['rtfMsPerSec'];
    final queueDepth = m['queueDepth'];
    final rssMb = m['rssMb'];
    final batteryDrop = m['batteryPctDropLastPeriod'];

    if (rtfMsPerSec is! int || queueDepth is! int) {
      throw MalformedEventException(
        'perf.rtfMsPerSec/queueDepth must be integers',
        m,
      );
    }
    if (rtfMsPerSec < 0 || queueDepth < 0) {
      throw MalformedEventException(
        'perf.rtfMsPerSec/queueDepth must be non-negative',
        m,
      );
    }
    if (rssMb is! num || batteryDrop is! num) {
      throw MalformedEventException(
        'perf.rssMb/batteryPctDropLastPeriod must be numeric',
        m,
      );
    }

    return PerfEvent(
      rtfMsPerSec: rtfMsPerSec,
      queueDepth: queueDepth,
      rssMb: rssMb.toDouble(),
      batteryPctDropLastPeriod: batteryDrop.toDouble(),
    );
  }

  SpoolPendingEvent _decodeSpoolPending(Map<Object?, Object?> m) {
    final count = m['count'];
    if (count is! int || count < 0) {
      throw MalformedEventException(
        'spoolPending.count must be a non-negative integer',
        m,
      );
    }
    return SpoolPendingEvent(count: count);
  }

  ErrorEvent _decodeError(Map<Object?, Object?> m) {
    final code = LivelensErrorCode.fromWire(m['code']);
    final detail = m['detail'];
    if (detail is! String) {
      throw MalformedEventException('error.detail must be a string', m);
    }
    return ErrorEvent(code: code, detail: detail);
  }
}

/// Parses a [SessionState] wire value, returning `null` when unrecognized
/// (the codec converts that into a [MalformedEventException]).
SessionState? sessionStateFromWireOrNull(Object? value) {
  if (value is! String) return null;
  for (final s in SessionState.values) {
    if (s.wireName == value) return s;
  }
  return null;
}
