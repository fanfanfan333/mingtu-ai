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
      // Every spoken item name: the five hazardKindName
      // values plus every label name the detector
      // vocabulary maps to (an unknown label falls back
      // to its kind name -- deduplicated by the set).
      final Map<String, bool> names = <String, bool>{};
      for (final HazardKind kind in HazardKind.values) {
        names[hazardKindName(kind)] =
            kind == HazardKind.motorVehicle ||
                kind == HazardKind.nonMotorVehicle;
      }
      for (final String label in <String>[
        'car', 'truck', 'bus', 'motorcycle', 'bicycle', 'person',
        'pole', 'mystery-box',
      ]) {
        final HazardKind kind =
            hazardKindForLabel(label) ?? HazardKind.clutter;
        names[hazardSpokenName(label, kind)] =
            kind == HazardKind.motorVehicle ||
                kind == HazardKind.nonMotorVehicle;
      }
      // Near direction forms: the three zones.
      const List<double> nearCxs = <double>[0.1, 0.5, 0.9];
      // Far direction forms: all twelve clock hours, one
      // centre-x per hour offset (-5..+6).
      final List<double> farCxs = <double>[
        for (int offset = -5; offset <= 6; offset++) 0.5 + offset * 30.0 / 70.0,
      ];
      // Near metre domain: unknown range plus every
      // half metre up to the near-wording limit.
      final List<double?> nearRanges = <double?>[
        null,
        for (double r = 0.5; r <= 5.0; r += 0.5) r,
      ];
      // Far metre domain: the boundary just past the near
      // limit, every whole metre 6..10, and every 5 m step
      // the readout can produce up to 100 m.
      final List<double> farRanges = <double>[
        5.5,
        for (double r = 6; r <= 10; r += 1) r,
        for (double r = 15; r <= 100; r += 5) r,
      ];
      final Set<String> zonesSeen = <String>{};
      final Set<String> clocksSeen = <String>{};
      final Set<String> metresSeen = <String>{};
      int count = 0;
      void check(String phrase, bool urgent) {
        count++;
        expect(containsBannedWord(phrase), isFalse,
            reason: 'banned word in "$phrase"');
        expect(phrase.startsWith(urgent ? '停，' : '注意，'), isTrue,
            reason: 'template shape: $phrase');
      }

      for (final MapEntry<String, bool> name in names.entries) {
        for (final bool urgent in <bool>[true, false]) {
          for (final double cx in nearCxs) {
            for (final double? range in nearRanges) {
              final String phrase = hazardPhrase(
                urgent: urgent,
                name: name.key,
                isVehicle: name.value,
                cx: cx,
                rangeM: range,
              );
              zonesSeen.add(zoneName(cx));
              if (range != null) metresSeen.add(metresText(range));
              check(phrase, urgent);
            }
          }
          for (final double cx in farCxs) {
            for (final double range in farRanges) {
              final String phrase = hazardPhrase(
                urgent: urgent,
                name: name.key,
                isVehicle: name.value,
                cx: cx,
                rangeM: range,
              );
              clocksSeen.add('${clockHour(cx)}');
              metresSeen.add(metresText(range));
              check(phrase, urgent);
            }
          }
        }
      }
      // The enumeration really covered the whole space:
      final int expected = names.length *
          2 *
          (nearCxs.length * nearRanges.length +
              farCxs.length * farRanges.length);
      expect(count, expected);
      expect(zonesSeen, <String>{'左边', '前方', '右边'});
      expect(clocksSeen.length, 12,
          reason: 'all twelve clock hours were produced');
      expect(metresSeen.length, greaterThanOrEqualTo(28),
          reason: 'near half-metres, 1..10 m and the 5 m '
              'steps were all produced: $metresSeen');
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
      expect(metresText(9.6), '十米');
      expect(metresText(12.0), '十米',
          reason: 'beyond 10 m the readout steps by 5');
      expect(metresText(13.0), '15米');
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
  });
}
