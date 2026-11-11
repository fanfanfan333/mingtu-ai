/// NAVHAZ M2 section 3.1 / acceptance 3.4.1: the adaptive
/// frame-rate policy -- three tiers (still 2 / walking 10
/// / danger 20 FPS), immediate upshifts, the 3 s downshift
/// hysteresis, the substitute still gate (no track + no
/// new detection for 2 s), and the danger definition over
/// the hazard pipeline's own estimates.
///
/// Everything runs on a fake clock: the policy takes its
/// evaluation time as an argument, so a test drives whole
/// timelines by choosing stamps. All thresholds are read
/// from NavHazConfig -- no literal tier/hold number is
/// restated here.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/frame_rate_policy.dart';
import 'package:mingtu_ai/core/hazard/ego_motion.dart';
import 'package:mingtu_ai/core/hazard/ttc_estimator.dart';
import 'package:mingtu_ai/core/navhaz_config.dart';
import 'package:mingtu_ai/core/tracking/tracker.dart';

void main() {
  final DateTime t0 = DateTime(2026, 1, 1, 12);

  // A walking verdict from the repo's own judge (GPS
  // evidence above the walking threshold).
  EgoMotion walking() => EgoMotion.judge(gpsSpeedMps: 1.0);

  TrackEstimate estimate({
    required bool confirmed,
    double? ttcS,
    double? ttcUrgentS,
    bool approaching = false,
    bool willHit = false,
  }) {
    final Track track = Track(id: 1, label: 'car');
    track.confirmed = confirmed;
    return TrackEstimate(
      track: track,
      ttcS: ttcS,
      ttcScaleS: null,
      ttcRangeS: null,
      rangeM: null,
      closingSpeedMps: null,
      approaching: approaching,
      willHit: willHit,
      cxVelocity: 0,
      ttcUrgentS: ttcUrgentS,
    );
  }

  int eval(
    FrameRatePolicy p,
    DateTime at, {
    EgoMotion? motion,
    bool danger = false,
    bool track = false,
    DateTime? lastDetectionAt,
  }) {
    return p.evaluate(
      now: at,
      motion: motion ?? EgoMotion.still,
      dangerPresent: danger,
      hasLiveTrack: track,
      lastDetectionAt: lastDetectionAt,
    );
  }

  // Drive a fresh policy to the settled STILL tier: the
  // first still evaluation only STARTS the downshift
  // hold; a second one a full hold later lands the drop.
  FrameRatePolicy settledStill() {
    final FrameRatePolicy p = FrameRatePolicy();
    eval(p, t0);
    eval(p, t0.add(NavHazConfig.frameRateDownshiftHold));
    return p;
  }

  group('acceptance 3.4.1: tier sequence 2 -> 10 -> 20', () {
    test('still (gate satisfied) settles at the still tier', () {
      final FrameRatePolicy p = FrameRatePolicy();
      // From the walking start, the still conditions must
      // ALSO outlast the downshift hold before the target
      // drops: the first still evaluation starts the hold
      // (target unchanged), the one a full hold later
      // lands it.
      expect(eval(p, t0), NavHazConfig.frameRateWalkingFps);
      expect(
        eval(p, t0.add(NavHazConfig.frameRateDownshiftHold)),
        NavHazConfig.frameRateStillFps,
      );
      expect(p.tier, FrameRateTier.still);
    });

    test('walking upshifts to the walking tier immediately', () {
      final FrameRatePolicy p = settledStill();
      expect(p.targetFps, NavHazConfig.frameRateStillFps);
      expect(
        eval(p, t0.add(const Duration(seconds: 10)),
            motion: walking()),
        NavHazConfig.frameRateWalkingFps,
      );
    });

    test('danger upshifts to the danger tier immediately, '
        'even mid-hold', () {
      final FrameRatePolicy p = settledStill();
      expect(
        eval(p, t0.add(const Duration(seconds: 5)), danger: true),
        NavHazConfig.frameRateDangerFps,
      );
      expect(p.tier, FrameRateTier.danger);
    });

    test('full sequence still -> walking -> danger reads '
        '${NavHazConfig.frameRateStillFps} -> '
        '${NavHazConfig.frameRateWalkingFps} -> '
        '${NavHazConfig.frameRateDangerFps}', () {
      final FrameRatePolicy p = settledStill();
      final List<int> seen = <int>[p.targetFps];
      seen.add(eval(p, t0.add(const Duration(seconds: 4)),
          motion: walking()));
      seen.add(eval(p, t0.add(const Duration(seconds: 5)),
          motion: walking(), danger: true));
      expect(seen, <int>[
        NavHazConfig.frameRateStillFps,
        NavHazConfig.frameRateWalkingFps,
        NavHazConfig.frameRateDangerFps,
      ]);
    });
  });

  group('downshift hysteresis (3 s hold)', () {
    test('danger gone: target HOLDS the danger tier until '
        'the hold elapses, then drops', () {
      final FrameRatePolicy p = FrameRatePolicy();
      expect(eval(p, t0, motion: walking(), danger: true),
          NavHazConfig.frameRateDangerFps);
      final DateTime gone = t0.add(const Duration(seconds: 1));
      // Immediately after the danger clears: still danger.
      expect(eval(p, gone, motion: walking()),
          NavHazConfig.frameRateDangerFps);
      // One tick before the hold completes: still danger.
      expect(
        eval(
            p,
            gone
                .add(NavHazConfig.frameRateDownshiftHold)
                .subtract(const Duration(milliseconds: 1)),
            motion: walking()),
        NavHazConfig.frameRateDangerFps,
      );
      // Hold complete: drops to the walking tier.
      expect(
        eval(p, gone.add(NavHazConfig.frameRateDownshiftHold),
            motion: walking()),
        NavHazConfig.frameRateWalkingFps,
      );
    });

    test('a danger blip inside the hold resets the clock', () {
      final FrameRatePolicy p = FrameRatePolicy();
      eval(p, t0, motion: walking(), danger: true);
      final DateTime gone = t0.add(const Duration(seconds: 1));
      eval(p, gone, motion: walking()); // hold starts
      // Danger returns mid-hold: upshift state re-entered,
      // hold cleared.
      eval(p, gone.add(const Duration(seconds: 2)),
          motion: walking(), danger: true);
      final DateTime gone2 = gone.add(const Duration(seconds: 3));
      expect(eval(p, gone2, motion: walking()),
          NavHazConfig.frameRateDangerFps);
      // The FIRST hold's deadline must NOT fire the drop.
      expect(
        eval(p, gone.add(NavHazConfig.frameRateDownshiftHold),
            motion: walking()),
        NavHazConfig.frameRateDangerFps,
      );
      expect(
        eval(p, gone2.add(NavHazConfig.frameRateDownshiftHold),
            motion: walking()),
        NavHazConfig.frameRateWalkingFps,
      );
    });

    test('walking -> still also waits out the full hold', () {
      final FrameRatePolicy p = FrameRatePolicy();
      expect(eval(p, t0, motion: walking()),
          NavHazConfig.frameRateWalkingFps);
      final DateTime stopped = t0.add(const Duration(seconds: 2));
      expect(eval(p, stopped), NavHazConfig.frameRateWalkingFps);
      expect(
        eval(
            p,
            stopped
                .add(NavHazConfig.frameRateDownshiftHold)
                .subtract(const Duration(milliseconds: 1))),
        NavHazConfig.frameRateWalkingFps,
      );
      expect(
        eval(p, stopped.add(NavHazConfig.frameRateDownshiftHold)),
        NavHazConfig.frameRateStillFps,
      );
    });

    test('danger can drop TWO tiers in one hold when the '
        'scene goes fully quiet', () {
      final FrameRatePolicy p = FrameRatePolicy();
      eval(p, t0, motion: walking(), danger: true);
      final DateTime quiet = t0.add(const Duration(seconds: 1));
      expect(eval(p, quiet), NavHazConfig.frameRateDangerFps);
      expect(
        eval(p, quiet.add(NavHazConfig.frameRateDownshiftHold)),
        NavHazConfig.frameRateStillFps,
      );
    });
  });

  group('still gate (substitute gating)', () {
    test('a live track blocks the still tier even when '
        'the user stands still', () {
      final FrameRatePolicy p = FrameRatePolicy();
      final DateTime at =
          t0.add(NavHazConfig.frameRateDownshiftHold * 2);
      expect(eval(p, at, track: true),
          NavHazConfig.frameRateWalkingFps);
      expect(p.tier, FrameRateTier.walking);
    });

    test('a detection inside the quiet window blocks the '
        'still tier; past the window it releases', () {
      final FrameRatePolicy p = FrameRatePolicy();
      // Detection 1 s ago: inside the 2 s quiet window, so
      // the wanted tier is walking and no hold even starts.
      expect(
        eval(p, t0,
            lastDetectionAt:
                t0.subtract(const Duration(seconds: 1))),
        NavHazConfig.frameRateWalkingFps,
      );
      // Past the quiet window the still tier becomes
      // WANTED: this evaluation starts the downshift hold
      // (target still walking)...
      final DateTime windowGone = t0
          .add(NavHazConfig.frameRateStillQuietWindow)
          .add(const Duration(seconds: 1));
      expect(
        eval(p, windowGone,
            lastDetectionAt:
                t0.subtract(const Duration(seconds: 1))),
        NavHazConfig.frameRateWalkingFps,
      );
      // ...and only a full hold later does it land.
      expect(
        eval(p, windowGone.add(NavHazConfig.frameRateDownshiftHold),
            lastDetectionAt:
                t0.subtract(const Duration(seconds: 1))),
        NavHazConfig.frameRateStillFps,
      );
    });

    test('no detection ever recorded counts as quiet', () {
      final FrameRatePolicy p = settledStill();
      expect(p.targetFps, NavHazConfig.frameRateStillFps);
    });

    test('walking motion alone blocks the still tier '
        '(gate is conjunctive with the ego verdict)', () {
      final FrameRatePolicy p = FrameRatePolicy();
      final DateTime at =
          t0.add(NavHazConfig.frameRateDownshiftHold * 2);
      expect(eval(p, at, motion: walking()),
          NavHazConfig.frameRateWalkingFps);
    });
  });

  group('danger definition over pipeline estimates', () {
    test('confirmed track with TTC below the danger '
        'threshold is danger (fused or published urgent)', () {
      expect(
        FrameRatePolicy.dangerPresentIn(<TrackEstimate>[
          estimate(
              confirmed: true,
              ttcS: NavHazConfig.frameRateDangerTtcS - 0.1),
        ]),
        isTrue,
      );
      expect(
        FrameRatePolicy.dangerPresentIn(<TrackEstimate>[
          estimate(confirmed: true, ttcS: 9, ttcUrgentS: 4.0),
        ]),
        isTrue,
      );
    });

    test('TTC at or above the threshold is not danger', () {
      expect(
        FrameRatePolicy.dangerPresentIn(<TrackEstimate>[
          estimate(
              confirmed: true,
              ttcS: NavHazConfig.frameRateDangerTtcS),
        ]),
        isFalse,
      );
    });

    test('an UNCONFIRMED track never counts, however '
        'close its TTC', () {
      expect(
        FrameRatePolicy.dangerPresentIn(<TrackEstimate>[
          estimate(confirmed: false, ttcS: 0.5),
        ]),
        isFalse,
      );
    });

    test('a confirmed approaching vehicle landing in the '
        'channel is danger without any TTC', () {
      expect(
        FrameRatePolicy.dangerPresentIn(<TrackEstimate>[
          estimate(
              confirmed: true, approaching: true, willHit: true),
        ]),
        isTrue,
      );
      // Approaching but crossing (no channel landing): no.
      expect(
        FrameRatePolicy.dangerPresentIn(<TrackEstimate>[
          estimate(
              confirmed: true, approaching: true, willHit: false),
        ]),
        isFalse,
      );
      // In the channel but not approaching (a static
      // obstacle): the corridor branch does not fire.
      expect(
        FrameRatePolicy.dangerPresentIn(<TrackEstimate>[
          estimate(
              confirmed: true, approaching: false, willHit: true),
        ]),
        isFalse,
      );
    });

    test('empty estimates are never danger', () {
      expect(FrameRatePolicy.dangerPresentIn(const <TrackEstimate>[]),
          isFalse);
    });
  });

  group('flag surface', () {
    test('the adaptive flag exists, defaults ON, and the '
        'tier constants match the spec bands', () {
      expect(NavHazConfig.adaptiveFrameRateEnabled, isTrue);
      expect(NavHazConfig.frameRateStillFps, 2);
      // Spec bands: walking 8-10, danger 15-20 -- the
      // policy takes the upper edges (see config docs).
      expect(NavHazConfig.frameRateWalkingFps,
          inInclusiveRange(8, 10));
      expect(NavHazConfig.frameRateDangerFps,
          inInclusiveRange(15, 20));
      expect(NavHazConfig.frameRateDangerTtcS, 5.0);
    });
  });
}
