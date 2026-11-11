/// NAVHAZ M1, NH-M1-11 (lead's ruling, 2026-11-11):
/// the disagreement exemption for an already-vibrated
/// track.
///
/// Background (the FIX4-FINAL residual): a fast approach
/// at true TTC 0.9 s under a KNOWN ego vibrated at frame
/// 2, then the two AGILE legs transiently disagreed at
/// frames 4-6; fusion distrust nulled the raw urgent tau
/// and the persistence guard's run reset to 0, so the
/// urgent voice never landed inside the physical window.
///
/// The ruling: a track that has ALREADY fired its
/// pre-urgent vibration in the current episode AND still
/// extrapolates into the forward channel (willHit) is
/// exempt from that distrust for the urgent tier only --
/// a disagreeing frame fuses the agile legs
/// CONSERVATIVELY (the smaller positive leg) and FREEZES
/// the guard run (neither advanced nor reset). A track
/// that never vibrated keeps the distrust verbatim.
///
/// These tests reuse the exact geometry that produced
/// the residual (Z0 = 6*0.9 m closing at 6 m/s under
/// pitch 10, walking user): the disagreement is not
/// synthesized -- the two agile filters genuinely diverge
/// on frames 4-6 of this dive (normal-tier disagreement
/// is visible on those frames too). The asserted frame
/// numbers are the measured timeline of that dive on both
/// backends (they agree frame for frame).
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/hazard/ego_motion.dart';
import 'package:mingtu_ai/core/hazard/hazard_pipeline.dart';
import 'package:mingtu_ai/core/hazard/ttc_estimator.dart';
import 'package:mingtu_ai/core/navhaz_config.dart';
import 'package:mingtu_ai/core/tracking/tracker.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';

import 'navhaz_fixture_harness.dart';

/// Box bottom for a ground-contact target at range [z]
/// under pitch 10 degrees (the estimator's law, inverted
/// -- same helper as navhaz_ego_test).
double _bottomForRange(double z) {
  final double fy = 0.5 / math.tan(math.pi / 6);
  final double depression = math.atan(NavHazConfig.cameraHeightM / z);
  return NavHazConfig.principalY +
      fy * math.tan(depression - 10.0 * math.pi / 180);
}

/// A car dead ahead at range [z]; size follows s = 0.96/z
/// so scale and ground-plane geometry agree.
Detection _carAt(double z) {
  final double s = 0.96 / z;
  final double bottom = _bottomForRange(z);
  return Detection(
      label: 'car', confidence: 0.9, cx: 0.5, cy: bottom - s / 2, w: s, h: s);
}

class _DiveFrame {
  final TrackEstimate? estimate;
  final bool preUrgent;
  final bool urgentSpeech;
  final int tauRun;
  final bool episodeLatched;
  const _DiveFrame({
    required this.estimate,
    required this.preUrgent,
    required this.urgentSpeech,
    required this.tauRun,
    required this.episodeLatched,
  });
}

/// The residual dive: Z0 = 6*bigT closing at 6 m/s, true
/// TTC at frame i = bigT - 0.1*i; frames run to 10 (the
/// geometry is fed while bigT - t > 0.05).
List<_DiveFrame> _runDive(String backend, double bigT,
    {required EgoMotion ego}) {
  final HazardPipeline pipeline =
      HazardPipeline(tracker: trackerForBackend(backend));
  final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
  final List<_DiveFrame> frames = <_DiveFrame>[];
  for (int i = 0; i <= 10; i++) {
    final double t = i * 0.1;
    final double z = 6.0 * (bigT - t) / bigT;
    final HazardPipelineResult r = pipeline.processFrame(
      (bigT - t) > 0.05 ? <Detection>[_carAt(z)] : const <Detection>[],
      epoch.add(Duration(milliseconds: i * 100)),
      pitchDeg: 10,
      ego: ego,
    );
    final TrackEstimate? e = r.estimates.isEmpty ? null : r.estimates.first;
    final ({int tauRun, bool vibratedEpisode}) st = e == null
        ? (tauRun: -1, vibratedEpisode: false)
        : pipeline.debugExemptionState(e.track.id);
    frames.add(_DiveFrame(
      estimate: e,
      preUrgent: r.preUrgentTrackIds.isNotEmpty,
      urgentSpeech: r.alert != null && r.alert!.urgent,
      tauRun: st.tauRun,
      episodeLatched: st.vibratedEpisode,
    ));
  }
  return frames;
}

