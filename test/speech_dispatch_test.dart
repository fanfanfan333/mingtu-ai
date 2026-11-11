import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/core/danger_alerts.dart';
import 'package:mingtu_ai/core/navigation_tracker.dart';
import 'package:mingtu_ai/core/avoidance_advisor.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/core/straight_pacing.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';

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
/// spec. Items 11 and 12 (side-space confirmation and
/// action-result tracking) are covered below through the
/// production avoidance advisor; item 15 (sensor-health
/// gating: unknown geometry is never treated as near) is
/// covered in test/avoidance_and_hazard_test.dart.
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
      // pauseStraight is clock-only (Codex re-test of
      // d01a081): it must NOT clear the active prompt -- the
      // old behaviour destroyed the state the preemption
      // logic inspected, so the physical stop never ran.
      final SpeechScheduler s2 = SpeechScheduler();
      s2.submit(req('st', SpeechKind.straight), t0);
      s2.recordStraightPlayed(t0);
      s2.pauseStraight();
      expect(s2.active!.id, 'st');
      expect(s2.interruptedLog, isNot(contains('st')));
      expect(s2.lastStraightPlayedAt, isNull);
      // The production pause state (the pacing machine):
      // the hold blocks every tick until the unified
      // re-check passes, and a live risk blocks the re-check.
      final StraightPacingMachine m = StraightPacingMachine();
      m.begin();
      m.hold('v1');
      expect(m.canTick, isFalse);
      expect(
        m.recheck(
            riskActive: true,
            dangerPending: false,
            trackerReady: false,
            currentSegmentStraight: true,
            currentNavVersion: 'v1'),
        isFalse,
      );
      expect(m.canTick, isFalse);
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
      // The production resume path, behaviourally (Codex
      // re-test of d01a081): the pacing machine releases its
      // hold only through the unified re-check -- never
      // while a danger prompt is still pending -- and arms
      // the timer exactly once per transition into running.
      final StraightPacingMachine m = StraightPacingMachine();
      m.begin();
      m.hold('v1');
      expect(
        m.recheck(
            riskActive: false,
            dangerPending: true,
            trackerReady: false,
            currentSegmentStraight: true,
            currentNavVersion: 'v1'),
        isFalse,
        reason: 'a pending danger blocks the resume',
      );
      expect(
        m.recheck(
            riskActive: false,
            dangerPending: false,
            trackerReady: false,
            currentSegmentStraight: true,
            currentNavVersion: 'v1'),
        isTrue,
      );
      expect(m.canTick, isTrue);
      expect(m.armCount, 2, reason: 'begin + this resume');
      expect(
        m.recheck(
            riskActive: false,
            dangerPending: false,
            trackerReady: false,
            currentSegmentStraight: true,
            currentNavVersion: 'v1'),
        isFalse,
        reason: 'already running: no second timer arm',
      );
      expect(m.armCount, 2);
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
        '7.7-11 when side space cannot be confirmed, no '
        'deterministic left/right step instruction is generated', () {
      const Detection car = Detection(
          label: 'car', confidence: 0.9, cx: 0.5, cy: 0.8, w: 0.4, h: 0.5);
      // (a) Central and near, but neither side has any
      // clear-frame history: stop only.
      final AvoidanceAdvisor a1 = AvoidanceAdvisor();
      AvoidanceDecision d = a1.decide(hazard: car, orientationStable: true);
      expect(d.advice, StepAdvice.stopOnly);
      expect(d.speech, '前方有机动车，请停下。');
      // (b) A side has cleared, but the orientation is not
      // stable: still stop only.
      final AvoidanceAdvisor a2 = AvoidanceAdvisor();
      for (int i = 0; i < 4; i++) {
        a2.observeFrame(const <Detection>[]);
      }
      d = a2.decide(hazard: car, orientationStable: false);
      expect(d.advice, StepAdvice.stopOnly);
      expect(d.speech, isNot(contains('迈一步')));
      // (c) Box geometry unknown (w/h zero): the distance
      // is unknown, never near, so never a step.
      const Detection ghost =
          Detection(label: 'car', confidence: 0.9, cx: 0.5, cy: 0.5);
      d = AvoidanceAdvisor().decide(hazard: ghost, orientationStable: true);
      expect(d.advice, StepAdvice.stopOnly);
    });

    test(
        '7.7-12 a spoken avoidance instruction is not treated '
        'as a completed avoidance: frame evidence decides', () {
      const Detection car = Detection(
          label: 'car', confidence: 0.9, cx: 0.5, cy: 0.8, w: 0.4, h: 0.5);
      AvoidanceAdvisor primed() {
        final AvoidanceAdvisor a = AvoidanceAdvisor();
        for (int i = 0; i < 4; i++) {
          a.observeFrame(const <Detection>[]);
        }
        return a;
      }

      // A step IS advised when all three conditions hold...
      final AvoidanceAdvisor a1 = primed();
      final AvoidanceDecision d =
          a1.decide(hazard: car, orientationStable: true);
      expect(d.advice, isNot(StepAdvice.stopOnly));
      expect(a1.hasPendingAction, isTrue);
      // ...but while the hazard stays central, the action
      // never confirms itself; after the window it resolves
      // as UNCERTAIN (main speaks a stop instruction then).
      AvoidanceNotice? notice;
      for (int i = 0; i < 6; i++) {
        notice = a1.observeFrame(const <Detection>[car]);
      }
      expect(notice, AvoidanceNotice.actionUncertain);
      expect(a1.hasPendingAction, isFalse);
      // Only frame evidence -- the centre clear on
      // consecutive frames -- confirms an action.
      final AvoidanceAdvisor a2 = primed();
      a2.decide(hazard: car, orientationStable: true);
      AvoidanceNotice? notice2;
      for (int i = 0; i < 2; i++) {
        notice2 = a2.observeFrame(const <Detection>[]);
      }
      expect(notice2, AvoidanceNotice.actionConfirmed);
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

    test('pauseStraight disarms only the clock, never the active prompt', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('st', SpeechKind.straight), t0);
      s.recordStraightPlayed(t0);
      s.pauseStraight();
      expect(s.active!.id, 'st');
      expect(s.interruptedLog, isNot(contains('st')));
      expect(s.lastStraightPlayedAt, isNull);
    });

    test('a same-level danger replaces the playing danger (no queue)', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('p', SpeechKind.danger), t0);
      expect(s.submit(req('c', SpeechKind.danger), t0), isTrue);
      expect(s.active!.id, 'c');
      expect(s.queue, isEmpty);
      expect(s.interruptedLog, contains('p'));
    });

    test('a same-event danger is deduped, never preemptive', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('p', SpeechKind.danger), t0);
      expect(s.submit(req('p', SpeechKind.danger), t0), isFalse);
      expect(s.droppedDuplicateLog, contains('p'));
      expect(s.active!.id, 'p');
    });

    test('a queued danger is replaced by a newer danger event', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('em', SpeechKind.emergency), t0);
      s.submit(req('d1', SpeechKind.danger), t0);
      s.submit(req('d2', SpeechKind.danger), t0);
      expect(s.queue.map((SpeechRequest q) => q.id), <String>['d2']);
      expect(s.interruptedLog, contains('d1'));
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
