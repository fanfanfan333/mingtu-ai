/// Arrival wording must be graded by EVIDENCE, not by distance.
///
/// A phone GPS fix near a building can be off by tens of
/// metres. Reaching the 15 m arrival radius with a 30 m
/// accuracy fix is not evidence that the user is at the door:
/// the radius may have been met by the error alone. The task
/// still ends there (there is nothing better to navigate to),
/// but the sentence must say "it may be nearby, I cannot
/// confirm it" instead of "you have arrived".
///
/// The forbidden claims below are the ones that would make a
/// blind user stop looking for a door that is not there:
/// "已确认到达", "已经找到入口", "到了门口".
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/entrance_guidance.dart';
import 'package:mingtu_ai/core/hazard/hazard_phrases.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';

const GeoPoint kDestination =
    GeoPoint(latitude: 37.724409, longitude: 120.441723);

/// A point [metres] due south of the destination (the approach
/// leg of the entrance phase).
GeoPoint southOfDestination(double metres) => GeoPoint(
      latitude: kDestination.latitude! - metres / 111194.9,
      longitude: kDestination.longitude,
    );

EntranceGuidance makeGuidance() =>
    EntranceGuidance(destinationName: '图书馆', destination: kDestination);

/// Claims no arrival wording may ever make.
const List<String> forbiddenArrivalClaims = <String>[
  '已确认到达',
  '已经找到入口',
  '到了门口',
];

void main() {
  final DateTime t0 = DateTime(2026, 1, 1, 12);

  group('the evidence threshold', () {
    test('confidence is a 15 m accuracy gate, distinct from the radius', () {
      expect(EntranceGuidance.confidentArrivalAccuracyM, 15.0);
      expect(EntranceGuidance.confidentArrivalAccuracyM,
          EntranceGuidance.arriveRadiusM);
      expect(EntranceGuidance.isConfidentArrival(10), isTrue);
      expect(EntranceGuidance.isConfidentArrival(15), isTrue);
      expect(EntranceGuidance.isConfidentArrival(15.1), isFalse);
      expect(EntranceGuidance.isConfidentArrival(30), isFalse);
      expect(EntranceGuidance.isConfidentArrival(null), isFalse);
    });
  });

  group('at the arrival radius', () {
    test('a 10 m fix states the arrival', () {
      final String? text = makeGuidance().onFix(southOfDestination(12), 10, t0);
      expect(text, entranceArrivedSpeech);
      expect(text, contains('已到达目的地附近'));
      expect(text, contains('入口的具体位置请通过盲杖探测或向身边的人确认。'));
    });

    test('a 30 m fix refuses to confirm the arrival', () {
      final String? text = makeGuidance().onFix(southOfDestination(12), 30, t0);
      expect(text, entranceVicinityUncertainSpeech);
      expect(text, contains('不能确认到达'));
      expect(text, isNot(contains('已到达目的地附近')));
      expect(text, contains('盲杖探测或询问身边的人'));
    });

    test('neither sentence may claim a confirmed doorway', () {
      final String? confident =
          makeGuidance().onFix(southOfDestination(12), 10, t0);
      final String? uncertain =
          makeGuidance().onFix(southOfDestination(12), 30, t0);
      for (final String text in <String>[confident!, uncertain!]) {
        for (final String claim in forbiddenArrivalClaims) {
          expect(text, isNot(contains(claim)), reason: text);
        }
        expect(containsBannedWord(text), isFalse, reason: text);
      }
    });
  });

  group('the first entrance announcement is graded the same way', () {
    test('a trusted fix opens with the plain arrival sentence', () {
      final String? text =
          makeGuidance().onFix(southOfDestination(55), 10, t0);
      expect(text, contains('已到达图书馆附近，继续为你指引入口方向。'));
      expect(text, contains('还剩约50米。'));
      expect(text, isNot(contains('不能确认到达')));
    });

    test('a coarse fix opens with the hedge instead', () {
      final String? text =
          makeGuidance().onFix(southOfDestination(55), 30, t0);
      expect(text, contains('不能确认到达'));
      expect(text, isNot(contains('已到达图书馆附近')));
      // The phase still guides: the distance and the cane
      // boundary are both there.
      expect(text, contains('还剩约50米'));
      expect(text, contains('请以盲杖探测和现场声音为准'));
    });

    test('a stale heading still announces the distance alone', () {
      final String? text =
          makeGuidance().onFix(southOfDestination(55), 30, t0);
      expect(text, isNot(contains('入口大致在')));
    });
  });

  group('the source itself carries no confirmed-doorway wording', () {
    test('entrance_guidance.dart contains none of the forbidden claims', () {
      final String source =
          File('lib/core/entrance_guidance.dart').readAsStringSync();
      for (final String claim in forbiddenArrivalClaims) {
        expect(source, isNot(contains(claim)), reason: claim);
      }
      // The honesty boundary is stated in words, not implied.
      expect(source, contains('盲杖'));
    });
  });
}
