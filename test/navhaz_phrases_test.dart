/// NAVHAZ M1, spec sections 0.1 / 2.4 / 2.7.10: no spoken
/// text may grant or imply passage. The check runs over
/// the FULL cross-product of the hazard-phrase templates
/// (levels x zones x clock positions x ranges x item
/// names), over every phrase the acceptance fixtures
/// produce, and over the lib/ sources themselves (string
/// literals must not contain a banned word; the banned
/// list itself is assembled from adjacent literals so this
/// scan stays clean by construction).
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
    test('full expansion contains no banned word', () {
      final List<String> labels = <String>[
        'person', 'car', 'truck', 'bus', 'motorcycle', 'bicycle', 'pole',
        'chair', 'unknown-thing',
      ];
      final List<double> cxs = <double>[
        0.0, 0.2, 0.33, 0.5, 0.67, 0.85, 1.0,
      ];
      final List<double?> ranges = <double?>[
        null, 0.8, 1.5, 2.5, 3.0, 4.2, 5.0, 7.0, 9.6, 12.0, 20.0, 33.0,
      ];
      int count = 0;
      for (final String label in labels) {
        for (final double cx in cxs) {
          for (final double? range in ranges) {
            for (final bool urgent in <bool>[true, false]) {
              final HazardKind kind =
                  hazardKindForLabel(label) ?? HazardKind.clutter;
              final String phrase = hazardPhrase(
                urgent: urgent,
                name: hazardSpokenName(label, kind),
                isVehicle: kind == HazardKind.motorVehicle ||
                    kind == HazardKind.nonMotorVehicle,
                cx: cx,
                rangeM: range,
              );
              count++;
              expect(containsBannedWord(phrase), isFalse,
                  reason: 'phrase "$phrase" (label=$label cx=$cx '
                      'range=$range urgent=$urgent)');
              expect(phrase.startsWith(urgent ? '停，' : '注意，'), isTrue,
                  reason: 'template shape: $phrase');
            }
          }
        }
      }
      expect(count, labels.length * cxs.length * ranges.length * 2);
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
