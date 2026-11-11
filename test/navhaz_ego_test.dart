/// NAVHAZ M1 fix round, item A / CDX1 item 1: ego motion.
///
/// - EgoMotion.judge source priority: accurate fresh GPS
///   speed > accelerometer step frequency x stride >
///   variance alone > UNKNOWN (conservative: no vehicle
///   can be confirmed "approaching" without a speed).
/// - StepFrequencyEstimator on synthetic magnitudes.
/// - Pipeline-level contrast groups (spec A):
///   (1) walking user approaching a PARKED car
///       (v_rel ~= v_ego): never judged approaching, never
///       urgent on the approaching rule;
///   (2) car approaching a STILL user (v_rel >> v_ego):
///       judged approaching, W/U on time;
///   (3) same direction, same speed (v_rel ~= 0): never
///       judged approaching, zero alerts;
///   (4) ego speed UNKNOWN with the (2) geometry: the
///       approaching judgement stays off (conservative
///       branch) even though the box expands.
/// - Main wiring guard: the pipeline call in main.dart is
///   fed by the per-frame judge, never by a hardcoded
///   still constant.
library;
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/hazard/ego_motion.dart';
import 'package:mingtu_ai/core/hazard/hazard_pipeline.dart';
import 'package:mingtu_ai/core/hazard/hazard_policy.dart';
import 'package:mingtu_ai/core/hazard/ttc_estimator.dart';
import 'package:mingtu_ai/core/navhaz_config.dart';
import 'package:mingtu_ai/core/step_frequency.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';

import 'navhaz_fixture_harness.dart';

/// Box bottom for a ground-contact target at range [z]
/// under pitch 10 degrees (the estimator's law, inverted).
double bottomForRange(double z) {
  final double fy = 0.5 / math.tan(math.pi / 6);
  final double depression = math.atan(NavHazConfig.cameraHeightM / z);
  return NavHazConfig.principalY +
      fy * math.tan(depression - 10.0 * math.pi / 180);
}

/// A car dead ahead at range [z]; size follows s = 0.96/z
/// so scale and ground-plane geometry agree.
Detection carAt(double z) {
  final double s = 0.96 / z;
  final double bottom = bottomForRange(z);
  return Detection(
      label: 'car', confidence: 0.9, cx: 0.5, cy: bottom - s / 2, w: s, h: s);
}

class EgoRun {
  final List<TrackEstimate> estimates = <TrackEstimate>[];
  final List<HazardAlert> alerts = <HazardAlert>[];
  final List<int> alertFrames = <int>[];
}

EgoRun runEgo(String backend, List<Detection?> frames, EgoMotion ego) {
  final HazardPipeline pipeline =
      HazardPipeline(tracker: trackerForBackend(backend));
  final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
  final EgoRun run = EgoRun();
  for (int i = 0; i < frames.length; i++) {
    final HazardPipelineResult r = pipeline.processFrame(
      <Detection>[if (frames[i] != null) frames[i]!],
      epoch.add(Duration(milliseconds: i * 100)),
      pitchDeg: 10,
      ego: ego,
    );
    run.estimates.addAll(r.estimates);
    if (r.alert != null) {
      run.alerts.add(r.alert!);
      run.alertFrames.add(i);
    }
  }
  return run;
}

