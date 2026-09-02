import 'dart:convert';

import 'package:livelens/bridge.dart';

import 'models.dart';
import 'repositories.dart';

/// Result of one reconciliation pass (D-03).
class ReconciliationResult {
  const ReconciliationResult({
    required this.imported,
    required this.skippedDuplicates,
    required this.malformed,
  });

  /// New segments written to the database.
  final int imported;

  /// Lines already present (idempotent upsert — not an error).
  final int skippedDuplicates;

  /// Lines that failed to parse (torn writes / garbage).
  final int malformed;

  int get totalLines => imported + skippedDuplicates + malformed;
}

/// Reconciliation importer (D-03): replays spooled segments into the
/// database after a crash relaunch.
///
/// Spool lines are JSONL matching the contract §3 `final` event shape, so
/// the existing [EventCodec] decodes them with zero translation. Upsert is
/// idempotent by segment id — replaying the same spool twice never
/// duplicates rows.
class ReconciliationImporter {
  ReconciliationImporter({
    required this.segments,
    required this.sessions,
    required this.codec,
  });

  final SegmentRepository segments;
  final SessionRepository sessions;
  final EventCodec codec;

  /// Imports [lines] (raw spool lines). Returns per-category counts.
  ///
  /// Segments whose session row is missing are still imported (the session
  /// may have been created after the crash); the session browser simply
  /// won't show them until the session row exists. This matches the
  /// append-only-during-live contract.
  ReconciliationResult importLines(Iterable<String> lines) {
    var imported = 0;
    var skipped = 0;
    var malformed = 0;

    for (final line in lines) {
      if (line.trim().isEmpty) continue;

      // Spool lines are JSONL; the codec expects a decoded Map.
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        malformed++;
        continue;
      }

      final event = codec.decode(decoded);
      if (event is! FinalEvent) {
        malformed++;
        continue;
      }

      final segment = Segment(
        id: event.segmentId,
        sessionId: event.sessionId,
        t0Ms: event.t0Ms,
        t1Ms: event.t1Ms,
        sourceText: event.sourceText,
        translatedText: event.translatedText,
        confidence: event.confidence,
        srcLang: event.sourceLang,
      );

      if (segments.upsert(segment)) {
        imported++;
      } else {
        skipped++;
      }
    }

    return ReconciliationResult(
      imported: imported,
      skippedDuplicates: skipped,
      malformed: malformed,
    );
  }
}
