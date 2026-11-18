/// The "what do I do next?" calculation, pinned case by case.
///
/// Product target this file defends: after the destination is
/// spoken the user hears ONE actionable instruction, and it is
/// only allowed to name a direction when the phone's compass
/// agrees with the route. The catastrophic failure mode being
/// ruled out is telling a blind user "turn left" while they are
/// facing the other way, or saying nothing at all because the
/// heading was unknown.
///
/// Every fixture here is local: hand-built polylines, hand-fed
/// fixes, no GPS, no network, no key.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/core/entrance_guidance.dart' show compassWords;
import 'package:mingtu_ai/core/guidance/route_instruction.dart';
import 'package:mingtu_ai/core/hazard/hazard_phrases.dart';
import 'package:mingtu_ai/core/navigation_tracker.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';

// ---------------------------------------------------------------------------
// Geometry: A --200 m north--> B --100 m west--> C  (so step 1 is a LEFT
// turn: walking north, then west). A second route gives a right turn.
// ---------------------------------------------------------------------------
const GeoPoint kA = GeoPoint(latitude: 37.724409, longitude: 120.441723);

GeoPoint northOf(GeoPoint p, double metres) => GeoPoint(
      latitude: p.latitude! + metres / 111194.9,
      longitude: p.longitude,
    );

GeoPoint westOf(GeoPoint p, double metres) => GeoPoint(
      latitude: p.latitude,
      longitude: p.longitude! - metres / 111194.9 / 0.7912,
    );

GeoPoint southOf(GeoPoint p, double metres) => GeoPoint(
      latitude: p.latitude! - metres / 111194.9,
      longitude: p.longitude,
    );

final GeoPoint kB = northOf(kA, 200);
final GeoPoint kC = westOf(kB, 100);

/// Heading that agrees with the leg A -> B (the user walks
/// north).
const double kHeadingAheadNorth = 0;

/// Heading perpendicular to that leg.
const double kHeadingSidewaysEast = 90;

/// Heading exactly opposite.
const double kHeadingReversedSouth = 180;

NavigationTracker buildTracker({
  String secondAction = '左转',
  String firstAction = '直行',
}) {
  return NavigationTracker(
    steps: <AmapStep>[
      AmapStep(
        action: firstAction,
        orientation: '北',
        polyline: <GeoPoint>[kA, kB],
        distanceM: 200,
        durationS: 150,
      ),
      AmapStep(
        action: secondAction,
        orientation: '西',
        polyline: <GeoPoint>[kB, kC],
        distanceM: 100,
        durationS: 75,
      ),
    ],
    stepTexts: const <String>['直行', '左转'],
    destination: kC,
    destinationName: '图书馆',
  );
}

/// Drive the tracker with one fix so `currentStepIndex` reflects
/// the same reality the production fix handler would produce.
void feed(NavigationTracker nav, GeoPoint p) {
  nav.onFix(NavFix(point: p, accuracyM: 5, at: DateTime(2026, 1, 1, 12)));
}

RouteInstruction? instructionFor(
  NavigationTracker nav,
  GeoPoint fix, {
  double? accuracyM = 5,
  double? headingDeg,
  bool firstInstruction = false,
}) {
  if (accuracyM != null && accuracyM <= NavigationTracker.weakAccuracyM) {
    feed(nav, fix);
  }
  return nextRouteInstruction(
    nav: nav,
    fix: fix,
    accuracyM: accuracyM,
    headingDeg: headingDeg,
    firstInstruction: firstInstruction,
  );
}

