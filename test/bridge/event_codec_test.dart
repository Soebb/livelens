import 'package:flutter_test/flutter_test.dart';
import 'package:livelens/bridge.dart';

/// Matcher: decode must throw [MalformedEventException].
final throwsMalformedEvent = throwsA(isA<MalformedEventException>());

void main() {
  group('EventCodec — contract §3.4 samples decode verbatim', () {
    const codec = EventCodec();

    test('state event', () {
      final event = codec.decode(const {
        'type': 'state',
        'v': 1,
        'value': 'capturing',
        'detail': 'FGS started',
      });
      expect(event, isA<StateEvent>());
      final state = event! as StateEvent;
      expect(state.state, SessionState.capturing);
      expect(state.detail, 'FGS started');
    });

    test('partial event (no text by design)', () {
      final event = codec.decode(const {
        'type': 'partial',
        'v': 1,
        'sessionId': 's1',
        'segId': 'seg-7',
        'showHint': true,
      });
      expect(event, isA<PartialEvent>());
      final partial = event! as PartialEvent;
      expect(partial.sessionId, 's1');
      expect(partial.segmentId, 'seg-7');
      expect(partial.showHint, isTrue);
    });

    test('final event — exact §3.4 sample incl. Japanese text', () {
      final event = codec.decode(const {
        'type': 'final',
        'v': 1,
        'sessionId': '…',
        'segId': '…',
        't0': 1234.5,
        't1': 5678.0,
        'srcLang': 'ja',
        'src': 'そろそろ出発したほうがいいと思います。',
        'en': 'I think we should leave soon.',
        'conf': 0.87,
      });
      expect(event, isA<FinalEvent>());
      final f = event! as FinalEvent;
      expect(f.sessionId, '…');
      expect(f.segmentId, '…');
      expect(f.t0Ms, 1234.5);
      expect(f.t1Ms, 5678.0);
      expect(f.sourceLang, 'ja');
      expect(f.sourceText, 'そろそろ出発したほうがいいと思います。');
      expect(f.translatedText, 'I think we should leave soon.');
      expect(f.confidence, 0.87);
    });

    test('perf event', () {
      final event = codec.decode(const {
        'type': 'perf',
        'v': 1,
        'rtfMsPerSec': 310,
        'queueDepth': 0,
        'rssMb': 380.0,
        'batteryPctDropLastPeriod': 1.2,
      });
      expect(event, isA<PerfEvent>());
      final p = event! as PerfEvent;
      expect(p.rtfMsPerSec, 310);
      expect(p.rtf, closeTo(0.31, 1e-9));
      expect(p.queueDepth, 0);
      expect(p.rssMb, 380.0);
      expect(p.batteryPctDropLastPeriod, 1.2);
    });

    test('spoolPending event', () {
      final event = codec.decode(const {
        'type': 'spoolPending',
        'v': 1,
        'count': 42,
      });
      expect(event, isA<SpoolPendingEvent>());
      expect((event! as SpoolPendingEvent).count, 42);
    });

    test('error event with registry code', () {
      final event = codec.decode(const {
        'type': 'error',
        'v': 1,
        'code': 'CAPTURE_REVOKED',
        'detail': 'user stopped casting',
      });
      expect(event, isA<ErrorEvent>());
      final e = event! as ErrorEvent;
      expect(e.code, LivelensErrorCode.captureRevoked);
      expect(e.detail, 'user stopped casting');
    });

    test('error event with UNKNOWN code parses to unknown', () {
      final event = codec.decode(const {
        'type': 'error',
        'v': 1,
        'code': 'SOME_FUTURE_CODE',
        'detail': 'x',
      });
      expect(event, isA<ErrorEvent>());
      expect((event! as ErrorEvent).code, LivelensErrorCode.unknown);
    });

    test('projectionGranted / projectionDenied', () {
      expect(
        codec.decode(const {'type': 'projectionGranted', 'v': 1}),
        isA<ProjectionGrantedEvent>(),
      );
      expect(
        codec.decode(const {'type': 'projectionDenied', 'v': 1}),
        isA<ProjectionDeniedEvent>(),
      );
    });
  });

  group('EventCodec — skip rules (contract §0 additive changes)', () {
    const codec = EventCodec();

    test('unknown type returns null', () {
      expect(
        codec.decode(const {'type': 'futureThing', 'v': 1, 'x': 1}),
        isNull,
      );
    });

    test('non-map payload returns null', () {
      expect(codec.decode('not a map'), isNull);
      expect(codec.decode(42), isNull);
      expect(codec.decode(null), isNull);
      expect(codec.decode(<Object?, Object?>{}), isNull); // no type key
    });

    test('future major version returns null', () {
      expect(
        codec.decode(const {'type': 'final', 'v': 2 /* rest irrelevant */}),
        isNull,
      );
    });
  });

  group(
    'EventCodec — malformed known shapes throw MalformedEventException',
    () {
      const codec = EventCodec();
      final validFinal = <Object?, Object?>{
        'type': 'final',
        'v': 1,
        'sessionId': 's',
        'segId': 'g',
        't0': 0.0,
        't1': 10.0,
        'srcLang': 'ja',
        'src': 'a',
        'en': 'b',
        'conf': 0.5,
      };

      test('missing "v"', () {
        final bad = Map<Object?, Object?>.from(validFinal)..remove('v');
        expect(() => codec.decode(bad), throwsMalformedEvent);
      });

      test('non-int "v"', () {
        final bad = Map<Object?, Object?>.from(validFinal)..['v'] = 'one';
        expect(() => codec.decode(bad), throwsMalformedEvent);
      });

      test('t1 < t0 rejected', () {
        final bad = Map<Object?, Object?>.from(validFinal)..['t1'] = -5.0;
        expect(() => codec.decode(bad), throwsMalformedEvent);
      });

      test('conf out of range rejected', () {
        final bad = Map<Object?, Object?>.from(validFinal)..['conf'] = 1.5;
        expect(() => codec.decode(bad), throwsMalformedEvent);
      });

      test('state.value outside enum rejected', () {
        expect(
          () => codec.decode(const {
            'type': 'state',
            'v': 1,
            'value': 'warping',
            'detail': '',
          }),
          throwsMalformedEvent,
        );
      });

      test('spoolPending negative count rejected', () {
        expect(
          () =>
              codec.decode(const {'type': 'spoolPending', 'v': 1, 'count': -1}),
          throwsMalformedEvent,
        );
      });

      test('perf negative rtf rejected', () {
        expect(
          () => codec.decode(const {
            'type': 'perf',
            'v': 1,
            'rtfMsPerSec': -1,
            'queueDepth': 0,
            'rssMb': 100.0,
            'batteryPctDropLastPeriod': 0.0,
          }),
          throwsMalformedEvent,
        );
      });
    },
  );

  group('Round-trip: every event serializes back to its wire shape', () {
    const codec = EventCodec();
    final samples = <LivelensEvent>[
      const StateEvent(state: SessionState.paused, detail: 'drain complete'),
      const ProjectionGrantedEvent(),
      const ProjectionDeniedEvent(),
      const PartialEvent(sessionId: 's', segmentId: 'g', showHint: false),
      const FinalEvent(
        sessionId: 's',
        segmentId: 'g',
        t0Ms: 1234.5,
        t1Ms: 5678.0,
        sourceLang: 'ja',
        sourceText: 'そろそろ出発したほうがいいと思います。',
        translatedText: 'I think we should leave soon.',
        confidence: 0.87,
      ),
      const PerfEvent(
        rtfMsPerSec: 310,
        queueDepth: 0,
        rssMb: 380.0,
        batteryPctDropLastPeriod: 1.2,
      ),
      const SpoolPendingEvent(count: 3),
      const ErrorEvent(code: LivelensErrorCode.thermalPause, detail: 'severe'),
    ];

    test('toWire() → decode() yields an equal event', () {
      for (final original in samples) {
        final decoded = codec.decode(original.toWire());
        expect(decoded, isNotNull, reason: '${original.wireType} must decode');
        // Structural equality via field-by-field wire comparison.
        expect(
          decoded!.toWire(),
          original.toWire(),
          reason: '${original.wireType} round-trip',
        );
      }
    });

    test('every wire payload carries v == 1', () {
      for (final sample in samples) {
        expect(sample.toWire()['v'], 1, reason: sample.wireType);
      }
    });
  });
}
