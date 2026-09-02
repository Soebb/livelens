import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';

/// Session repository (D-01/D-04): CRUD over the Hive `sessions` box.
class SessionRepository {
  SessionRepository(this._box);

  final Box<Session> _box;

  static const _uuid = Uuid();

  /// Creates a session row. Dart pre-creates the row BEFORE startSession
  /// (contract §2.1: "Dart pre-creates session row").
  Session create({
    required String title,
    required String srcLang,
    required String tgtLang,
    required String mode,
  }) {
    final session = Session(
      id: _uuid.v7(),
      title: title,
      createdAt: DateTime.now(),
      srcLang: srcLang,
      tgtLang: tgtLang,
      mode: mode,
    );
    _box.put(session.id, session);
    return session;
  }

  Session? byId(String id) => _box.get(id);

  List<Session> all({bool newestFirst = true}) {
    final list = _box.values.toList();
    list.sort(
      (a, b) => newestFirst
          ? b.createdAt.compareTo(a.createdAt)
          : a.createdAt.compareTo(b.createdAt),
    );
    return list;
  }

  /// Rename anytime (D-01).
  void rename(String id, String newTitle) {
    final s = _box.get(id);
    if (s != null) {
      s.title = newTitle;
      s.save();
    }
  }

  void setFavorite(String id, bool favorite) {
    final s = _box.get(id);
    if (s != null) {
      s.favorite = favorite;
      s.save();
    }
  }

  /// Marks a session started/ended and persists live duration (B-08 clock).
  void markStarted(String id, DateTime startedAt) {
    final s = _box.get(id);
    if (s != null) {
      s.startedAt = startedAt;
      s.save();
    }
  }

  void markEnded(String id, DateTime endedAt, int durationMsLive) {
    final s = _box.get(id);
    if (s != null) {
      s.endedAt = endedAt;
      s.durationMsLive = durationMsLive;
      s.save();
    }
  }

  void delete(String id) => _box.delete(id);

  /// Duplicate a session (D-04) — new id, same metadata, no segments.
  Session duplicate(String id) {
    final src = _box.get(id);
    if (src == null) {
      throw StateError('session $id not found');
    }
    return create(
      title: '${src.title} (copy)',
      srcLang: src.srcLang,
      tgtLang: src.tgtLang,
      mode: src.mode,
    );
  }

  /// Deletes a session AND all of its segments (orphan prevention).
  /// Returns the number of segments removed.
  int deleteCascade(String id, SegmentRepository segments) {
    final orphans = segments.forSession(id).map((s) => s.id).toList();
    for (final segId in orphans) {
      segments.delete(segId);
    }
    _box.delete(id);
    return orphans.length;
  }
}

/// Segment repository (D-02): append-only during live, editable after.
///
/// [upsert] is idempotent by segment id — the reconciliation seam (D-03):
/// replaying the same spool twice never duplicates rows.
class SegmentRepository {
  SegmentRepository(this._box);

  final Box<Segment> _box;

  /// Appends a segment. Returns the stored segment.
  Segment append({
    required String sessionId,
    required String sourceText,
    required String translatedText,
    required double t0Ms,
    required double t1Ms,
    required String srcLang,
    double? confidence,
    String? id,
  }) {
    final segment = Segment(
      id: id ?? const Uuid().v7(),
      sessionId: sessionId,
      t0Ms: t0Ms,
      t1Ms: t1Ms,
      sourceText: sourceText,
      translatedText: translatedText,
      confidence: confidence,
      srcLang: srcLang,
    );
    _box.put(segment.id, segment);
    return segment;
  }

  /// Idempotent upsert by segment id (D-03 reconciliation).
  /// Returns true if a NEW row was created, false if it already existed.
  bool upsert(Segment segment) {
    final existed = _box.containsKey(segment.id);
    _box.put(segment.id, segment);
    return !existed;
  }

  List<Segment> forSession(String sessionId, {bool byTime = true}) {
    final list = _box.values.where((s) => s.sessionId == sessionId).toList();
    if (byTime) {
      list.sort((a, b) => a.t0Ms.compareTo(b.t0Ms));
    }
    return list;
  }

  Segment? byId(String id) => _box.get(id);

