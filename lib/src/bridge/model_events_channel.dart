import 'package:flutter/services.dart';

import 'dtos.dart';

/// Broadcast facade over the ADDITIVE EventChannel `livelens/model_events`
/// (PRD E-02). The §3 event set on `livelens/events` stays frozen; model
/// download progress is a v1-addition on its own channel so older Dart
/// receivers are unaffected.
///
/// Messages are flat maps ({type:'modelDownload', v:1, modelId, state,
/// bytesDone, bytesTotal, error}) parsed into [ModelDownloadProgress].
/// Malformed payloads throw [FormatException]-style shape errors loudly —
/// an implementation bug, not bad data.
class LivelensModelEvents {
  /// Creates the facade. The channel is injectable for tests; production
  /// uses the const default.
  LivelensModelEvents({EventChannel? eventChannel})
    : _eventChannel = eventChannel ?? const EventChannel('livelens/model_events');

  final EventChannel _eventChannel;

  Stream<ModelDownloadProgress>? _stream;

  /// Broadcast stream of download progress. Lazily subscribes; cancels the
  /// platform subscription when the last listener cancels.
  Stream<ModelDownloadProgress> get stream {
    _stream ??= _eventChannel
        .receiveBroadcastStream()
        .map(ModelDownloadProgress.fromWire);
    return _stream!;
  }
}