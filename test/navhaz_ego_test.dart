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
///       approaching judgement stays off -- BUT (EGOUNK
///       ruling, superseding the fix round's conservative
///       expectation) the dedicated scale path still
///       alerts W then U for a head-on target.
/// - EGOUNK ruling group: the ego-unknown scale path end
///   to end (pipeline W/U, crossing silence), the
///   intersection gate's boundary values (centre-fraction
///   and metric channels), and the cooldown split
///   (6 s unknown / 4 s known, exceptions retained).
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
import 'package:mingtu_ai/core/tracking/tracker.dart';
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
          '$backend (4) ego UNKNOWN, car head-on: approach '
          'never confirmed, scale path still alerts W then U', () {
        // Same geometry as (2) but no ego evidence at all.
        // The approaching judgement itself stays off (there
        // is no v_ego to beat) -- that part of the fix
        // round's conservative branch stands. What the
        // EGOUNK ruling (2026-11-11) supersedes is the old
        // expectation "no urgent here": the dedicated
        // ego-unknown scale path grades the head-on car on
        // its scale TTC alone (intersection: dead centre,
        // metric offset 0), so the sequence now warns and
        // then urgents on the same windows as (2). The
        // sequence still stops at Z = 3.25 m, outside the
        // close-range rule, so both alerts are provably the
        // scale path's, not the range rules'.
        final List<Detection?> frames = <Detection?>[
          for (int i = 0; i <= 35; i++) carAt(12.0 - 0.25 * i),
        ];
        final EgoRun run = runEgo(backend, frames, EgoMotion.unknown);
        for (final TrackEstimate e in run.estimates) {
          expect(e.approaching, isFalse,
              reason: 'unknown v_ego: approach cannot be confirmed');
          expect(e.egoSpeedKnown, isFalse);
        }
        final List<HazardAlert> warnings =
            run.alerts.where((HazardAlert a) => !a.urgent).toList();
        final List<HazardAlert> urgents =
            run.alerts.where((HazardAlert a) => a.urgent).toList();
        expect(warnings, isNotEmpty,
            reason: 'scale path: TTC_s in (3, 5] warns');
        expect(urgents, isNotEmpty,
            reason: 'scale path: TTC_s <= 3 urgents, no downgrade');
        final int wFrame =
            run.alertFrames[run.alerts.indexOf(warnings.first)];
        final int uFrame =
            run.alertFrames[run.alerts.indexOf(urgents.first)];
        expect((12.0 - 0.25 * wFrame) / 2.5, inInclusiveRange(3.0, 5.2),
            reason: 'first warning inside the W band');
        expect((12.0 - 0.25 * uFrame) / 2.5, inInclusiveRange(2.0, 3.3),
            reason: 'first urgent inside the U band (lower '
                'edge widened for the 6 s unknown-ego '
                'cooldown: the W -> U upgrade speaks at '
                'once, but its stored TTC then holds bare '
                'same-level re-alerts until the >= 40% drop, '
                'so the first SPOKEN urgent lands deeper '
                'than the known-ego window of group (2))');
        expect(wFrame, lessThan(uFrame));
      });
    }
  });

  group('EGOUNK scale path (ruling + CDX2/FIX2)', () {
    // Policy-level estimate builder: full control of the
    // scale leg, the range leg and the ego flag.
    Track confirmedAt(double cx, {double w = 0.2, String label = 'car'}) {
      final Track t = Track(id: 1, label: label);
      final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
      for (int i = 0; i < 5; i++) {
        t.recordMatch(
          Detection(
              label: label, confidence: 0.9, cx: cx, cy: 0.55, w: w, h: 0.4),
          epoch.add(Duration(milliseconds: i * 100)),
        );
      }
      return t;
    }

    TrackEstimate est(
      Track track, {
      double? ttcScale,
      double? ttcRange,
      double? range,
      double? fused,
      double scaleRate = 0.05,
      double cxVel = 0,
      bool known = false,
      bool willHit = true,
    }) {
      return TrackEstimate(
        track: track,
        ttcS: fused ?? ttcScale,
        ttcScaleS: ttcScale,
        ttcRangeS: ttcRange,
        rangeM: range,
        closingSpeedMps: null,
        approaching: false,
        willHit: willHit,
        cxVelocity: cxVel,
        egoSpeedKnown: known,
        scaleRate: scaleRate,
      );
    }

    final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
    DateTime atMs(int ms) => epoch.add(Duration(milliseconds: ms));

    test('CDX2-1 data flow: range leg at 1 s cannot promote '
        'when TTC_s is 8 s (ego unknown)', () {
      final HazardPolicy policy = HazardPolicy();
      final Track car = confirmedAt(0.5);
      // The estimator under unknown ego outputs TTC_s as
      // the effective TTC; this estimate mirrors that
      // output shape (fused == scale), with the range leg
      // present only as a diagnostic.
      final HazardPolicyResult r = policy.evaluate(
        <TrackEstimate>[
          est(car, ttcScale: 8.0, ttcRange: 1.0, range: 8.0),
        ],
        atMs(0),
      );
      expect(r.alert, isNull,
          reason: 'TTC_s 8 s is outside every band; the '
              'range leg must not fuse into the judgement');
      expect(r.riskPresent, isFalse);
    });

    test('CDX2-1 data flow: TTC_s 2.5 s with no range leg '
        'urgents (ego unknown)', () {
      final HazardPolicy policy = HazardPolicy();
      final Track car = confirmedAt(0.5);
      final HazardPolicyResult r = policy.evaluate(
        <TrackEstimate>[est(car, ttcScale: 2.5)],
        atMs(0),
      );
      expect(r.alert?.level, HazardLevel.urgent);
    });

    test('FIX2 conjunction: TTC_s in band but scale NOT '
        'growing -> silent', () {
      final HazardPolicy policy = HazardPolicy();
      final Track car = confirmedAt(0.5);
      final HazardPolicyResult r = policy.evaluate(
        <TrackEstimate>[est(car, ttcScale: 2.0, scaleRate: 0)],
        atMs(0),
      );
      expect(r.alert, isNull,
          reason: 'condition (ii) fails: no growth, no alert, '
              'however small TTC_s reads');
    });

    test('CDX2-2: box overlaps the channel NOW but the '
        'extrapolated landing is outside -> silent', () {
      final HazardPolicy policy = HazardPolicy();
      // Wide box centred at 0.5 (spans 0.25..0.75: overlaps
      // both channel definitions) sweeping right at
      // 0.3 /s; TTC_s 2 s puts the landing at 1.1 -- the
      // old overlap-inclusive willHit would have fired.
      final Track car = confirmedAt(0.5, w: 0.5);
      final HazardPolicyResult r = policy.evaluate(
        <TrackEstimate>[est(car, ttcScale: 2.0, cxVel: 0.3)],
        atMs(0),
      );
      expect(r.alert, isNull);
      expect(r.riskPresent, isFalse);
    });

    test('CDX2-4: no range, TTC_s 2 s, target at the frame '
        'edge -> silent; same target centred -> urgent', () {
      final HazardPolicy edgePolicy = HazardPolicy();
      final Track edge = confirmedAt(0.85);
      expect(
        edgePolicy
            .evaluate(<TrackEstimate>[est(edge, ttcScale: 2.0)], atMs(0))
            .alert,
        isNull,
        reason: 'extrapolated cx 0.85 is outside the '
            'central 40% channel: the intersection gate is '
            'not bypassed by a small TTC_s',
      );
      final HazardPolicy centrePolicy = HazardPolicy();
      final Track centre = confirmedAt(0.5);
      expect(
        centrePolicy
            .evaluate(
                <TrackEstimate>[est(centre, ttcScale: 2.0)], atMs(0))
            .alert
            ?.level,
        HazardLevel.urgent,
      );
    });

    test('intersection gate boundaries: central fraction '
        '0.30 / 0.70 are inclusive, just outside is silent', () {
      expect(
        TtcEstimator.scalePathIntersects(
            cx: 0.30, cxVelocity: 0, ttcScaleS: 2.0, rangeM: null),
        isTrue,
      );
      expect(
        TtcEstimator.scalePathIntersects(
            cx: 0.70, cxVelocity: 0, ttcScaleS: 2.0, rangeM: null),
        isTrue,
      );
      expect(
        TtcEstimator.scalePathIntersects(
            cx: 0.299, cxVelocity: 0, ttcScaleS: 2.0, rangeM: null),
        isFalse,
      );
      expect(
        TtcEstimator.scalePathIntersects(
            cx: 0.701, cxVelocity: 0, ttcScaleS: 2.0, rangeM: null),
        isFalse,
      );
      // Extrapolation, not the current position, decides:
      expect(
        TtcEstimator.scalePathIntersects(
            cx: 0.5, cxVelocity: 0.05, ttcScaleS: 4.0, rangeM: null),
        isTrue,
        reason: 'lands exactly on 0.70',
      );
      expect(
        TtcEstimator.scalePathIntersects(
            cx: 0.5, cxVelocity: 0.06, ttcScaleS: 4.0, rangeM: null),
        isFalse,
        reason: 'lands on 0.74',
      );
    });

    test('intersection gate boundaries: metric channel at '
        '+/-1.0 m (range known)', () {
      final double cxStar =
          0.5 + TtcEstimator.focalX * NavHazConfig.egoUnknownChannelHalfWidthM / 10.0;
      expect(TtcEstimator.lateralOffsetM(cxStar, 10.0),
          closeTo(NavHazConfig.egoUnknownChannelHalfWidthM, 1e-9));
      expect(
        TtcEstimator.scalePathIntersects(
            cx: cxStar - 0.002, cxVelocity: 0, ttcScaleS: 2.0, rangeM: 10.0),
        isTrue,
      );
      expect(
        TtcEstimator.scalePathIntersects(
            cx: cxStar + 0.002, cxVelocity: 0, ttcScaleS: 2.0, rangeM: 10.0),
        isFalse,
      );
      // Policy level, metric channel: just inside urgents,
      // just outside stays silent.
      final HazardPolicy inPolicy = HazardPolicy();
      expect(
        inPolicy
            .evaluate(
                <TrackEstimate>[
                  est(confirmedAt(cxStar - 0.01),
                      ttcScale: 2.5, range: 10.0),
                ],
                atMs(0))
            .alert
            ?.level,
        HazardLevel.urgent,
      );
      final HazardPolicy outPolicy = HazardPolicy();
      expect(
        outPolicy
            .evaluate(
                <TrackEstimate>[
                  est(confirmedAt(cxStar + 0.01),
                      ttcScale: 2.5, range: 10.0),
                ],
                atMs(0))
            .alert,
        isNull,
      );
    });

    test('cooldown split: unknown ego holds 6 s, known ego '
        're-alerts at 4 s; upgrade exception survives the '
        '6 s window', () {
      // Unknown: U at t=0; same level at 5.9 s suppressed;
      // at 6.0 s re-alerts.
      final HazardPolicy unknown = HazardPolicy();
      final Track carU = confirmedAt(0.5);
      expect(
          unknown
              .evaluate(
                  <TrackEstimate>[est(carU, ttcScale: 2.9)], atMs(0))
              .alert
              ?.level,
          HazardLevel.urgent);
      expect(
          unknown
              .evaluate(
                  <TrackEstimate>[est(carU, ttcScale: 2.85)], atMs(5900))
              .alert,
          isNull,
          reason: '5.9 s < 6 s unknown-ego cooldown');
      expect(
          unknown
              .evaluate(
                  <TrackEstimate>[est(carU, ttcScale: 2.8)], atMs(6000))
              .alert
              ?.level,
          HazardLevel.urgent,
          reason: '6.0 s: the unknown-ego cooldown has elapsed');
      // Known control: same shape re-alerts at 4.0 s.
      final HazardPolicy knownPolicy = HazardPolicy();
      final Track carK = confirmedAt(0.5);
      TrackEstimate knownEst(double ttc) => TrackEstimate(
            track: carK,
            ttcS: ttc,
            ttcScaleS: ttc,
            ttcRangeS: ttc,
            rangeM: 5.8,
            closingSpeedMps: 2.0,
            approaching: true,
            willHit: true,
            cxVelocity: 0,
            egoSpeedKnown: true,
            scaleRate: 0.05,
          );
      expect(knownPolicy.evaluate(<TrackEstimate>[knownEst(2.9)], atMs(0)).alert?.level,
          HazardLevel.urgent);
      expect(knownPolicy.evaluate(<TrackEstimate>[knownEst(2.85)], atMs(3900)).alert,
          isNull);
      expect(knownPolicy.evaluate(<TrackEstimate>[knownEst(2.8)], atMs(4000)).alert?.level,
          HazardLevel.urgent,
          reason: 'known ego keeps the 4 s cooldown');
      // Upgrade exception inside the 6 s window: W at 0,
      // U 1 s later still speaks at once.
      final HazardPolicy upgrade = HazardPolicy();
      final Track carUp = confirmedAt(0.5);
      expect(
          upgrade
              .evaluate(
                  <TrackEstimate>[est(carUp, ttcScale: 4.0)], atMs(0))
              .alert
              ?.level,
          HazardLevel.warning);
      expect(
          upgrade
              .evaluate(
                  <TrackEstimate>[est(carUp, ttcScale: 2.9)], atMs(1000))
              .alert
              ?.level,
          HazardLevel.urgent,
          reason: 'W -> U upgrade is never held back, also '
              'under the 6 s window');
      // TTC-drop exception inside the 6 s window.
      final HazardPolicy drop = HazardPolicy();
      final Track carD = confirmedAt(0.5);
      expect(
          drop
              .evaluate(
                  <TrackEstimate>[est(carD, ttcScale: 2.9)], atMs(0))
              .alert
              ?.level,
          HazardLevel.urgent);
      expect(
          drop
              .evaluate(
                  <TrackEstimate>[est(carD, ttcScale: 1.7)], atMs(1000))
              .alert
              ?.level,
          HazardLevel.urgent,
          reason: 'a >= 40% TTC drop re-alerts inside the '
              '6 s window');
    });

    for (final String backend in kBackends) {
      test('$backend pipeline: ego unknown, head-on car, '
          'scale-only: W first, then U as TTC_s falls (FIX2 '
          'sequence)', () {
        // No pitch: Z invalid, so this is the pure scale
        // path with the central-fraction channel. Box scale
        // follows s(t) = s0*T/(T-t), T = 6 s: true TTC_s is
        // exactly 6 - t.
        Detection frame(int i) {
          final double t = i * 0.1;
          final double s = 0.12 * 6.0 / (6.0 - t);
          return Detection(
              label: 'car', confidence: 0.9, cx: 0.5, cy: 0.55, w: s, h: s);
        }

        final HazardPipeline pipeline =
            HazardPipeline(tracker: trackerForBackend(backend));
        final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
        final List<HazardAlert> alerts = <HazardAlert>[];
        final List<int> frames = <int>[];
        for (int i = 0; i <= 50; i++) {
          final HazardPipelineResult r = pipeline.processFrame(
            <Detection>[frame(i)],
            epoch.add(Duration(milliseconds: i * 100)),
            pitchDeg: null,
            ego: EgoMotion.unknown,
          );
          if (r.alert != null) {
            alerts.add(r.alert!);
            frames.add(i);
          }
        }
        expect(alerts, isNotEmpty);
        expect(alerts.first.level, HazardLevel.warning,
            reason: 'the sequence opens with a warning');
        final int wIdx = alerts
            .indexWhere((HazardAlert a) => a.level == HazardLevel.warning);
        final int uIdx = alerts
            .indexWhere((HazardAlert a) => a.level == HazardLevel.urgent);
        expect(uIdx, greaterThan(wIdx),
            reason: 'W precedes U; no direct jump to U');
        expect(6.0 - frames[wIdx] * 0.1, inInclusiveRange(3.0, 5.2),
            reason: 'first W inside the (3, 5] band');
        expect(6.0 - frames[uIdx] * 0.1, inInclusiveRange(2.0, 3.3),
            reason: 'first U inside the <= 3 band (the lower '
                'edge allows the 6 s unknown-ego cooldown to '
                'hold a bare-3.0 s re-alert until the TTC has '
                'fallen further; group (4) with pitch shows '
                'the un-cooldowned window)');
      });

      test('$backend pipeline: ego unknown, crossing '
          'pedestrian with a growing box: zero alerts', () {
        // cx sweeps 0.1 -> 0.9 in 2 s while the box grows
        // at a constant relative rate (TTC_s ~= 4 s, inside
        // the warning band): the ONLY thing keeping this
        // silent is the intersection gate -- the
        // extrapolated landing is far outside the channel
        // at every frame.
        final HazardPipeline pipeline =
            HazardPipeline(tracker: trackerForBackend(backend));
        final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
        final List<TrackEstimate> seen = <TrackEstimate>[];
        for (int i = 0; i < 20; i++) {
          final double g = math.exp(0.025 * i);
          final HazardPipelineResult r = pipeline.processFrame(
            <Detection>[
              Detection(
                  label: 'person',
                  confidence: 0.9,
                  cx: 0.1 + 0.8 * i / 19,
                  cy: 0.55,
                  w: 0.18 * g,
                  h: 0.36 * g),
            ],
            epoch.add(Duration(milliseconds: i * 100)),
            pitchDeg: null,
            ego: EgoMotion.unknown,
          );
          seen.addAll(r.estimates);
          expect(r.alert, isNull,
              reason: 'frame $i: crossing target, extrapolated '
                  'landing outside the channel');
        }
        // The test is not vacuous: the scale leg really was
        // armed (finite TTC_s in the warning band) on the
        // confirmed frames.
        expect(
          seen.any((TrackEstimate e) =>
              e.ttcScaleS != null &&
              e.ttcScaleS! > 3.0 &&
              e.ttcScaleS! <= 5.0 &&
              e.scaleRate > 0),
          isTrue,
          reason: 'TTC_s was in band; the gate, not a '
              'missing TTC, kept it silent',
        );
      });

      test('$backend pipeline: ego unknown, constant-size '
          'car dead ahead: zero alerts (FIX2 no-growth)', () {
        // Pitch present and geometry honest (Z = 6 m,
        // bottom by the ground law, so neither the static
        // range rule nor the near rule can fire): the box
        // never grows, TTC_s is infinite, and the
        // conjunction's growth condition keeps the
        // confirmed head-on target silent.
        final List<Detection?> frames = <Detection?>[
          for (int i = 0; i < 30; i++) carAt(6.0),
        ];
        final EgoRun run = runEgo(backend, frames, EgoMotion.unknown);
        expect(run.alerts, isEmpty);
        for (final TrackEstimate e in run.estimates) {
          expect(e.ttcScaleS, isNull,
              reason: 'constant scale: no scale TTC exists');
          expect(e.scaleRate, lessThanOrEqualTo(1e-6),
              reason: 'no measurable growth');
        }
      });

      test('$backend pipeline: CDX2-1 estimator output -- '
          'range leg fast, scale leg slow: effective TTC is '
          'the scale leg, no alert', () {
        // Z collapses exponentially (range TTC ~= 1 s)
        // while the box scale grows as if TTC_s ~= 8 s.
        // With a KNOWN ego this geometry would fuse (and
        // likely urgent); with the ego UNKNOWN the
        // estimator must output the scale leg untouched.
        Detection frame(int i) {
          final double t = i * 0.1;
          final double z = 10.0 * math.exp(-t);
          final double s = 0.10 * 8.0 / (8.0 - t);
          final double bottom = bottomForRange(z);
          return Detection(
              label: 'car',
              confidence: 0.9,
              cx: 0.5,
              cy: bottom - s / 2,
              w: s,
              h: s);
        }

        final HazardPipeline pipeline =
            HazardPipeline(tracker: trackerForBackend(backend));
        final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
        TrackEstimate? last;
        final List<TrackEstimate> seen = <TrackEstimate>[];
        for (int i = 0; i <= 20; i++) {
          final HazardPipelineResult r = pipeline.processFrame(
            <Detection>[frame(i)],
            epoch.add(Duration(milliseconds: i * 100)),
            pitchDeg: 10,
            ego: EgoMotion.unknown,
          );
          expect(r.alert, isNull,
              reason: 'frame $i: TTC_s ~= 8 s is out of band');
          if (r.estimates.isNotEmpty) {
            last = r.estimates.single;
            seen.add(r.estimates.single);
          }
        }
        expect(last, isNotNull);
        final TrackEstimate estLast = last!;
        // The range leg is read on a mid-sequence frame:
        // past Z ~= 1.6 m the box bottom crosses the
        // estimator's ground-plane cap (bottom < 0.98) and
        // the leg legitimately goes invalid -- the last
        // frames only carry the scale leg.
        final TrackEstimate mid = seen[10];
        expect(mid.ttcRangeS, isNotNull);
        expect(mid.ttcRangeS!, lessThan(2.0),
            reason: 'the range leg really did read ~1 s '
                '(filtered value ~0.6 s on this geometry)');
        expect(estLast.ttcS, estLast.ttcScaleS,
            reason: 'effective TTC == scale leg (no fusion)');
        expect(estLast.ttcDisagreement, isFalse,
            reason: 'no fusion -> no disagreement');
        expect(estLast.ttcS!, greaterThan(5.0),
            reason: 'and it is the slow leg, ~8 s');
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