  /// Editable after (D-02): updates text fields + rebuilds search index.
  void updateText(String id, {String? sourceText, String? translatedText}) {
    final s = _box.get(id);
    if (s != null) {
      if (sourceText != null) s.sourceText = sourceText;
      if (translatedText != null) s.translatedText = translatedText;
      s.searchIndex = Segment.buildSearchIndex(s.sourceText, s.translatedText);
      s.save();
    }
  }

  void delete(String id) => _box.delete(id);

  /// Global prefix search across source+translated (D-06).
  List<Segment> search(String query, {int limit = 100}) {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return const [];
    final hits = _box.values.where((s) => s.searchIndex.contains(q)).toList()
      ..sort((a, b) => a.t0Ms.compareTo(b.t0Ms));
    return hits.take(limit).toList();
  }

  int count() => _box.length;

  /// Merges [segmentId] with the chronologically NEXT segment of the same
  /// session (D-05 editor merge). Texts join with a space, t1 extends to the
  /// next segment's t1, and the next row is deleted. Returns the merged
  /// segment, or null when there is no next segment.
  Segment? mergeWithNext(String segmentId) {
    final seg = _box.get(segmentId);
    if (seg == null) return null;

    final session = forSession(seg.sessionId); // sorted by t0
    final idx = session.indexWhere((s) => s.id == segmentId);
    if (idx < 0 || idx == session.length - 1) return null;

    final next = session[idx + 1];
    seg
      ..sourceText = '${seg.sourceText.trim()} ${next.sourceText.trim()}'
      ..translatedText =
          '${seg.translatedText.trim()} ${next.translatedText.trim()}'
      ..t1Ms = next.t1Ms
      ..searchIndex =
          Segment.buildSearchIndex(seg.sourceText, seg.translatedText);
    seg.save();
    _box.delete(next.id);
    return seg;
  }

  /// Splits [segmentId] into two segments (D-05 editor split).
  ///
  /// [sourceCharIndex] is where the SOURCE text is cut (the second segment
  /// starts with `substring(sourceCharIndex)`); translated text is divided
  /// proportionally by character count, and the time range is divided by the
  /// same ratio (best-effort — word-level timing is not recoverable, per
  /// architecture OpenQ 1 interpolation fallback).
  ///
  /// Returns the NEW (second) segment, or null when the index is out of
  /// bounds or the cut would produce an empty half.
  Segment? split(String segmentId, {required int sourceCharIndex}) {
    final seg = _box.get(segmentId);
    if (seg == null) return null;

    final src = seg.sourceText;
    if (sourceCharIndex <= 0 || sourceCharIndex >= src.length) return null;

    final srcA = src.substring(0, sourceCharIndex).trim();
    final srcB = src.substring(sourceCharIndex).trim();
    if (srcA.isEmpty || srcB.isEmpty) return null;

    final ratio = sourceCharIndex / src.length;
    final en = seg.translatedText;
    var cut = (en.length * ratio).round();
    // Never cut inside a surrogate pair: back off while the code unit before
    // the cut is a high surrogate (i.e. the pair spans the boundary).
    while (cut > 0 &&
        cut < en.length &&
        en.codeUnitAt(cut - 1) >= 0xD800 &&
        en.codeUnitAt(cut - 1) <= 0xDBFF) {
      cut--;
    }
    final enA = en.substring(0, cut).trim();
    final enB = en.substring(cut).trim();

    final tCut = seg.t0Ms + (seg.t1Ms - seg.t0Ms) * ratio;

    seg
      ..sourceText = srcA
      ..translatedText = enA
      ..t1Ms = tCut
      ..searchIndex = Segment.buildSearchIndex(srcA, enA);
    seg.save();

    final second = Segment(
      id: const Uuid().v7(),
      sessionId: seg.sessionId,
      t0Ms: tCut,
      t1Ms: seg.t1Ms,
      sourceText: srcB,
      translatedText: enB,
      confidence: seg.confidence,
      srcLang: seg.srcLang,
    );
    _box.put(second.id, second);
    return second;
  }

  /// Recomputes the derived [Segment.searchIndex] for every stored row
  /// (§3.5: "tokenized prefix index rebuilt lazily"). Returns the number of
  /// rows whose index actually changed (legacy rows migrated).
  int rebuildIndex() {
    var changed = 0;
    for (final seg in _box.values) {
      final correct = Segment.buildSearchIndex(
        seg.sourceText,
        seg.translatedText,
      );
      if (seg.searchIndex != correct) {
        seg.searchIndex = correct;
        seg.save();
        changed++;
      }
    }
    return changed;
  }
}
