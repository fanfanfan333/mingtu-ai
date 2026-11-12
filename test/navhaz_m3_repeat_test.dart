/// NH-M2-07 (M3 first commit, lead's FINAL ruling
/// 2026-11-11): the cooldown's TTC-drop re-alert
/// exception gains a minimum interval. M1's rule stands
/// unchanged -- inside the cooldown, a TTC fallen to at
/// most (1 - ttcDropReAlertRatio) x the last spoken
/// value re-alerts -- but the re-alert now additionally
/// requires at least [NavHazConfig.realertDropMinInterval]
/// (1.0 s) since that track's last spoken alert: at the
/// originating cell's 0.5 s gap the first sentence has
/// not finished playing, and a repeat would only talk
/// over it. The W -> U upgrade exception is NOT subject
/// to the interval, and a same-level re-alert after the
/// cooldown window has elapsed is plain M1 behaviour.
///
/// (The earlier M3 draft of this round -- a per-track
/// urgent-repeat budget with its own TTC bound -- was
/// WITHDRAWN by the same ruling; nothing of it
/// remains.)
///
/// The matrix here is policy-level (fabricated
/// estimates, the navhaz_policy_test pattern) for the
/// interval arithmetic, plus a pipeline-level
/// regression of the originating cell (the fix1 scale
/// dive) for the issuance set and the unchanged
/// vibration timeline.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/hazard/ego_motion.dart';
import 'package:mingtu_ai/core/hazard/hazard_pipeline.dart';
import 'package:mingtu_ai/core/hazard/hazard_policy.dart';
import 'package:mingtu_ai/core/hazard/ttc_estimator.dart';
import 'package:mingtu_ai/core/navhaz_config.dart';
import 'package:mingtu_ai/core/tracking/tracker.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';

import 'navhaz_fixture_harness.dart';

/// A confirmed track with [frames] samples at [cx]
/// (the navhaz_policy_test fabrication pattern).
Track _confirmedTrack(int id, String label,
    {double cx = 0.5, int frames = 5}) {
  final Track t = Track(id: id, label: label);
  final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
  for (int i = 0; i < frames; i++) {
    t.recordMatch(
      Detection(
          label: label, confidence: 0.9, cx: cx, cy: 0.55, w: 0.2, h: 0.4),
      epoch.add(Duration(milliseconds: i * 100)),
    );
  }
  return t;
}

/// One named TTC for every tier (these tests judge the
/// policy's cooldown arithmetic, not the estimator's
/// tiers, which the pipeline tests cover). Range null:
/// the no-range composition. egoSpeedKnown keeps its
/// hand-built default (true), so the cooldown window in
/// play is the 4 s known-ego one.
TrackEstimate _estimate(Track track, {double? ttc}) {
  return TrackEstimate(
    track: track,
    ttcS: ttc,
    ttcScaleS: ttc,
    ttcRangeS: ttc,
    ttcUrgentS: ttc,
    rangeM: null,
    closingSpeedMps: null,
    approaching: false,
    willHit: true,
    cxVelocity: 0,
  );
}

final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);
DateTime _at(int ms) => _epoch.add(Duration(milliseconds: ms));

