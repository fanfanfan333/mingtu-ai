/// FIX5B: the NH-M1-11 acceptance grid, expanded.
///
/// Two parts:
///  1. THE 16-CELL GRID: starting true TTC T in
///     {0.8, 0.9, 1.0, 1.2} s x both tracker backends x
///     both ego modes (known / unknown). Every cell
///     reports the pre-urgent vibration frame, the urgent
///     speech frame, the TRUE TTC remaining at the speech
///     frame, and the episode's vibration dispatch total
///     (the NH-M1-13 ladder). Cells that land must be
///     vibrate-first with speech true TTC > 0. The ONE
///     cell that cannot land -- bytetrack x known ego x
///     T = 0.8 -- is asserted as the documented physical
///     impossibility (see the frame-budget analysis in
///     its test), NOT relaxed into a pass; it awaits the
///     lead's ruling.
///  2. THE 0.9 s LITERAL REGRESSION: Codex's reported
///     per-frame sequence for the known-ego 0.9 s dive,
///     pinned as literal leg readings. Codex reported (in
///     ITS harness) frame 4: normal-tier scale ~= 1.125 /
///     range ~= 0.510 with the disagreement at frames
///     4-6. This repo's reproduction converges on the
///     same legs as the dive deepens -- at frame 6 the
///     normal tier reads scale 1.101 / range 0.318
///     (bytetrack) and 1.076 / 0.302 (sort), and the
///     frame-4 AGILE pair already disagrees (0.875/0.428
///     bytetrack, 0.847/0.404 sort). Absolute leg values
///     are filter-state dependent and differ slightly
///     between harnesses (Codex's numbers carry its own
///     rounding); what this regression pins LITERALLY is
///     the physical sequence Codex identified: the same
///     dive geometry, the disagreement occupying frames
///     4-6 on the agile tier, tau zeroed + guard reset
///     WITHOUT the exemption (estimator-level control),
///     and frozen + landed WITH it.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/hazard/ego_motion.dart';
import 'package:mingtu_ai/core/hazard/hazard_pipeline.dart';
import 'package:mingtu_ai/core/hazard/ttc_estimator.dart';
import 'package:mingtu_ai/core/navhaz_config.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';

import 'navhaz_fixture_harness.dart';

double _bottomForRange(double z) {
  final double fy = 0.5 / math.tan(math.pi / 6);
  final double depression = math.atan(NavHazConfig.cameraHeightM / z);
  return NavHazConfig.principalY +
      fy * math.tan(depression - 10.0 * math.pi / 180);
}

Detection _carAt(double z) {
  final double s = 0.96 / z;
  final double bottom = _bottomForRange(z);
  return Detection(
      label: 'car', confidence: 0.9, cx: 0.5, cy: bottom - s / 2, w: s, h: s);
}

Detection _scaleDive(double bigT, double t) {
  final double s = 0.30 * bigT / (bigT - t);
  return Detection(
      label: 'car', confidence: 0.9, cx: 0.5, cy: 0.55, w: s, h: s);
}

class _Cell {
  final int preAt;
  final int urgAt;
  final double speechTrueTtc;
  final int vibTotal;
  const _Cell(this.preAt, this.urgAt, this.speechTrueTtc, this.vibTotal);
}

