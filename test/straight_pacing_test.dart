import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/straight_pacing.dart';

/// The straight-pacing state machine (Codex re-test of
/// d01a081, item 2): pause, timing and the resume re-check
/// are one machine. These tests pin the transitions main
/// relies on -- above all the reroute suspension (no
/// straight prompts while re-planning, no reading the old
/// tracker, exactly one timer arm on recovery) and the rule
/// that straight timing never restarts before a danger
/// prompt has finished.
void main() {
  StraightPacingMachine running() {
    final StraightPacingMachine m = StraightPacingMachine();
    m.begin();
    return m;
  }

  bool recheck(
    StraightPacingMachine m, {
    bool riskActive = false,
    bool dangerPending = false,
    bool trackerReady = false,
    bool currentSegmentStraight = true,
    String version = 'v1',
  }) =>
      m.recheck(
        riskActive: riskActive,
        dangerPending: dangerPending,
        trackerReady: trackerReady,
        currentSegmentStraight: currentSegmentStraight,
        currentNavVersion: version,
      );

  group('hold and resume', () {
    test('a hold blocks ticks until the re-check passes', () {
      final StraightPacingMachine m = running();
      m.hold('v1');
      expect(m.state, StraightPacingState.held);
      expect(m.canTick, isFalse);
      expect(recheck(m, riskActive: true), isFalse);
      expect(recheck(m), isTrue);
      expect(m.canTick, isTrue);
    });

    test('a pending danger blocks the resume even with no risk active', () {
      final StraightPacingMachine m = running();
      m.hold('v1');
      // The danger prompt has not finished: its completion
      // callback is what re-runs this re-check afterwards.
      expect(recheck(m, dangerPending: true), isFalse);
      expect(m.state, StraightPacingState.held);
      expect(recheck(m, dangerPending: false), isTrue);
    });

    test('an unconfirmed segment keeps the hold', () {
      final StraightPacingMachine m = running();
      m.hold('v1');
      expect(recheck(m, currentSegmentStraight: false), isFalse);
      expect(m.state, StraightPacingState.held);
    });

    test('a version change re-anchors instead of wedging the hold', () {
      final StraightPacingMachine m = running();
      m.hold('v1');
      expect(recheck(m, version: 'v2'), isTrue);
      expect(m.heldNavVersion, 'v2');
    });

    test('a second hold does not move the anchor', () {
      final StraightPacingMachine m = running();
      m.hold('v1');
      m.hold('v2');
      expect(m.heldNavVersion, 'v1');
    });
  });

  group('reroute suspension', () {
    test('while re-planning, no resume is possible at all', () {
      final StraightPacingMachine m = running();
      m.suspendForReroute();
      expect(m.canTick, isFalse);
      // The caller passes trackerReady=false while the
      // re-plan is in flight, so even a straight-looking
      // answer (which could only come from the OLD tracker)
      // cannot release the suspension.
      expect(recheck(m, trackerReady: false), isFalse);
      expect(m.state, StraightPacingState.suspendedForReroute);
    });

    test('the new tracker must be ready AND on a straight segment', () {
      final StraightPacingMachine m = running();
      m.suspendForReroute();
      expect(recheck(m, trackerReady: true, currentSegmentStraight: false),
          isFalse);
      expect(recheck(m, trackerReady: true), isTrue);
      expect(m.canTick, isTrue);
    });

    test('risk or a pending danger also block a reroute resume', () {
      final StraightPacingMachine m = running();
      m.suspendForReroute();
      expect(recheck(m, trackerReady: true, riskActive: true), isFalse);
      expect(recheck(m, trackerReady: true, dangerPending: true), isFalse);
      expect(recheck(m, trackerReady: true), isTrue);
    });
  });

  group('exactly one timer', () {
    test('begin arms once; repeated begins do not re-arm', () {
      final StraightPacingMachine m = StraightPacingMachine();
      expect(m.begin(), isTrue);
      expect(m.begin(), isFalse);
      expect(m.armCount, 1);
    });

    test('a resume arms once; re-checks while running never re-arm', () {
      final StraightPacingMachine m = running();
      m.hold('v1');
      final int before = m.armCount;
      expect(recheck(m), isTrue);
      expect(m.armCount, before + 1);
      expect(recheck(m), isFalse);
      expect(recheck(m), isFalse);
      expect(m.armCount, before + 1);
    });

    test('stop ends the session; a later begin starts a new one', () {
      final StraightPacingMachine m = running();
      m.stop();
      expect(m.state, StraightPacingState.idle);
      expect(m.canTick, isFalse);
      expect(m.begin(), isTrue);
      expect(m.canTick, isTrue);
    });
  });
}
