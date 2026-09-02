import 'models.dart';
import 'repositories.dart';

/// One heuristic-parsed piece of raw text (D-07).
class ParsedSegment {
  const ParsedSegment({
    required this.text,
    required this.t0Ms,
    required this.t1Ms,
  });

  /// The paragraph/sentence text (trimmed, non-empty).
  final String text;

  /// Synthetic timeline position — manual sessions have no real audio, but
  /// timestamps are required so SRT/VTT export (D-08) and the transcript
  /// editor work uniformly with captured sessions.
  final double t0Ms;
  final double t1Ms;
}

/// Naive heuristic parser for manual sessions (D-07, PRD F3).
///
/// "paragraph → segment":
/// 1. Split raw text on blank lines → paragraphs.
/// 2. A paragraph longer than [maxParagraphChars] is subdivided at sentence
///    boundaries (。！？.!? and newlines), packing sentences greedily up to
///    the limit — never splitting mid-sentence.
/// 3. Synthetic timestamps: reading pace of [charsPerSecond], minimum
///    [minSegmentMs] per segment, small inter-segment gap.
///
/// Pure function — no I/O; the creator layer persists results.
abstract final class ManualSessionParser {
  static const maxParagraphChars = 200;
  static const charsPerSecond = 12.0;
  static const minSegmentMs = 1500.0;
  static const gapMs = 200.0;

  /// Splits sentences:
  /// - After CJK terminators (。！？) — always, since Japanese text has no
  ///   inter-sentence whitespace.
  /// - After Latin terminators (.!?) — only when followed by whitespace, so
  ///   decimals ("3.14") and abbreviations ("e.g.") stay intact.
  /// - On runs of newlines (paragraphs already folded these to spaces; kept
  ///   for direct calls with raw multi-line input).
  static final _sentenceBreak = RegExp(r'(?<=[。！？])|(?<=[.!?])\s+|\n+');

  /// Parses [raw] into time-ordered segments. Returns empty list for
  /// whitespace-only input.
  static List<ParsedSegment> parse(String raw) {
    final paragraphs = raw
        .split(RegExp(r'\n\s*\n'))
        .map((p) => p.replaceAll('\n', ' ').trim())
        .where((p) => p.isNotEmpty)
        .expand(_subdivideIfLong)
        .toList();

    final result = <ParsedSegment>[];
    var cursor = 0.0;
    for (final text in paragraphs) {
      final durationMs = (text.length / charsPerSecond * 1000).clamp(
        minSegmentMs,
        double.infinity,
      );
      result.add(
        ParsedSegment(text: text, t0Ms: cursor, t1Ms: cursor + durationMs),
      );
      cursor += durationMs + gapMs;
    }
    return result;
  }

  static Iterable<String> _subdivideIfLong(String paragraph) sync* {
    if (paragraph.length <= maxParagraphChars) {
      yield paragraph;
      return;
    }
    final sentences = paragraph
        .split(_sentenceBreak)
        .where((s) => s.trim().isNotEmpty);
    final buf = StringBuffer();
    for (final sentence in sentences) {
      final candidate = buf.isEmpty
          ? sentence
          : '${buf.toString().trim()} $sentence';
      if (candidate.length > maxParagraphChars && buf.isNotEmpty) {
        yield buf.toString().trim();
        buf.clear();
      }
      buf.write(sentence);
      buf.write(' ');
    }
    final rest = buf.toString().trim();
    if (rest.isNotEmpty) yield rest;
  }
}

/// Persists a manual session (D-07, PRD F3): "Dashboard → '+' → title +
/// paste clipboard/typed text → editable plain segment list".
///
/// Mirrors the §3.5 transcription-mode convention: [Segment.translatedText]
/// duplicates [sourceText] (keeps the editor simple; user edits both in the
/// transcript view later).
class ManualSessionCreator {
  ManualSessionCreator({required this.sessions, required this.segments});

  final SessionRepository sessions;
  final SegmentRepository segments;

  /// Creates the session row and appends one segment per parsed chunk.
  /// Returns the created session.
  ///
  /// [title] falls back to 'Manual session' when blank (visual.md F3 flow
  /// allows leaving the title empty).
  Session create({
    required String rawText,
    String title = '',
    String srcLang = 'auto',
  }) {
    final parsed = ManualSessionParser.parse(rawText);
    final session = sessions.create(
      title: title.trim().isEmpty ? 'Manual session' : title.trim(),
      srcLang: srcLang,
      tgtLang: srcLang == 'auto' ? 'auto' : srcLang,
      mode: 'manual',
    );
    for (final p in parsed) {
      segments.append(
        sessionId: session.id,
        sourceText: p.text,
        translatedText: p.text,
        t0Ms: p.t0Ms,
        t1Ms: p.t1Ms,
        srcLang: srcLang,
      );
    }
    // Manual sessions are "complete" at creation: started == ended, and the
    // live duration equals the synthetic timeline so exports are sane.
    sessions.markStarted(session.id, session.createdAt);
    sessions.markEnded(session.id, session.createdAt, _lastEnd(parsed));
    return session;
  }

  static int _lastEnd(List<ParsedSegment> parsed) =>
      parsed.isEmpty ? 0 : parsed.last.t1Ms.round();
}
