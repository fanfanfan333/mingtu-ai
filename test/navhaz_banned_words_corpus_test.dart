/// NAVHAZ M1, spec 2.7.10 corpus (CDX2-6b / FIX2 round):
/// the spoken texts produced by the test classes 1-8,
/// gathered into ONE auditable set and asserted free of
/// every banned word (the full four-word list -- 安全 /
/// 可以通行 / 放心 / 可以过马路 -- never a reduced set).
///
/// Sources of the corpus (each entry's origin is kept in
/// the failure message):
///  1. enumerateAllHazardPhrases() -- the single
///     enumerable entry point of hazard_phrases (the whole
///     template space; the phrases suite asserts the same
///     space in depth, this corpus re-checks it as part of
///     the unified set);
///  2. every alert phrase the five acceptance fixtures
///     produce on BOTH tracker backends (the fixture-driven
///     alert texts of test classes 1-5 / 8);
///  3. every alert phrase of the ego contrast geometries
///     (walking / approaching / same-speed / unknown) on
///     both backends -- the class-3/6 alert texts that the
///     ego suite asserts on;
///  4. the spoken texts of the arbitration suites are
///     asserted INSIDE their own files on their recorded
///     timelines (navhaz_arb_15s_expiry_test: every case
///     ends with a full-timeline banned-word sweep;
///     navhaz_arbitration_test predates that sweep -- its
///     hazard texts are the same pipeline phrases covered
///     here under 2, and its navigation texts are covered
///     by the lib source scan in navhaz_phrases_test).
/// The scheduler / tracking unit suites speak no natural
/// language (synthetic ids like 'text-<id>'), so they
/// contribute no corpus entries; that is stated here
/// rather than silently skipped.
library;
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/hazard/ego_motion.dart';
import 'package:mingtu_ai/core/hazard/hazard_phrases.dart';
import 'package:mingtu_ai/core/hazard/hazard_pipeline.dart';
import 'package:mingtu_ai/core/navhaz_config.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';

import 'navhaz_fixture_harness.dart';

/// Box bottom for a ground-contact target at range [z]
/// under pitch 10 degrees (the estimator's law, inverted;
/// mirrors the ego suite's helper).
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

void main() {
  test('corpus: every spoken text from test classes 1-8 '
      'is free of all four banned words', () {
    final Map<String, String> corpus = <String, String>{};
    void add(String origin, String text) {
      corpus.putIfAbsent(text, () => origin);
    }

    // Source 1: the whole phrase-template space.
    for (final String phrase in enumerateAllHazardPhrases()) {
      add('enumerateAllHazardPhrases', phrase);
    }
    final int templateCount = corpus.length;

    // Source 2: fixture alert phrases, both backends.
    for (final String fixture in <String>[
      'approaching_car.jsonl',
      'jitter_car.jsonl',
      'crossing_pedestrian.jsonl',
      'side_pass_car.jsonl',
      'flicker_person.jsonl',
    ]) {
      for (final String backend in kBackends) {
        final FixtureRun run = runFixture(fixture, backend);
        for (final AlertRecord a in run.alerts) {
          add('fixture $fixture/$backend', a.phrase);
        }
      }
    }

    // Source 3: the ego contrast geometries, both backends.
    final Map<String, EgoMotion> egoCases = <String, EgoMotion>{
      'walking->parked': EgoMotion.judge(gpsSpeedMps: 1.2, gpsAccuracyM: 5),
      'car->still': EgoMotion.still,
      'same-speed': EgoMotion.judge(gpsSpeedMps: 1.2, gpsAccuracyM: 5),
      'unknown-head-on': EgoMotion.unknown,
    };
    for (final String backend in kBackends) {
      for (final MapEntry<String, EgoMotion> c in egoCases.entries) {
        final HazardPipeline pipeline =
            HazardPipeline(tracker: trackerForBackend(backend));
        final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
        final List<Detection> frames = switch (c.key) {
          'walking->parked' => <Detection>[
              for (int i = 0; i <= 50; i++) _carAt(8.0 - 0.12 * i),
            ],
          'same-speed' => <Detection>[
              for (int i = 0; i < 30; i++) _carAt(6.0),
            ],
          _ => <Detection>[
              for (int i = 0; i <= 40; i++) _carAt(12.0 - 0.25 * i),
            ],
        };
        for (int i = 0; i < frames.length; i++) {
          final HazardPipelineResult r = pipeline.processFrame(
            <Detection>[frames[i]],
            epoch.add(Duration(milliseconds: i * 100)),
            pitchDeg: 10,
            ego: c.value,
          );
          if (r.alert != null) add('ego ${c.key}/$backend', r.alert!.phrase);
        }
      }
    }

    // The corpus is substantive, not a token sample: the
    // template space alone is in the thousands RAW, and
    // the fixture/ego runs add their distinct spoken
    // forms. (FIX3B: the floor drops from 5000 to 1000 --
    // the banded distance wording collapses the unique
    // phrase space by design, from 11,700 raw phrases to
    // 2,460, of which 1,044 are unique texts; the old
    // floor counted numeric gradations the wording no
    // longer has.)
    expect(templateCount, greaterThan(1000),
        reason: 'the enumerable phrase space (FIX3B bands)');
    expect(corpus.length, greaterThanOrEqualTo(templateCount),
        reason: 'FIX3B: the fixture + ego runs now add NO '
            'texts beyond the enumerated template space '
            '(1044 == 1044) -- under the banded wording '
            'every producible phrase is already enumerated, '
            'which is the completeness property itself; the '
            'pre-FIX3B strict-greater premise relied on '
            'out-of-template numeric readouts. '
            '${corpus.length} total');

    for (final MapEntry<String, String> e in corpus.entries) {
      expect(containsBannedWord(e.key), isFalse,
          reason: 'banned word in "${e.key}" (from ${e.value})');
    }
  });
}
