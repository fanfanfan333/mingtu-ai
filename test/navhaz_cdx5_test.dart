/// CDX5 round: non-finite distance wording (S2-1 /
/// NH-M1-12) and per-approach vibration counting (S2-2 /
/// NH-M1-13).
///
/// S2-1: navigationDistanceText and metresText must treat
/// a non-finite (NaN / +/-Infinity) or negative input as
/// "no distance to report" -- the empty readout -- never
/// a number, never a throw; every call site must still
/// produce a complete sentence on that input.
///
/// S2-2 / NH-M1-13: vibrations are counted per APPROACH
/// (per alert episode) on the ladder documented at
/// HazardAlertSteps -- the pre-urgent one-shot (1),
/// the episode's first warning (1), the W -> U upgrade
/// (1 more); a direct pre-urgent -> U path vibrates ONCE
/// in total. The counts below are read off
/// HazardPipelineResult.vibrations, the merged dispatch
/// list main.dart dispatches verbatim.
library;
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/core/hazard/ego_motion.dart';
import 'package:mingtu_ai/core/hazard/hazard_phrases.dart';
import 'package:mingtu_ai/core/hazard/hazard_pipeline.dart';
import 'package:mingtu_ai/core/navhaz_config.dart';
import 'package:mingtu_ai/core/navigation_tracker.dart';
import 'package:mingtu_ai/core/real_navigation.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';

import 'navhaz_fixture_harness.dart';

const List<double> kAbnormal = <double>[
  double.nan,
  double.infinity,
  double.negativeInfinity,
  -1,
  -0.5,
];

bool hasDigit(String s) => s.contains(RegExp(r'[0-9]'));

