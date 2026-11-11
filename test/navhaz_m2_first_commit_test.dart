/// M2 first commit: the three M1 residuals.
///
///  1. NH-M1-13 RESIDUAL (Codex replay on 5280e00): the
///     unknown-ego T = 0.9 s dive dispatched its vibration
///     on frames [2, 3] -- the frame-2 urgent consumed the
///     pre-urgent one-shot, frame 3's still-eligible
///     estimate re-fired it, and the re-firing WAS a
///     second physical dispatch. The step-1 account is
///     now approach-scoped: a re-armed re-firing inside
///     the same approach never dispatches again.
///  2. NH-M1-17: an urgent whose remaining TTC at
///     issuance is shorter than its normal phrase's
///     estimated spoken duration speaks the kind's short
///     form instead, at the SAME issuance frame.
///     NH-M1-19 (M2-FIX1) NARROWS that rule: the short
///     form now needs BOTH tauNow < preVibrationTtcS
///     (inside the vibrate-first zone) AND tauNow <
///     chars x 0.25 s (shortPhraseSecondsPerChar), and
///     the short forms themselves carry a bearing (see
///     navhaz_fix1_test for the gate's three named tests;
///     this file keeps the dives and the boundary in the
///     NH-M1-19 form).
/// (NH-M1-18 is a README line; NH-M1-16's vibration
/// assertion for the impossible cell lives in
/// navhaz_grid16_test and is untouched.)
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/avoidance_advisor.dart';
import 'package:mingtu_ai/core/hazard/ego_motion.dart';
import 'package:mingtu_ai/core/hazard/hazard_phrases.dart';
import 'package:mingtu_ai/core/hazard/hazard_pipeline.dart';
import 'package:mingtu_ai/core/hazard/hazard_policy.dart';
import 'package:mingtu_ai/core/hazard/ttc_estimator.dart';
import 'package:mingtu_ai/core/navhaz_config.dart';
import 'package:mingtu_ai/core/tracking/tracker.dart';
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

/// One dive replay, collected in a single pass.
class _Replay {
  final List<int> vibFrames;
  final List<int> preFrames;
  final int vibTotal;
  final int urgAt;
  final String urgPhrase;
  const _Replay(
      this.vibFrames, this.preFrames, this.vibTotal, this.urgAt, this.urgPhrase);
}

_Replay _runDive(String backend, bool knownEgo, double bigT) {
  final HazardPipeline pipeline =
      HazardPipeline(tracker: trackerForBackend(backend));
  final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
  final List<int> vibFrames = <int>[];
  final List<int> preFrames = <int>[];
  int vibTotal = 0;
  int urgAt = -1;
  String urgPhrase = '';
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
    if (r.vibrations.isNotEmpty) vibFrames.add(i);
    vibTotal += r.vibrations.length;
    if (r.preUrgentTrackIds.isNotEmpty) preFrames.add(i);
    if (r.alert != null && r.alert!.urgent && urgAt < 0) {
      urgAt = i;
      urgPhrase = r.alert!.phrase;
    }
  }
  return _Replay(vibFrames, preFrames, vibTotal, urgAt, urgPhrase);
}

