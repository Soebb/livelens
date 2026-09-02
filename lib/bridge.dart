/// LiveLens platform bridge — typed Dart side of the frozen v1 contract
/// (docs/contract.md).
///
/// Public API:
/// - [LivelensControl]: commands Flutter → Kotlin (`livelens/control`).
/// - [LivelensEvents]: typed broadcast stream of Kotlin → Flutter events
///   (`livelens/events`).
/// - DTOs and enums shared by both.
library;

export 'src/bridge/control_channel.dart';
export 'src/bridge/dtos.dart';
export 'src/bridge/error_codes.dart';
export 'src/bridge/event_codec.dart';
export 'src/bridge/events.dart';
export 'src/bridge/events_channel.dart';
export 'src/bridge/model_events_channel.dart';