void main() {
  group('NH-M2-07 drop re-alert minimum interval '
      '(policy matrix)', () {
    test('(a) drop holds but interval < 1.0 s: blocked; '
        'the blocked attempt leaves the baseline '
        'untouched, so a later frame still re-alerts',
        () {
      final Track track = _confirmedTrack(1, 'car');
      final HazardPolicy p = HazardPolicy();
      // The (c) cell's first issuance, transplanted:
      // urgent at t = 200 ms with tauNow 1.29.
      HazardPolicyResult r =
          p.evaluate(<TrackEstimate>[_estimate(track, ttc: 1.29)], _at(200));
      expect(r.alert, isNotNull);
      expect(r.alert!.urgent, isTrue);
      expect(r.alert!.phrase, '停，前方来车');
      // The frame-7 shape: tauNow 0.64 satisfies the
      // drop exception (0.64 <= 1.29 x 0.6 = 0.774) but
      // comes only 0.5 s after the first urgent --
      // inside the 1.0 s minimum interval, the repeat
      // would talk over the still-playing sentence.
      r = p.evaluate(<TrackEstimate>[_estimate(track, ttc: 0.64)], _at(700));
      expect(r.alert, isNull,
          reason: 'drop holds but 0.5 s < '
              'realertDropMinInterval 1.0 s: suppressed');
      expect(r.riskPresent, isTrue,
          reason: 'the frame still reports risk -- only '
              'the re-alert is held back');
      // The blocked attempt recorded nothing: at
      // t = 1300 ms the drop is still measured against
      // the SPOKEN 1.29 (0.70 <= 0.774) -- against the
      // blocked attempt's 0.64 it would fail
      // (0.70 > 0.64 x 0.6) -- and the interval since
      // the spoken alert is 1.1 s, so the re-alert
      // fires now.
      r = p.evaluate(<TrackEstimate>[_estimate(track, ttc: 0.70)], _at(1300));
      expect(r.alert, isNotNull,
          reason: 'the interval runs from the last '
              'SPOKEN alert and the drop baseline is '
              'still that alert\'s TTC: the held-back '
              're-alert lands at the first frame past '
              '1.0 s whose drop still holds');
      expect(r.alert!.urgent, isTrue);
      expect(r.alert!.phrase, '停，前方来车');
    });

    test('(b) drop holds at interval >= 1.0 s: '
        're-alerts (the spec 2.7.6 shape)', () {
      final Track track = _confirmedTrack(1, 'car');
      final HazardPolicy p = HazardPolicy();
      HazardPolicyResult r =
          p.evaluate(<TrackEstimate>[_estimate(track, ttc: 2.9)], _at(0));
      expect(r.alert, isNotNull);
      expect(r.alert!.urgent, isTrue);
      expect(r.alert!.phrase, '停，十二点钟方向，汽车靠近',
          reason: 'tauNow 2.9: the full no-range form '
              '(the short-form gate does not apply)');
      // A 24% drop is not a drop exception at any
      // interval.
      r = p.evaluate(<TrackEstimate>[_estimate(track, ttc: 2.2)], _at(700));
      expect(r.alert, isNull,
          reason: '2.2 > 2.9 x 0.6: no drop, no '
              're-alert (unchanged M1 arithmetic)');
      // A 41% drop at 1.2 s: the exception fires, as
      // spec 2.7.6 pins it -- once, in the same
      // composition as the first issuance.
      r = p.evaluate(<TrackEstimate>[_estimate(track, ttc: 1.7)], _at(1200));
      expect(r.alert, isNotNull,
          reason: '1.7 <= 2.9 x 0.6 and 1.2 s >= 1.0 s: '
              'the drop re-alert speaks');
      expect(r.alert!.urgent, isTrue);
      expect(r.alert!.phrase, '停，十二点钟方向，汽车靠近',
          reason: 'same composition basis as the first '
              'issuance (tauNow 1.7 is also a full-form '
              'value)');
      // And not twice in a row: a same-level nudge
      // right after is back under the plain cooldown.
      r = p.evaluate(<TrackEstimate>[_estimate(track, ttc: 1.65)], _at(1700));
      expect(r.alert, isNull,
          reason: 'no fresh drop against the new '
              'baseline 1.7, and inside the window');
    });

    test('(c) W -> U upgrade at interval < 1.0 s is '
        'NOT gated by the minimum interval', () {
      final Track track = _confirmedTrack(1, 'car');
      final HazardPolicy p = HazardPolicy();
      HazardPolicyResult r =
          p.evaluate(<TrackEstimate>[_estimate(track, ttc: 4.0)], _at(0));
      expect(r.alert, isNotNull);
      expect(r.alert!.urgent, isFalse);
      expect(r.alert!.phrase, '注意，十二点钟方向，汽车靠近');
      // 0.5 s later the same track grades urgent: the
      // upgrade exception speaks at once (arbitration
      // interrupts the warning), exactly as in M1 --
      // the 1.0 s interval applies to the drop path
      // only.
      r = p.evaluate(<TrackEstimate>[_estimate(track, ttc: 2.9)], _at(500));
      expect(r.alert, isNotNull,
          reason: 'upgrade W -> U is never held back, '
              'also not by realertDropMinInterval');
      expect(r.alert!.urgent, isTrue);
    });

    test('(d) after the cooldown window the same level '
        're-alerts unchanged (no drop needed)', () {
      final Track track = _confirmedTrack(1, 'car');
      final HazardPolicy p = HazardPolicy();
      HazardPolicyResult r =
          p.evaluate(<TrackEstimate>[_estimate(track, ttc: 2.9)], _at(0));
      expect(r.alert, isNotNull);
      expect(r.alert!.urgent, isTrue);
      // Inside the 4 s window with no drop: silent.
      r = p.evaluate(<TrackEstimate>[_estimate(track, ttc: 2.85)], _at(3900));
      expect(r.alert, isNull,
          reason: '3.9 s < 4 s window and 2.85 is no '
              'drop against 2.9');
      // Past the window the same level speaks again on
      // the plain M1 rule -- the interval gate lives
      // only inside the drop exception and is not
      // consulted here (2.8 is no drop either).
      r = p.evaluate(<TrackEstimate>[_estimate(track, ttc: 2.8)], _at(4100));
      expect(r.alert, isNotNull,
          reason: 'window elapsed: same-level re-alert '
              'as in M1');
      expect(r.alert!.urgent, isTrue);
    });

    test('(e) tracks are independent: A\'s short '
        'interval does not gate B\'s drop re-alert', () {
      final Track a = _confirmedTrack(1, 'car');
      final Track b = _confirmedTrack(2, 'car');
      final HazardPolicy p = HazardPolicy();
      HazardPolicyResult r;
      r = p.evaluate(<TrackEstimate>[_estimate(a, ttc: 1.29)], _at(200));
      expect(r.alert, isNotNull, reason: 'A first urgent');
      expect(r.alert!.trackId, a.id);
      // A's frame-7 shape: blocked by A's own interval.
      r = p.evaluate(<TrackEstimate>[_estimate(a, ttc: 0.64)], _at(700));
      expect(r.alert, isNull,
          reason: 'A: 0.5 s < 1.0 s since A\'s alert');
      // B's own first urgent is nobody's re-alert.
      r = p.evaluate(<TrackEstimate>[_estimate(b, ttc: 1.29)], _at(900));
      expect(r.alert, isNotNull, reason: 'B first urgent');
      expect(r.alert!.trackId, b.id);
      // A's held-back re-alert lands once A's OWN
      // interval (from t = 200) reaches 1.0 s.
      r = p.evaluate(<TrackEstimate>[_estimate(a, ttc: 0.64)], _at(1500));
      expect(r.alert, isNotNull,
          reason: 'A: 1.3 s since A\'s spoken alert, '
              'drop still holds');
      expect(r.alert!.trackId, a.id);
      // B's drop re-alert runs on B's own clock (from
      // t = 900), unaffected by A's issuances between.
      r = p.evaluate(<TrackEstimate>[_estimate(b, ttc: 0.64)], _at(2100));
      expect(r.alert, isNotNull,
          reason: 'B: 1.2 s since B\'s spoken alert, '
              'drop holds on B\'s own baseline');
      expect(r.alert!.trackId, b.id);
    });

    test('(f) the constant is the ruled value', () {
      expect(NavHazConfig.realertDropMinInterval,
          const Duration(seconds: 1));
    });
  });

  group('NH-M2-07 pipeline regression: the originating '
      'unknown-ego x T = 1.2 scale dive', () {
    for (final String backend in kBackends) {
      test('$backend: the run\'s urgent set is frame 2 '
          'only, and the vibration timeline is the '
          'pre-rule one', () {
        final HazardPipeline pipeline =
            HazardPipeline(tracker: trackerForBackend(backend));
        final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
        final List<int> urgentFrames = <int>[];
        final List<String> urgentPhrases = <String>[];
        final List<int> vibFrames = <int>[];
        final List<int> preFrames = <int>[];
        int vibTotal = 0;
        for (int i = 0; i <= 14; i++) {
          final double t = i * 0.1;
          final HazardPipelineResult r = pipeline.processFrame(
            (1.2 - t) > 0.05
                ? <Detection>[_scaleDive(1.2, t)]
                : const <Detection>[],
            epoch.add(Duration(milliseconds: i * 100)),
            pitchDeg: null,
            ego: EgoMotion.unknown,
          );
          if (r.alert != null && r.alert!.urgent) {
            urgentFrames.add(i);
            urgentPhrases.add(r.alert!.phrase);
          }
          if (r.vibrations.isNotEmpty) vibFrames.add(i);
          vibTotal += r.vibrations.length;
          if (r.preUrgentTrackIds.isNotEmpty) preFrames.add(i);
        }
        // The issuance set under the ruling: frame 7's
        // re-alert satisfies the TTC-drop exception
        // (tauNow ~= 0.64 <= 1.29 x 0.6) but comes
        // 0.5 s after frame 2 -- inside the 1.0 s
        // minimum interval, so it is held back. The
        // dive feeds detections only through frame 11
        // (t = 1.1 s, a 0.9 s gap), so no fed frame
        // ever reaches the interval with the drop
        // still measurable: measured on both backends,
        // there is NO later top-up issuance in this
        // run and frame 2 stands alone.
        expect(urgentFrames, <int>[2],
            reason: 'NH-M2-07 holds back the frame-7 '
                'drop re-alert of this cell (0.5 s < '
                '1.0 s minimum interval)');
        expect(urgentPhrases, <String>['停，前方来车'],
            reason: 'the surviving urgent is the '
                'gate\'s short form, verbatim');
        // Vibration is untouched by the ruling: the
        // pre-urgent step dispatches on frame 2 (the
        // held-back frame-7 alert carried no vibration
        // of its own -- an episode re-alert never
        // does), so the dispatch timeline equals the
        // pre-rule one exactly.
        expect(preFrames, <int>[2],
            reason: 'the pre-urgent dispatch frame is '
                'unchanged');
        expect(vibFrames, <int>[2],
            reason: 'every vibration dispatch of the '
                'approach sits on frame 2, as before '
                'the rule');
        expect(vibTotal, 1,
            reason: 'one merged physical dispatch in '
                'total, as before the rule');
      });
    }
  });
}

/// The fix1 scale-dive geometry (unknown ego: box
/// scale growth alone, s = 0.30 * T / (T - t)).
Detection _scaleDive(double bigT, double t) {
  final double s = 0.30 * bigT / (bigT - t);
  return Detection(
      label: 'car', confidence: 0.9, cx: 0.5, cy: 0.55, w: s, h: s);
}
