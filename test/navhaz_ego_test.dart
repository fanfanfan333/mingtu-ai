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
        expect(uTrueTtc, inInclusiveRange(2.4, 3.3),
            reason: 'first urgent at true TTC $uTrueTtc '
                '(FIX3B acceptance grid: [2.4, 3.3] for all '
                'four backend x ego combinations; measured '
                '3.00 here)');
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
        expect((12.0 - 0.25 * uFrame) / 2.5, inInclusiveRange(2.4, 3.3),
            reason: 'first urgent inside the FIX3B '
                'acceptance grid [2.4, 3.3] (measured 2.60 '
                'here). The EGOUNK/FIX2 round had widened '
                'this lower edge to 2.0 because the single '
                'normal-tier filter read TTC_s ~+0.87 s '
                'high at the crossing; FIX3B retired that '
                'widening -- the urgent judgement now runs '
                'on the agile tier\'s predicted, '
                'latency-compensated tau_now with 2-of-3 '
                'urgent confirmation, so the first spoken '
                'urgent lands inside the grid without any '
                'assertion relief.');
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
        // FIX3B: the urgent judgement reads ttcUrgentS;
        // these hand-built estimates mirror the scale TTC
        // into it (the estimator's own tier behaviour is
        // covered by the pipeline tests).
        ttcUrgentS: ttcScale,
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

    test('Codex near constant size no range must remain silent', () {
      // Codex CDX3 counterexample, verbatim: a confirmed
      // car, box bottom near the frame bottom (cy .8 +
      // h .3 -> bottom .95), with NO range and NO scale
      // TTC and zero growth must NOT warn on frame position
      // alone (ego unknown degradation).
      final track = Track(id: 938, label: 'car');
      for (int i = 0; i < 5; i++) {
        track.recordMatch(
            const Detection(
                label: 'car', confidence: .9, cx: .5, cy: .8, w: .2, h: .3),
            DateTime.fromMillisecondsSinceEpoch(i * 100));
      }
      final result =
          HazardPolicy().levelFor(est(track, ttcScale: null, scaleRate: 0));
      expect(result, isNull);
    });

    test('CDX3 item 2: the near rule survives where it is '
        'pinned -- a near person (arbitration (d) geometry) '
        'still warns; a vehicle WITH a range still warns '
        'via the Z rule', () {
      // The (d) scenario's evidence source, at policy
      // level: person, bottom 0.9, no range, no TTC, ego
      // unknown -> the legacy near warning.
      final Track person = Track(id: 941, label: 'person');
      for (int i = 0; i < 5; i++) {
        person.recordMatch(
            const Detection(
                label: 'person',
                confidence: .9,
                cx: .5,
                cy: .7,
                w: .2,
                h: .4),
            DateTime.fromMillisecondsSinceEpoch(i * 100));
      }
      expect(
        HazardPolicy().levelFor(est(person, ttcScale: null, scaleRate: 0)),
        HazardLevel.warning,
        reason: 'non-vehicle near obstacle: the near '
            'rule is its pinned evidence source',
      );
      // A vehicle at a MEASURED close range: the static Z
      // rule (not position) warns, exactly as CDX3 keeps.
      final Track car = Track(id: 942, label: 'car');
      for (int i = 0; i < 5; i++) {
        car.recordMatch(
            const Detection(
                label: 'car', confidence: .9, cx: .5, cy: .8, w: .2, h: .3),
            DateTime.fromMillisecondsSinceEpoch(i * 100));
      }
      expect(
        HazardPolicy()
            .levelFor(est(car, ttcScale: null, scaleRate: 0, range: 2.5)),
        HazardLevel.warning,
        reason: 'range 2.5 m <= 3 m: the static Z rule',
      );
    });

    test('CDX3 item 2: the same vehicle scoping on the '
        'KNOWN path -- car bottom-only silent, person '
        'bottom-only warns', () {
      final Track car = Track(id: 943, label: 'car');
      final Track person = Track(id: 944, label: 'person');
      for (int i = 0; i < 5; i++) {
        car.recordMatch(
            const Detection(
                label: 'car', confidence: .9, cx: .5, cy: .8, w: .2, h: .3),
            DateTime.fromMillisecondsSinceEpoch(i * 100));
        person.recordMatch(
            const Detection(
                label: 'person',
                confidence: .9,
                cx: .5,
                cy: .7,
                w: .2,
                h: .4),
            DateTime.fromMillisecondsSinceEpoch(i * 100));
      }
      expect(
        HazardPolicy().levelFor(
            est(car, ttcScale: null, scaleRate: 0, known: true)),
        isNull,
      );
      expect(
        HazardPolicy().levelFor(
            est(person, ttcScale: null, scaleRate: 0, known: true)),
        HazardLevel.warning,
      );
    });

    test('CDX3 item 3: known ego, crossing target whose '
        'box currently overlaps the corridor: extrapolated '
        'landing outside -> zero alerts', () {
      // The pre-CDX3 willHit counted CURRENT overlap as a
      // hit, so this growing crossing target (TTC_s in the
      // warning band) warned mid-crossing on the known
      // path. The unified rule reads only the extrapolated
      // landing point, which is far outside the channel.
      final HazardPipeline pipeline = HazardPipeline();
      final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
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
          ego: EgoMotion.still,
        );
        expect(r.alert, isNull,
            reason: 'frame $i: crossing, landing outside '
                'the channel (known ego)');
      }
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
            ttcUrgentS: ttc,
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
        expect(6.0 - frames[uIdx] * 0.1, inInclusiveRange(2.4, 3.3),
            reason: 'first U inside the FIX3B acceptance '
                'grid [2.4, 3.3] (measured 2.60 here). The '
                'FIX2 round\'s 2.0 lower edge is retired by '
                'the same FIX3B change as group (4): the '
                'urgent signal is the compensated tau_now, '
                'not the lagging normal-tier TTC_s.');
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

  group('FIX3B acceptance grid + urgent tiering', () {
    // The grid, independent of the contrast groups above
    // (the lag regression the FIX3 round asked to stand on
    // its own): the SAME approaching geometry family as
    // groups (2)/(4) -- Z 12 -> 2 m at 2.5 m/s under pitch
    // 10 -- run in all four backend x ego combinations.
    // First W: true TTC <= 5.5 (and not later than the
    // urgent). First U: true TTC in [2.4, 3.3].
    for (final String backend in kBackends) {
      for (final (String, EgoMotion) egoCase in <(String, EgoMotion)>[
        ('known', EgoMotion.still),
        ('unknown', EgoMotion.unknown),
      ]) {
        test('$backend x ego ${egoCase.$1}: first W <= 5.5, '
            'first U in [2.4, 3.3]', () {
          final List<Detection?> frames = <Detection?>[
            for (int i = 0; i <= 40; i++) carAt(12.0 - 0.25 * i),
          ];
          final EgoRun run = runEgo(backend, frames, egoCase.$2);
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
          expect(wTrueTtc, lessThanOrEqualTo(5.5),
              reason: 'first W at frame $wFrame, true TTC '
                  '$wTrueTtc (grid: <= 5.5)');
          expect(wFrame, lessThan(uFrame),
              reason: 'W precedes U');
          expect(uTrueTtc, inInclusiveRange(2.4, 3.3),
              reason: 'first U at frame $uFrame, true TTC '
                  '$uTrueTtc (grid: [2.4, 3.3]; measured '
                  'known 3.00 / unknown 2.60 at the FIX3B '
                  'calibration)');
        });
      }
    }

    test('urgentConfirmed is 2-of-3 with the current frame '
        'a hit; confirmed stays the 3-frame latch', () {
      final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
      Detection det() => const Detection(
          label: 'car', confidence: .9, cx: .5, cy: .55, w: .2, h: .3);
      final Track t = Track(id: 77, label: 'car');
      t.recordMatch(det(), epoch);
      expect(t.urgentConfirmed, isFalse,
          reason: 'a single hit is not 2-of-3');
      t.recordMatch(det(), epoch.add(const Duration(milliseconds: 100)));
      expect(t.urgentConfirmed, isTrue,
          reason: 'two hits, current a hit: urgent tier '
              'confirmed one frame before the warning tier');
      expect(t.confirmed, isFalse,
          reason: 'the warning tier still wants 3');
      t.recordMiss();
      expect(t.urgentConfirmed, isFalse,
          reason: 'current frame a miss: never urgent-'
              'confirmed, whatever the window holds');
      t.recordMatch(det(), epoch.add(const Duration(milliseconds: 300)));
      expect(t.urgentConfirmed, isTrue,
          reason: 'hit-miss-hit: 2 of the last 3, current '
              'a hit');
      expect(t.confirmed, isFalse,
          reason: 'the miss broke the consecutive run: '
              'the warning latch is still open');
    });

    for (final String backend in kBackends) {
      test('$backend pre-urgent vibration: sparse '
          'reappearance walks through on BOTH backends '
          '(CDX4 S1-a)', () {
        // Sparse hits (frames 0, 3, 6, 9, 12, 13): each
        // hit is isolated by two misses, so the 2-of-3
        // window never confirms -- until the back-to-back
        // hit at frame 13. The box grows across the gaps
        // (x1.25 a gap, faster at the end): the agile seed
        // promotes at the 3rd estimate, the raw tau_now
        // runs in-band from then, the jitter guard issues
        // it at the 3rd consecutive in-band estimate
        // (frame 12, issued tau 1.42 < 1.5), and the track
        // is STILL unconfirmed there -- that is the
        // pre-urgent frame.
        //
        // History: in the FIX3B round this test ran on
        // SORT only, because the ByteTrack backend re-idd
        // a target that vanished for two frames (the
        // package deleted its still-tentative track, so
        // no estimator state could develop). CDX4 S1-a
        // fixed the root cause (package minHits 1 +
        // the ~1 s buffer at every layer), and the
        // scenario now walks through IDENTICALLY on the
        // default backend: pre-urgent at 12, urgent
        // speech at 13, one track id throughout.
        final HazardPipeline pipeline =
            HazardPipeline(tracker: trackerForBackend(backend));
        final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
        Detection car(double s) => Detection(
            label: 'car', confidence: 0.9, cx: 0.5, cy: 0.55, w: s, h: s);
        final Map<int, List<Detection>> frames = <int, List<Detection>>{
          0: <Detection>[car(0.30)],
          3: <Detection>[car(0.375)],
          6: <Detection>[car(0.47)],
          9: <Detection>[car(0.59)],
          12: <Detection>[car(0.80)],
          13: <Detection>[car(0.95)],
        };
        int preUrgentAt = -1;
        int urgentSpeechAt = -1;
        final Set<int> ids = <int>{};
        for (int i = 0; i <= 13; i++) {
          final HazardPipelineResult r = pipeline.processFrame(
            frames[i] ?? const <Detection>[],
            epoch.add(Duration(milliseconds: i * 100)),
            pitchDeg: null,
            ego: EgoMotion.unknown,
          );
          for (final TrackEstimate e in r.estimates) {
            ids.add(e.track.id);
          }
          if (r.preUrgentTrackIds.isNotEmpty && preUrgentAt < 0) {
            preUrgentAt = i;
          }
          if (r.alert != null && r.alert!.urgent && urgentSpeechAt < 0) {
            urgentSpeechAt = i;
          }
          if (i < 13) {
            expect(r.alert, isNull,
                reason: 'frame $i: no speech of any level '
                    'before urgent confirmation (the sparse '
                    'hits never confirm the warning tier '
                    'either)');
          }
        }
        expect(ids, hasLength(1),
            reason: 'the sparse target keeps ONE id on '
                '$backend (the S1-a regression)');
        expect(preUrgentAt, 12,
            reason: 'frame 12: tau_now issued below 1.5 '
                'with the track still unconfirmed -> the '
                'pre-urgent vibration fires (and only there)');
        expect(urgentSpeechAt, 13,
            reason: 'frame 13: the back-to-back hit '
                'confirms (2-of-3), the urgent speaks AFTER '
                'the vibration on the timeline');
      });

      test('$backend pre-urgent one-shot: without '
          'confirmation the speech is never made up', () {
        final HazardPipeline pipeline =
            HazardPipeline(tracker: trackerForBackend(backend));
        final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
        Detection car(double s) => Detection(
            label: 'car', confidence: 0.9, cx: 0.5, cy: 0.55, w: s, h: s);
        // Same sparse dive as above through frame 12 (the
        // pre-urgent fires), then the track VANISHES for
        // good: no urgent speech may ever follow.
        final Map<int, List<Detection>> frames = <int, List<Detection>>{
          0: <Detection>[car(0.30)],
          3: <Detection>[car(0.375)],
          6: <Detection>[car(0.47)],
          9: <Detection>[car(0.59)],
          12: <Detection>[car(0.80)],
        };
        int preCount = 0;
        for (int i = 0; i <= 16; i++) {
          final HazardPipelineResult r = pipeline.processFrame(
            frames[i] ?? const <Detection>[],
            epoch.add(Duration(milliseconds: i * 100)),
            pitchDeg: null,
            ego: EgoMotion.unknown,
          );
          preCount += r.preUrgentTrackIds.length;
          expect(r.alert, isNull,
              reason: 'frame $i: confirmation never arrives, '
                  'so the urgent speech is never made up '
                  '(the spent vibration is the accepted '
                  'false-alarm cost)');
        }
        expect(preCount, 1,
            reason: 'exactly one pre-urgent vibration for '
                'the whole unbroken condition run');
      });
    }

    for (final String backend in kBackends) {
      for (final double bigT in <double>[1.0, 0.9]) {
        test('$backend fast approach (start TTC $bigT s, '
            'ego UNKNOWN): pre-urgent reads the RAW frame '
            'estimate (FIX4-FINAL dual surfaces)', () {
          // Pure scale dive, pitch unknown: s(t) =
          // s0*T/(T-t) has true scale TTC (T - t) from the
          // first frame. The persistence guard cannot have
          // published tau by frame 2 (it needs three
          // in-band estimates), yet the RAW agile tau_now
          // is already < 1.5 s there -- the pre-urgent
          // vibration reads THAT surface and fires at
          // frame 2 (<= the 3-frame cap). The urgent
          // SPEECH on this path lands the same frame via
          // the scale path's NORMAL-ttcS band (ttcS is
          // already <= 3 s with urgent confirmation) --
          // never via the raw surface; inside the frame,
          // _onYoloDetectionsPipeline dispatches the
          // pre-urgent vibrations BEFORE the alert speech,
          // so on the real timeline vibration still
          // strictly precedes speech.
          final HazardPipeline pipeline =
              HazardPipeline(tracker: trackerForBackend(backend));
          final DateTime epoch =
              DateTime.fromMillisecondsSinceEpoch(0);
          Detection dive(double t) {
            final double s = 0.30 * bigT / (bigT - t);
            return Detection(
                label: 'car',
                confidence: 0.9,
                cx: 0.5,
                cy: 0.55,
                w: s,
                h: s);
          }

          int preAt = -1;
          int urgAt = -1;
          for (int i = 0; i <= 8; i++) {
            final double t = i * 0.1;
            final HazardPipelineResult r = pipeline.processFrame(
              t < bigT - 0.05
                  ? <Detection>[dive(t)]
                  : const <Detection>[],
              epoch.add(Duration(milliseconds: i * 100)),
              pitchDeg: null,
              ego: EgoMotion.unknown,
            );
            if (r.preUrgentTrackIds.isNotEmpty && preAt < 0) {
              preAt = i;
            }
            if (r.alert != null && r.alert!.urgent && urgAt < 0) {
              urgAt = i;
            }
          }
          expect(preAt, 2,
              reason: 'the raw current-frame tau_now '
                  '(< 1.5 s from frame 2) fires the '
                  'vibration inside the first three frames '
                  '-- the guard-published value does not '
                  'exist yet at that point');
          expect(urgAt, 2,
              reason: 'urgent speech follows through the '
                  'existing published/normal surfaces, '
                  'dispatched after the vibration in the '
                  'same frame');
          expect(preAt, lessThanOrEqualTo(urgAt));
        });
      }

      for (final double bigT in <double>[1.0, 0.9]) {
        test('$backend fast approach (start TTC $bigT s, ego '
            'KNOWN): vibration first, speech inside the '
            'physical window (FIX4-FINAL dual surfaces; '
            'NH-M1-11 for 0.9)', () {
          // Ranged geometry (carAt: scale and ground plane
          // agree by construction), walking user, closing
          // 6 m/s from Z0 = 6*bigT: true TTC at frame i is
          // bigT - 0.1*i and the target is gone at frame
          // bigT*10, so the urgent speech must land on a
          // frame whose true TTC is still positive.
          //
          // T = 1.0 (the FIX4-FINAL case): the agile legs
          // agree at the decisive frame; raw tau_now is
          // in-band from frame 2, the guard publishes at
          // the 3rd consecutive in-band estimate, speech
          // at frame 4 -- the two frame numbers ARE the
          // dual reading surfaces made visible.
          //
          // T = 0.9 (the NH-M1-11 case): at frames 4-6 the
          // agile legs transiently DISAGREE (relative
          // difference > 50%) exactly while the guard run
          // sits at 2. Before the exemption the fused tau
          // nulled and the run reset to 0; the geometry
          // died at frame 8 with the run back at only 2
          // and the voice never landed. With the exemption
          // (the track vibrated at frame 2 and willHit
          // holds throughout) the disagreeing frames fuse
          // the smaller positive agile leg and FREEZE the
          // run at 2; frame 7's ordinary in-band estimate
          // resumes it to 3 and the speech lands there --
          // true TTC 0.2 s, inside the window. The normal
          // tier is NOT exempted: both T values carry a
          // normal-tier disagreement on the speech frame
          // or its neighbours while the urgent speaks via
          // tau_now.
          final HazardPipeline pipeline =
              HazardPipeline(tracker: trackerForBackend(backend));
          final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
          int preAt = -1;
          int urgAt = -1;
          for (int i = 0; i <= 10; i++) {
            final double t = i * 0.1;
            final double z = 6.0 * (bigT - t) / bigT;
            final HazardPipelineResult r = pipeline.processFrame(
              (bigT - t) > 0.05
                  ? <Detection>[carAt(z)]
                  : const <Detection>[],
              epoch.add(Duration(milliseconds: i * 100)),
              pitchDeg: 10,
              ego: EgoMotion.judge(gpsSpeedMps: 1.2),
            );
            if (r.preUrgentTrackIds.isNotEmpty && preAt < 0) {
              preAt = i;
            }
            if (r.alert != null && r.alert!.urgent && urgAt < 0) {
              urgAt = i;
            }
          }
          expect(preAt, 2,
              reason: 'raw tau_now < 1.5 s at frame 2: the '
                  'vibration fires on the current-frame '
                  'estimate (both T values, both backends)');
          expect(urgAt, bigT >= 1.0 ? 4 : 7,
              reason: 'T=$bigT urgent speech frame '
                  '(measured: 1.0 -> 4 via the ordinary '
                  'guard publication; 0.9 -> 7 via the '
                  'NH-M1-11 frozen run resuming)');
          expect(preAt, lessThan(urgAt),
              reason: 'vibration strictly before speech');
          expect(bigT - 0.1 * urgAt, greaterThan(0),
              reason: 'the speech lands while the target '
                  'still has true TTC left (inside the '
                  'physical window)');
        });
      }

      test('$backend cooldown survives a 2-frame gap '
          'after the urgent (CDX4 S1-a regression)', () {
        // Scenario (2) geometry (Z 12 -> 2 m at 2.5 m/s,
        // still user): find the urgent frame on a clean
        // run, then re-run with the target VANISHED for
        // the two frames right after the urgent and back
        // for six more. With the id (and with it the
        // estimator state and the cooldown) intact, the
        // reappeared target produces NO second urgent
        // inside the cooldown; the window after the gap
        // is kept short enough that neither the cooldown
        // expiry (4 s) nor the 40% TTC-drop exception can
        // legitimately re-arm it.
        List<Detection?> frames({Set<int> gap = const <int>{}}) =>
            <Detection?>[
              for (int i = 0; i <= 40; i++)
                gap.contains(i) ? null : carAt(12.0 - 0.25 * i),
            ];
        final EgoRun clean =
            runEgo(backend, frames(), EgoMotion.still);
        final int uIdx = clean.alerts
            .indexWhere((HazardAlert a) => a.urgent);
        expect(uIdx, greaterThanOrEqualTo(0),
            reason: 'the clean run urgents (scenario 2)');
        final int uFrame = clean.alertFrames[uIdx];
        final int uTrackId = clean.alerts[uIdx].trackId;
        final List<Detection?> gappedAll =
            frames(gap: <int>{uFrame + 1, uFrame + 2});
        final EgoRun gapped = runEgo(
          backend,
          gappedAll.sublist(0, uFrame + 9),
          EgoMotion.still,
        );
        final List<HazardAlert> urgents =
            gapped.alerts.where((HazardAlert a) => a.urgent).toList();
        expect(urgents, hasLength(1),
            reason: 'exactly one urgent across the gap: '
                'the cooldown is keyed by the SURVIVING '
                'track id, not restarted by the '
                'reappearance');
        expect(urgents.single.trackId, uTrackId);
        // One estimate per present frame in frame order
        // (single-target scenario), so the estimates
        // after the gap are a plain tail slice: frames
        // uFrame+3 .. uFrame+8 are the last six entries.
        final List<TrackEstimate> afterGap =
            gapped.estimates.sublist(gapped.estimates.length - 6);
        expect(afterGap, hasLength(6));
        for (final TrackEstimate e in afterGap) {
          expect(e.track.id, uTrackId,
              reason: 'the reappeared target keeps its '
                  'pre-gap id');
        }
      });
    }

    test('main wiring: pre-urgent ids vibrate without '
        'speech; latency stamps wired', () {
      final String src = File('lib/main.dart').readAsStringSync();
      expect(src.contains('result.preUrgentTrackIds'), isTrue,
          reason: 'the app consumes the pipeline\'s '
              'pre-urgent set');
      expect(src.contains('_hazardPipeline.onLatency'), isTrue,
          reason: 'the pipeline-segment latency stamp is '
              'wired to the app log (kept, FIX4-FINAL S3)');
      expect(src.contains('frame-to-callback'), isTrue,
          reason: 'S3 segment 1 (frame timestamp -> '
              'detection callback) is stamped');
      expect(src.contains('pipeline-to-speak'), isTrue,
          reason: 'S3 segment 2 (pipeline return -> TTS '
              'speak start) is stamped');
      expect(src.contains('onSpeakStart'), isTrue,
          reason: 'segment 2 closes on the engine\'s '
              'speak-start callback, not on the speak() '
              'call');
      expect(src.contains('latencySegmentMs'), isTrue,
          reason: 'both segments use the shared, '
              'unit-tested segment helper');
    });

    for (final String backend in kBackends) {
      test('$backend U=0 grid: side-pass car under KNOWN '
          'and UNKNOWN ego stays silent', () {
        // The car grows (it is genuinely approaching its
        // closest point) but its extrapolated landing stays
        // 0.56 * Z metres off-axis -- outside the 1.0 m
        // channel at every Z in range (blocking condition:
        // the channel-intersection conjunct).
        for (final EgoMotion ego in <EgoMotion>[
          EgoMotion.still,
          EgoMotion.unknown,
        ]) {
          final HazardPipeline pipeline =
              HazardPipeline(tracker: trackerForBackend(backend));
          final DateTime epoch =
              DateTime.fromMillisecondsSinceEpoch(0);
          for (int i = 0; i < 25; i++) {
            final double z = 12.0 - 0.3 * i;
            final double s = 0.96 / z;
            final double bottom = bottomForRange(z);
            final HazardPipelineResult r = pipeline.processFrame(
              <Detection>[
                Detection(
                    label: 'car',
                    confidence: 0.9,
                    cx: 0.5 + 0.56 * 0.714,
                    cy: bottom - s / 2,
                    w: s,
                    h: s),
              ],
              epoch.add(Duration(milliseconds: i * 100)),
              pitchDeg: 10,
              ego: ego,
            );
            expect(r.alert, isNull,
                reason: 'frame $i (ego known: '
                    '${ego.speedKnown}): side-pass, landing '
                    'outside the channel');
          }
        }
      });

      test('$backend U=0 grid: flicker person under '
          'UNKNOWN ego stays silent (no growth conjunct)',
          () {
        // Two frames on, three off, constant size: TTC_s
        // never exists, so the scale path's growth
        // conjunct (ii) blocks every level; the flicker
        // can also never satisfy urgent confirmation with
        // an in-band tau (there is no tau at all).
        final HazardPipeline pipeline =
            HazardPipeline(tracker: trackerForBackend(backend));
        final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
        for (int i = 0; i < 30; i++) {
          final bool on = i % 5 < 2;
          final HazardPipelineResult r = pipeline.processFrame(
            <Detection>[
              if (on)
                const Detection(
                    label: 'person',
                    confidence: 0.9,
                    cx: 0.5,
                    cy: 0.55,
                    w: 0.18,
                    h: 0.36),
            ],
            epoch.add(Duration(milliseconds: i * 100)),
            pitchDeg: null,
            ego: EgoMotion.unknown,
          );
          expect(r.alert, isNull, reason: 'frame $i');
          expect(r.preUrgentTrackIds, isEmpty, reason: 'frame $i');
        }
      });
    }
  });

  group('main wiring guard (CDX1 item 1)', () {
    test('the pipeline is fed by the per-frame ego judge', () {
      final String src = File('lib/main.dart').readAsStringSync();
      expect(src.contains('ego: EgoMotion.still'), isFalse,
          reason: 'the hardcoded still ego is gone');
      // M2B-FIX1 item 4: the original literal
      // 'ego: _egoMotionNow(now)' expired when M2
      // section 3.1 hoisted the per-frame judgement
      // into a shared local -- the pipeline and the
      // frame-rate policy must read ONE judgement of
      // the frame, never two sensor reads. The guard's
      // INTENT is unchanged (the pipeline eats the
      // per-frame judged ego, never a hardcoded
      // still); the literal is now a DUAL assertion
      // covering both halves of the hoisting: the
      // per-frame assignment AND the pipeline call
      // consuming exactly that local.
      expect(
          src.contains('final EgoMotion egoNow = _egoMotionNow(now);'),
          isTrue,
          reason: 'the frame\'s ego is judged once, '
              'into the shared egoNow local');
      expect(src.contains('ego: egoNow,'), isTrue,
          reason: 'the pipeline call consumes that '
              'per-frame judgement');
      expect(src.contains('EgoMotion.judge('), isTrue);
    });
  });
}
