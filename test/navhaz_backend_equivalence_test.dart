/// NAVHAZ M1, spec section 2.7.9: the two tracker backends
/// must produce the SAME alert timeline on the same
/// fixture -- same levels in the same order, timestamps
/// within one frame (100 ms).
///
/// Phrases are compared after normalising the metre
/// readout: the spoken metres are a ROUNDED rendering of a
/// continuous range estimate, and two legitimate smoothing
/// chains may straddle a rounding boundary (9.6 m vs
/// 10.4 m speak as different metre counts while describing
/// the same event). The metre VALUES are additionally
/// asserted to differ by at most one rounding step, so the
/// normalisation cannot hide a real divergence.
library;
import 'package:flutter_test/flutter_test.dart';

import 'navhaz_fixture_harness.dart';

final RegExp _metrePattern = RegExp(r'[一二三四五六七八九十百零0-9]+米');

String normalisePhrase(String phrase) =>
    phrase.replaceAll(_metrePattern, 'N米');

int? spokenMetres(String phrase) {
  final RegExpMatch? m = _metrePattern.firstMatch(phrase);
  if (m == null) return null;
  const Map<String, int> digits = <String, int>{
    '零': 0, '一': 1, '二': 2, '三': 3, '四': 4,
    '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
  };
  final String text = m.group(0)!.replaceAll('米', '');
  final int? arabic = int.tryParse(text);
  if (arabic != null) return arabic;
  if (!text.contains('十')) return digits[text];
  final List<String> parts = text.split('十');
  final int tens = parts[0].isEmpty ? 1 : digits[parts[0]]!;
  final int ones =
      parts.length > 1 && parts[1].isNotEmpty ? digits[parts[1]]! : 0;
  return tens * 10 + ones;
}

void main() {
  for (final String fixture in <String>[
    'approaching_car.jsonl',
    'jitter_car.jsonl',
    'crossing_pedestrian.jsonl',
    'side_pass_car.jsonl',
    'flicker_person.jsonl',
  ]) {
    test('$fixture: byteTrack and SORT timelines agree', () {
      final FixtureRun a = runFixture(fixture, 'bytetrack');
      final FixtureRun b = runFixture(fixture, 'sort');
      expect(a.alerts.length, b.alerts.length,
          reason: 'alert count differs: '
              '${a.alerts.map((x) => '${x.tMs}/${x.level.name}').toList()} vs '
              '${b.alerts.map((x) => '${x.tMs}/${x.level.name}').toList()}');
      for (int i = 0; i < a.alerts.length; i++) {
        expect(a.alerts[i].level, b.alerts[i].level,
            reason: 'alert $i level');
        expect((a.alerts[i].tMs - b.alerts[i].tMs).abs(),
            lessThanOrEqualTo(100),
            reason: 'alert $i must land within one frame');
        expect(normalisePhrase(a.alerts[i].phrase),
            normalisePhrase(b.alerts[i].phrase),
            reason: 'alert $i phrase (modulo metre rounding)');
        final int? ma = spokenMetres(a.alerts[i].phrase);
        final int? mb = spokenMetres(b.alerts[i].phrase);
        if (ma != null && mb != null) {
          expect((ma - mb).abs(), lessThanOrEqualTo(5),
              reason: 'alert $i metre readouts within one rounding step');
        }
      }
    });
  }
}
