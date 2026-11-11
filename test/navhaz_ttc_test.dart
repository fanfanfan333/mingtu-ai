/// NAVHAZ M1, spec sections 2.2 / 2.7.1: ground-plane
/// ranging geometry, the alpha-beta filter's seeding
/// behaviour, ego-motion judgement, and the fused TTC
/// accuracy on the approaching-car fixture (error <= 20%
/// wherever the true TTC is in the 2-4 s band).
library;
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/hazard/ego_motion.dart';
import 'package:mingtu_ai/core/hazard/ttc_estimator.dart';
import 'package:mingtu_ai/core/navhaz_config.dart';
import 'package:mingtu_ai/core/tracking/tracker.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';

import 'navhaz_fixture_harness.dart';

void main() {
  group('ground-plane ranging', () {
    // Inverse of the fixture generator's placement law.
    double bottomForRange(double z, double pitchDeg) {
      final double fy = 0.5 / math.tan(math.pi / 6); // VFOV 60
      final double depression = math.atan(NavHazConfig.cameraHeightM / z);
      return NavHazConfig.principalY +
          fy * math.tan(depression - pitchDeg * math.pi / 180);
    }

    test('recovers known ranges at pitch 10 deg', () {
      for (final double z in <double>[3, 6, 12]) {
        final double? got = TtcEstimator.groundRangeM(
          bottom: bottomForRange(z, 10),
          pitchDeg: 10,
        );
        expect(got, closeTo(z, z * 0.02));
      }
    });

    test('no range when the box bottom is at/below the cutoff', () {
      expect(
        TtcEstimator.groundRangeM(
            bottom: NavHazConfig.groundPlaneMaxBottom, pitchDeg: 10),
        isNull,
      );
      expect(
        TtcEstimator.groundRangeM(bottom: 0.3, pitchDeg: 10),
        isNull,
        reason: 'bottom above the horizon line gives no ground range',
      );
    });
  });

  group('alpha-beta filter', () {
    test('velocity is seeded from the first difference, promoted '
        'after one alpha-beta update', () {
      final AlphaBetaFilter f = AlphaBetaFilter();
      final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
      // First observation: value seeded, velocity 0.
      f.update(12, epoch);
      expect(f.velocity, 0);
      // Second observation: the difference seed (-2 m/s)
      // is computed but held pending -- the reported
      // velocity is still 0 for this frame.
      f.update(11.8, epoch.add(const Duration(milliseconds: 100)));
      expect(f.velocity, 0,
          reason: 'the seed is not used raw (fix-round rule)');
      // Third observation: the seed has passed one
      // alpha-beta update; for an exact constant-rate
      // series the residual is 0 and the velocity is the
      // seeded rate itself.
      f.update(11.6, epoch.add(const Duration(milliseconds: 200)));
      expect(f.velocity, closeTo(-2.0, 0.05),
          reason: 'seeded from the first difference over the '
              'real interval');
      // It then tracks the constant rate without the
      // overshoot the rejected raw-seed experiment showed.
      double v = 0;
      for (int i = 3; i <= 20; i++) {
        f.update(12 - 0.2 * i, epoch.add(Duration(milliseconds: i * 100)));
        v = f.velocity;
        expect(v.abs(), lessThanOrEqualTo(2.0 * 1.05),
            reason: 'no material overshoot beyond the true rate');
      }
      expect(v.abs(), closeTo(2.0, 0.15));
    });
  });

  group('ego motion', () {
    test('no evidence -> speed UNKNOWN (conservative branch)', () {
      final EgoMotion e = EgoMotion.judge();
      expect(e.speedKnown, isFalse);
      expect(e.vEgoMps, isNull);
      expect(e.isWalking, isFalse);
    });

    test('GPS speed at walking pace -> walking with that speed', () {
      final EgoMotion e = EgoMotion.judge(gpsSpeedMps: 1.4);
      expect(e.isWalking, isTrue);
      expect(e.vEgoMps, closeTo(1.4, 1e-9));
    });

    test('accelerometer variance alone -> walking at the nominal speed', () {
      final EgoMotion e =
          EgoMotion.judge(accelVariance: NavHazConfig.walkingAccelVariance);
      expect(e.isWalking, isTrue);
      expect(e.vEgoMps, NavHazConfig.walkingSpeedMps);
    });

    test('slow GPS drift alone is not walking', () {
      final EgoMotion e = EgoMotion.judge(gpsSpeedMps: 0.2);
      expect(e.isWalking, isFalse);
    });
  });

  group('approaching-car TTC accuracy (spec 2.7.1)', () {
    for (final String backend in kBackends) {
      test('$backend: fused TTC within 20% across the 2-4 s band', () {
        final FixtureRun run = runFixture('approaching_car.jsonl', backend);
        int checked = 0;
        for (final int tMs in run.frameTimes) {
          final double trueTtc = 6.0 - tMs / 1000.0;
          if (trueTtc < 2.0 || trueTtc > 4.0) continue;
          final estimates = run.estimatesByTime[tMs]!;
          expect(estimates, hasLength(1));
          final double? est = estimates.single.ttcS;
          expect(est, isNotNull, reason: 't=$tMs');
          final double err = (est! - trueTtc).abs() / trueTtc;
          expect(err, lessThanOrEqualTo(0.20),
              reason: '$backend t=$tMs est=$est true=$trueTtc');
          checked++;
        }
        expect(checked, greaterThanOrEqualTo(15),
            reason: 'the 2-4 s band must actually be sampled');
      });

      test('$backend: closing speed converges to the true 2 m/s', () {
        final FixtureRun run = runFixture('approaching_car.jsonl', backend);
        final double? closing =
            run.estimatesByTime[3000]!.single.closingSpeedMps;
        expect(closing, closeTo(2.0, 0.2));
        expect(run.estimatesByTime[3000]!.single.approaching, isTrue);
      });
    }
  });

  group('TTC fusion consistency rule (fix round, spec 2.2)', () {
    test('difference 30% -> consistent, fused is the smaller', () {
      // |4.0 - 2.8| / 4.0 = 30%.
      expect(TtcEstimator.legsDisagree(4.0, 2.8), isFalse);
      expect(TtcEstimator.fuseLegs(4.0, 2.8), closeTo(2.8, 1e-12));
      expect(TtcEstimator.fuseLegs(2.8, 4.0), closeTo(2.8, 1e-12),
          reason: 'the smaller wins regardless of leg order');
    });

    test('difference exactly 50% -> consistent (boundary inclusive)', () {
      // |5.0 - 2.5| / 5.0 = 50%: at the tolerance, not above.
      expect(TtcEstimator.legsDisagree(5.0, 2.5), isFalse);
      expect(TtcEstimator.fuseLegs(5.0, 2.5), closeTo(2.5, 1e-12));
    });

    test('difference 80% -> inconsistent, fused is null', () {
      // |5.0 - 1.0| / 5.0 = 80%.
      expect(TtcEstimator.legsDisagree(5.0, 1.0), isTrue);
      expect(TtcEstimator.fuseLegs(5.0, 1.0), isNull);
    });

    test('a single valid leg is used as-is; none -> null', () {
      expect(TtcEstimator.fuseLegs(3.3, null), closeTo(3.3, 1e-12));
      expect(TtcEstimator.fuseLegs(null, 4.4), closeTo(4.4, 1e-12));
      expect(TtcEstimator.fuseLegs(null, null), isNull);
    });

    test('estimator level: contradictory legs yield ttc null + marker',
        () {
      // Range law: Z falls 12 -> 6 m at 2 m/s (TTC_z ~ 3 s
      // and shrinking). Scale law: s grows as exp(t/12)
      // (TTC_s = 12 s throughout). The legs contradict
      // each other by ~75%: the fused TTC must be null and
      // the estimate marked, never the min of the two.
      final TtcEstimator estimator = TtcEstimator();
      final Track track = Track(id: 77, label: 'car');
      final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
      TrackEstimate? last;
      for (int i = 0; i <= 30; i++) {
        final double t = i / 10.0;
        final double z = 12.0 - 2.0 * t;
        final double fy = 0.5 / math.tan(math.pi / 6);
        final double depression = math.atan(NavHazConfig.cameraHeightM / z);
        final double bottom = NavHazConfig.principalY +
            fy * math.tan(depression - 10.0 * math.pi / 180);
        final double s = 0.08 * math.exp(t / 12.0);
        track.recordMatch(
          Detection(
              label: 'car',
              confidence: 0.9,
              cx: 0.5,
              cy: bottom - s / 2,
              w: s,
              h: s),
          epoch.add(Duration(milliseconds: i * 100)),
        );
        last = estimator.estimate(track,
            at: epoch.add(Duration(milliseconds: i * 100)),
            pitchDeg: 10,
            ego: EgoMotion.still);
      }
      expect(last!.ttcScaleS, isNotNull);
      expect(last.ttcRangeS, isNotNull);
      expect(last.ttcDisagreement, isTrue,
          reason: 'legs ${last.ttcScaleS} vs ${last.ttcRangeS}');
      expect(last.ttcS, isNull,
          reason: 'contradictory ranging is distrusted, not min-ed');
      expect(last.rangeM, isNotNull,
          reason: 'the range itself stays usable for the '
              'static / close-range policy rules');
    });
  });
}