void main() {
  group('NH-M1-11 transient-disagreement injection', () {
    for (final String backend in kBackends) {
      test('$backend exempt track: disagreeing frames fuse '
          'the smaller positive leg, the guard run FREEZES, '
          'and the voice lands after the run resumes', () {
        // INJECTION POINT: no synthetic leg values are
        // fed anywhere -- the dive geometry itself makes
        // the agile scale/range filters diverge beyond
        // the 50% tolerance on frames 4-6 (both legs stay
        // positive throughout). The track vibrates at
        // frame 2, so by frame 4 the guard run has
        // accumulated to 2 and the episode latch is set:
        // the exemption's two qualifications are met.
        final List<_DiveFrame> f =
            _runDive(backend, 0.9, ego: EgoMotion.judge(gpsSpeedMps: 1.2));

        // Precondition: the vibration fired (frame 2) and
        // the run accumulated to 2 before the injection.
        expect(f[2].preUrgent, isTrue,
            reason: 'frame 2: the pre-urgent vibration '
                'fires on the raw surface');
        expect(f[2].tauRun, 1);
        expect(f[3].tauRun, 2,
            reason: 'frame 3: the guard run reaches 2 '
                'before the disagreement starts');
        expect(f[3].episodeLatched, isTrue,
            reason: 'the episode latch is set from the '
                'frame-2 vibration on');

        // (a) The disagreeing frames' raw tau is the
        // SMALLER POSITIVE agile leg minus the pipeline
        // latency -- present, positive, never null/zeroed.
        // The agile legs are recomputed from the returned
        // estimate's own fields? They are not carried on
        // the estimate; the exact min is pinned instead by
        // the fuseLegsConservative unit assertions below
        // and by the raw tau's measured band here: it
        // keeps shrinking toward zero with the dive
        // (0.2x -> 0.1x -> ~0.0x), tracking the faster
        // (range) leg, not the slower scale leg (~0.5+).
        for (final int i in <int>[4, 5, 6]) {
          final TrackEstimate e = f[i].estimate!;
          expect(e.urgentDisagreementExempted, isTrue,
              reason: 'frame $i: the frame ran under the '
                  'exemption');
          expect(e.ttcDisagreement, isTrue,
              reason: 'frame $i: the NORMAL tier still '
                  'disagrees -- the exemption never touches '
                  'the normal fusion');
          expect(e.ttcS, isNull,
              reason: 'frame $i: the normal fused TTC '
                  'stays distrusted-null');
          expect(e.ttcUrgentRawS, isNotNull,
              reason: 'frame $i: (a) the raw urgent tau '
                  'is NOT zeroed by the disagreement');
          expect(e.ttcUrgentRawS!, greaterThanOrEqualTo(0),
              reason: 'frame $i: (a) the fused value is a '
                  'positive leg (clamped at 0 by the '
                  'latency subtraction at most)');
          expect(e.ttcUrgentRawS!, lessThan(0.3),
              reason: 'frame $i: (a) the raw tau tracks '
                  'the SMALLER (range) agile leg -- the '
                  'scale leg alone would read ~0.5+ here');
          // (b) The guard run is FROZEN at its
          // pre-injection value on every disagreeing
          // frame: not advanced, not reset.
          expect(f[i].tauRun, 2,
              reason: 'frame $i: (b) the run froze at 2');
          expect(e.ttcUrgentS, isNull,
              reason: 'frame $i: a frozen frame never '
                  'issues the published tau');
          expect(f[i].episodeLatched, isTrue,
              reason: 'frame $i: the episode latch '
                  'survives the whole injection (mid-episode '
                  'eligibility loss is not an episode end)');
        }

        // (c) The disagreement ends at frame 7 (the range
        // leg's geometry expires, the scale leg carries):
        // the run resumes FROM the frozen value, reaches
        // 3, the tau publishes, and the urgent voice lands
        // -- at true TTC 0.9 - 0.7 = 0.2 s, inside the
        // physical window.
        expect(f[7].tauRun, 3,
            reason: 'frame 7: (c) the run resumes from '
                'the frozen 2 and reaches 3');
        expect(f[7].estimate!.ttcUrgentS, isNotNull,
            reason: 'frame 7: (c) the tau publishes');
        expect(f[7].urgentSpeech, isTrue,
            reason: 'frame 7: (c) the urgent voice lands');
        expect(f.indexWhere((_DiveFrame x) => x.urgentSpeech), 7,
            reason: 'no urgent speech on any earlier frame');
        expect(f.indexWhere((_DiveFrame x) => x.preUrgent), 2,
            reason: 'vibration (frame 2) strictly precedes '
                'speech (frame 7)');
      });

      test('$backend control: the SAME dive judged with an '
          'UNKNOWN ego never fuses, so there is nothing to '
          'exempt and the timeline is the pre-NH-M1-11 one',
          () {
        // Control by construction: with the ego speed
        // unknown the estimator performs NO fusion (the
        // effective TTC is the scale leg alone), so the
        // disagreement the exemption forgives cannot
        // occur; the exemption flag must stay false on
        // every frame and the scale path must behave
        // exactly as it did before NH-M1-11 (vibration
        // frame 2, speech frame 2 via the normal scale
        // band -- the FIX4-FINAL unknown-ego timeline).
        final List<_DiveFrame> f =
            _runDive(backend, 0.9, ego: EgoMotion.unknown);
        for (int i = 0; i < f.length; i++) {
          final TrackEstimate? e = f[i].estimate;
          if (e == null) continue;
          expect(e.urgentDisagreementExempted, isFalse,
              reason: 'frame $i: no fusion on the unknown '
                  'path -> the exemption never triggers');
          expect(e.ttcDisagreement, isFalse,
              reason: 'frame $i: disagreement is not even '
                  'applicable without fusion');
        }
        expect(f.indexWhere((_DiveFrame x) => x.preUrgent), 2);
        expect(f.indexWhere((_DiveFrame x) => x.urgentSpeech), 2,
            reason: 'the unknown-ego timeline is unchanged '
                'by NH-M1-11');
      });
    }

    test('estimator-level control: a track that never '
        'vibrated keeps the distrust verbatim through the '
        'same leg geometry', () {
      // (d) Feed the T=0.9 dive's boxes straight into a
      // bare estimator WITHOUT the pipeline: no
      // pre-urgent vibration can ever fire, so the
      // episode latch stays empty and every disagreeing
      // frame must behave exactly as before NH-M1-11 --
      // raw tau null on the disagreeing frames and the
      // guard run RESET to 0 (not frozen).
      final TtcEstimator estimator = TtcEstimator();
      final Track track = Track(id: 4242, label: 'car');
      final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
      final List<TrackEstimate> estimates = <TrackEstimate>[];
      final List<int> runs = <int>[];
      for (int i = 0; i <= 8; i++) {
        final double t = i * 0.1;
        final double z = 6.0 * (0.9 - t) / 0.9;
        if (0.9 - t > 0.05) {
          track.recordMatch(_carAt(z), epoch.add(Duration(milliseconds: i * 100)));
          estimates.add(estimator.estimate(
            track,
            at: epoch.add(Duration(milliseconds: i * 100)),
            pitchDeg: 10,
            ego: EgoMotion.judge(gpsSpeedMps: 1.2),
          ));
        } else {
          estimates.add(estimates.last);
        }
        runs.add(estimator.debugTauNowInBandRun(track.id));
      }
      expect(estimator.debugPreVibratedEpisode(track.id), isFalse,
          reason: 'no pipeline -> no vibration -> the '
              'latch is empty for the whole dive');
      // The run accumulates on the agreeing frames...
      expect(runs[3], 2,
          reason: 'frames 2-3 agree: the run reaches 2, '
              'exactly as in the pipeline run');
      // ...and the first disagreeing frame RESETS it
      // (the pre-NH-M1-11 behaviour), with the raw tau
      // zeroed -- the precise contrast to the exempt
      // pipeline run above, on identical geometry.
      for (final int i in <int>[4, 5, 6]) {
        expect(estimates[i].urgentDisagreementExempted, isFalse,
            reason: 'frame $i: (d) no exemption without a '
                'vibration');
        expect(estimates[i].ttcUrgentRawS, isNull,
            reason: 'frame $i: (d) the raw tau is zeroed '
                'by the distrust, as before');
        expect(runs[i], 0,
            reason: 'frame $i: (d) the guard run is '
                'RESET, not frozen');
      }
    });

    test('fuseLegsConservative: the smaller POSITIVE leg, '
        'never an average, never a degenerate leg', () {
      // Consistent with fuseLegs' shape: one valid leg ->
      // that leg; none -> null.
      expect(TtcEstimator.fuseLegsConservative(2.0, null), 2.0);
      expect(TtcEstimator.fuseLegsConservative(null, 3.0), 3.0);
      expect(TtcEstimator.fuseLegsConservative(null, null), isNull);
      // Disagreeing pair -> the smaller (the conservative
      // reading), in either order -- and NOT the mean.
      expect(TtcEstimator.fuseLegsConservative(5.0, 1.0), 1.0);
      expect(TtcEstimator.fuseLegsConservative(1.0, 5.0), 1.0);
      expect(TtcEstimator.fuseLegsConservative(5.0, 1.0),
          isNot(closeTo(3.0, 1e-9)),
          reason: 'never averaged');
      // A non-positive leg is not a usable reading: it
      // must not win the min and manufacture a zero tau.
      expect(TtcEstimator.fuseLegsConservative(0.0, 2.0), isNull);
      expect(TtcEstimator.fuseLegsConservative(-1.0, 2.0), isNull);
      // The ordinary fusion is untouched by the helper's
      // existence: the same disagreeing pair still
      // distrusts to null through fuseLegs.
      expect(TtcEstimator.fuseLegs(5.0, 1.0), isNull,
          reason: 'the standing distrust rule is verbatim');
    });
  });
}
