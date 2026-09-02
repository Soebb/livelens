import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:livelens/src/data/manual_session.dart';
import 'package:livelens/src/data/datetime_adapter.dart';
import 'package:livelens/src/data/models.dart';
import 'package:livelens/src/data/repositories.dart';
import 'package:livelens/src/export/exporters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Hive's type registry is global — register adapters ONCE, not per-test.
  Hive.registerAdapter(SessionAdapter());
  Hive.registerAdapter(SegmentAdapter());
  Hive.registerAdapter(DateTimeAdapter());

  late Box<Session> sessionBox;
  late Box<Segment> segmentBox;
  late SessionRepository sessions;
  late SegmentRepository segments;
  late ManualSessionCreator creator;

  setUp(() async {
    Hive.init(Directory.systemTemp.createTempSync('livelens_test').path);
    sessionBox = await Hive.openBox<Session>('sessions');
    segmentBox = await Hive.openBox<Segment>('segments');
    sessions = SessionRepository(sessionBox);
    segments = SegmentRepository(segmentBox);
    creator = ManualSessionCreator(sessions: sessions, segments: segments);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
  });

  group('ManualSessionParser — paragraph splitting (D-07)', () {
    test('splits raw text on blank lines into paragraphs', () {
      final parsed = ManualSessionParser.parse(
        'First paragraph here.\n\nSecond paragraph there.',
      );
      expect(parsed, hasLength(2));
      expect(parsed[0].text, 'First paragraph here.');
      expect(parsed[1].text, 'Second paragraph there.');
    });

    test('single newlines are folded into one paragraph', () {
      final parsed = ManualSessionParser.parse(
        'Line one.\nLine two continues.',
      );
      expect(parsed, hasLength(1));
      expect(parsed[0].text, 'Line one. Line two continues.');
    });

    test('whitespace-only input yields no segments', () {
      expect(ManualSessionParser.parse(''), isEmpty);
      expect(ManualSessionParser.parse('   \n\n \t \n\n  '), isEmpty);
    });

    test('long paragraph is subdivided at sentence boundaries', () {
      // 6 sentences × 39 chars ≈ 234 chars > 200 limit.
      final long = List.filled(
        6,
        'This is sentence number which is long.',
      ).join(' ');
      expect(long.length, greaterThan(ManualSessionParser.maxParagraphChars));

      final parsed = ManualSessionParser.parse(long);
      expect(parsed.length, greaterThanOrEqualTo(2));
      for (final p in parsed) {
        expect(p.text, endsWith('long.'));
        expect(
          p.text.length,
          lessThanOrEqualTo(ManualSessionParser.maxParagraphChars),
        );
      }
    });

    test('Japanese sentence-ending punctuation splits too', () {
      // 17 chars × 14 = 238 chars > 200 limit, forcing subdivision.
      final parsed = ManualSessionParser.parse('そろそろ出発したほうがいいと思います。' * 14);
      expect(parsed.length, greaterThanOrEqualTo(2));
      for (final p in parsed) {
        expect(p.text, endsWith('。'));
      }
    });
  });

  group('ManualSessionParser — synthetic timestamps', () {
    test('segments are time-ordered with gaps and min duration', () {
      final parsed = ManualSessionParser.parse('A.\n\nB.\n\nC.');
      expect(parsed, hasLength(3));

      var prevT1 = -1.0;
      for (final p in parsed) {
        expect(p.t0Ms, greaterThanOrEqualTo(prevT1));
        // Reading-pace duration clamped to the 1.5 s minimum.
        expect(
          p.t1Ms - p.t0Ms,
          greaterThanOrEqualTo(ManualSessionParser.minSegmentMs - 0.001),
        );
        prevT1 = p.t1Ms;
      }
      // Inter-segment gap exists (not back-to-back zero-gap).
      expect(parsed[1].t0Ms, greaterThan(parsed[0].t1Ms));
    });

    test('duration scales with text length', () {
      final short = ManualSessionParser.parse('Hi.').single;
      final long = ManualSessionParser.parse('x' * 120).single;
      expect(long.t1Ms - long.t0Ms, greaterThan(short.t1Ms - short.t0Ms));
    });
  });

  group('ManualSessionCreator (D-07 + PRD F3)', () {
    test('creates session row + one segment per parsed chunk', () {
      final session = creator.create(
        rawText: 'First paragraph.\n\nSecond paragraph.',
        title: 'Pasted lecture notes',
        srcLang: 'ja',
      );

      final got = sessions.byId(session.id);
      expect(got, isNotNull);
      expect(got!.title, 'Pasted lecture notes');
      expect(got.mode, 'manual');
      expect(got.srcLang, 'ja');

      final segs = segments.forSession(session.id);
      expect(segs, hasLength(2));
      expect(segs[0].sourceText, 'First paragraph.');
      expect(segs[1].sourceText, 'Second paragraph.');
      // Transcription-mode convention: translated duplicates source.
      expect(segs[0].translatedText, segs[0].sourceText);
    });

    test('blank title falls back to Manual session', () {
      final session = creator.create(rawText: 'Hello.');
      expect(sessions.byId(session.id)!.title, 'Manual session');
    });

    test('manual session is complete at creation (started == ended)', () {
      final session = creator.create(rawText: 'A.\n\nB.');
      final s = sessions.byId(session.id)!;
      expect(s.startedAt, isNotNull);
      expect(s.endedAt, isNotNull);
      expect(s.durationMsLive, greaterThan(0));
    });

    test('empty text still creates a session with no segments', () {
      final session = creator.create(rawText: '   ');
      expect(sessions.byId(session.id), isNotNull);
      expect(segments.forSession(session.id), isEmpty);
    });

    test('created manual session exports to SRT with valid timeline', () {
      final session = creator.create(
        rawText: 'First paragraph.\n\nSecond paragraph.',
        title: 'Export check',
      );
      final segs = segments.forSession(session.id);

      final srt = SessionExporter.render(ExportFormat.srt, session, segs);
      expect(srt, startsWith('1\n'));
      expect(srt, contains('-->'));
      expect(srt, contains('First paragraph.'));
      expect(srt, contains('Second paragraph.'));
      // Parser timestamps must be monotonic across segments.
      expect(segs[1].t0Ms, greaterThanOrEqualTo(segs[0].t1Ms));
    });
  });
}
