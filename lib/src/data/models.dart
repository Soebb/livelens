import 'package:hive/hive.dart';

part 'models.g.dart';

/// Session entity — architecture §3.5 schema, verbatim.
@HiveType(typeId: 0)
class Session extends HiveObject {
  @HiveField(0)
  late String id; // uuid v7-ish (sortable)

  @HiveField(1)
  String title;

  @HiveField(2)
  DateTime createdAt;

  @HiveField(3)
  DateTime? startedAt;

  @HiveField(4)
  DateTime? endedAt;

  /// Live duration excluding pauses (B-08 SessionClock).
  @HiveField(5)
  int durationMsLive;

  /// 'auto' resolved → dominant detected.
  @HiveField(6)
  String srcLang;

  /// 'en' in V1, or equals srcLang for transcription mode.
  @HiveField(7)
  String tgtLang;

  /// 'translate' | 'transcribe'.
  @HiveField(8)
  String mode;

  @HiveField(9)
  bool favorite;

  Session({
    required this.id,
    required this.title,
    required this.createdAt,
    this.startedAt,
    this.endedAt,
    this.durationMsLive = 0,
    required this.srcLang,
    required this.tgtLang,
    required this.mode,
    this.favorite = false,
  });
}

/// Segment entity — architecture §3.5 schema, verbatim.
///
/// [translatedText] duplicates [sourceText] in transcription mode
/// deliberately (keeps the editor simple, per §3.5).
@HiveType(typeId: 1)
class Segment extends HiveObject {
  @HiveField(0)
  late String id; // stable across reconciliation!

  @HiveField(1)
  String sessionId;

  @HiveField(2)
  double t0Ms;

  @HiveField(3)
  double t1Ms;

  @HiveField(4)
  String sourceText;

  @HiveField(5)
  String translatedText;

  @HiveField(6)
  double? confidence;

  @HiveField(7)
  String srcLang;

  /// Derived lowercase search index (architecture §3.5 storage rule:
  /// "tokenized prefix index rebuilt lazily"). Kept in sync by the
  /// repository on write; never edited directly.
  @HiveField(8)
  String searchIndex;

  Segment({
    required this.id,
    required this.sessionId,
    required this.t0Ms,
    required this.t1Ms,
    required this.sourceText,
    required this.translatedText,
    this.confidence,
    required this.srcLang,
    String? searchIndex,
  }) : searchIndex =
           searchIndex ?? buildSearchIndex(sourceText, translatedText);

  /// Lowercase concatenation of source + translated for prefix matching.
  static String buildSearchIndex(String source, String translated) =>
      '${source.toLowerCase()} ${translated.toLowerCase()}';
}
