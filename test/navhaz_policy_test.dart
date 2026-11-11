/// NAVHAZ M1, spec sections 2.3 / 2.7: hazard-policy
/// behaviour on the acceptance fixtures (alert windows,
/// silent scenarios, flicker confirmation) and the
/// cooldown / upgrade / merge rules as direct unit tests.
library;
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/hazard/hazard_policy.dart';
import 'package:mingtu_ai/core/hazard/ttc_estimator.dart';
import 'package:mingtu_ai/core/tracking/tracker.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';

import 'navhaz_fixture_harness.dart';

/// A confirmed track with [frames] samples at [cx].
Track confirmedTrack(int id, String label, {double cx = 0.5, int frames = 5}) {
  final Track t = Track(id: id, label: label);
  final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
  for (int i = 0; i < frames; i++) {
    t.recordMatch(
      _det(label, cx),
      epoch.add(Duration(milliseconds: i * 100)),
    );
  }
  return t;
}

Detection _det(String label, double cx) => Detection(
      label: label,
      confidence: 0.9,
      cx: cx,
      cy: 0.55,
      w: 0.2,
      h: 0.4,
    );

TrackEstimate estimate(
  Track track, {
  double? ttc,
  double? range,
  double? closing,
  bool approaching = false,
  bool willHit = true,
  bool disagreement = false,
}) {
  return TrackEstimate(
    track: track,
    ttcS: ttc,
    ttcScaleS: ttc,
    ttcRangeS: ttc,
    // FIX3B: the urgent judgement reads ttcUrgentS; these
    // unit estimates name ONE ttc for every tier (they
    // test the policy's band logic, not the estimator's
    // tiers, which the pipeline tests cover).
    ttcUrgentS: ttc,
    rangeM: range,
    closingSpeedMps: closing,
    approaching: approaching,
    willHit: willHit,
    cxVelocity: 0,
    ttcDisagreement: disagreement,
  );
}

final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);
DateTime at(int ms) => _epoch.add(Duration(milliseconds: ms));

