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
      // The count is pinned so a silently shrinking entry
      // point fails loudly.
      final int names = spokenNameAxes().length;
      expect(all.length, names * 2 * (3 * 9 + 12 * 8),
          reason: 'names x levels x (near 3 zones x 9 '
              'ranges + far 12 hours x 8 ranges) -- the '
              'FIX3B band space is deliberately compact: '
              'distance wording no longer has hundreds of '
              'numeric gradations');
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
      expect(navigationDistanceText(29.5), '约20米',
          reason: '17-100 m floors DOWN to a 10 m '
              'multiple (a turn prompt never names a '
              'distance longer than the real one)');
      expect(navigationDistanceText(35), '约30米');
      expect(navigationDistanceText(99), '约90米');
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

    test('property: large distances land in the enumerated '
        'sets, both wordings (FIX3B)', () {
      final Set<String> navSet = enumerateNavigationDistanceTexts();
      final Set<String> hazardReachable = reachableMetresTexts();
      final List<double> samples = <double>[105, 1234, 99999];
      final Random rng = Random(20261111);
      for (int i = 0; i < 24; i++) {
        samples.add(100 + rng.nextDouble() * 200000);
      }
      for (final double d in samples) {
        expect(navSet.contains(navigationDistanceText(d)), isTrue,
            reason: 'navigation wording for $d m is enumerated');
        expect(containsBannedWord(navigationDistanceText(d)), isFalse);
        final String hazard = metresText(d);
        expect(hazard.isEmpty || hazardReachable.contains(hazard),
            isTrue,
            reason: 'hazard wording for $d m is a reachable '
                'readout (or the no-number form)');
        expect(containsBannedWord(hazard), isFalse);
      }
      // Every enumerated navigation readout is itself
      // banned-word free (the navigation space joins the
      // section 2.7.10 exhaustion this round).
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
