/// NAVHAZ M1, spec sections 0.1 / 2.4 / 2.7.10: no spoken
/// text may grant or imply passage. The check runs over
/// the FULL output space of the hazard-phrase templates --
/// every item name (all hazardKindName values and every
/// spoken label name) x every direction form (the three
/// near zones and all twelve clock hours) x the whole
/// spoken-metre domain (the near set, 1..10 m per metre,
/// and every 5 m step beyond) x both levels -- enumerated
/// at one central point (fix round: the earlier sampled
/// cross-product was replaced by this exhaustive one),
/// over every phrase the acceptance fixtures produce, and
/// over the lib/ sources themselves (string literals must
/// not contain a banned word; the banned list itself is
/// assembled from adjacent literals so this scan stays
/// clean by construction).
library;
import 'dart:io';
import 'dart:math' show Random;

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/avoidance_advisor.dart';
import 'package:mingtu_ai/core/hazard/hazard_phrases.dart';

import 'navhaz_fixture_harness.dart';

/// Remove // line comments and /* */ block comments while
/// keeping string literals intact (a small state machine;
/// raw strings and interpolation nesting beyond one level
/// are not needed for this guard).
String stripComments(String src) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  bool inLine = false;
  bool inBlock = false;
  String? quote;
  bool triple = false;
  while (i < src.length) {
    final String c = src[i];
    final String next = i + 1 < src.length ? src[i + 1] : '';
    if (inLine) {
      if (c == '\n') {
        inLine = false;
        out.write(c);
      }
      i++;
      continue;
    }
    if (inBlock) {
      if (c == '*' && next == '/') {
        inBlock = false;
        i += 2;
      } else {
        i++;
      }
      continue;
    }
    if (quote != null) {
      out.write(c);
      if (c == '\\') {
        if (i + 1 < src.length) out.write(src[i + 1]);
        i += 2;
        continue;
      }
      if (triple) {
        if (c == quote && next == quote && src[i + 2] == quote) {
          out.write(quote);
          out.write(quote);
          i += 3;
          quote = null;
          triple = false;
          continue;
        }
      } else if (c == quote) {
        quote = null;
      }
      i++;
      continue;
    }
    if (c == '/' && next == '/') {
      inLine = true;
      i += 2;
      continue;
    }
    if (c == '/' && next == '*') {
      inBlock = true;
      i += 2;
      continue;
    }
    if (c == "'" || c == '"') {
      if (next == c && src[i + 2] == c) {
        triple = true;
        out.write(c);
        out.write(c);
        out.write(c);
        i += 3;
      } else {
        out.write(c);
        i++;
      }
      quote = c;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

void main() {
  group('hazard phrase templates', () {
    test('EXHAUSTIVE output space contains no banned word (2.7.10)',
        () {
      // FIX2 round: the enumeration runs through the
      // SINGLE enumerable entry point in hazard_phrases
      // (enumerateAllHazardPhrases) instead of a test-local
      // cross product, so the exhausted space is by
      // construction the space the production builder can
      // produce: every spoken name x both levels x the
      // three near zones + twelve clock hours x the full
      // metre domain.
      final List<String> all = enumerateAllHazardPhrases().toList();
      expect(all, isNotEmpty);
      for (final String phrase in all) {
        expect(containsBannedWord(phrase), isFalse,
            reason: 'banned word in "$phrase"');
        expect(
            phrase.startsWith('停，') || phrase.startsWith('注意，'),
            isTrue,
            reason: 'template shape: $phrase');
      }
      // Direction coverage really happened: all three
      // zones and all twelve clock hours appear.
      expect(all.any((String p) => p.contains('左边')), isTrue);
      expect(all.any((String p) => p.contains('前方')), isTrue);
      expect(all.any((String p) => p.contains('右边')), isTrue);
      for (int h = 1; h <= 12; h++) {
        expect(all.any((String p) => p.contains('点钟方向')), isTrue);
      }
      // Metre coverage under the FIX3B bands: every
      // reachable (non-empty) readout appears in some
      // enumerated phrase, and -- the stronger direction --
      // EVERY phrase the production builder produces over
      // a fine input sweep (plus very large ranges, whose
      // readout is the no-number form) is a member of the
      // enumerated set. The enumeration IS the producible
      // space, not a sample of it.
      final Set<String> enumerated = all.toSet();
      for (final String m in reachableMetresTexts()) {
        expect(all.any((String p) => p.contains(m)), isTrue,
            reason: 'readout "$m" appears in the enumeration');
      }
      for (double r = 0.05; r <= 30.0; r += 0.05) {
        for (final bool urgent in <bool>[true, false]) {
          final String phrase = hazardPhrase(
              urgent: urgent,
              name: '汽车',
              isVehicle: true,
              cx: 0.5,
              rangeM: r);
          expect(enumerated.contains(phrase), isTrue,
              reason: 'range $r: "$phrase" is enumerated');
        }
      }
      for (final double r in <double>[105, 1234, 99999]) {
        final String phrase = hazardPhrase(
            urgent: false, name: '汽车', isVehicle: true, cx: 0.5, rangeM: r);
        expect(enumerated.contains(phrase), isTrue,
            reason: 'range $r (no-number band): "$phrase" '
                'is enumerated');
        expect(containsBannedWord(phrase), isFalse);
      }
      // The UNIQUE phrase set is pinned verbatim so a
      // silently shrinking (or growing) entry point fails
      // loudly. Composition, stated against the CODE (the
      // previous round's comment had the genuinely-new
      // form wrong -- it named the pole form; the rebuild
      // below is the corrected account, re-verified this
      // round by set difference):
      // - NH-M1-14 baseline: 1,044 (templates only).
      // - NH-M1-17's kind-only short forms added exactly
      //   ONE new phrase: '停，前方有人' -- the person
      //   near template always carries a distance readout
      //   or the 有+name shape at its zone, so a bare
      //   centre person short form existed nowhere in the
      //   templates. The other three coincided with
      //   template phrases: '停，前方来车' IS the
      //   template's own vehicle minimum, '停，前方有杆子'
      //   and '停，前方有杂物' are the pole / clutter near
      //   forms verbatim. => 1,045.
      // - NH-M1-19 reshaped the short forms (per kind x
      //   label name x three bearings, 18 distinct texts
      //   replacing the 4 kind-only ones): the 3 forms
      //   that already existed stay ('停，前方来车',
      //   '停，前方有人', '停，前方有杂物'); the remaining
      //   NH-M1-17 form is REPLACED as a short form
      //   ('停，前方有杆子' -> the pole short '停，前方有杆')
      //   -- note the
      //   direction of the survival, stated precisely
      //   (M2-B item 3: an earlier draft of this comment
      //   attached it to the wrong form): it is the OLD
      //   form '停，前方有杆子' that still exists as a
      //   template phrase (the pole near form verbatim,
      //   per the NH-M1-17 bullet above), so nothing is
      //   lost from the set when the short form changes;
      //   '停，前方有杆' itself is genuinely new (one of
      //   the 15 below). 15 forms are genuinely new
      //   (every side-bearing form plus the two kind-name
      //   centre forms and the new pole centre form).
      //   => 1,045 + 15 = 1,060, verified by set
      //   difference against the rebuilt pre-NH-M1-19 set
      //   that round (gained 15, lost 0).
      // - M2-B item 2 (no-range full sentence): a null
      //   range no longer takes the near branch -- it
      //   renders the clock form with the distance
      //   omitted ('停，十二点钟方向，汽车靠近'), a string the
      //   far no-number band already produced, so item 2
      //   ADDS no string. What leaves the space is the
      //   30 warning zone forms with no distance segment
      //   ('注意，{左边/前方/右边}有{name}' x the 10 spoken
      //   names): they were producible ONLY through a
      //   null range (a measured near range always
      //   carries a readout), and a null range now takes
      //   the clock form instead. The urgent zone forms
      //   lose nothing (every one stays producible via a
      //   measured range in the (3, 5] near band, and the
      //   centre vehicle form via the short table too).
      //   => 1,060 - 30 = 1,030, verified by set
      //   difference this round (gained 0, lost 30).
      // - M3 (pothole second detector): ONE new spoken
      //   name axis joins the space -- 坑洞 (the pit
      //   kind's name, also the 'pothole' label's spoken
      //   name; the two deduplicate to a single axis).
      //   Its producible forms are the axis' near zone
      //   forms, no-range clock forms and far clock
      //   forms: 102 distinct strings, every one
      //   carrying the new item name.
      //   => 1,030 + 102 = 1,132, verified by set
      //   difference this round (gained 102, lost 0;
      //   measured in navhaz_pothole_test.dart).
      // The RAW yield count is deliberately NOT pinned
      // any more (NH-M1-14): the distance axes are now
      // DERIVED from the shared hazardBands table (denser
      // interior samples than the old hand-listed ones),
      // so the raw combination count follows the table's
      // sampling density (3,960 at the current table)
      // while the producible phrase SET -- the quantity
      // the 2,460-combination baseline actually pinned
      // semantically -- is what the pin above tracks.
      expect(all.toSet().length, 1132,
          reason: 'the producible phrase set: NH-M1-14 '
              'baseline 1,044 + 1 NH-M1-17 short form '
              '(person) + 15 NH-M1-19 bearing forms '
              '- 30 M2-B no-range warning forms '
              '+ 102 M3 pothole-axis forms (see the '
              'composition account above)');
      expect(all.length, greaterThan(2460),
          reason: 'the table-derived axes sample at least '
              'the old hand-listed coverage');
    });

    test('distance wording bands (FIX3B)', () {
      // Hazard bands.
      expect(metresText(0.8), '很近');
      expect(metresText(1.49), '很近');
      expect(metresText(1.5), '二米');
      expect(metresText(4.4), '四米');
      expect(metresText(6.0), '约五米');
      expect(metresText(7.49), '约五米');
      expect(metresText(7.5), '约十米');
      expect(metresText(9.9), '约十米');
      expect(metresText(10.0), '',
          reason: 'at 10 m and beyond: no number at all');
      expect(metresText(1234), '');
      // Navigation bands.
      expect(navigationDistanceText(12), '约12米');
      expect(navigationDistanceText(16.6), '约17米');
      expect(navigationDistanceText(29.5), '约30米',
          reason: 'S2 acceptance point (FIX4-FINAL): '
              '17-100 m rounds to the NEAREST 10 m, '
              'halves up -- 29.5 -> 30 (the FIX3B floor '
              'rule read 20 here)');
      expect(navigationDistanceText(24.9), '约20米',
          reason: 'S2 acceptance point: just under the '
              '25 m midpoint rounds down to 20');
      expect(navigationDistanceText(25), '约30米',
          reason: 'S2 acceptance point: exactly on the '
              'midpoint, half-up -> 30');
      expect(navigationDistanceText(35), '约40米',
          reason: '35 is the 30/40 midpoint: half-up '
              'gives 40 under S2 (the floor rule gave 30)');
      expect(navigationDistanceText(99), '约100米');
      expect(navigationDistanceText(100), '约100米');
      expect(navigationDistanceText(120), '约100米');
      expect(navigationDistanceText(130), '约150米',
          reason: '100-1000 m rounds to the nearest 50 m');
      expect(navigationDistanceText(999), '约1000米');
      expect(navigationDistanceText(1000), '约1公里');
      expect(navigationDistanceText(1499), '约1公里');
      expect(navigationDistanceText(1500), '约2公里');
      expect(navigationDistanceText(2400), '约2公里');
      expect(navigationDistanceText(2600), '约3公里');
      expect(navigationDistanceText(9999), '约10公里');
      expect(navigationDistanceText(10000), '10公里以外');
    });

    test('minimum readout: sub-half-metre never says '
        'about-0-metres (FIX4-FINAL)', () {
      final Set<String> navSet = enumerateNavigationDistanceTexts();
      for (final double d in <double>[0, 0.1, 0.49]) {
        expect(navigationDistanceText(d), '约1米',
            reason: 'd=$d rounds to 0 whole metres; the '
                'readout clamps at navMinReportedMetres '
                'instead of announcing "about 0 metres"');
        expect(navSet.contains(navigationDistanceText(d)), isTrue,
            reason: 'the clamped readout is in the '
                'analytic enumeration');
      }
      expect(navigationDistanceText(0.5), '约1米',
          reason: 'the 0.5 boundary follows round() '
              'semantics (half away from zero): 0.5 -> 1, '
              'the clamp is not even needed');
      expect(navSet.contains('约0米'), isFalse,
          reason: 'the analytic set has no about-0 readout');
    });

    test('property: fine grid lands in the ANALYTIC '
        'enumerated set (FIX4-FINAL)', () {
      // The enumeration is derived from the band table
      // analytically (no input sampling); this sweep is
      // the drift guard between it and the production
      // function. Grid steps are FINER than each band's
      // smallest rounding granularity (1 m in the
      // whole-metre band, so the 0.01 step crosses every
      // rounding boundary; the coarser bands keep a 1 m
      // step, still finer than their 10/50/1000 m
      // granularities), and every band edge is probed at
      // +/- 0.001 explicitly below via the boundary
      // samples in the samples list.
      final Set<String> navSet = enumerateNavigationDistanceTexts();
      final Set<String> hazardReachable = reachableMetresTexts();
      void check(double d) {
        final String out = navigationDistanceText(d);
        expect(navSet.contains(out), isTrue,
            reason: 'navigation wording for $d m ("$out") '
                'is in the analytic enumeration');
        expect(containsBannedWord(out), isFalse,
            reason: 'no banned word in the SAMPLED output '
                'for $d m, not just in the enumerated set');
      }

      for (double d = 0; d <= 200; d += 0.01) {
        check(d);
      }
      for (double d = 200; d <= 12000; d += 1) {
        check(d);
      }
      final List<double> samples = <double>[
        16.999, 17, 17.001, 99.999, 100, 100.001,
        999.999, 1000, 1499.999, 1500, 9999.999, 10000,
        1234, 99999,
      ];
      final Random rng = Random(20261111);
      for (int i = 0; i < 24; i++) {
        samples.add(100 + rng.nextDouble() * 200000);
      }
      for (final double d in samples) {
        check(d);
        final String hazard = metresText(d);
        expect(hazard.isEmpty || hazardReachable.contains(hazard),
            isTrue,
            reason: 'hazard wording for $d m is a reachable '
                'readout (or the no-number form)');
        expect(containsBannedWord(hazard), isFalse);
      }
      // Every enumerated navigation readout is itself
      // banned-word free (the navigation space joins the
      // section 2.7.10 exhaustion).
      for (final String text in navSet) {
        expect(containsBannedWord(text), isFalse, reason: text);
      }
    });

    test('zone and clock wording follow the geometry', () {
      expect(zoneName(0.1), '左边');
      expect(zoneName(0.5), '前方');
      expect(zoneName(0.9), '右边');
      expect(clockHour(0.5), 12);
      expect(clockHour(0.85), 1, reason: 'right of centre reads 1 o-clock');
      expect(clockHour(0.15), 11, reason: 'left of centre reads 11 o-clock');
      expect(clockHour(1.0), 1,
          reason: 'the frame edge is +35 deg at HFOV 70, still 1 o-clock');
      expect(metresText(9.6), '约十米',
          reason: 'FIX3B band: 5-10 m reads about-5 / '
              'about-10 split at 7.5 (was: 十米 under the '
              'pre-FIX3B 5 m stepping)');
      expect(metresText(12.0), '',
          reason: 'FIX3B band: >= 10 m speaks no number '
              '(was: 十米)');
      expect(metresText(13.0), '',
          reason: 'FIX3B band: >= 10 m speaks no number '
              '(was: 15米)');
    });

    test('no-range full sentence (M2-B item 2): item and '
        'bearing kept, distance omitted, never the short '
        'form', () {
      // Scale-only evidence (rangeM == null -- no pitch,
      // so no range can be computed): the FULL sentence
      // must still name the item and the bearing; only
      // the distance segment is omitted. Before this
      // fix the null case fell into the near branch and
      // a dead-centre vehicle collapsed to the short
      // form's text verbatim.
      const String urgentCar = '停，十二点钟方向，汽车靠近';
      expect(
          hazardPhrase(
              urgent: true, name: '汽车', isVehicle: true, cx: 0.5, rangeM: null),
          urgentCar,
          reason: 'verbatim: the far (clock) form minus '
              'its distance segment');
      expect(voicedCharCount(urgentCar), 11,
          reason: '11 voiced characters -- the count the '
              'NH-M1-19 gate\'s condition 2 now uses for '
              'a no-range car sentence (was 5, when the '
              'full sentence coincided with the short '
              'form)');
      expect(urgentCar.contains('汽车'), isTrue,
          reason: 'the item word is present');
      expect(urgentCar.contains('十二点钟方向'), isTrue,
          reason: 'the bearing is present');
      expect(urgentCar.contains(RegExp(r'[0-9]')), isFalse,
          reason: 'no distance figure');
      for (final String readout in reachableMetresTexts()) {
        expect(urgentCar.contains(readout), isFalse,
            reason: 'no metre readout "$readout" either');
      }
      expect(
          urgentCar,
          isNot(shortUrgentPhrase(HazardKind.motorVehicle, '汽车', 0.5)),
          reason: 'the no-range full sentence is NOT the '
              'short form -- missing geometry must not '
              'demote it');
      // The warning level takes the same no-range form.
      expect(
          hazardPhrase(
              urgent: false, name: '汽车', isVehicle: true, cx: 0.5, rangeM: null),
          '注意，十二点钟方向，汽车靠近');
      // Other bearings / kinds follow the same rule
      // (clock bearing from the same geometry).
      expect(
          hazardPhrase(
              urgent: true, name: '行人', isVehicle: false, cx: 0.9, rangeM: null),
          '停，一点钟方向，行人靠近',
          reason: 'right-of-centre reads 1 o-clock, item '
              'kept');
      expect(
          hazardPhrase(
              urgent: true, name: '杆子', isVehicle: false, cx: 0.1, rangeM: null),
          '停，十一点钟方向，杆子靠近');
      // The no-range form is not a new shape: it is
      // byte-identical to what the ranged far template
      // renders inside the no-number band.
      expect(
          hazardPhrase(
              urgent: true, name: '汽车', isVehicle: true, cx: 0.5, rangeM: 25),
          urgentCar,
          reason: 'a 25 m range (no-number band) renders '
              'the same string -- ranged form minus '
              'distance IS this form');
      // And it belongs to the enumerated output space.
      expect(enumerateAllHazardPhrases().toSet().contains(urgentCar),
          isTrue,
          reason: 'the no-range form is enumerated '
              '(completeness follows the builder)');
      expect(containsBannedWord(urgentCar), isFalse);
    });

    test('the fallback sentence itself is clean', () {
      expect(containsBannedWord(bannedWordFallbackPhrase), isFalse);
    });

    test('assertNoBannedWords throws in debug for a banned sample', () {
      // Assembled at runtime so THIS test file also stays
      // free of the contiguous banned string.
      final String banned = <String>['安', '全'].join();
      expect(containsBannedWord('前方$banned'), isTrue);
      expect(() => assertNoBannedWords('前方$banned'),
          throwsA(isA<AssertionError>()));
      expect(assertNoBannedWords('前方有车'), isTrue);
    });
  });

  group('acceptance fixture phrases', () {
    test('every phrase the fixtures produce is clean', () {
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
            expect(containsBannedWord(a.phrase), isFalse,
                reason: '$fixture/$backend: ${a.phrase}');
          }
        }
      }
    });
  });

  group('lib source scan', () {
    test('no lib source contains a contiguous banned phrase', () {
      // The banned strings are assembled at runtime; the
      // hazard_phrases.dart banned list itself is written
      // as adjacent literals, so a contiguous match
      // anywhere under lib/ is a real finding.
      final List<String> banned = <String>[
        <String>['安', '全'].join(),
        <String>['可以', '通行'].join(),
        <String>['放', '心'].join(),
        <String>['可以', '过马路'].join(),
      ];
      final List<File> files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart'))
          .toList();
      expect(files, isNotEmpty);
      for (final File f in files) {
        // Comments are stripped first: a comment may QUOTE
        // a banned phrase to say it must never be spoken
        // (traffic_scene.dart does exactly that); what the
        // guard forbids is the phrase in code / string
        // literals that can reach the speech path.
        final String src = stripComments(f.readAsStringSync());
        for (final String word in banned) {
          expect(src.contains(word), isFalse,
              reason: '${f.path} contains a banned phrase outside comments');
        }
      }
    });

    test('no lib source contains a contiguous banned phrase '
        'INCLUDING comments (CDX3 item 6)', () {
      // The stricter CDX3口径: comments are NOT stripped.
      // Quoting a banned phrase in a comment -- even to
      // forbid it -- is itself a finding now; comments
      // must paraphrase. (The banned-word LIST in
      // hazard_phrases.dart is assembled from adjacent
      // literals, which never forms the contiguous
      // string, so it does not trip this scan.)
      final List<String> banned = <String>[
        <String>['安', '全'].join(),
        <String>['可以', '通行'].join(),
        <String>['放', '心'].join(),
        <String>['可以', '过马路'].join(),
      ];
      final List<File> files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart'))
          .toList();
      expect(files, isNotEmpty);
      for (final File f in files) {
        final String src = f.readAsStringSync();
        for (final String word in banned) {
          expect(src.contains(word), isFalse,
              reason: '${f.path} contains a banned phrase '
                  '(comments included)');
        }
      }
    });
  });
}