void main() {
  group('acceptance fixtures (spec 2.7.1-2.7.4)', () {
    for (final String backend in kBackends) {
      test('$backend approaching car: W first in TTC[3,5], U first in [2.5,3.0]',
          () {
        final FixtureRun run = runFixture('approaching_car.jsonl', backend);
        expect(run.warnings, isNotEmpty);
        expect(run.urgents, isNotEmpty);
        final double wTrueTtc = 6.0 - run.warnings.first.tMs / 1000.0;
        final double uTrueTtc = 6.0 - run.urgents.first.tMs / 1000.0;
        expect(wTrueTtc, inInclusiveRange(3.0, 5.0),
            reason: 'first warning at t=${run.warnings.first.tMs}');
        expect(uTrueTtc, inInclusiveRange(2.5, 3.0),
            reason: 'first urgent at t=${run.urgents.first.tMs}');
        expect(run.warnings.first.tMs, lessThan(run.urgents.first.tMs));
      });

      test('$backend crossing pedestrian: zero alerts', () {
        final FixtureRun run =
            runFixture('crossing_pedestrian.jsonl', backend);
        expect(run.alerts, isEmpty);
      });

      test('$backend side-passing car: zero alerts', () {
        final FixtureRun run = runFixture('side_pass_car.jsonl', backend);
        expect(run.alerts, isEmpty,
            reason: 'extrapolated path never enters the corridor');
      });

      test('$backend flicker: nothing until 3 consecutive frames, then 1 W',
          () {
        final FixtureRun run = runFixture('flicker_person.jsonl', backend);
        expect(run.alerts, hasLength(1));
        expect(run.alerts.single.level, HazardLevel.warning);
        expect(run.alerts.single.tMs, 1200,
            reason: 'frames 10,11,12 are the first unbroken run of 3');
      });

      test('$backend jitter: exactly one U, no later than clean + 300 ms',
          () {
        final FixtureRun clean = runFixture('approaching_car.jsonl', backend);
        final FixtureRun jitter = runFixture('jitter_car.jsonl', backend);
        expect(jitter.urgents, hasLength(1));
        expect(
          jitter.urgents.single.tMs,
          lessThanOrEqualTo(clean.urgents.first.tMs + 300),
        );
        expect(jitter.trackIds, hasLength(1));
      });
    }
  });

  group('cooldown / upgrade / re-alert (spec 2.7.6)', () {
    test('same level within 4 s is suppressed; W -> U upgrades at once', () {
      final HazardPolicy policy = HazardPolicy();
      final Track car = confirmedTrack(1, 'car');
      HazardPolicyResult r = policy.evaluate(
        <TrackEstimate>[
          estimate(car, ttc: 4.0, range: 8, closing: 2, approaching: true),
        ],
        at(0),
      );
      expect(r.alert?.level, HazardLevel.warning);
      // Same warning 1 s later: suppressed.
      r = policy.evaluate(
        <TrackEstimate>[
          estimate(car, ttc: 3.8, range: 7.6, closing: 2, approaching: true),
        ],
        at(1000),
      );
      expect(r.alert, isNull);
      expect(r.riskPresent, isTrue,
          reason: 'suppressed speech does not clear the risk state');
      // Upgrade to urgent inside the cooldown: immediate.
      r = policy.evaluate(
        <TrackEstimate>[
          estimate(car, ttc: 2.9, range: 5.8, closing: 2, approaching: true),
        ],
        at(1500),
      );
      expect(r.alert?.level, HazardLevel.urgent);
      // Same urgent, TTC barely moved, still in cooldown: suppressed.
      r = policy.evaluate(
        <TrackEstimate>[
          estimate(car, ttc: 2.7, range: 5.4, closing: 2, approaching: true),
        ],
        at(2000),
      );
      expect(r.alert, isNull);
    });

    test('TTC drop >= 40% re-alerts inside the cooldown; smaller does not',
        () {
      final HazardPolicy policy = HazardPolicy();
      final Track car = confirmedTrack(1, 'car');
      policy.evaluate(
        <TrackEstimate>[
          estimate(car, ttc: 2.9, range: 5.8, closing: 2, approaching: true),
        ],
        at(0),
      );
      // 2.9 -> 2.2 is a 24% drop: suppressed.
      HazardPolicyResult r = policy.evaluate(
        <TrackEstimate>[
          estimate(car, ttc: 2.2, range: 4.4, closing: 2, approaching: true),
        ],
        at(700),
      );
      expect(r.alert, isNull);
      // 2.9 -> 1.7 is a 41% drop: re-alert.
      r = policy.evaluate(
        <TrackEstimate>[
          estimate(car, ttc: 1.7, range: 3.4, closing: 2, approaching: true),
        ],
        at(1200),
      );
      expect(r.alert?.level, HazardLevel.urgent);
    });

    test('after the cooldown the same level may speak again', () {
      final HazardPolicy policy = HazardPolicy();
      final Track car = confirmedTrack(1, 'car');
      policy.evaluate(
        <TrackEstimate>[
          estimate(car, ttc: 4.0, range: 8, closing: 2, approaching: true),
        ],
        at(0),
      );
      final HazardPolicyResult r = policy.evaluate(
        <TrackEstimate>[
          estimate(car, ttc: 3.9, range: 7.8, closing: 2, approaching: true),
        ],
        at(4100),
      );
      expect(r.alert?.level, HazardLevel.warning);
    });
  });

  group('merge + selection (spec 2.7.7)', () {
    test('two same-kind same-zone tracks within 500 ms merge to one', () {
      final HazardPolicy policy = HazardPolicy();
      final Track a = confirmedTrack(1, 'car');
      final Track b = confirmedTrack(2, 'car');
      HazardPolicyResult r = policy.evaluate(
        <TrackEstimate>[
          estimate(a, ttc: 4.0, range: 8, closing: 2, approaching: true),
        ],
        at(0),
      );
      expect(r.alert, isNotNull);
      // A second car, same zone, 300 ms later -- even with a
      // slightly lower TTC it merges into the first alert.
      r = policy.evaluate(
        <TrackEstimate>[
          estimate(b, ttc: 3.9, range: 7.8, closing: 2, approaching: true),
        ],
        at(300),
      );
      expect(r.alert, isNull,
          reason: 'same kind + same zone inside the merge window');
      expect(r.riskPresent, isTrue);
    });

    test('one alert per frame: urgent beats warning, then lowest TTC', () {
      final HazardPolicy policy = HazardPolicy();
      final Track car = confirmedTrack(1, 'car');
      final Track person = confirmedTrack(2, 'person');
      final HazardPolicyResult r = policy.evaluate(
        <TrackEstimate>[
          estimate(person, ttc: 4.0, range: 2.5),
          estimate(car, ttc: 2.8, range: 5.6, closing: 2, approaching: true),
        ],
        at(0),
      );
      expect(r.alert?.level, HazardLevel.urgent);
      expect(r.alert?.trackId, 1);
    });

    test('unconfirmed tracks: warnings still need 3 frames; '
        'urgent fires on the 2-of-3 predicate (FIX3B)', () {
      final HazardPolicy policy = HazardPolicy();
      final Track car = confirmedTrack(1, 'car', frames: 2);
      // Warning-grade estimate on a 2-frame track: the
      // latched 3-frame confirmation still gates every
      // warning-level rule (FIX3B did NOT relax it).
      HazardPolicyResult r = policy.evaluate(
        <TrackEstimate>[
          estimate(car, ttc: 4.0, range: 8, closing: 2, approaching: true),
        ],
        at(0),
      );
      expect(r.alert, isNull);
      expect(r.riskPresent, isFalse);
      // Urgent-grade estimate on the same 2-frame track:
      // 2-of-3 with the current frame a hit IS the urgent
      // confirmation (FIX3B), so the urgent fires one
      // frame earlier than any warning could. (The
      // pre-FIX3B form of this test expected silence here;
      // that premise is exactly what the tiering retired.)
      r = policy.evaluate(
        <TrackEstimate>[
          estimate(car, ttc: 1.0, range: 2, closing: 3, approaching: true),
        ],
        at(100),
      );
      expect(r.alert?.level, HazardLevel.urgent);
    });

    test('crossing target that will not hit stays silent', () {
      final HazardPolicy policy = HazardPolicy();
      final Track person = confirmedTrack(1, 'person', cx: 0.9);
      final HazardPolicyResult r = policy.evaluate(
        <TrackEstimate>[
          estimate(person, ttc: 2.0, range: 4, willHit: false),
        ],
        at(0),
      );
      expect(r.alert, isNull);
      expect(r.riskPresent, isFalse);
    });

    test('TTC unknown: only the inherited near-corridor rule applies', () {
      final HazardPolicy policy = HazardPolicy();
      // Static person, box bottom 0.9 (near rule), no TTC, no
      // range: a warning via the legacy near rule -- never
      // urgent on unknown TTC.
      final Track person = Track(id: 1, label: 'person');
      final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
      for (int i = 0; i < 4; i++) {
        person.recordMatch(
          const Detection(
              label: 'person',
              confidence: 0.9,
              cx: 0.5,
              cy: 0.7,
              w: 0.2,
              h: 0.4),
          epoch.add(Duration(milliseconds: i * 100)),
        );
      }
      final HazardPolicyResult r = policy.evaluate(
        <TrackEstimate>[estimate(person)],
        at(0),
      );
      expect(r.alert?.level, HazardLevel.warning);
    });
  });

  group('TTC disagreement degrades, never promotes (fix round)', () {
    test('one leg at 2.5 s + disagreement -> NO urgent', () {
      final HazardPolicy policy = HazardPolicy();
      final Track car = confirmedTrack(1, 'car');
      // The estimator nulls the fused TTC on disagreement;
      // even though a (distrusted) scale leg read 2.5 s and
      // the target is closing, no TTC branch may promote.
      // Range 8 m keeps every range rule out of reach, and
      // the box bottom (0.75) keeps the near rule out.
      final HazardPolicyResult r = policy.evaluate(
        <TrackEstimate>[
          estimate(car,
              ttc: null, range: 8, closing: 2, approaching: true,
              disagreement: true),
        ],
        at(0),
      );
      expect(r.alert, isNull);
      expect(r.riskPresent, isFalse);
    });

    test('disagreement still allows the static Z rule (W)', () {
      final HazardPolicy policy = HazardPolicy();
      final Track car = confirmedTrack(1, 'car');
      final HazardPolicyResult r = policy.evaluate(
        <TrackEstimate>[
          estimate(car, ttc: null, range: 2.5, disagreement: true),
        ],
        at(0),
      );
      expect(r.alert?.level, HazardLevel.warning,
          reason: 'range Z is separately valid: the static '
              'corridor rule applies as for any TTC == null');
    });

    test('disagreement at 1.2 m: close-range TTC branch stays off', () {
      final HazardPolicy policy = HazardPolicy();
      final Track car = confirmedTrack(1, 'car');
      // Range <= 1.5 m would be urgent WITH a trusted TTC
      // <= 2 s; with the fused TTC null by distrust only
      // the static warning remains.
      final HazardPolicyResult r = policy.evaluate(
        <TrackEstimate>[
          estimate(car, ttc: null, range: 1.2, disagreement: true),
        ],
        at(0),
      );
      expect(r.alert?.level, HazardLevel.warning);
    });

    test('disagreement still allows the near-corridor rule (W)', () {
      final HazardPolicy policy = HazardPolicy();
      final Track person = Track(id: 1, label: 'person');
      final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
      for (int i = 0; i < 4; i++) {
        person.recordMatch(
          const Detection(
              label: 'person',
              confidence: 0.9,
              cx: 0.5,
              cy: 0.75,
              w: 0.2,
              h: 0.4),
          epoch.add(Duration(milliseconds: i * 100)),
        );
      }
      final HazardPolicyResult r = policy.evaluate(
        <TrackEstimate>[estimate(person, disagreement: true)],
        at(0),
      );
      expect(r.alert?.level, HazardLevel.warning,
          reason: 'box bottom 0.95 in the corridor: the '
              'inherited TTC == null rule');
    });
  });
}