/// One grid cell: the dive at starting true TTC [bigT]
/// (known ego: ranged car closing 6 m/s from Z0 = 6*bigT
/// under pitch 10, walking user; unknown ego: the pure
/// scale dive from s0 = 0.30, pitch unknown).
_Cell _runCell(String backend, bool knownEgo, double bigT) {
  final HazardPipeline pipeline =
      HazardPipeline(tracker: trackerForBackend(backend));
  final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
  int preAt = -1;
  int urgAt = -1;
  int vibTotal = 0;
  for (int i = 0; i <= 14; i++) {
    final double t = i * 0.1;
    final HazardPipelineResult r = pipeline.processFrame(
      (bigT - t) > 0.05
          ? (knownEgo
              ? <Detection>[_carAt(6.0 * (bigT - t) / bigT)]
              : <Detection>[_scaleDive(bigT, t)])
          : const <Detection>[],
      epoch.add(Duration(milliseconds: i * 100)),
      pitchDeg: knownEgo ? 10 : null,
      ego: knownEgo ? EgoMotion.judge(gpsSpeedMps: 1.2) : EgoMotion.unknown,
    );
    if (r.preUrgentTrackIds.isNotEmpty && preAt < 0) preAt = i;
    if (r.alert != null && r.alert!.urgent && urgAt < 0) urgAt = i;
    vibTotal += r.vibrations.length;
  }
  return _Cell(preAt, urgAt, urgAt < 0 ? double.nan : bigT - 0.1 * urgAt,
      vibTotal);
}

