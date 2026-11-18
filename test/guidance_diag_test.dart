/// The navigation-guidance diagnostic trail: bounded, ordered,
/// and REDACTED.
///
/// This trail is what makes a real-device report actionable
/// ("the warning interrupted the instruction, then the
/// instruction expired, then nothing came back"), so it is
/// copied into bug reports and chat. That is exactly why the
/// redaction assertions below are the point of the file: a log
/// line must never carry a position, a URL, a credential, a
/// place name or an exception's raw text.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/guidance/guidance_diag.dart';

void main() {
  setUp(GuidanceDiag.clear);
  tearDown(() {
    GuidanceDiag.clear();
    GuidanceDiag.clock = DateTime.now;
  });

  group('ring buffer', () {
    test('records in order with the redacted detail', () {
      GuidanceDiag.record('route_adopted', detail: 'steps=3');
      GuidanceDiag.record('first_instruction_enqueued',
          detail: 'kind=turn match=matched');
      final List<GuidanceDiagEntry> entries = GuidanceDiag.snapshot();
      expect(entries, hasLength(2));
      expect(entries[0].event, 'route_adopted');
      expect(entries[0].detail, 'steps=3');
      expect(entries[1].event, 'first_instruction_enqueued');
      expect(entries[1].detail, 'kind=turn match=matched');
      expect(GuidanceDiag.dumpLines().split('\n'), hasLength(2));
    });

    test('a null detail is recorded as no detail', () {
      GuidanceDiag.record('guidance_resumed');
      expect(GuidanceDiag.snapshot().single.detail, isNull);
      expect(GuidanceDiag.dumpLines(), isNot(contains('null')));
    });

    test('the ring keeps at most 200 lines, oldest dropped first', () {
      for (int i = 0; i < 250; i++) {
        GuidanceDiag.record('tts_started', detail: 'n=$i');
      }
      expect(GuidanceDiag.snapshot(), hasLength(GuidanceDiag.maxEntries));
      expect(GuidanceDiag.maxEntries, 200);
      final List<GuidanceDiagEntry> entries = GuidanceDiag.snapshot();
      expect(entries.first.detail, 'n=50');
      expect(entries.last.detail, 'n=249');
    });

    test('clear empties the ring', () {
      GuidanceDiag.record('route_adopted', detail: 'steps=1');
      GuidanceDiag.clear();
      expect(GuidanceDiag.snapshot(), isEmpty);
      expect(GuidanceDiag.dumpLines(), isEmpty);
    });

    test('the clock seam is honoured', () {
      GuidanceDiag.clock = () => DateTime(2026, 3, 4, 5, 6, 7);
      GuidanceDiag.record('route_adopted');
      expect(GuidanceDiag.snapshot().single.at, DateTime(2026, 3, 4, 5, 6, 7));
      expect(GuidanceDiag.dumpLines(), startsWith('2026-03-04T05:06:07'));
    });

    test('every production event name is one of the fixed names', () {
      for (final String name in <String>[
        'route_adopted',
        'first_instruction_enqueued',
        'speech_interrupted',
        'speech_expired',
        'tts_started',
        'guidance_resumed',
        'hazard_suppressed',
        'nav_paused_no_fix',
        'arrived_vicinity',
      ]) {
        expect(GuidanceDiag.eventNames, contains(name));
      }
      expect(GuidanceDiag.eventNames, hasLength(9));
    });

    test('an unknown event name is still recorded (no silent drop)', () {
      GuidanceDiag.record('something_new', detail: 'x=1');
      expect(GuidanceDiag.snapshot().single.event, 'something_new');
    });
  });

  group('redaction', () {
    test('a coordinate-shaped number never survives', () {
      expect(GuidanceDiag.redact('fix=116.400000,39.900000'),
          isNot(contains('116.4')));
      expect(GuidanceDiag.redact('37.724409,120.441723'),
          isNot(contains('37.72')));
    });

    test('URLs and credentials never survive', () {
      final String out = GuidanceDiag.redact(
          'GET https://proxy.example.test/walking?key=abc123 401');
      expect(out, isNot(contains('https://')));
      expect(out, isNot(contains('key=')));
      expect(out, isNot(contains('abc123')));
    });

    test('an API key written as a bare token is removed', () {
      final String out = GuidanceDiag.redact('token: sk-live-9f8e7d6c5b4a');
      expect(out, isNot(contains('sk-live')));
      expect(out, isNot(contains('9f8e7d6c5b4a')));
    });

    test('a long hexadecimal run is removed', () {
      final String out =
          GuidanceDiag.redact('hash=0123456789abcdef0123456789abcdef');
      expect(out, contains('<hex>'));
      expect(out, isNot(contains('0123456789abcdef')));
    });

    test('a place name the user said is removed from the detail', () {
      final String out = GuidanceDiag.redact('destination=同仁堂药店');
      expect(out, isNot(contains('同仁堂')));
      expect(out, isNot(contains('药店')));
    });

    test('a raw exception message is reduced to a marker', () {
      final String out = GuidanceDiag.redact(
          'StateError: 停止之前的语音播报失败 at main.dart');
      expect(out, isNot(contains('停止之前')));
      expect(out, contains('main.dart'));
    });

    test('the detail is length-capped', () {
      // 'z' is deliberately NOT a hexadecimal digit: an all-'a'
      // string would (correctly) be cut by the hash rule first,
      // and this case is about the length cap.
      final String out = GuidanceDiag.redact('z' * 400);
      expect(out.length, lessThanOrEqualTo(GuidanceDiag.maxDetailLength + 3));
      expect(out, endsWith('...'));
    });

    test('redaction is idempotent', () {
      final String once = GuidanceDiag.redact(
          'https://x.test/a?key=k 116.4,39.9 同仁堂 0123456789abcdef0123456789abcdef');
      expect(GuidanceDiag.redact(once), once);
    });
  });

  group('the dump is safe by construction', () {
    test('no coordinate shape and no credential in dumpLines', () {
      // Everything a real-device incident would actually carry.
      GuidanceDiag.record('nav_paused_no_fix',
          detail: 'hazard-persistent at 37.724409,120.441723');
      GuidanceDiag.record('route_adopted',
          detail: 'steps=3 dest=同仁堂药店 url=https://proxy.example.test/'
              'walking?key=abc123');
      GuidanceDiag.record('speech_interrupted',
          detail: 'by_kind=danger token: sk-live-9f8e7d6c5b4a');
      GuidanceDiag.record('guidance_resumed',
          detail: 'urgent-finished 116.400000,39.900000');
      final String dump = GuidanceDiag.dumpLines();

      expect(RegExp(r'1[0-9]{2}\.[0-9]').hasMatch(dump), isFalse,
          reason: dump);
      expect(dump, isNot(contains('key=')));
      expect(dump, isNot(contains('://')));
      expect(dump, isNot(contains('同仁堂')));
      expect(dump, isNot(contains('sk-live')));
      // The event names themselves are the useful part and stay.
      expect(dump, contains('nav_paused_no_fix'));
      expect(dump, contains('route_adopted'));
    });

    test('the two sinks agree: the ring is what the voice log got', () {
      GuidanceDiag.record('arrived_vicinity', detail: 'confident=true');
      final String dump = GuidanceDiag.dumpLines();
      expect(dump, contains('arrived_vicinity'));
      expect(dump, contains('confident=true'));
    });
  });
}
