import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:livelens/bridge.dart';
import 'package:livelens/src/data/datetime_adapter.dart';
import 'package:livelens/src/data/models.dart';
import 'package:livelens/src/data/reconciliation.dart';
import 'package:livelens/src/data/repositories.dart';

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

  setUp(() async {
    Hive.init(Directory.systemTemp.createTempSync('livelens_test').path);
    sessionBox = await Hive.openBox<Session>('sessions');
    segmentBox = await Hive.openBox<Segment>('segments');
    sessions = SessionRepository(sessionBox);
    segments = SegmentRepository(segmentBox);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
  });

  group('SessionRepository (D-01/D-04)', () {
    test('create persists and byId retrieves', () {
      final s = sessions.create(
        title: 'NHK Evening News',
        srcLang: 'ja',
        tgtLang: 'en',
        mode: 'translate',
      );

      final got = sessions.byId(s.id);
      expect(got, isNotNull);
      expect(got!.title, 'NHK Evening News');
      expect(got.srcLang, 'ja');
      expect(got.tgtLang, 'en');
      expect(got.mode, 'translate');
      expect(got.favorite, isFalse);
    });

    test('all() sorts newest first', () {
      final a = sessions.create(
        title: 'a',
        srcLang: 'ja',
        tgtLang: 'en',
        mode: 'translate',
      );
      // Ensure distinct timestamps (same-ms creation would be unstable).
      final b = sessions.create(
        title: 'b',
        srcLang: 'ja',
        tgtLang: 'en',
        mode: 'translate',
      );
      b.createdAt = a.createdAt.add(const Duration(milliseconds: 1));
      b.save();

      final list = sessions.all();
      expect(list.map((s) => s.id), [b.id, a.id]);
    });

    test('rename updates title', () {
      final s = sessions.create(
        title: 'old',
        srcLang: 'ja',
        tgtLang: 'en',
        mode: 'translate',
      );
      sessions.rename(s.id, 'new title');
      expect(sessions.byId(s.id)!.title, 'new title');
    });

    test('markEnded persists live duration', () {
      final s = sessions.create(
        title: 't',
        srcLang: 'ja',
        tgtLang: 'en',
        mode: 'translate',
      );
      sessions.markStarted(s.id, DateTime(2026, 1, 1, 10));
      sessions.markEnded(s.id, DateTime(2026, 1, 1, 10, 30), 1_500_000);
      final got = sessions.byId(s.id)!;
      expect(got.durationMsLive, 1_500_000);
      expect(got.endedAt, isNotNull);
    });

    test('duplicate creates new id with copy suffix', () {
      final s = sessions.create(
        title: 'NHK',
        srcLang: 'ja',
        tgtLang: 'en',
        mode: 'translate',
      );
      final copy = sessions.duplicate(s.id);
      expect(copy.id, isNot(s.id));
      expect(copy.title, 'NHK (copy)');
      expect(sessions.all(), hasLength(2));
    });

    test('delete removes', () {
      final s = sessions.create(
        title: 'x',
        srcLang: 'ja',
        tgtLang: 'en',
        mode: 'translate',
      );
      sessions.delete(s.id);
      expect(sessions.byId(s.id), isNull);
    });
  });

  group('SegmentRepository (D-02)', () {
    test('append stores and forSession returns time-ordered', () {
      final s = sessions.create(
        title: 't',
        srcLang: 'ja',
        tgtLang: 'en',
        mode: 'translate',
      );
      segments.append(
        sessionId: s.id,
        sourceText: 'second',
        translatedText: 'two',
        t0Ms: 2000,
        t1Ms: 3000,
        srcLang: 'ja',
      );
      segments.append(
        sessionId: s.id,
        sourceText: 'first',
        translatedText: 'one',
        t0Ms: 0,
        t1Ms: 1000,
        srcLang: 'ja',
      );

      final list = segments.forSession(s.id);
      expect(list.map((x) => x.sourceText), ['first', 'second']);
    });

    test('upsert is idempotent by segment id', () {
      final s = sessions.create(
        title: 't',
        srcLang: 'ja',
        tgtLang: 'en',
        mode: 'translate',
      );
      final seg = Segment(
        id: 'stable-id',
        sessionId: s.id,
        t0Ms: 0,
        t1Ms: 1000,
        sourceText: 'hello',
        translatedText: 'こんにちは',
        srcLang: 'ja',
      );

      expect(segments.upsert(seg), isTrue); // new
      expect(segments.upsert(seg), isFalse); // duplicate
      expect(segments.count(), 1);
    });

    test('updateText rebuilds search index', () {
      final s = sessions.create(
        title: 't',
        srcLang: 'ja',
        tgtLang: 'en',
        mode: 'translate',
      );
      final seg = segments.append(
        sessionId: s.id,
        sourceText: 'old',
        translatedText: 'old en',
        t0Ms: 0,
        t1Ms: 1000,
        srcLang: 'ja',
      );

      segments.updateText(seg.id, sourceText: 'new', translatedText: 'new en');
      final got = segments.byId(seg.id)!;
      expect(got.sourceText, 'new');
      expect(got.searchIndex, contains('new en'));
    });

    test('search matches source and translated case-insensitively', () {
      final s = sessions.create(
        title: 't',
        srcLang: 'ja',
        tgtLang: 'en',
        mode: 'translate',
      );
      segments.append(
        sessionId: s.id,
        sourceText: 'そろそろ出発',
        translatedText: 'I think we should leave soon',
        t0Ms: 0,
        t1Ms: 1000,
        srcLang: 'ja',
      );
      segments.append(
        sessionId: s.id,
        sourceText: 'other',
        translatedText: 'unrelated',
        t0Ms: 2000,
        t1Ms: 3000,
        srcLang: 'ja',
      );

      expect(segments.search('LEAVE'), hasLength(1));
      expect(segments.search('そろそろ'), hasLength(1));
      expect(segments.search('nope'), isEmpty);
    });
  });

  group('ReconciliationImporter (D-03)', () {
    test('imports spool lines and is idempotent on replay', () {
      final s = sessions.create(
        title: 'recovered',
        srcLang: 'ja',
        tgtLang: 'en',
        mode: 'translate',
      );
      final importer = ReconciliationImporter(
        segments: segments,
        sessions: sessions,
        codec: const EventCodec(),
      );

      // Two spool lines matching the contract §3 `final` shape.
      final lines = [
        '{"type":"final","v":1,"sessionId":"${s.id}","segId":"seg-1",'
            '"t0":0.0,"t1":1000.0,"srcLang":"ja","src":"hello",'
            '"en":"こんにちは","conf":0.9}',
        '{"type":"final","v":1,"sessionId":"${s.id}","segId":"seg-2",'
            '"t0":1000.0,"t1":2000.0,"srcLang":"ja","src":"world",'
            '"en":"世界","conf":0.8}',
      ];

      final first = importer.importLines(lines);
      expect(first.imported, 2);
      expect(first.skippedDuplicates, 0);
      expect(first.malformed, 0);
      expect(segments.count(), 2);

      // Replay the same spool → all duplicates, no new rows.
      final second = importer.importLines(lines);
      expect(second.imported, 0);
      expect(second.skippedDuplicates, 2);
      expect(segments.count(), 2);
    });

    test('malformed lines are counted not fatal', () {
      final importer = ReconciliationImporter(
        segments: segments,
        sessions: sessions,
        codec: const EventCodec(),
      );

      final result = importer.importLines([
        'not json at all',
        '{"type":"state","v":1,"value":"capturing","detail":""}', // wrong type
        '',
      ]);

      expect(result.imported, 0);
      expect(result.malformed, 2);
      expect(segments.count(), 0);
    });

    test('imported segments are queryable by session', () {
      final s = sessions.create(
        title: 'recovered',
        srcLang: 'ja',
        tgtLang: 'en',
        mode: 'translate',
      );
      final importer = ReconciliationImporter(
        segments: segments,
        sessions: sessions,
        codec: const EventCodec(),
      );

      importer.importLines([
        '{"type":"final","v":1,"sessionId":"${s.id}","segId":"seg-1",'
            '"t0":0.0,"t1":1000.0,"srcLang":"ja","src":"hello",'
            '"en":"こんにちは","conf":0.9}',
      ]);

      final list = segments.forSession(s.id);
      expect(list, hasLength(1));
      expect(list.first.sourceText, 'hello');
      expect(list.first.translatedText, 'こんにちは');
    });
  });
}