void main() {
  group('position evidence', () {
    test('no fix at all pauses guidance instead of guessing', () {
      final RouteInstruction? r = nextRouteInstruction(
        nav: buildTracker(),
        fix: null,
        accuracyM: 5,
        headingDeg: kHeadingAheadNorth,
      );
      expect(r, isNotNull);
      expect(r!.kind, SpeechKind.alert);
      expect(r.match, InstructionMatch.positionUnclear);
      expect(r.text, positionUnknownSpeech);
      expect(r.text, contains('导航暂停'));
    });

    test('a 60 m accuracy fix pauses guidance and is an alert', () {
      final RouteInstruction? r = nextRouteInstruction(
        nav: buildTracker(),
        fix: southOf(kB, 25),
        accuracyM: 60,
        headingDeg: kHeadingAheadNorth,
      );
      expect(r, isNotNull);
      expect(r!.kind, SpeechKind.alert);
      expect(r.match, InstructionMatch.positionUnclear);
      expect(r.text, weakAccuracySpeech);
    });

    test('a null accuracy fix pauses guidance too', () {
      final RouteInstruction? r = nextRouteInstruction(
        nav: buildTracker(),
        fix: southOf(kB, 25),
        accuracyM: null,
        headingDeg: kHeadingAheadNorth,
      );
      expect(r!.kind, SpeechKind.alert);
      expect(r.match, InstructionMatch.positionUnclear);
    });
  });

  group('heading decides whether a direction may be named', () {
    test('heading agrees: the action is named, with the distance', () {
      final NavigationTracker nav = buildTracker();
      final RouteInstruction r =
          instructionFor(nav, southOf(kB, 25), headingDeg: kHeadingAheadNorth)!;
      expect(r.kind, SpeechKind.turn);
      expect(r.match, InstructionMatch.matched);
      expect(r.text, '前方约30米左转');
      expect(r.text, contains('左转'));
    });

    test('heading unknown: NO left / right / straight-ahead, asks to stop', () {
      final NavigationTracker nav = buildTracker();
      final RouteInstruction r = instructionFor(nav, southOf(kB, 25))!;
      expect(r.kind, SpeechKind.turn);
      expect(r.match, InstructionMatch.headingUnknown);
      expect(r.text, isNot(contains('左转')));
      expect(r.text, isNot(contains('右转')));
      expect(r.text, isNot(contains('直行')));
      expect(r.text, isNot(contains('直走')));
      expect(r.text, contains('无法确认你的朝向'));
      expect(r.text, contains('请先停下'));
    });

    test('heading 90 degrees off: no left turn is claimed', () {
      final NavigationTracker nav = buildTracker();
      final RouteInstruction r = instructionFor(nav, southOf(kB, 25),
          headingDeg: kHeadingSidewaysEast)!;
      expect(r.kind, SpeechKind.turn);
      expect(r.match, InstructionMatch.headingConflict);
      expect(r.text, isNot(contains('左转')));
      expect(r.text, contains('朝向可能和路线不一致'));
    });

    test('heading 180 degrees off: says the user may be facing away', () {
      final NavigationTracker nav = buildTracker();
      final RouteInstruction r = instructionFor(nav, southOf(kB, 25),
          headingDeg: kHeadingReversedSouth)!;
      expect(r.kind, SpeechKind.turn);
      expect(r.match, InstructionMatch.headingConflict);
      expect(r.text, backFacingSpeech);
      expect(r.text, contains('背对路线'));
      expect(r.text, isNot(contains('左转')));
    });

    test('a right turn is named only when the heading agrees', () {
      final NavigationTracker nav = buildTracker(secondAction: '右转');
      final RouteInstruction matched = instructionFor(nav, southOf(kB, 25),
          headingDeg: kHeadingAheadNorth)!;
      expect(matched.text, contains('右转'));
      final NavigationTracker nav2 = buildTracker(secondAction: '右转');
      final RouteInstruction unknown = instructionFor(nav2, southOf(kB, 25))!;
      expect(unknown.text, isNot(contains('右转')));
    });
  });

  group('upstream action strings', () {
    test('an unknown action never reaches the sentence', () {
      final NavigationTracker nav = buildTracker(secondAction: '');
      final RouteInstruction r =
          instructionFor(nav, southOf(kB, 25), headingDeg: kHeadingAheadNorth)!;
      expect(r.match, InstructionMatch.headingUnknown);
      expect(r.text, '前方约30米$headingUnknownTurnSpeech');
      // The turn class is kept: the user DOES have to change
      // direction, only the name of the direction is unknown.
      expect(r.kind, SpeechKind.turn);
    });

    test('a provider-specific token is treated as unknown, not spliced', () {
      final NavigationTracker nav = buildTracker(secondAction: '斜穿马路进入辅路');
      final RouteInstruction r = instructionFor(nav, southOf(kB, 25),
          headingDeg: kHeadingAheadNorth)!;
      expect(r.text, isNot(contains('斜穿马路')));
      expect(r.match, InstructionMatch.headingUnknown);
    });
  });

  group('never points back', () {
    test('a turn already passed is not announced again', () {
      final NavigationTracker nav = buildTracker();
      // 65 m east (here: west) of B along step 1 -- the turn is
      // behind the user.
      final GeoPoint past = westOf(kB, 65);
      final RouteInstruction r = instructionFor(nav, past)!;
      expect(r.text, isNot(contains('左转')));
      expect(r.text, contains('继续直走'));
    });

    test('a mid-leg position reports the distance to the maneuver', () {
      final NavigationTracker nav = buildTracker();
      final RouteInstruction r =
          instructionFor(nav, southOf(kB, 100), headingDeg: kHeadingAheadNorth)!;
      expect(r.kind, SpeechKind.straight);
      expect(r.match, InstructionMatch.matched);
      expect(r.text, '继续直走，约100米后需要改变方向。');
    });

    test('a reversed heading on a straight leg is reported, not walked on', () {
      final NavigationTracker nav = buildTracker();
      final RouteInstruction r = instructionFor(nav, southOf(kB, 100),
          headingDeg: kHeadingReversedSouth)!;
      expect(r.kind, SpeechKind.straight);
      expect(r.match, InstructionMatch.headingConflict);
      expect(r.text, headingMismatchStraightSpeech);
      expect(r.text, isNot(contains('继续直走')));
    });

    test('with no heading the straight leg asks for cane confirmation', () {
      final NavigationTracker nav = buildTracker();
      final RouteInstruction r = instructionFor(nav, southOf(kB, 100))!;
      expect(r.kind, SpeechKind.straight);
      expect(r.match, InstructionMatch.headingUnknown);
      expect(r.text, headingUnknownStraightSpeech);
    });
  });

  group('the opening instruction', () {
    test('standing at the route start says 开始导航, not 前方0米', () {
      final NavigationTracker nav = buildTracker();
      final RouteInstruction r =
          instructionFor(nav, kA, firstInstruction: true)!;
      expect(r.kind, SpeechKind.straight);
      expect(r.match, InstructionMatch.matched);
      expect(r.text, '开始导航，先直走约200米');
      expect(r.text, isNot(contains('前方')));
      expect(r.text, isNot(contains('约0米')));
      expect(r.text, isNot(contains('约1米')));
    });

    test('the opening wording needs the start position', () {
      final NavigationTracker nav = buildTracker();
      // 100 m along the first leg: the normal rules apply again.
      final RouteInstruction r = instructionFor(nav, southOf(kB, 100),
          firstInstruction: true, headingDeg: kHeadingAheadNorth)!;
      expect(r.text, isNot(startsWith('开始导航')));
      expect(r.text, contains('继续直走'));
    });

    test('a start whose first action is a turn is not named without heading',
        () {
      final NavigationTracker nav =
          buildTracker(firstAction: '左转', secondAction: '直行');
      final RouteInstruction r =
          instructionFor(nav, kA, firstInstruction: true)!;
      expect(r.text, isNot(contains('开始导航，先左转')));
    });
  });

  group('wording rules for every instruction this module can produce', () {
    // The full reachable set, driven from the same fixtures as
    // above plus the destination leg.
    List<RouteInstruction> allInstructions() {
      final List<RouteInstruction> out = <RouteInstruction>[];
      final List<double?> headings = <double?>[
        null,
        kHeadingAheadNorth,
        kHeadingSidewaysEast,
        kHeadingReversedSouth,
      ];
      final List<GeoPoint> points = <GeoPoint>[
        kA,
        southOf(kB, 100),
        southOf(kB, 25),
        kB,
        westOf(kB, 65),
      ];
      for (final double? h in headings) {
        for (final GeoPoint p in points) {
          final RouteInstruction? normal =
              instructionFor(buildTracker(), p, headingDeg: h);
          if (normal != null) out.add(normal);
          final RouteInstruction? opening = instructionFor(buildTracker(), p,
              headingDeg: h, firstInstruction: true);
          if (opening != null) out.add(opening);
        }
      }
      final RouteInstruction? noFix = nextRouteInstruction(
        nav: buildTracker(),
        fix: null,
        accuracyM: 5,
        headingDeg: null,
      );
      if (noFix != null) out.add(noFix);
      final RouteInstruction? weak = nextRouteInstruction(
        nav: buildTracker(),
        fix: kA,
        accuracyM: 80,
        headingDeg: null,
      );
      if (weak != null) out.add(weak);
      return out;
    }

    test('the fixture set is not empty (sanity)', () {
      expect(allInstructions(), isNotEmpty);
    });

    test('no segment numbering, no compass point as an action', () {
      for (final RouteInstruction r in allInstructions()) {
        expect(RegExp(r'第\s*\d+\s*段').hasMatch(r.text), isFalse,
            reason: r.text);
        expect(r.text, isNot(contains('共')), reason: r.text);
        for (final String compass in compassWords) {
          expect(r.text, isNot(contains(compass)), reason: r.text);
        }
        expect(r.text, isNot(contains('正东')), reason: r.text);
        expect(r.text, isNot(contains('正西')), reason: r.text);
      }
    });

    test('no banned announcement word and no raw coordinate', () {
      for (final RouteInstruction r in allInstructions()) {
        expect(containsBannedWord(r.text), isFalse, reason: r.text);
        expect(RegExp(r'\d{2,3}\.\d+').hasMatch(r.text), isFalse,
            reason: r.text);
        expect(r.text, isNot(contains('://')), reason: r.text);
      }
    });

    test('guidance is never the info class', () {
      for (final RouteInstruction r in allInstructions()) {
        expect(r.kind, isNot(SpeechKind.info), reason: r.text);
      }
    });
  });

  group('distance wording reuses the shared formatter', () {
    test('the distance readout is the navigation band text', () {
      for (final double metres in <double>[3, 12, 25, 100, 420]) {
        expect(navigationDistanceText(metres), isNotEmpty);
      }
      // The template embeds the SAME readout production uses;
      // 25 m rounds to the 10 m band's 30.
      expect('前方${navigationDistanceText(25)}左转', '前方约30米左转');
    });
  });
}