void main() {
  group('S2-1 / NH-M1-12: abnormal distances report nothing', () {
    test('navigationDistanceText: five abnormal inputs -> empty', () {
      for (final double d in kAbnormal) {
        expect(navigationDistanceText(d), '',
            reason: 'd=$d: no distance readout, no number, '
                'no throw (before the fix: NaN fell through '
                'to the beyond-10-km band, -Infinity threw '
                'inside round(), negatives clamped into a '
                'spoken figure)');
        expect(containsBannedWord(navigationDistanceText(d)), isFalse);
      }
      // The empty readout is NOT a member of the analytic
      // enumeration: it is not a distance readout, it is
      // the absence of one (the enumerated domain is the
      // finite, non-negative inputs).
      expect(enumerateNavigationDistanceTexts().contains(''), isFalse);
    });

    test('metresText: abnormal ranges -> the no-distance form', () {
      for (final double z in kAbnormal) {
        expect(metresText(z), '',
            reason: 'z=$z: the obstacle side omits the '
                'distance exactly like the >= 10 m band '
                '(before the fix, -Infinity and negatives '
                'read "very close" -- a distance claim '
                'manufactured from a broken measurement)');
      }
    });

    test('hazard phrases on abnormal Z equal the Z-null shape', () {
      // NOTE on the comparison baseline: hazardPhrase
      // BRANCHES on isNearWording(rangeM), and the branch
      // predicates key on rangeM in ways an abnormal value
      // perturbs differently per value (NaN fails every
      // comparison and lands far; -Infinity satisfies the
      // near predicate and even the urgent rangeM <= 3
      // sub-branch). So no single baseline phrase covers
      // all five inputs; the invariant NH-M1-12 actually
      // pins is narrower and is asserted exactly: the
      // DISTANCE READOUT inside the phrase is the
      // no-distance form -- the phrase contains no digit
      // and no metre readout at all (metresText == '' is
      // asserted separately above), and it is banned-word
      // free. The branch a broken range lands in is an
      // undefined-geometry artefact (see the note at the
      // end of this test); production never feeds one
      // (the estimator's rangeM is finite or null).
      const List<String> metreReadouts = <String>[
        '很近', '一米', '二米', '三米', '四米', '五米', '约五米', '约十米',
      ];
      for (final double z in kAbnormal) {
        for (final bool urgent in <bool>[true, false]) {
          for (final double cx in <double>[0.1, 0.5, 0.9]) {
            final String withBad = hazardPhrase(
                urgent: urgent,
                name: '汽车',
                isVehicle: true,
                cx: cx,
                rangeM: z);
            expect(hasDigit(withBad), isFalse,
                reason: 'z=$z urgent=$urgent cx=$cx: no '
                    'numeric distance in "$withBad"');
            for (final String readout in metreReadouts) {
              expect(withBad.contains(readout), isFalse,
                  reason: 'z=$z: no "$readout" readout in '
                      '"$withBad" -- the distance is omitted');
            }
            expect(withBad.contains('汽车'), isTrue,
                reason: 'the category still speaks');
            expect(containsBannedWord(withBad), isFalse);
          }
        }
      }
      // Far-form spot check: NaN renders the clock form
      // with the no-number readout, exactly like a
      // >= 10 m range does.
      expect(
          hazardPhrase(
              urgent: false,
              name: '汽车',
              isVehicle: true,
              cx: 0.5,
              rangeM: double.nan),
          '注意，十二点钟方向，汽车靠近',
          reason: 'the far form on NaN is the no-number '
              'form, intact');
      // Honest boundary, recorded not papered over --
      // UPDATED by M2-B item 2: a null range no longer
      // takes the near branch at all; it takes the
      // dedicated no-range form (the clock template with
      // the distance omitted), which lands on the SAME
      // string a NaN range produces via the far branch
      // (asserted just above) -- the two cases converge
      // now instead of diverging. (The NH-M1-12-era note
      // here described null taking the NEAR branch via
      // isNearWording's null-inclusive predicate; that
      // predicate still exists for its other callers, but
      // hazardPhrase consults it only with a non-null
      // range.) A NaN range still fails every comparison
      // and lands far; with an abnormal range the very
      // notion of near/far is undefined, and hazardPhrase
      // is in production only ever called with the
      // estimator's rangeM, which is finite or null (a
      // non-finite raw range never survives the filter).
      // NH-M1-12's contract -- omit the distance -- holds
      // on every branch (asserted above).
    });

    test('call site: amapStepSpeechText stands alone on abnormal input',
        () {
      for (final double d in kAbnormal) {
        final String text = amapStepSpeechText(
            action: '左转', orientation: '东', distanceM: d);
        expect(text, '朝东方向左转',
            reason: 'd=$d: the head alone is a complete '
                'sentence -- no dangling separator, no '
                'distance figure');
        expect(hasDigit(text), isFalse);
        expect(containsBannedWord(text), isFalse);
      }
      // And the normal path is untouched.
      expect(
          amapStepSpeechText(
              action: '左转', orientation: '东', distanceM: 29.5),
          '朝东方向左转，约30米');
    });

    test('call site: realRouteReadyAnnouncement drops the clause', () {
      for (final double d in kAbnormal) {
        final String text = realRouteReadyAnnouncement(
            destinationName: '图书馆', distanceM: d, stepsCount: 3);
        expect(text.startsWith('已获取到图书馆的真实步行路线，共 3 段。'),
            isTrue,
            reason: 'd=$d: the distance clause is dropped '
                'wholesale; the sentence is complete');
        expect(text.contains('距离'), isFalse,
            reason: 'no orphaned distance lead-in');
        expect(containsBannedWord(text), isFalse);
      }
      expect(
          realRouteReadyAnnouncement(
                  destinationName: '图书馆', distanceM: 155, stepsCount: 3)
              .contains('距离约150米'),
          isTrue,
          reason: 'the normal path still carries its clause');
    });

    test('call site: regenerateTurnPrompt -- framework limit, '
        'distance always finite', () {
      // The third call site cannot be fed an abnormal
      // distance: its input is a haversine over two real
      // GeoPoints, which is finite and >= 0 for any valid
      // coordinates (asserted in the sibling arbitration
      // suites). What CAN be pinned here is the end-to-end
      // shape: a normal regeneration carries the distance
      // prefix, and the empty-readout branch of the
      // function is covered by the unit tests above.
      const GeoPoint a =
          GeoPoint(latitude: 37.724409, longitude: 120.441723);
      const GeoPoint b =
          GeoPoint(latitude: 37.726206, longitude: 120.441723);
      const GeoPoint c =
          GeoPoint(latitude: 37.726206, longitude: 120.442859);
      final NavigationTracker tracker = NavigationTracker(
        steps: const <AmapStep>[
          AmapStep(
              action: '直行',
              orientation: '北',
              polyline: <GeoPoint>[a, b],
              distanceM: 200,
              durationS: 150),
          AmapStep(
              action: '右转',
              orientation: '东',
              polyline: <GeoPoint>[b, c],
              distanceM: 100,
              durationS: 75),
        ],
        stepTexts: const <String>['直行', '右转进入林荫道'],
        destination: c,
        destinationName: '图书馆',
      );
      final GeoPoint south12 = GeoPoint(
          latitude: b.latitude! - 12 / 111194.9, longitude: b.longitude);
      final String? prompt = tracker.regenerateTurnPrompt(
          1, NavFix(point: south12, accuracyM: 5, at: DateTime.now()));
      expect(prompt, '前方约12米右转进入林荫道',
          reason: 'the normal regeneration is byte-identical '
              'to before this round');
    });
  });

  group('S2-2 / NH-M1-13: vibration counted per approach', () {
    // Geometry helpers shared with the ego suite: a car
    // dead ahead at range z, scale and ground plane in
    // agreement.
    double bottomForRange(double z) {
      final double fy = 0.5 / math.tan(math.pi / 6);
      final double depression = math.atan(NavHazConfig.cameraHeightM / z);
      return NavHazConfig.principalY +
          fy * math.tan(depression - 10.0 * math.pi / 180);
    }

    Detection carAt(double z) {
      final double s = 0.96 / z;
      final double bottom = bottomForRange(z);
      return Detection(
          label: 'car', confidence: 0.9, cx: 0.5, cy: bottom - s / 2, w: s, h: s);
    }

    test('pure pre-urgent -> U path vibrates EXACTLY ONCE '
        '(known ego, T = 0.9)', () {
      // The CDX5-flagged timeline: pre-urgent fires frame
      // 2, the urgent lands frame 7. Before this round the
      // frame's dispatches were pre-urgent (frame 2) +
      // alert vibration (frame 7) = 2 for ONE physical
      // approach that never warned. The ladder spends the
      // episode's one vibration at the pre-urgent step;
      // the direct-to-U frame adds none.
      final HazardPipeline pipeline = HazardPipeline();
      final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
      int vibTotal = 0;
      final List<int> vibFrames = <int>[];
      int urgAt = -1;
      for (int i = 0; i <= 10; i++) {
        final double t = i * 0.1;
        final double z = 6.0 * (0.9 - t) / 0.9;
        final HazardPipelineResult r = pipeline.processFrame(
          (0.9 - t) > 0.05 ? <Detection>[carAt(z)] : const <Detection>[],
          epoch.add(Duration(milliseconds: i * 100)),
          pitchDeg: 10,
          ego: EgoMotion.judge(gpsSpeedMps: 1.2),
        );
        if (r.vibrations.isNotEmpty) vibFrames.add(i);
        vibTotal += r.vibrations.length;
        if (r.alert != null && r.alert!.urgent && urgAt < 0) urgAt = i;
      }
      expect(urgAt, 7, reason: 'the NH-M1-11 speech frame');
      expect(vibTotal, 1,
          reason: 'one approach, one vibration: the '
              'pre-urgent step spends it');
      expect(vibFrames, <int>[2],
          reason: 'the single vibration is the pre-urgent '
              'one at frame 2; the urgent frame adds none');
    });

    test('W -> U upgrade path vibrates TWICE, second exactly '
        'at the upgrade frame (both backends)', () {
      // Scenario (2) of the ego suite: Z 12 -> 2 m at
      // 2.5 m/s past a still user -- W first (warning
      // vibration, step 2), then the upgrade to U
      // (step 3, one more). No pre-urgent on this
      // geometry (tau crosses 1.5 only with the urgent).
      for (final String backend in kBackends) {
        final HazardPipeline pipeline =
            HazardPipeline(tracker: trackerForBackend(backend));
        final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
        final List<({int frame, bool urgent})> vibs =
            <({int frame, bool urgent})>[];
        int warnAt = -1;
        int urgAt = -1;
        for (int i = 0; i <= 40; i++) {
          final HazardPipelineResult r = pipeline.processFrame(
            <Detection>[carAt(12.0 - 0.25 * i)],
            epoch.add(Duration(milliseconds: i * 100)),
            pitchDeg: 10,
            ego: EgoMotion.still,
          );
          for (final ({int trackId, bool urgent}) v in r.vibrations) {
            vibs.add((frame: i, urgent: v.urgent));
          }
          if (r.alert != null && !r.alert!.urgent && warnAt < 0) {
            warnAt = i;
          }
          if (r.alert != null && r.alert!.urgent && urgAt < 0) {
            urgAt = i;
          }
        }
        expect(warnAt, greaterThanOrEqualTo(0),
            reason: '$backend: the warning speaks');
        expect(urgAt, greaterThan(warnAt),
            reason: '$backend: the urgent upgrades later');
        expect(vibs.length, 2,
            reason: '$backend: warning step + upgrade step, '
                'nothing else in the episode');
        expect(vibs[0].frame, warnAt,
            reason: '$backend: first vibration at the '
                'warning frame, warning pattern');
        expect(vibs[0].urgent, isFalse);
        expect(vibs[1].frame, urgAt,
            reason: '$backend: the second vibration lands '
                'exactly on the upgrade frame');
        expect(vibs[1].urgent, isTrue);
      }
    });

    test('pre-urgent + W + U full path follows the ladder '
        '(both backends)', () {
      // Two-phase construction on the ego-unknown scale
      // path: phase 1 holds the target at a W-band scale
      // TTC (~4 s) until the warning speaks; phase 2 dives
      // hyperbolically from the phase-1 size, so the raw
      // tau crosses the pre-vibration threshold BEFORE the
      // urgent confirmation lands. Expected ladder: W
      // vibration (phase 1) + pre-urgent vibration (phase
      // 2, its own episode clock) + NO third at the urgent
      // frame (the episode already warned; the upgrade
      // step was... see reason) -- total 2 or 3 per the
      // ladder: the upgrade step is a THIRD only if the
      // policy counts it separately from the pre-urgent;
      // the ladder as ruled counts steps {pre, W, upgrade}
      // as distinct steps, so the full path is 3 ONLY when
      // the urgent is a genuine W -> U upgrade alert --
      // which it is here. This test pins whichever the
      // implementation produces AGAINST the ladder text.
      for (final String backend in kBackends) {
        final HazardPipeline pipeline =
            HazardPipeline(tracker: trackerForBackend(backend));
        final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
        Detection car(double s) => Detection(
            label: 'car', confidence: 0.9, cx: 0.5, cy: 0.55, w: s, h: s);
        final List<int> vibFrames = <int>[];
        final List<bool> vibUrgent = <bool>[];
        int warnAt = -1;
        int preAt = -1;
        int urgAt = -1;
        // Phase 1: 12 frames of slow growth, scale TTC
        // ~4 s (s *= 1.025 / frame).
        double s = 0.30;
        for (int i = 0; i < 12; i++) {
          final HazardPipelineResult r = pipeline.processFrame(
            <Detection>[car(s)],
            epoch.add(Duration(milliseconds: i * 100)),
            pitchDeg: null,
            ego: EgoMotion.unknown,
          );
          s *= 1.025;
          for (final ({int trackId, bool urgent}) v in r.vibrations) {
            vibFrames.add(i);
            vibUrgent.add(v.urgent);
          }
          if (r.alert != null && !r.alert!.urgent && warnAt < 0) {
            warnAt = i;
          }
          if (r.preUrgentTrackIds.isNotEmpty && preAt < 0) preAt = i;
          if (r.alert != null && r.alert!.urgent && urgAt < 0) urgAt = i;
        }
        // Phase 2: hyperbolic dive from the current size
        // with T2 = 1.2 s.
        final double s0 = s;
        for (int j = 1; j <= 11; j++) {
          final double t2 = j * 0.1;
          final HazardPipelineResult r = pipeline.processFrame(
            t2 < 1.15
                ? <Detection>[car(s0 * 1.2 / (1.2 - t2))]
                : const <Detection>[],
            epoch.add(Duration(milliseconds: (12 + j) * 100)),
            pitchDeg: null,
            ego: EgoMotion.unknown,
          );
          for (final ({int trackId, bool urgent}) v in r.vibrations) {
            vibFrames.add(12 + j);
            vibUrgent.add(v.urgent);
          }
          if (r.preUrgentTrackIds.isNotEmpty && preAt < 0) preAt = 12 + j;
          if (r.alert != null && r.alert!.urgent && urgAt < 0) {
            urgAt = 12 + j;
          }
        }
        expect(warnAt, greaterThanOrEqualTo(0),
            reason: '$backend: phase 1 warns');
        expect(preAt, greaterThan(warnAt),
            reason: '$backend: the dive pre-vibrates after '
                'the warning');
        expect(urgAt, greaterThan(preAt),
            reason: '$backend: the urgent follows the '
                'pre-urgent');
        // Ladder accounting: {W step, pre step, upgrade
        // step} -- the upgrade IS a distinct step from the
        // pre-urgent (different clocks), so the full path
        // totals 3, the last exactly at the urgent frame.
        expect(vibFrames.length, 3,
            reason: '$backend: W + pre-urgent + W->U '
                'upgrade = 3 ladder steps, no more');
        expect(vibFrames, <int>[warnAt, preAt, urgAt],
            reason: '$backend: each vibration sits on its '
                'own step frame');
        expect(vibUrgent, <bool>[false, true, true],
            reason: '$backend: warning pattern, then two '
                'urgent-pattern steps');
      }
    });

    test('same-frame pre-urgent + U on one track dispatches once', () {
      // Policy-level construction: an estimate set whose
      // alert is urgent on a track the pipeline also finds
      // pre-urgent-eligible the same frame. The merged
      // dispatch must carry exactly one entry for that
      // track. (The ego-unknown fast dives land their
      // urgent the same frame the pre-urgent fires --
      // frame 2 of the FIX4-FINAL cases.)
      final HazardPipeline pipeline = HazardPipeline();
      final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
      Detection dive(double t) {
        final double s = 0.30 * 1.0 / (1.0 - t);
        return Detection(
            label: 'car', confidence: 0.9, cx: 0.5, cy: 0.55, w: s, h: s);
      }

      int frame2Dispatches = -1;
      int frame2UrgentEntries = -1;
      for (int i = 0; i <= 4; i++) {
        final HazardPipelineResult r = pipeline.processFrame(
          <Detection>[dive(i * 0.1)],
          epoch.add(Duration(milliseconds: i * 100)),
          pitchDeg: null,
          ego: EgoMotion.unknown,
        );
        if (i == 2) {
          expect(r.preUrgentTrackIds, isNotEmpty,
              reason: 'the pre-urgent fires this frame');
          expect(r.alert?.urgent, isTrue,
              reason: 'and the urgent lands the same frame');
          frame2Dispatches = r.vibrations.length;
          frame2UrgentEntries =
              r.vibrations.where((v) => v.urgent).length;
        }
      }
      // Measured shape (this construction): at frame 2
      // the scale path grades the alert URGENT, and the
      // pre-urgent one-shot fires the same frame for the
      // same track. Before this round the app dispatched
      // BOTH (the pre-urgent loop + the alert vibration)
      // -- two urgent-pattern dispatches for one physical
      // event. The merged list carries exactly ONE: the
      // pre-urgent entry (the alert's own entry is
      // suppressed as the same-frame duplicate; the
      // policy's step-1 registration independently marks
      // the step spent).
      expect(frame2UrgentEntries, 1,
          reason: 'one urgent-pattern entry for the track '
              'this frame -- the pre-urgent one; the '
              'alert\'s duplicate does not appear');
      expect(frame2Dispatches, 1,
          reason: 'and the whole dispatch list is that '
              'one entry (no warning entry: the only alert '
              'this frame is the urgent)');
    });

    test('anti-over-dedup: two tracks vibrate independently, '
        'and a fresh episode re-arms', () {
      final HazardPipeline pipeline = HazardPipeline();
      final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
      Detection dive(double t, double cx) {
        final double s = 0.30 * 1.0 / (1.0 - t);
        return Detection(
            label: 'car', confidence: 0.9, cx: cx, cy: 0.55, w: s, h: s);
      }

      // Two simultaneous fast targets, laterally separated
      // (separate tracks): each spends its own pre-urgent.
      int twoTrackVibs = 0;
      for (int i = 0; i <= 3; i++) {
        final HazardPipelineResult r = pipeline.processFrame(
          <Detection>[dive(i * 0.1, 0.35), dive(i * 0.1, 0.65)],
          epoch.add(Duration(milliseconds: i * 100)),
          pitchDeg: null,
          ego: EgoMotion.unknown,
        );
        twoTrackVibs += r.vibrations.length;
      }
      expect(twoTrackVibs, greaterThanOrEqualTo(2),
          reason: 'dedup is per track, never global');

      // Fresh episode: after the target is gone well past
      // the retention window, a new dive (new track id)
      // vibrates again.
      final HazardPipeline p2 = HazardPipeline();
      int episodeVibs = 0;
      void run(int fromMs, int frames, bool present) {
        for (int i = 0; i < frames; i++) {
          final int f = fromMs + i;
          final HazardPipelineResult r = p2.processFrame(
            present
                ? <Detection>[dive((i % 10) * 0.1, 0.5)]
                : const <Detection>[],
            epoch.add(Duration(milliseconds: f * 100)),
            pitchDeg: null,
            ego: EgoMotion.unknown,
          );
          episodeVibs += r.vibrations.length;
        }
      }

      run(0, 4, true); // episode 1: pre-urgent at frame 2
      final int afterFirst = episodeVibs;
      run(4, 15, false); // gone, past the 10-frame window
      run(19, 4, true); // episode 2: a new approach
      expect(afterFirst, greaterThanOrEqualTo(1),
          reason: 'episode 1 vibrated');
      expect(episodeVibs, greaterThan(afterFirst),
          reason: 'a NEW episode re-arms the vibration '
              'budget (no lifetime dedup)');
    });
  });
}
