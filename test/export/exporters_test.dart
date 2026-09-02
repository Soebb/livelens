import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:livelens/src/data/models.dart';
import 'package:livelens/src/export/exporters.dart';

void main() {
  final session = Session(
    id: 'sess-1',
    title: 'NHK Evening News',
    createdAt: DateTime(2026, 4, 12, 20, 0),
    startedAt: DateTime(2026, 4, 12, 20, 0),
    endedAt: DateTime(2026, 4, 12, 20, 30),
    durationMsLive: 1_500_000,
    srcLang: 'ja',
    tgtLang: 'en',
    mode: 'translate',
  );

  final segments = [
    Segment(
      id: 'seg-1',
      sessionId: 'sess-1',
      t0Ms: 0,
      t1Ms: 2000,
      sourceText: 'そろそろ出発したほうがいいと思います。',
      translatedText: 'I think we should leave soon.',
      confidence: 0.87,
      srcLang: 'ja',
    ),
    Segment(
      id: 'seg-2',
      sessionId: 'sess-1',
      t0Ms: 2500,
      t1Ms: 5000,
      sourceText: '明日は晴れるでしょう。',
      translatedText: 'It will be sunny tomorrow.',
      confidence: 0.92,
      srcLang: 'ja',
    ),
  ];

  group('TXT export', () {
    test('includes header, timestamps, and bilingual lines', () {
      final out = SessionExporter.render(ExportFormat.txt, session, segments);
      expect(out, contains('NHK Evening News'));
      expect(out, contains('ja → en · translate'));
      expect(out, contains('[00:00.0] そろそろ出発したほうがいいと思います。'));
      expect(out, contains('I think we should leave soon.'));
      expect(out, contains('[00:02.5] 明日は晴れるでしょう。'));
    });

    test('includeTimestamps=false omits timestamps', () {
      final out = SessionExporter.render(
        ExportFormat.txt,
        session,
        segments,
        includeTimestamps: false,
      );
      expect(out, isNot(contains('[00:00.0]')));
      expect(out, contains('そろそろ出発したほうがいいと思います。'));
    });
  });

  group('Markdown export', () {
    test('renders heading, meta, and blockquote translation', () {
      final out = SessionExporter.render(
        ExportFormat.markdown,
        session,
        segments,
      );
      expect(out, contains('# NHK Evening News'));
      expect(out, contains('*ja → en · translate*'));
      expect(out, contains('**00:00.0**'));
      expect(out, contains('> I think we should leave soon.'));
    });
  });

  group('SRT export — regression fixtures', () {
    test('produces spec-compliant SubRip blocks', () {
      final out = SessionExporter.render(ExportFormat.srt, session, segments);
      expect(out, '''
1
00:00:00,000 --> 00:00:02,000
そろそろ出発したほうがいいと思います。
I think we should leave soon.

2
00:00:02,500 --> 00:00:05,000
明日は晴れるでしょう。
It will be sunny tomorrow.''');
    });

    test('handles hour rollover and millisecond padding', () {
      final longSeg = [
        Segment(
          id: 'x',
          sessionId: 's',
          t0Ms: 3_600_000 + 61_000 + 5, // 1:01:01.005
          t1Ms: 3_600_000 + 61_000 + 999,
          sourceText: 'a',
          translatedText: 'b',
          srcLang: 'ja',
        ),
      ];
      final out = SessionExporter.render(ExportFormat.srt, session, longSeg);
      expect(out, contains('01:01:01,005 --> 01:01:01,999'));
    });
  });

  group('VTT export', () {
    test('starts with WEBVTT and uses dot milliseconds', () {
      final out = SessionExporter.render(ExportFormat.vtt, session, segments);
      expect(out, startsWith('WEBVTT'));
      expect(out, contains('00:00:00.000 --> 00:00:02.000'));
      expect(out, contains('00:00:02.500 --> 00:00:05.000'));
    });
  });

  group('Timestamp formatting edge cases', () {
    test('59.96s rolls over to 01:00.0, never prints 00:60.0', () {
      final out = SessionExporter.render(ExportFormat.txt, session, [
        Segment(
          id: 'seg-x',
          sessionId: 'sess-1',
          t0Ms: 59_960,
          t1Ms: 60_040,
          sourceText: 'x',
          translatedText: 'y',
          srcLang: 'ja',
        ),
      ]);
      expect(out, contains('[01:00.0]'));
      expect(out, isNot(contains('60.0]')));
    });
  });

  group('JSON export', () {
    test('round-trips through jsonDecode with full structure', () {
      final out = SessionExporter.render(ExportFormat.json, session, segments);
      final decoded = jsonDecode(out) as Map<String, dynamic>;

      final s = decoded['session'] as Map<String, dynamic>;
      expect(s['id'], 'sess-1');
      expect(s['title'], 'NHK Evening News');
      expect(s['durationMsLive'], 1_500_000);
      expect(s['srcLang'], 'ja');
      expect(s['tgtLang'], 'en');
      expect(s['mode'], 'translate');

      final segs = decoded['segments'] as List;
      expect(segs, hasLength(2));
      final first = segs[0] as Map<String, dynamic>;
      expect(first['sourceText'], 'そろそろ出発したほうがいいと思います。');
      expect(first['translatedText'], 'I think we should leave soon.');
      expect(first['confidence'], 0.87);
    });
  });

  group('Ordering', () {
    test('segments are always exported time-ordered regardless of input', () {
      final shuffled = [segments[1], segments[0]];
      final out = SessionExporter.render(ExportFormat.srt, session, shuffled);
      // First block must be seg-1 (t0=0), not seg-2.
      expect(out, startsWith('1\n00:00:00,000'));
    });
  });
}
