import 'dart:convert';

import '../data/models.dart';

/// Export format identifiers (D-08; visual.md §4.6 export sheet tabs).
enum ExportFormat {
  txt('TXT'),
  markdown('MD'),
  srt('SRT'),
  vtt('VTT'),
  json('JSON');

  const ExportFormat(this.label);
  final String label;
}

/// Renders a session's segments into a shareable/exportable document.
///
/// All writers are pure functions over [Session] + [List<Segment>] — no I/O,
/// fully unit-testable. The caller (UI layer) handles file writing / share
/// intents (D-09).
abstract final class SessionExporter {
  /// Renders [session] + [segments] in [format].
  ///
  /// [includeTimestamps] toggles the timestamp column/prefix for TXT/MD
  /// (visual.md §4.6 export sheet: "include-timestamps toggle"). SRT/VTT
  /// always include timestamps (that's their purpose); JSON always includes
  /// the full structured data.
  static String render(
    ExportFormat format,
    Session session,
    List<Segment> segments, {
    bool includeTimestamps = true,
  }) {
    final sorted = [...segments]..sort((a, b) => a.t0Ms.compareTo(b.t0Ms));
    return switch (format) {
      ExportFormat.txt => _txt(session, sorted, includeTimestamps),
      ExportFormat.markdown => _markdown(session, sorted, includeTimestamps),
      ExportFormat.srt => _srt(sorted),
      ExportFormat.vtt => _vtt(sorted),
      ExportFormat.json => _json(session, sorted),
    };
  }

  // -- TXT -------------------------------------------------------------------

  static String _txt(Session s, List<Segment> segs, bool withTs) {
    final buf = StringBuffer()
      ..writeln(s.title)
      ..writeln('${s.srcLang} → ${s.tgtLang} · ${s.mode}')
      ..writeln('---');
    for (final seg in segs) {
      if (withTs) {
        buf.writeln('[${_fmtClock(seg.t0Ms)}] ${seg.sourceText}');
        buf.writeln(seg.translatedText);
      } else {
        buf.writeln(seg.sourceText);
        buf.writeln(seg.translatedText);
      }
      buf.writeln();
    }
    return buf.toString().trimRight();
  }

  // -- Markdown --------------------------------------------------------------

  static String _markdown(Session s, List<Segment> segs, bool withTs) {
    final buf = StringBuffer()
      ..writeln('# ${s.title}')
      ..writeln()
      ..writeln('*${s.srcLang} → ${s.tgtLang} · ${s.mode}*')
      ..writeln();
    for (final seg in segs) {
      if (withTs) {
        buf.writeln('**${_fmtClock(seg.t0Ms)}**');
      }
      buf.writeln(seg.sourceText);
      buf.writeln();
      buf.writeln('> ${seg.translatedText}');
      buf.writeln();
    }
    return buf.toString().trimRight();
  }

  // -- SRT -------------------------------------------------------------------

  /// SubRip: `index\nHH:MM:SS,mmm --> HH:MM:SS,mmm\ntext\n\n`
  static String _srt(List<Segment> segs) {
    final buf = StringBuffer();
    for (var i = 0; i < segs.length; i++) {
      final seg = segs[i];
      buf
        ..writeln(i + 1)
        ..writeln('${_fmtSrt(seg.t0Ms)} --> ${_fmtSrt(seg.t1Ms)}')
        ..writeln(seg.sourceText)
        ..writeln(seg.translatedText)
        ..writeln();
    }
    return buf.toString().trimRight();
  }

  // -- VTT -------------------------------------------------------------------

  /// WebVTT: `WEBVTT\n\nHH:MM:SS.mmm --> HH:MM:SS.mmm\ntext\n\n`
  static String _vtt(List<Segment> segs) {
    final buf = StringBuffer()
      ..writeln('WEBVTT')
      ..writeln();
    for (final seg in segs) {
      buf
        ..writeln('${_fmtVtt(seg.t0Ms)} --> ${_fmtVtt(seg.t1Ms)}')
        ..writeln(seg.sourceText)
        ..writeln(seg.translatedText)
        ..writeln();
    }
    return buf.toString().trimRight();
  }

  // -- JSON ------------------------------------------------------------------

  static String _json(Session s, List<Segment> segs) {
    final payload = <String, Object?>{
      'session': {
        'id': s.id,
        'title': s.title,
        'createdAt': s.createdAt.toIso8601String(),
        'startedAt': s.startedAt?.toIso8601String(),
        'endedAt': s.endedAt?.toIso8601String(),
        'durationMsLive': s.durationMsLive,
        'srcLang': s.srcLang,
        'tgtLang': s.tgtLang,
        'mode': s.mode,
        'favorite': s.favorite,
      },
      'segments': segs
          .map(
            (seg) => <String, Object?>{
              'id': seg.id,
              't0Ms': seg.t0Ms,
              't1Ms': seg.t1Ms,
              'sourceText': seg.sourceText,
              'translatedText': seg.translatedText,
              'confidence': seg.confidence,
              'srcLang': seg.srcLang,
            },
          )
          .toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  // -- time formatting helpers ------------------------------------------------

  /// `mm:ss.d` — matches SegmentRow.formatTimestamp (visual.md mono chip).
  ///
  /// Rounding happens on the TENTHS unit, then minutes/seconds are derived
  /// from that — so 59.96 s correctly rolls over to `01:00.0` and no
  /// intermediate `00:60.0` can ever be emitted.
  static String _fmtClock(double ms) {
    final tenths = (ms / 100).round();
    final minutes = tenths ~/ 600;
    final remainder = tenths % 600;
    final seconds = (remainder / 10).toStringAsFixed(1);
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.padLeft(4, '0')}';
  }

  /// SRT: `HH:MM:SS,mmm` (comma milliseconds).
  static String _fmtSrt(double ms) {
    final total = ms.round();
    final h = total ~/ 3_600_000;
    final m = (total % 3_600_000) ~/ 60_000;
    final s = (total % 60_000) ~/ 1000;
    final milli = total % 1000;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')},${milli.toString().padLeft(3, '0')}';
  }

  /// VTT: `HH:MM:SS.mmm` (dot milliseconds).
  static String _fmtVtt(double ms) {
    final total = ms.round();
    final h = total ~/ 3_600_000;
    final m = (total % 3_600_000) ~/ 60_000;
    final s = (total % 60_000) ~/ 1000;
    final milli = total % 1000;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}.${milli.toString().padLeft(3, '0')}';
  }
}