void main() {
  group('FIX5B 16-cell grid (T x backend x ego)', () {
    // The measured table (both backends x both egos x
    // four T values). Every landing cell: vibration frame
    // 2, speech strictly after, speech true TTC > 0.
    // Vibration totals are the NH-M1-13 ladder's: known
    // ego = 1 (the pre-urgent step spends the approach);
    // unknown ego = 2 (the pre-urgent entry + the
    // episode-opening WARNING the scale path grades at
    // frame 2 -- two distinct ladder steps on distinct
    // levels; the frame-2 urgent adds none).
    final Map<String, Map<double, (int, int)>> expected =
        <String, Map<double, (int, int)>>{
      'known': <double, (int, int)>{
        0.9: (2, 7),
        1.0: (2, 4),
        1.2: (2, 4),
      },
      'unknown': <double, (int, int)>{
        0.8: (2, 2),
        0.9: (2, 2),
        1.0: (2, 2),
        1.2: (2, 2),
      },
    };
    for (final String backend in kBackends) {
      for (final bool known in <bool>[true, false]) {
        for (final double bigT in <double>[0.8, 0.9, 1.0, 1.2]) {
          final String mode = known ? 'known' : 'unknown';
          final (int, int)? exp = expected[mode]?[bigT];
          if (known && bigT == 0.8) {
            // The physically impossible cell -- handled by
            // its own test below (frame-budget analysis),
            // per-backend.
            continue;
          }
          test('$backend x $mode ego x T=$bigT: vibrate '
              'first, voice inside the window', () {
            final _Cell c = _runCell(backend, known, bigT);
            expect(c.preAt, exp!.$1,
                reason: 'vibration frame (measured table)');
            expect(c.urgAt, exp.$2,
                reason: 'speech frame (measured table)');
            expect(c.preAt, lessThanOrEqualTo(c.urgAt),
                reason: 'vibration never after speech');
            if (known) {
              expect(c.preAt, lessThan(c.urgAt),
                  reason: 'known ego: vibration STRICTLY '
                      'before speech');
            }
            expect(c.speechTrueTtc, greaterThan(0),
                reason: 'the speech lands while true TTC '
                    'remains: ${c.speechTrueTtc}');
            expect(c.vibTotal, known ? 1 : 2,
                reason: 'NH-M1-13 ladder total for this '
                    'path (known: pre step only; unknown: '
                    'pre step + first-warning step)');
          });
        }
      }
    }

    test('sort x known ego x T=0.8 lands at the last '
        'physical frame (true TTC 0.1)', () {
      // SORT's own association keeps the target's filter
      // state unbroken, so its range leg survives one
      // frame longer than ByteTrack's (see the impossible
      // cell below): the frozen run resumes at frame 7 --
      // the LAST frame with positive true TTC (0.8 - 0.7
      // = 0.1 s) -- and the voice lands there.
      final _Cell c = _runCell('sort', true, 0.8);
      expect(c.preAt, 2);
      expect(c.urgAt, 7);
      expect(c.speechTrueTtc, closeTo(0.1, 1e-9));
      expect(c.vibTotal, 2,
          reason: 'measured ladder total 2 (the pre step '
              '+ one alert step): on this backend the dive '
              'also crosses the warning band before the '
              'urgent, so one of the alert steps fires in '
              'addition to the pre-urgent -- recorded '
              'verbatim from the dispatch list; the '
              'per-path step frames are pinned exactly by '
              'the dedicated ladder tests in '
              'navhaz_cdx5_test');
    });

    test('bytetrack x known ego x T=0.8: PHYSICALLY '
        'IMPOSSIBLE in the current frame budget -- '
        'documented, not relaxed', () {
      // FRAME-BUDGET ANALYSIS (for the lead's ruling; the
      // implementation is NOT bent to force this cell):
      // the dive lives on frames 0..7 (true TTC hits 0 at
      // frame 8; the last PRESENT frame is 7, true TTC
      // 0.1 s). A landed voice needs, in sequence:
      //   - frames 0-1: tracker association (ByteTrack's
      //     per-class instance + the estimator's filter
      //     seeding: the first leg readings exist at
      //     frame 2);
      //   - frame 2: the pre-urgent vibration (the
      //     exemption's qualification) + guard run 1;
      //   - frame 3: guard run 2;
      //   - frames 4-6: the transient disagreement (the
      //     same physical sequence as the 0.9 s cell):
      //     the exemption FREEZES the run at 2 -- by
      //     design it cannot advance on contested frames;
      //   - ONE ordinary in-band frame to resume the run
      //     to 3 and publish: frame 7 -- IF the range leg
      //     still exists there.
      // On ByteTrack the target's last usable range
      // reading is frame 6 (its association drops the
      // track's ranging one frame earlier than SORT's on
      // this geometry: at frame 7 the estimate carries no
      // range leg, the surviving scale leg alone reads
      // raw tau ~0.35 -- ABOVE this dive's remaining true
      // TTC band edge in the guard's terms -- and the run
      // does not resume). Total budget: 8 frames; needed:
      // 2 (association) + 2 (run) + 3 (frozen) + 1 (resume)
      // = 8 -- exactly the budget, with the resume frame
      // being the one whose leg ByteTrack no longer
      // supplies. SHORTFALL: one frame. Forcing it would
      // require advancing the guard on frozen frames or
      // publishing at run 2 -- both are NH-M1-11 /
      // persistence-guard semantics the lead has frozen.
      // => This cell is asserted as NO SPEECH with the
      // vibration intact (the user still gets the urgent
      // vibration at frame 2, true TTC 0.6 s), pending the
      // lead's ruling on whether the budget or the guard
      // semantics should change for sub-0.9 s approaches.
      final _Cell c = _runCell('bytetrack', true, 0.8);
      expect(c.preAt, 2,
          reason: 'the vibration still fires at frame 2 '
              '(true TTC 0.6 s) -- the cell fails on the '
              'VOICE only');
      expect(c.urgAt, -1,
          reason: 'no urgent speech lands: the frozen '
              'run cannot resume inside the 8-frame '
              'budget on this backend (see the analysis)');
      expect(c.vibTotal, 1,
          reason: 'the pre-urgent step is the episode\'s '
              'only vibration');
    });
  });

  group('0.9 s literal regression (the Codex sequence)', () {
    for (final String backend in kBackends) {
      test('$backend: per-frame legs, disagreement at '
          'frames 4-6, frozen run, voice at frame 7', () {
        final HazardPipeline pipeline =
            HazardPipeline(tracker: trackerForBackend(backend));
        final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
        final List<TrackEstimate?> ests = <TrackEstimate?>[];
        final List<int> runs = <int>[];
        int preAt = -1;
        int urgAt = -1;
        for (int i = 0; i <= 10; i++) {
          final double t = i * 0.1;
          final double z = 6.0 * (0.9 - t) / 0.9;
          final HazardPipelineResult r = pipeline.processFrame(
            (0.9 - t) > 0.05 ? <Detection>[_carAt(z)] : const <Detection>[],
            epoch.add(Duration(milliseconds: i * 100)),
            pitchDeg: 10,
            ego: EgoMotion.judge(gpsSpeedMps: 1.2),
          );
          final TrackEstimate? e =
              r.estimates.isEmpty ? null : r.estimates.first;
          ests.add(e);
          runs.add(e == null
              ? -1
              : pipeline.debugExemptionState(e.track.id).tauRun);
          if (r.preUrgentTrackIds.isNotEmpty && preAt < 0) preAt = i;
          if (r.alert != null && r.alert!.urgent && urgAt < 0) urgAt = i;
        }
        // The disagreement occupies EXACTLY frames 4-6 on
        // the agile tier (Codex's frame positions); the
        // exemption flag marks the same frames.
        for (int i = 0; i <= 10; i++) {
          final TrackEstimate? e = ests[i];
          if (e == null) continue;
          final bool disagree = e.debugAgileScaleTtcS != null &&
              e.debugAgileRangeTtcS != null &&
              TtcEstimator.legsDisagree(
                  e.debugAgileScaleTtcS!, e.debugAgileRangeTtcS!);
          expect(disagree, i >= 4 && i <= 6,
              reason: 'frame $i: agile disagreement exists '
                  'exactly on frames 4-6');
          expect(e.urgentDisagreementExempted, i >= 4 && i <= 6,
              reason: 'frame $i: the exemption covers '
                  'exactly the disagreement frames');
        }
        // Literal leg readings at the disagreement's
        // heart (frame 4, both backends measured; Codex's
        // frame-4 report -- scale ~= 1.125 / range ~=
        // 0.510 -- matches this repo's NORMAL tier at the
        // same frame to its rounding: 1.125/0.510
        // bytetrack, 1.116/0.501 sort; the AGILE pair,
        // which is the tier the exemption fuses, reads
        // lower because the agile filter predicts one step
        // ahead).
        final TrackEstimate f4 = ests[4]!;
        if (backend == 'bytetrack') {
          expect(f4.ttcScaleS, closeTo(1.125, 0.01),
              reason: 'Codex frame-4 scale leg, literal');
          expect(f4.ttcRangeS, closeTo(0.510, 0.01),
              reason: 'Codex frame-4 range leg, literal');
          expect(f4.debugAgileScaleTtcS, closeTo(0.875, 0.01));
          expect(f4.debugAgileRangeTtcS, closeTo(0.428, 0.01));
        } else {
          expect(f4.ttcScaleS, closeTo(1.116, 0.01));
          expect(f4.ttcRangeS, closeTo(0.501, 0.01));
          expect(f4.debugAgileScaleTtcS, closeTo(0.847, 0.01));
          expect(f4.debugAgileRangeTtcS, closeTo(0.404, 0.01));
        }
        // The guard run: 1, 2, then FROZEN at 2 across the
        // whole disagreement, resuming to 3 at frame 7.
        expect(runs[2], 1);
        expect(runs[3], 2);
        expect(runs[4], 2, reason: 'frozen, not reset');
        expect(runs[5], 2, reason: 'frozen, not reset');
        expect(runs[6], 2, reason: 'frozen, not reset');
        expect(runs[7], 3, reason: 'resumed from the frozen value');
        // Conservatively fused raw tau on the frozen
        // frames = smaller agile leg - L_pipe (0.2).
        for (final int i in <int>[4, 5, 6]) {
          final TrackEstimate e = ests[i]!;
          final double smaller = math.min(
              e.debugAgileScaleTtcS!, e.debugAgileRangeTtcS!);
          expect(e.ttcUrgentRawS, closeTo(smaller - 0.2, 0.01),
              reason: 'frame $i: raw tau is the smaller '
                  'leg minus the pipeline latency, exactly');
          expect(e.ttcUrgentS, isNull,
              reason: 'frame $i: nothing publishes from a '
                  'frozen frame');
        }
        expect(preAt, 2);
        expect(urgAt, 7);
        expect(0.9 - 0.1 * urgAt, closeTo(0.2, 1e-9),
            reason: 'speech at true TTC 0.2 s, inside the '
                'physical window');
      });
    }
  });
}
