import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/core/danger_alerts.dart';
import 'package:mingtu_ai/core/navigation_tracker.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';

/// Unified speech dispatch -- the module-7 spec from the
/// design conversation (ChatGPT share, section 7, read in
/// full on 2026-11-09) as restated in the user's brief:
/// five priority levels (P0 emergency/danger, P1 avoidance,
/// P2 turn, P3 straight, P4 info), straight prompts only on
/// a confirmed straight segment at a 3-second cadence,
/// immediate interruption by higher priorities, a re-check
/// before resuming, and expiry / duplicate / contradiction
/// filtering.
///
/// The tests below are numbered after section 7.7 of that
/// spec. Items 11, 12 and 15 concern the avoidance-action
/// layer (side-space confirmation, action-result tracking,
/// sensor-health gating) and are implemented with the
/// avoidance module in the danger-recognition step; they
/// are intentionally NOT claimed here.
void main() {
  final DateTime t0 = DateTime(2026, 1, 1, 12);

  SpeechRequest req(
    String id,
    SpeechKind kind, {
    DateTime? at,
    int ttlSeconds = 30,
    bool neverExpires = false,
    String version = 'v1',
  }) {
    final DateTime start = at ?? t0;
    return SpeechRequest(
      id: id,
      eventId: 'e-$id',
      text: 'msg-$id',
      kind: kind,
      createdAt: start,
      expiresAt: start.add(Duration(seconds: ttlSeconds)),
      navigationStateVersion: version,
      neverExpires: neverExpires,
    );
  }

  group('module 7.7 -- the spec tests', () {
    test(
        '7.7-1 on a straight segment, straight prompts run on a '
        '3-second cycle', () {
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

    test('7.7-2 off a straight segment, no straight cycle runs', () {
      final SpeechScheduler s = SpeechScheduler();
      expect(
        s.shouldPlayStraight(
            now: t0, straightSegmentConfirmed: false, riskActive: false),
        isFalse,
      );
      // The live-navigation source of the confirmation: the
      // tracker only reports a straight segment on a 直行 step.
      AmapStep step(String action) => AmapStep(
            action: action,
            orientation: '北',
            distanceM: 50,
            durationS: 40,
            polyline: const <GeoPoint>[],
          );
      final NavigationTracker tracker = NavigationTracker(
        steps: <AmapStep>[step('直行'), step('左转')],
        stepTexts: const <String>['a', 'b'],
        destination: const GeoPoint(latitude: 37.72, longitude: 120.44),
        destinationName: '图书馆',
      );
      expect(tracker.currentSegmentIsStraight, isTrue);
      tracker.currentStepIndex = 1;
      expect(tracker.currentSegmentIsStraight, isFalse);
    });

    test('7.7-3 a high-priority risk pauses straight prompts at once', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('st', SpeechKind.straight), t0);
      expect(s.submit(req('dg', SpeechKind.danger), t0), isTrue);
      expect(s.active!.id, 'dg');
      expect(s.interruptedLog, contains('st'));
      // Production wiring: a danger submission enters the
      // unified pause state, which clears the straight clock
      // via pauseStraight and anchors the nav version. The
      // behaviour itself (danger preempts, TTS stop is really
      // issued) is covered by production-path widget tests in
      // test/codex_f951240_fix_test.dart.
      final String mainDart = File('lib/main.dart').readAsStringSync();
      expect(mainDart, contains('_scheduler.pauseStraight()'));
      expect(mainDart, contains('_pauseStraightForRisk();'));
      expect(mainDart, contains('_straightPausedNavVersion = _navVersion'));
    });

    test(
        '7.7-4 while the risk is still present, straight does not '
        'resume', () {
      final SpeechScheduler s = SpeechScheduler();
      expect(
        s.resumeStraight(
            now: t0,
            straightSegmentConfirmed: true,
            riskActive: true,
            currentNavigationVersion: 'v1',
            straightNavigationVersion: 'v1'),
        isFalse,
      );
      // And a queued straight prompt is dropped at promotion
      // time while a risk is active.
      final SpeechScheduler s2 = SpeechScheduler();
      s2.submit(req('em', SpeechKind.emergency), t0);
      s2.submit(req('st', SpeechKind.straight), t0);
      s2.completeActive();
      expect(
        s2.promoteNext(t0, straightSegmentConfirmed: true, riskActive: true),
        isNull,
      );
      expect(s2.droppedExpiredLog, contains('st'));
    });

    test(
        '7.7-5 once the risk clears and navigation is still valid, '
        'the 3-second timer restarts (no catch-up)', () {
      final SpeechScheduler s = SpeechScheduler();
      final DateTime t1 = t0.add(const Duration(seconds: 30));
      expect(
        s.resumeStraight(
            now: t1,
            straightSegmentConfirmed: true,
            riskActive: false,
            currentNavigationVersion: 'v1',
            straightNavigationVersion: 'v1'),
        isTrue,
      );
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
      // Production wiring (Codex re-test of f951240): the
      // resume re-check now runs on EVERY speech completion
      // through the unified _recheckStraightResume, and the
      // confirmation it consults is the tracker-governed
      // production rule.
      final String mainDart = File('lib/main.dart').readAsStringSync();
      expect(mainDart, contains('_recheckStraightResume();'));
      expect(mainDart, contains('straightSegmentConfirmedNow('));
    });

    test('7.7-6 when a turn state appears, the straight cycle stops', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('st', SpeechKind.straight), t0);
      expect(s.submit(req('tn', SpeechKind.turn), t0), isTrue);
      expect(s.active!.id, 'tn');
      expect(s.interruptedLog, contains('st'));
    });

    test(
        '7.7-7 when the navigation state changes, old instructions '
        'are dropped or re-validated', () {
      final SpeechScheduler s = SpeechScheduler();
      // A straight prompt created under v1 must not resume
      // under v2 without re-validation.
      expect(
        s.resumeStraight(
            now: t0,
            straightSegmentConfirmed: true,
            riskActive: false,
            currentNavigationVersion: 'v2',
            straightNavigationVersion: 'v1'),
        isFalse,
      );
    });

    test('7.7-8 an expired avoidance instruction is never played', () {
      final SpeechScheduler s = SpeechScheduler();
      final SpeechRequest old =
          req('av', SpeechKind.obstacleAvoidance, ttlSeconds: 5);
      expect(s.submit(old, t0.add(const Duration(seconds: 10))), isFalse);
      expect(s.droppedExpiredLog, contains('av'));
      expect(s.active, isNull);
      // Queued and expired before promotion: also dropped.
      final SpeechScheduler s2 = SpeechScheduler();
      s2.submit(req('em', SpeechKind.emergency), t0);
      s2.submit(req('av2', SpeechKind.obstacleAvoidance, ttlSeconds: 5), t0);
      s2.completeActive();
      expect(
        s2.promoteNext(t0.add(const Duration(seconds: 10)),
            straightSegmentConfirmed: true, riskActive: false),
        isNull,
      );
      expect(s2.droppedExpiredLog, contains('av2'));
    });

    test('7.7-9 the same risk event never announces twice in a row', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('a', SpeechKind.danger), t0);
      expect(s.submit(req('a', SpeechKind.danger), t0), isFalse);
      expect(s.droppedDuplicateLog, contains('a'));
      // The production danger path additionally debounces
      // per category.
      final DangerAlertGate gate = DangerAlertGate();
      expect(gate.tryPass(DangerCategory.vehicle, t0), isTrue);
      expect(
        gate.tryPass(
            DangerCategory.vehicle, t0.add(const Duration(seconds: 5))),
        isFalse,
      );
      expect(
        gate.tryPass(
            DangerCategory.vehicle, t0.add(const Duration(seconds: 11))),
        isTrue,
      );
    });

    test(
        '7.7-10 two contradictory action instructions are never '
        'played back to back', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('av', SpeechKind.obstacleAvoidance), t0);
      expect(s.submit(req('tn', SpeechKind.turn), t0), isFalse);
      expect(s.droppedConflictLog, contains('tn'));
      expect(s.active!.id, 'av');
    });

    test(
        '7.7-13 an emergency request immediately pauses all '
        'non-essential speech', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('in', SpeechKind.info), t0);
      expect(s.submit(req('em', SpeechKind.emergency), t0), isTrue);
      expect(s.active!.id, 'em');
      expect(s.interruptedLog, contains('in'));
      final SpeechScheduler s2 = SpeechScheduler();
      s2.submit(req('st', SpeechKind.straight), t0);
      s2.submit(req('em', SpeechKind.emergency), t0);
      expect(s2.active!.id, 'em');
      expect(s2.interruptedLog, contains('st'));
    });

    test(
        '7.7-14 with the LLM service unavailable, the base dispatch '
        'and predefined rules still work', () {
      // The dispatch layer is pure local code: no LLM import
      // anywhere in the scheduler / danger / risk modules.
      for (final String path in <String>[
        'lib/core/speech_scheduler.dart',
        'lib/core/danger_alerts.dart',
        'lib/core/risk_engine.dart',
      ]) {
        final String src = File(path).readAsStringSync();
        expect(src.toLowerCase(), isNot(contains('llm')),
            reason: '$path must not depend on the LLM layer');
        expect(src, isNot(contains('LlmGateway')));
      }
      // And it functions end to end with no gateway at all.
      final SpeechScheduler s = SpeechScheduler();
      expect(s.submit(req('tn', SpeechKind.turn), t0), isTrue);
      expect(s.submit(req('dg', SpeechKind.danger), t0), isTrue);
      expect(s.active!.id, 'dg');
    });
  });

  group('supporting scheduler guarantees', () {
    test('five levels: P0 < P1 < P2 < P3 < P4', () {
      expect(priorityOf(SpeechKind.emergency), 0);
      expect(priorityOf(SpeechKind.danger), 1);
      expect(priorityOf(SpeechKind.obstacleAvoidance), 2);
      expect(priorityOf(SpeechKind.turn), 3);
      expect(priorityOf(SpeechKind.straight), 4);
      expect(priorityOf(SpeechKind.info), 5);
    });

    test('P1 avoidance interrupts a turn (never silenced by it)', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('tn', SpeechKind.turn), t0);
      expect(s.submit(req('av', SpeechKind.obstacleAvoidance), t0), isTrue);
      expect(s.active!.id, 'av');
    });

    test('P4 info never interrupts P2: it queues', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('tn', SpeechKind.turn), t0);
      expect(s.submit(req('in', SpeechKind.info), t0), isTrue);
      expect(s.active!.id, 'tn');
      expect(s.queue.map((q) => q.id), contains('in'));
    });

    test('a duplicate of a queued eventId is dropped', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('x', SpeechKind.emergency), t0);
      s.submit(req('b', SpeechKind.info), t0);
      expect(s.submit(req('b', SpeechKind.info), t0), isFalse);
      expect(s.queue, hasLength(1));
    });

    test('a never-expires danger request survives its nominal TTL', () {
      final SpeechScheduler s = SpeechScheduler();
      final SpeechRequest dg =
          req('dg', SpeechKind.danger, ttlSeconds: 5, neverExpires: true);
      expect(s.submit(dg, t0.add(const Duration(minutes: 5))), isTrue);
      expect(s.active!.id, 'dg');
    });

    test('pauseStraight drops the prompt and its clock', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('st', SpeechKind.straight), t0);
      s.recordStraightPlayed(t0);
      s.pauseStraight();
      expect(s.active, isNull);
      expect(s.interruptedLog, contains('st'));
      expect(s.lastStraightPlayedAt, isNull);
    });

    test('straight is refused while a risk is active', () {
      final SpeechScheduler s = SpeechScheduler();
      expect(
        s.shouldPlayStraight(
            now: t0, straightSegmentConfirmed: true, riskActive: true),
        isFalse,
      );
    });
  });
}
