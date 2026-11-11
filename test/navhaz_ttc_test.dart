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
    test('velocity starts at zero and builds by beta corrections', () {
      final AlphaBetaFilter f = AlphaBetaFilter();
      final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
      f.update(12, epoch);
      expect(f.velocity, 0);
      // A constant closing rate of 2 m/s: after ~2 s of
      // frames the velocity estimate must be close -- and
      // crucially it must UNDERSHOOT early (never overshoot
      // the way a first-difference seed did), so early TTC
      // reads high, not low.
      double v = 0;
      for (int i = 1; i <= 20; i++) {
        f.update(12 - 0.2 * i, epoch.add(Duration(milliseconds: i * 100)));
        v = f.velocity;
        expect(v, lessThanOrEqualTo(0),
            reason: 'velocity is signed: closing range gives v <= 0');
        expect(v.abs(), lessThanOrEqualTo(2.0 * 1.02),
            reason: 'no material overshoot beyond the true rate '
                '(the rejected first-difference seed overshot by ~15%)');
      }
      expect(v.abs(), closeTo(2.0, 0.15));
    });
  });

  group('ego motion', () {
    test('no evidence -> still', () {
      final EgoMotion e = EgoMotion.judge();
      expect(e.isWalking, isFalse);
      expect(e.vEgoMps, 0);
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
}
