import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'event_codec.dart';
import 'events.dart';

/// Broadcast facade over EventChannel `livelens/events`
/// (docs/contract.md §3; Epic 5 "StreamController façade").
///
/// - Decodes via [EventCodec]; skips unknown types / future versions.
/// - Re-throws [MalformedEventException] into the stream as an error so a
///   native bug surfaces loudly instead of being silently dropped.
/// - Multiple listeners share one underlying subscription (broadcast).
class LivelensEvents {
  /// Creates the events facade. Both channels are injectable for tests;
  /// production uses the const defaults.
  LivelensEvents({EventChannel? eventChannel})
    : _eventChannel = eventChannel ?? const EventChannel('livelens/events');

  final EventChannel _eventChannel;

  Stream<LivelensEvent>? _stream;

  /// Broadcast stream of typed events. Lazily subscribes to the platform
  /// channel on first listen; cancels the platform subscription when the
  /// last listener cancels.
  Stream<LivelensEvent> get stream {
    _stream ??= _eventChannel
        .receiveBroadcastStream()
        .map(_decodeOrRethrow)
        .where((event) => event != null)
        .cast<LivelensEvent>();
    return _stream!;
  }

  LivelensEvent? _decodeOrRethrow(Object? raw) {
    try {
      return const EventCodec().decode(raw);
    } on MalformedEventException catch (e) {
      // Surface native contract violations as stream errors; a broadcast
      // stream error without a listener at that instant is simply dropped,
      // which matches the "log loudly in debug" policy.
      if (kDebugMode) {
        // ignore: avoid_print
        print('livelens: malformed event → ${e.message}');
      }
      rethrow; // propagate into the stream as an error
    }
  }

  /// Convenience filtered views ----------------------------------------------

  Stream<StateEvent> get states => _of<StateEvent>();
  Stream<FinalEvent> get finals => _of<FinalEvent>();
  Stream<PartialEvent> get partials => _of<PartialEvent>();
  Stream<PerfEvent> get perf => _of<PerfEvent>();
  Stream<ErrorEvent> get errors => _of<ErrorEvent>();
  Stream<SpoolPendingEvent> get spoolPending => _of<SpoolPendingEvent>();
  Stream<ProjectionGrantedEvent> get projectionGranted =>
      _of<ProjectionGrantedEvent>();
  Stream<ProjectionDeniedEvent> get projectionDenied =>
      _of<ProjectionDeniedEvent>();

  /// Typed view over [stream] for one concrete event class.
  ///
  /// Note: `Stream` has no `whereType`; errors inside [stream] still
  /// propagate through these derived streams untouched.
  Stream<E> _of<E extends LivelensEvent>() =>
      stream.where((event) => event is E).cast<E>();
}