void main() {
  group('NH-M1-13 residual: one vibration dispatch run per approach', () {
    for (final String backend in kBackends) {
      test('$backend x unknown ego x T=0.9: the Codex '
          'replay -- dispatch frames are [2], not [2, 3]', () {
        final _Replay r = _runDive(backend, false, 0.9);
        expect(r.preFrames, <int>[2],
            reason: 'the pre-urgent dispatch happens on '
                'frame 2 only: frame 3\'s re-armed one-shot '
                're-firing is gated by the approach account');
        expect(r.vibFrames, <int>[2],
            reason: 'every vibration dispatch of the '
                'approach sits on frame 2 (the pre-urgent '
                'step and the same-frame episode-opening '
                'urgent are that frame\'s single dispatch)');
        expect(r.urgAt, 2,
            reason: 'the urgent speech frame is unchanged');
        expect(r.vibTotal, 1,
            reason: 'ONE merged physical dispatch in '
                'total: the same-frame pre-urgent + alert '
                'pair is one event (the FIX5 same-frame '
                'rule); the pre-fix total of 2 counted the '
                'frame-3 bug dispatch as its second entry');
      });
    }

    for (final String backend in kBackends) {
      for (final bool known in <bool>[true, false]) {
        for (final double bigT in <double>[0.8, 0.9, 1.0, 1.2]) {
          test('$backend x ${known ? 'known' : 'unknown'} ego '
              'x T=$bigT: no step re-dispatches on a later '
              'frame of the approach', () {
            final _Replay r = _runDive(backend, known, bigT);
            expect(r.preFrames.length, lessThanOrEqualTo(1),
                reason: 'the pre-urgent step dispatches at '
                    'most once per approach: ${r.preFrames}');
            // No two dispatches on ADJACENT frames: the
            // [2, 3] signature of the residual bug (a
            // re-arm re-firing the frame right after the
            // consuming urgent) must not appear anywhere
            // in the grid. Well-separated dispatches are
            // the ladder's distinct steps (a warning step
            // frames before an upgrade step).
            for (int k = 1; k < r.vibFrames.length; k++) {
              expect(r.vibFrames[k] - r.vibFrames[k - 1],
                  greaterThan(1),
                  reason: 'dispatch frames ${r.vibFrames}: '
                      'adjacent-frame re-dispatch is the '
                      'residual bug\'s signature');
            }
          });
        }
      }
    }
  });

  group('NH-M1-17 as narrowed by NH-M1-19: the short '
      'urgent form', () {
    for (final String backend in kBackends) {
      test('$backend x known ego x T=0.9: the frame-7 '
          'urgent speaks the SHORT form, same frame', () {
        final _Replay r = _runDive(backend, true, 0.9);
        expect(r.urgAt, 7,
            reason: 'issuance timing is unchanged -- the '
                'short form rescues the utterance\'s '
                'completion, not its start');
        expect(r.urgPhrase,
            shortUrgentPhrase(HazardKind.motorVehicle, '汽车', 0.5),
            reason: 'the NH-M1-19 gate at issuance: the '
                'published tau (~0.32-0.35 s) is inside '
                'the vibrate-first zone (< 1.5 s, '
                'condition 1) and below the normal '
                'phrase\'s fastest-reading time '
                '(condition 2), so the bearing short form '
                'is chosen');
      });
    }

    test('direct boundary (NH-M1-19 gate): condition 1 '
        'at exactly 1.5 s keeps the normal phrase even '
        'when condition 2 holds; both conditions true '
        'takes the short form', () {
      // Hand-built estimates through the policy: a car
      // track graded urgent via the approaching-vehicle
      // branch (tau <= 3.0 s). This geometry's normal
      // phrase is '停，前方很近有汽车' (8 voiced
      // characters -- the near template inserts the
      // very-close readout '很近' at range 1.2 m), so
      // condition 2's threshold is 8 x 0.25 = 2.0 s.
      // NH-M1-17's boundary cases (tau 2.3 / 2.4 / 2.5
      // against the old 0.30 s/char estimate) all sit
      // ABOVE condition 1's 1.5 s line under NH-M1-19 and
      // therefore keep the normal phrase now; the cases
      // below pin the narrowed gate itself:
      //   tau 1.5 exactly: condition 1 FALSE (strict) ->
      //     normal, even though 1.5 < 2.0 (condition 2
      //     true);
      //   tau 1.4: both true (1.4 < 1.5 and 1.4 < 2.0) ->
      //     the bearing short form.
      // (Condition 1 true + condition 2 false keeping the
      // normal phrase is pinned in navhaz_fix1_test with
      // the 14-character spec-2.7 sentence.)
      String? phraseAt(double tau) {
        final HazardPolicy policy = HazardPolicy();
        final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
        final Tracker tracker = trackerForBackend('sort');
        Track? track;
        for (int i = 0; i < 3; i++) {
          track = tracker.update(
            <Detection>[
              const Detection(
                  label: 'car',
                  confidence: 0.9,
                  cx: 0.5,
                  cy: 0.75,
                  w: 0.4,
                  h: 0.4),
            ],
            epoch.add(Duration(milliseconds: i * 100)),
          ).first;
        }
        final TrackEstimate e = TrackEstimate(
          track: track!,
          ttcS: tau,
          ttcScaleS: null,
          ttcRangeS: tau,
          rangeM: 1.2,
          closingSpeedMps: 3,
          approaching: true,
          willHit: true,
          cxVelocity: 0,
          ttcUrgentS: tau,
          ttcUrgentRawS: tau,
        );
        final HazardPolicyResult r =
            policy.evaluate(<TrackEstimate>[e], epoch);
        return r.alert?.phrase;
      }

      final String normal = hazardPhrase(
          urgent: true, name: '汽车', isVehicle: true, cx: 0.5, rangeM: 1.2);
      expect(normal, '停，前方很近有汽车');
      expect(voicedCharCount(normal), 8,
          reason: 'the gate arithmetic: 8 voiced '
              'characters x 0.25 s = 2.0 s for condition 2');
      expect(phraseAt(2.5), normal,
          reason: 'tau 2.5 s: outside the vibrate-first '
              'zone -- NH-M1-19 keeps the full sentence '
              '(this tau took the short form under the '
              'NH-M1-17 rule)');
      expect(phraseAt(1.5), normal,
          reason: 'tau exactly AT condition 1\'s 1.5 s '
              'line is not "inside" the zone (strict): '
              'the normal phrase is kept even though '
              'condition 2 (1.5 < 2.0) holds');
      expect(phraseAt(1.4),
          shortUrgentPhrase(HazardKind.motorVehicle, '汽车', 0.5),
          reason: 'tau 1.4 s: BOTH conditions hold '
              '(1.4 < 1.5 and 1.4 < 8 x 0.25 = 2.0), so '
              'the bearing short form is issued');
    });

    test('warnings never take the short form, even with '
        'a short remaining TTC', () {
      // A warning-graded estimate (TTC band 3-5 s) whose
      // phrase estimate exceeds its TTC is impossible by
      // band arithmetic, so pin the rule at its edge: a
      // warning with the smallest band TTC still speaks
      // its full templated phrase.
      final HazardPolicy policy = HazardPolicy();
      final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
      final Tracker tracker = trackerForBackend('sort');
      Track? track;
      for (int i = 0; i < 3; i++) {
        track = tracker.update(
          <Detection>[
            const Detection(
                label: 'car',
                confidence: 0.9,
                cx: 0.5,
                cy: 0.75,
                w: 0.4,
                h: 0.4),
          ],
          epoch.add(Duration(milliseconds: i * 100)),
        ).first;
      }
      final TrackEstimate e = TrackEstimate(
        track: track!,
        ttcS: 3.1,
        ttcScaleS: null,
        ttcRangeS: 3.1,
        rangeM: 8,
        closingSpeedMps: 3,
        approaching: true,
        willHit: true,
        cxVelocity: 0,
        ttcUrgentS: 3.1,
        ttcUrgentRawS: 3.1,
      );
      final HazardPolicyResult r =
          policy.evaluate(<TrackEstimate>[e], epoch);
      expect(r.alert, isNotNull);
      expect(r.alert!.level, HazardLevel.warning);
      expect(r.alert!.phrase,
          hazardPhrase(
              urgent: false, name: '汽车', isVehicle: true, cx: 0.5, rangeM: 8),
          reason: 'the warning speaks its normal templated '
              'phrase verbatim');
    });

    test('every short form passes the banned-word scan, '
        'fits its category voiced-character cap (config '
        'constants) and is inside the enumerated phrase '
        'space (NH-M1-19 forms)', () {
      final Set<String> enumerated = enumerateAllHazardPhrases().toSet();
      final Set<String> forms = shortUrgentPhrases().toSet();
      expect(forms.length, 18,
          reason: 'NH-M1-19: 10 (kind, name) entries x '
              'three bearings, with the five vehicle-label '
              'entries sharing their three forms: 18 '
              'distinct texts');
      for (final String s in forms) {
        expect(containsBannedWord(s), isFalse, reason: s);
        expect(assertNoBannedWords(s), isTrue, reason: s);
        expect(enumerated.contains(s), isTrue,
            reason: 'the short form "$s" is part of the '
                'enumerable output space');
        expect(s.contains('迈步'), isFalse,
            reason: 'a short form never carries a step '
                'direction');
      }
      // NH-M1-19's voiced-character caps, asserted over
      // the WHOLE table by category (M2-B item 4: the
      // caps are NavHazConfig constants --
      // shortPhraseMaxCharsInVocabulary /
      // shortPhraseMaxCharsFallback -- and this test
      // reads them; the numbers live in exactly one
      // place). This replaces the previous shape, which
      // skipped ('exempted') any form containing the
      // kind-name substring: forms are now classified by
      // their (kind, name) key -- a name the detector
      // vocabulary produces is in-vocabulary; the two
      // kind-name entries （机动车 / 非机动车, reached
      // only by labels outside the vocabulary) are the
      // fallback class. The fallback entries keep their
      // full kind name because compressing it would
      // misreport the category.
      final Set<String> inVocabularyNames = <String>{
        for (final String label in <String>[
          'car', 'truck', 'bus', 'motorcycle', 'bicycle',
          'person', 'pole', 'mystery-box',
        ])
          hazardSpokenName(
              label, hazardKindForLabel(label) ?? HazardKind.clutter),
      };
      int tableEntries = 0;
      final List<int> fallbackCounts = <int>[];
      int inVocabularyMax = 0;
      for (final MapEntry<(HazardKind, String), String> entry
          in shortUrgentPhraseByKindAndName.entries) {
        final bool fallback =
            !inVocabularyNames.contains(entry.key.$2);
        for (final String form in entry.value.split('|')) {
          tableEntries++;
          final int chars = voicedCharCount(form);
          if (fallback) {
            fallbackCounts.add(chars);
            expect(chars,
                lessThanOrEqualTo(
                    NavHazConfig.shortPhraseMaxCharsFallback),
                reason: 'NH-M1-19 fallback cap (config '
                    'constant): "$form"');
          } else {
            if (chars > inVocabularyMax) inVocabularyMax = chars;
            expect(chars,
                lessThanOrEqualTo(
                    NavHazConfig.shortPhraseMaxCharsInVocabulary),
                reason: 'NH-M1-19 in-vocabulary cap (config '
                    'constant): "$form"');
          }
        }
      }
      expect(tableEntries, 30,
          reason: 'the whole table: 10 (kind, name) '
              'entries x three bearings');
      expect(inVocabularyMax,
          NavHazConfig.shortPhraseMaxCharsInVocabulary,
          reason: 'the in-vocabulary cap is genuinely '
              'reached (the clutter centre form), not '
              'headroom');
      // The fallback cap is genuinely exercised, not a
      // vacuous allowance: the motor centre form
      // measures 7 and the non-motor centre form
      // measures exactly the fallback cap.
      expect(fallbackCounts, contains(7),
          reason: 'the motor-vehicle kind-name centre '
              'form （停，前方有机动车） measures 7');
      expect(
          fallbackCounts,
          contains(NavHazConfig.shortPhraseMaxCharsFallback),
          reason: 'the non-motor kind-name centre form '
              '（停，前方有非机动车） measures exactly the '
              'fallback cap');
      expect(
          voicedCharCount(
              shortUrgentPhrase(HazardKind.motorVehicle, '机动车', 0.1)),
          6,
          reason: 'the motor fallback at a side bearing '
              'measures 6 (inside even the in-vocabulary '
              'cap)');
      // The bearing is selected by the same zone rule as
      // the normal templates (one probe per zone edge).
      expect(shortUrgentPhrase(HazardKind.motorVehicle, '汽车', 0.5),
          '停，前方来车');
      expect(shortUrgentPhrase(HazardKind.motorVehicle, '汽车', 0.1),
          '停，左来车');
      expect(shortUrgentPhrase(HazardKind.motorVehicle, '汽车', 0.9),
          '停，右来车');
    });

    test('estimated spoken duration: punctuation is not '
        'voiced, characters are', () {
      expect(estimatedSpeechSeconds('停，前方来车'),
          closeTo(5 * NavHazConfig.ttsSecondsPerCharUpperBound, 1e-9),
          reason: 'the duration estimate keeps the 0.30 '
              's/char planning bound (NH-M1-19 moved only '
              'the short-form GATE to its own 0.25 '
              'coefficient)');
      expect(
          voicedCharCount('停，十二点钟方向约五米，汽车靠近'), 14,
          reason: 'the spec-2.7 first-urgent sentence: '
              '14 voiced characters (16 runes minus its '
              'two commas), matching Codex\'s count of the '
              'sentence; gate arithmetic in '
              'navhaz_fix1_test (14 x 0.25 = 3.5 > tauNow '
              '2.70-2.73, but condition 1 keeps the full '
              'sentence)');
    });
  });
}
