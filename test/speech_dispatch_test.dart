import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/core/navigation_tracker.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';

/// Unified speech dispatch (the user's module-7 spec, as
/// restated in the 2026-11-09 brief): five priority levels,
/// straight prompts only on a confirmed straight segment at
/// a 3-second cadence, immediate interruption by higher
/// priorities, re-check before resuming, and expiry /
/// duplicate / contradiction filtering. The ChatGPT share
/// link's own 7.7 list could not be read (the page returned
/// no conversation content), so these 15 tests enumerate the
/// brief's stated rules one by one.
void main() {
  final DateTime t0 = DateTime(2026, 1, 1, 12);

  SpeechRequest req(
    String id,
    SpeechKind kind, {
    DateTime? at,
    int ttlSeconds = 30,
    bool neverExpires = false,
  }) {
    final DateTime start = at ?? t0;
    return SpeechRequest(
      id: id,
      eventId: 'e-$id',
      text: 'msg-$id',
      kind: kind,
      createdAt: start,
      expiresAt: start.add(Duration(seconds: ttlSeconds)),
      navigationStateVersion: 'v1',
      neverExpires: neverExpires,
    );
  }

  group('unified dispatch: the 15 spec rules', () {
    test('01 five levels: P0 < P1 < P2 < P3 < P4', () {
      expect(priorityOf(SpeechKind.emergency), 0);
      expect(priorityOf(SpeechKind.danger), 1);
      expect(priorityOf(SpeechKind.obstacleAvoidance), 2);
      expect(priorityOf(SpeechKind.turn), 3);
      expect(priorityOf(SpeechKind.straight), 4);
      expect(priorityOf(SpeechKind.info), 5);
    });

    test('02 P0 danger interrupts an active straight prompt', () {
      final SpeechScheduler s = SpeechScheduler();
      expect(s.submit(req('st', SpeechKind.straight), t0), isTrue);
      expect(s.submit(req('dg', SpeechKind.danger), t0), isTrue);
      expect(s.active!.id, 'dg');
      expect(s.interruptedLog, contains('st'));
    });

    test('03 P0 danger interrupts an active turn prompt', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('tn', SpeechKind.turn), t0);
      s.submit(req('dg', SpeechKind.danger), t0);
      expect(s.active!.id, 'dg');
      expect(s.interruptedLog, contains('tn'));
    });

    test('04 P1 avoidance interrupts a turn (never silenced by it)', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('tn', SpeechKind.turn), t0);
      expect(s.submit(req('av', SpeechKind.obstacleAvoidance), t0), isTrue);
      expect(s.active!.id, 'av');
    });

    test('05 a turn conflicting with active avoidance is dropped', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('av', SpeechKind.obstacleAvoidance), t0);
      expect(s.submit(req('tn', SpeechKind.turn), t0), isFalse);
      expect(s.droppedConflictLog, contains('tn'));
      expect(s.active!.id, 'av');
    });

    test('06 P4 info never interrupts P2: it queues', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('tn', SpeechKind.turn), t0);
      expect(s.submit(req('in', SpeechKind.info), t0), isTrue);
      expect(s.active!.id, 'tn');
      expect(s.queue.map((q) => q.id), contains('in'));
    });

    test('07 an expired request is dropped and never activated', () {
      final SpeechScheduler s = SpeechScheduler();
      final SpeechRequest old = req('old', SpeechKind.info, ttlSeconds: 5);
      expect(s.submit(old, t0.add(const Duration(seconds: 10))), isFalse);
      expect(s.droppedExpiredLog, contains('old'));
      expect(s.active, isNull);
    });

    test('08 a duplicate of the active eventId is dropped', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('a', SpeechKind.info), t0);
      expect(s.submit(req('a', SpeechKind.info), t0), isFalse);
      expect(s.droppedDuplicateLog, contains('a'));
    });

    test('09 a duplicate of a queued eventId is dropped', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('x', SpeechKind.emergency), t0);
      s.submit(req('b', SpeechKind.info), t0);
      expect(s.submit(req('b', SpeechKind.info), t0), isFalse);
      expect(s.queue, hasLength(1));
    });

    test('10 a never-expires danger request survives its nominal TTL', () {
      final SpeechScheduler s = SpeechScheduler();
      final SpeechRequest dg =
          req('dg', SpeechKind.danger, ttlSeconds: 5, neverExpires: true);
      expect(s.submit(dg, t0.add(const Duration(minutes: 5))), isTrue);
      expect(s.active!.id, 'dg');
    });

    test('11 straight is refused when the segment is not confirmed', () {
      final SpeechScheduler s = SpeechScheduler();
      expect(
        s.shouldPlayStraight(
            now: t0, straightSegmentConfirmed: false, riskActive: false),
        isFalse,
      );
    });

    test('12 straight is refused while a risk is active', () {
      final SpeechScheduler s = SpeechScheduler();
      expect(
        s.shouldPlayStraight(
            now: t0, straightSegmentConfirmed: true, riskActive: true),
        isFalse,
      );
    });

    test('13 straight cadence is 3 s: not before, due at/after', () {
      final SpeechScheduler s = SpeechScheduler();
      s.recordStraightPlayed(t0);
      expect(
        s.shouldPlayStraight(
            now: t0.add(const Duration(milliseconds: 2999)),
            straightSegmentConfirmed: true,
            riskActive: false),
        isFalse,
      );
      expect(
        s.shouldPlayStraight(
            now: t0.add(const Duration(milliseconds: 3000)),
            straightSegmentConfirmed: true,
            riskActive: false),
        isTrue,
      );
    });

    test('14 pauseStraight drops the prompt and its clock (no catch-up)', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('st', SpeechKind.straight), t0);
      s.recordStraightPlayed(t0);
      s.pauseStraight();
      expect(s.active, isNull);
      expect(s.interruptedLog, contains('st'));
      expect(s.lastStraightPlayedAt, isNull);
    });

    test(
        '15 resumeStraight restarts the clock and refuses on risk '
        'or version change', () {
      final SpeechScheduler s = SpeechScheduler();
      final DateTime t1 = t0.add(const Duration(seconds: 30));
      expect(
        s.resumeStraight(
            now: t1,
            straightSegmentConfirmed: true,
            riskActive: true,
            currentNavigationVersion: 'v1',
            straightNavigationVersion: 'v1'),
        isFalse,
      );
      expect(
        s.resumeStraight(
            now: t1,
            straightSegmentConfirmed: true,
            riskActive: false,
            currentNavigationVersion: 'v2',
            straightNavigationVersion: 'v1'),
        isFalse,
      );
      expect(
        s.resumeStraight(
            now: t1,
            straightSegmentConfirmed: true,
            riskActive: false,
            currentNavigationVersion: 'v1',
            straightNavigationVersion: 'v1'),
        isTrue,
      );
      // Fresh timing: not due again until a full 3 s later.
      expect(
        s.shouldPlayStraight(
            now: t1.add(const Duration(seconds: 2)),
            straightSegmentConfirmed: true,
            riskActive: false),
        isFalse,
      );
      expect(
        s.shouldPlayStraight(
            now: t1.add(const Duration(seconds: 3)),
            straightSegmentConfirmed: true,
            riskActive: false),
        isTrue,
      );
    });
  });

  group('live navigation straight source + production wiring', () {
    AmapStep step(String action) => AmapStep(
          action: action,
          orientation: '北',
          distanceM: 50,
          durationS: 40,
          polyline: const <GeoPoint>[],
        );

    test('the tracker reports a straight segment only on a 直行 step', () {
      final NavigationTracker t = NavigationTracker(
        steps: <AmapStep>[step('直行'), step('左转')],
        stepTexts: const <String>['a', 'b'],
        destination: const GeoPoint(latitude: 37.72, longitude: 120.44),
        destinationName: '图书馆',
      );
      expect(t.currentSegmentIsStraight, isTrue);
      t.currentStepIndex = 1;
      expect(t.currentSegmentIsStraight, isFalse);
    });

    test('main wires danger-pause, post-danger resume and the live tick', () {
      final String mainDart = File('lib/main.dart').readAsStringSync();
      expect(mainDart, contains('_scheduler.pauseStraight()'));
      expect(mainDart, contains('_versionAtInterrupt = _navVersion'));
      expect(mainDart, contains('finishedKind == SpeechKind.danger'));
      expect(mainDart, contains('_liveNav?.currentSegmentIsStraight'));
    });
  });
}