void main() {
  group('EgoMotion.judge source priority', () {
    test('no source at all -> speed UNKNOWN (conservative)', () {
      final EgoMotion e = EgoMotion.judge();
      expect(e.speedKnown, isFalse);
      expect(e.vEgoMps, isNull);
      expect(e.isWalking, isFalse);
    });

    test('accurate GPS speed wins and is used verbatim', () {
      final EgoMotion e = EgoMotion.judge(gpsSpeedMps: 1.4, gpsAccuracyM: 5);
      expect(e.isWalking, isTrue);
      expect(e.vEgoMps, closeTo(1.4, 1e-9));
    });

    test('accurate GPS stillness beats step noise (priority order)', () {
      final EgoMotion e = EgoMotion.judge(
          gpsSpeedMps: 0, gpsAccuracyM: 5, stepFrequencyHz: 1.8);
      expect(e.speedKnown, isTrue);
      expect(e.isWalking, isFalse);
      expect(e.vEgoMps, 0);
    });

    test('inaccurate GPS is distrusted; step frequency carries', () {
      final EgoMotion e = EgoMotion.judge(
          gpsSpeedMps: 3.0, gpsAccuracyM: 80, stepFrequencyHz: 1.8);
      expect(e.isWalking, isTrue);
      expect(e.vEgoMps,
          closeTo(1.8 * NavHazConfig.strideLengthM, 1e-9),
          reason: 'speed = step frequency x stride');
    });

    test('inaccurate GPS with no other source -> UNKNOWN', () {
      final EgoMotion e = EgoMotion.judge(gpsSpeedMps: 3.0, gpsAccuracyM: 80);
      expect(e.speedKnown, isFalse);
    });

    test('zero step frequency -> known still at 0', () {
      final EgoMotion e = EgoMotion.judge(stepFrequencyHz: 0);
      expect(e.speedKnown, isTrue);
      expect(e.isWalking, isFalse);
      expect(e.vEgoMps, 0);
    });

    test('variance alone: walking at the nominal speed / still at 0', () {
      expect(EgoMotion.judge(accelVariance: 0.9).vEgoMps,
          NavHazConfig.walkingSpeedMps);
      final EgoMotion still = EgoMotion.judge(accelVariance: 0.1);
      expect(still.speedKnown, isTrue);
      expect(still.vEgoMps, 0);
    });
  });

  group('StepFrequencyEstimator', () {
    final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);

    test('constant magnitude: variance ~0, frequency exactly 0', () {
      final StepFrequencyEstimator est = StepFrequencyEstimator();
      for (int i = 0; i < 150; i++) {
        est.add(9.81, epoch.add(Duration(milliseconds: i * 20)));
      }
      expect(est.variance, isNotNull);
      expect(est.variance!, lessThan(0.02));
      expect(est.stepFrequencyHz, 0);
    });

    test('1.8 Hz walking rhythm: variance and frequency recovered', () {
      final StepFrequencyEstimator est = StepFrequencyEstimator();
      for (int i = 0; i < 150; i++) {
        final double t = i * 0.02;
        est.add(9.81 + 1.6 * math.sin(2 * math.pi * 1.8 * t),
            epoch.add(Duration(milliseconds: i * 20)));
      }
      expect(est.variance!, closeTo(1.28, 0.35),
          reason: 'a sine of amplitude A has variance A^2/2');
      expect(est.stepFrequencyHz!, inInclusiveRange(1.3, 2.3));
    });

    test('too little signal -> nulls, never a guess', () {
      final StepFrequencyEstimator est = StepFrequencyEstimator();
      est.add(9.81, epoch);
      expect(est.variance, isNull);
      expect(est.stepFrequencyHz, isNull);
    });
  });

  group('pipeline ego contrast groups (spec A)', () {
    for (final String backend in kBackends) {
      test(
          '$backend (1) walking user, parked car: v_rel ~= v_ego, '
          'never approaching, never urgent', () {
        // Z: 8.0 -> 2.0 m at the user's own 1.2 m/s.
        final List<Detection?> frames = <Detection?>[
          for (int i = 0; i <= 50; i++) carAt(8.0 - 0.12 * i),
        ];
        final EgoRun run = runEgo(
            backend,
            frames,
            EgoMotion.judge(gpsSpeedMps: 1.2, gpsAccuracyM: 5));
        expect(run.estimates, isNotEmpty);
        for (final TrackEstimate e in run.estimates) {
          expect(e.approaching, isFalse,
              reason: 'closing is the user\'s own walking speed; '
                  'v_rel - v_ego ~= 0 must never read as a vehicle '
                  'approaching');
        }
        // Converged closing speed really is ~ the walking
        // speed (the geometry is honest, the JUDGE is what
        // keeps it from counting as an approach).
        final List<double> closings = run.estimates
            .skip(15)
            .map((TrackEstimate e) => e.closingSpeedMps)
            .whereType<double>()
            .toList();
        expect(closings, isNotEmpty);
        for (final double c in closings) {
          expect(c, closeTo(1.2, 0.3));
        }
        // No URGENT anywhere in Z in [2, 8]: the only
        // warnings the rules may produce here are the TTC
        // band (time until the USER reaches the car) and,
        // at Z <= 3 m, the static-obstacle rule -- neither
        // is a vehicle-approaching alert.
        expect(
            run.alerts.where((HazardAlert a) => a.urgent), isEmpty,
            reason: 'a parked car must not escalate to a vehicle '
                'urgent because the user walks toward it');
        final List<HazardAlert> warnings =
            run.alerts.where((HazardAlert a) => !a.urgent).toList();
        if (warnings.isNotEmpty) {
          // First warning only once the TTC band (Z <= 6 m)
          // or the static rule (Z <= 3 m) can explain it.
          final double zAtFirst = 8.0 - 0.12 * run.alertFrames.first;
          expect(zAtFirst, lessThanOrEqualTo(6.05),
              reason: 'first warning at Z=$zAtFirst');
        }
      });

      test(
          '$backend (2) car approaching a still user: judged '
          'approaching, W then U on time', () {
        // Z: 12 -> 2 m at 2.5 m/s; true TTC = Z / 2.5.
        final List<Detection?> frames = <Detection?>[
          for (int i = 0; i <= 40; i++) carAt(12.0 - 0.25 * i),
        ];
        final EgoRun run = runEgo(backend, frames, EgoMotion.still);
        final List<TrackEstimate> converged = run.estimates.skip(10).toList();
        expect(converged, isNotEmpty);
        for (final TrackEstimate e in converged) {
          expect(e.approaching, isTrue,
              reason: 'v_rel 2.5 - v_ego 0 > 1.0 margin');
        }
        final List<HazardAlert> warnings =
            run.alerts.where((HazardAlert a) => !a.urgent).toList();
        final List<HazardAlert> urgents =
            run.alerts.where((HazardAlert a) => a.urgent).toList();
        expect(warnings, isNotEmpty);
        expect(urgents, isNotEmpty);
        final int wFrame =
            run.alertFrames[run.alerts.indexOf(warnings.first)];
        final int uFrame =
            run.alertFrames[run.alerts.indexOf(urgents.first)];
        final double wTrueTtc = (12.0 - 0.25 * wFrame) / 2.5;
        final double uTrueTtc = (12.0 - 0.25 * uFrame) / 2.5;
        expect(wTrueTtc, inInclusiveRange(3.0, 5.2),
            reason: 'first warning at true TTC $wTrueTtc');
        expect(uTrueTtc, inInclusiveRange(2.3, 3.3),
            reason: 'first urgent at true TTC $uTrueTtc');
        expect(wFrame, lessThan(uFrame));
      });

      test(
          '$backend (3) same direction, same speed: relative '
          'speed ~0, never approaching, zero alerts', () {
        final List<Detection?> frames = <Detection?>[
          for (int i = 0; i < 30; i++) carAt(6.0),
        ];
        final EgoRun run = runEgo(
            backend,
            frames,
            EgoMotion.judge(gpsSpeedMps: 1.2, gpsAccuracyM: 5));
        expect(run.alerts, isEmpty);
        for (final TrackEstimate e in run.estimates) {
          expect(e.approaching, isFalse);
          if (e.closingSpeedMps != null) {
            expect(e.closingSpeedMps!.abs(), lessThan(0.35),
                reason: 'no relative motion to measure');
          }
        }
      });

      test(
          '$backend (4) ego UNKNOWN with an approaching car: '
          'approach never confirmed, no urgent', () {
        // Same geometry as (2) but no ego evidence at all:
        // the conservative branch. The TTC band may still
        // warn (time-to-contact is what it is), but the
        // approaching-based urgent path stays off, and the
        // sequence stops at Z = 3.25 m, outside the
        // close-range urgent rule.
        final List<Detection?> frames = <Detection?>[
          for (int i = 0; i <= 35; i++) carAt(12.0 - 0.25 * i),
        ];
        final EgoRun run = runEgo(backend, frames, EgoMotion.unknown);
        for (final TrackEstimate e in run.estimates) {
          expect(e.approaching, isFalse,
              reason: 'unknown v_ego: approach cannot be confirmed');
        }
        expect(run.alerts.where((HazardAlert a) => a.urgent), isEmpty,
            reason: 'no urgent without a confirmed approach in '
                'this geometry (range stays > 1.5 m)');
      });
    }
  });

  group('main wiring guard (CDX1 item 1)', () {
    test('the pipeline is fed by the per-frame ego judge', () {
      final String src = File('lib/main.dart').readAsStringSync();
      expect(src.contains('ego: EgoMotion.still'), isFalse,
          reason: 'the hardcoded still ego is gone');
      expect(src.contains('ego: _egoMotionNow(now)'), isTrue,
          reason: 'frames carry the judged ego estimate');
      expect(src.contains('EgoMotion.judge('), isTrue);
    });
  });
}
