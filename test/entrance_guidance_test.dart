import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/core/entrance_guidance.dart';
import 'package:mingtu_ai/core/navigation_tracker.dart';
import 'package:mingtu_ai/core/orientation.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';

/// Step D: entrance guidance after the route ends. Fixtures
/// only: the destination is the verified library point
/// (GCJ-02), and approach points are built by latitude
/// offsets along the meridian, where one metre is
/// 180 / (pi * 6371000) degrees -- the same earth radius the
/// production haversine uses, so distances are exact.
const GeoPoint library = GeoPoint(latitude: 37.723667, longitude: 120.443212);
const GeoPoint gate = GeoPoint(latitude: 37.724409, longitude: 120.441723);

const double _degPerMetre = 180.0 / (3.141592653589793 * 6371000.0);

/// A point [metres] due south of the library (so the library
/// bears due north from it).
GeoPoint southOfLibrary(double metres) => GeoPoint(
      latitude: library.latitude! - metres * _degPerMetre,
      longitude: library.longitude,
    );

void main() {
  group('bearing and the eight compass words', () {
    test('due north / south / east / west', () {
      expect(bearingDegrees(southOfLibrary(100), library), closeTo(0, 1));
      expect(
          compassWord(bearingDegrees(southOfLibrary(100), library)), '正北');
      const GeoPoint northOf = GeoPoint(
          latitude: 37.724667, longitude: 120.443212);
      expect(bearingDegrees(northOf, library), closeTo(180, 1));
      expect(compassWord(bearingDegrees(northOf, library)), '正南');
      const GeoPoint westOf = GeoPoint(
          latitude: 37.723667, longitude: 120.441712);
      expect(bearingDegrees(westOf, library), closeTo(90, 2));
      expect(compassWord(bearingDegrees(westOf, library)), '正东');
      const GeoPoint eastOf = GeoPoint(
          latitude: 37.723667, longitude: 120.444712);
      expect(bearingDegrees(eastOf, library), closeTo(270, 2));
      expect(compassWord(bearingDegrees(eastOf, library)), '正西');
    });

    test('northeast diagonal', () {
      const GeoPoint southWest = GeoPoint(
          latitude: 37.722667, longitude: 120.441712);
      final double b = bearingDegrees(southWest, library);
      expect(b, inInclusiveRange(25, 65));
      expect(compassWord(b), '东北');
    });

    test('sector boundaries sit at 22.5 degrees', () {
      expect(compassWord(0), '正北');
      expect(compassWord(22.4), '正北');
      expect(compassWord(22.5), '东北');
      expect(compassWord(67.5), '正东');
      expect(compassWord(337.4), '西北');
      expect(compassWord(337.5), '正北');
      expect(compassWord(359.9), '正北');
    });
  });

  group('EntranceGuidance announcements', () {
    final DateTime t0 = DateTime(2026, 1, 1, 12);
    EntranceGuidance make() =>
        EntranceGuidance(destinationName: '图书馆', destination: library);

    test('first trusted fix speaks the full first announcement', () {
      final EntranceGuidance g = make();
      final String? text = g.onFix(southOfLibrary(55), 10, t0);
      expect(text, isNotNull);
      expect(text, contains('已到达图书馆附近，继续为你指引入口方向。'));
      // No heading was passed, so the announcement is
      // distance only -- no direction clause at all (a
      // direction clause now appears only as a RELATIVE
      // direction with a fresh heading; see below).
      expect(text, contains('还剩约50米。'));
      expect(text, isNot(contains('入口大致在')));
      expect(text, contains('请以盲杖探测和现场声音为准。'));
      expect(g.completed, isFalse);
      expect(g.lastDistanceM, closeTo(55, 0.5));
    });

    test(
        'throttle: same distance, small change, and short '
        'interval all stay silent', () {
      final EntranceGuidance g = make();
      expect(g.onFix(southOfLibrary(55), 10, t0), isNotNull);
      // Same distance, plenty of time: no distance change.
      expect(
          g.onFix(southOfLibrary(55), 10,
              t0.add(const Duration(seconds: 30))),
          isNull);
      // 8 m closer (< announceEveryM): still silent.
      expect(
          g.onFix(southOfLibrary(47), 10,
              t0.add(const Duration(seconds: 30))),
          isNull);
      // 11 m closer and 30 s later: speaks the short update.
      final String? text = g.onFix(
          southOfLibrary(44), 10, t0.add(const Duration(seconds: 30)));
      expect(text, '还剩约40米。');
    });

    test('distance change without the interval stays silent', () {
      final EntranceGuidance g = make();
      expect(g.onFix(southOfLibrary(55), 10, t0), isNotNull);
      // 15 m change but only 10 s (< 15 s) since the last one.
      expect(
          g.onFix(southOfLibrary(40), 10,
              t0.add(const Duration(seconds: 10))),
          isNull);
      // Same point once the interval has passed: speaks.
      expect(
          g.onFix(southOfLibrary(40), 10,
              t0.add(const Duration(seconds: 16))),
          '还剩约40米。');
    });

    test('untrusted fixes never produce numbers', () {
      final EntranceGuidance g = make();
      expect(g.onFix(southOfLibrary(40), null, t0), isNull);
      expect(g.onFix(southOfLibrary(40), 80, t0), isNull);
      expect(g.lastDistanceM, isNull);
      // A trusted fix still counts as the FIRST announcement.
      final String? text = g.onFix(southOfLibrary(40), 40, t0);
      expect(text, contains('继续为你指引入口方向'));
      expect(text, contains('还剩约40米'));
    });

    test('distances are spoken rounded down to 10 m steps', () {
      final EntranceGuidance g = make();
      final String? text = g.onFix(southOfLibrary(43), 10, t0);
      expect(text, contains('还剩约40米'));
      expect(EntranceGuidance.roundedDistanceM(59), 50);
      expect(EntranceGuidance.roundedDistanceM(60), 60);
      expect(EntranceGuidance.roundedDistanceM(40), 40);
      expect(EntranceGuidance.roundedDistanceM(39.5), 30);
    });

    test('arrival radius completes, once, with the completion line', () {
      final EntranceGuidance g = make();
      final String? text = g.onFix(southOfLibrary(12), 10, t0);
      expect(text, entranceArrivedSpeech);
      expect(text, contains('小途已完成任务'));
      expect(text, contains('入口的具体位置请通过盲杖探测'));
      expect(g.completed, isTrue);
      // After completion the module is done: always null.
      expect(g.onFix(southOfLibrary(5), 10, t0), isNull);
      expect(g.onFix(southOfLibrary(50), 10, t0), isNull);
    });

    test('just outside the arrival radius still guides', () {
      final EntranceGuidance g = make();
      final String? text = g.onFix(southOfLibrary(16), 10, t0);
      expect(text, isNot(entranceArrivedSpeech));
      expect(g.completed, isFalse);
    });

    test(
        'startAnnouncement has the opening line but no '
        'distance claim', () {
      final EntranceGuidance g = make();
      final String text = g.startAnnouncement();
      expect(text, contains('已到达图书馆附近，继续为你指引入口方向。'));
      expect(text, isNot(contains('还剩约')));
    });
  });

  group('relative direction words (Step D adjustment)', () {
    test('the six sector centres', () {
      expect(EntranceGuidance.relativeDirectionWord(0), '前方');
      expect(EntranceGuidance.relativeDirectionWord(60), '右前方');
      expect(EntranceGuidance.relativeDirectionWord(112), '右侧');
      expect(EntranceGuidance.relativeDirectionWord(180), '身后');
      expect(EntranceGuidance.relativeDirectionWord(247), '左侧');
      expect(EntranceGuidance.relativeDirectionWord(303), '左前方');
    });

    test('sector boundaries follow natural language', () {
      // Ahead/behind own +/-45 degrees around 0/180; each
      // side quadrant splits at 45 degrees from the side
      // axis (the project lead's examples: +80 is the right
      // SIDE -- the destination is beside the user, not
      // front-right -- and -80 is the left side).
      expect(EntranceGuidance.relativeDirectionWord(44), '前方');
      expect(EntranceGuidance.relativeDirectionWord(45), '右前方');
      expect(EntranceGuidance.relativeDirectionWord(80), '右侧');
      expect(EntranceGuidance.relativeDirectionWord(89), '右侧');
      expect(EntranceGuidance.relativeDirectionWord(-80), '左侧');
      expect(EntranceGuidance.relativeDirectionWord(-90), '左侧');
      expect(EntranceGuidance.relativeDirectionWord(134), '右侧');
      expect(EntranceGuidance.relativeDirectionWord(135), '身后');
      expect(EntranceGuidance.relativeDirectionWord(269), '左侧');
      expect(EntranceGuidance.relativeDirectionWord(292), '左侧');
      expect(EntranceGuidance.relativeDirectionWord(293), '左前方');
    });

    test(
        'end to end through onFix: heading rotates the '
        'relative direction', () {
      final DateTime t0 = DateTime(2026, 1, 1, 12);
      EntranceGuidance make() =>
          EntranceGuidance(destinationName: '图书馆', destination: library);
      // Standing 25 m due south of the library: the
      // destination bears due north (0 degrees).
      final String? ahead =
          make().onFix(southOfLibrary(25), 10, t0, headingDeg: 0);
      expect(ahead, contains('入口大致在前方'));
      final String? behind =
          make().onFix(southOfLibrary(25), 10, t0, headingDeg: 180);
      expect(behind, contains('入口大致在身后'));
      expect(behind, contains('身后'));
      // Heading 90 (facing east): relative bearing is
      // 0 - 90 = -90, squarely the left SIDE sector.
      final String? side =
          make().onFix(southOfLibrary(25), 10, t0, headingDeg: 90);
      expect(side, contains('入口大致在左侧'));
    });
  });

  group('heading freshness (Step D adjustment)', () {
    test(
        'a heading sample is fresh at 400 ms and stale at '
        '600 ms; a stale heading announces distance only', () {
      final DateTime t0 = DateTime(2026, 1, 1, 12);
      final HeadingTracker tracker = HeadingTracker();
      tracker.addSample(90, t0);
      expect(tracker.headingAt(t0.add(const Duration(milliseconds: 400))),
          90);
      expect(tracker.headingAt(t0.add(const Duration(milliseconds: 600))),
          isNull);

      // The caller passes headingDeg only when headingAt is
      // non-null; with the expired sample it passes null
      // and the announcement carries no direction clause.
      final EntranceGuidance g =
          EntranceGuidance(destinationName: '图书馆', destination: library);
      final String? text = g.onFix(southOfLibrary(25), 10, t0,
          headingDeg:
              tracker.headingAt(t0.add(const Duration(milliseconds: 600))));
      expect(text, contains('还剩约'));
      expect(text, isNot(contains('入口大致在')));
    });
  });

  group('tracker hand-over', () {
    NavigationTracker makeTracker() => NavigationTracker(
          steps: const <AmapStep>[
            AmapStep(
              action: '直行',
              orientation: '南',
              polyline: <GeoPoint>[gate, library],
              distanceM: 180,
              durationS: 150,
            ),
          ],
          stepTexts: const <String>['直行。'],
          destination: library,
          destinationName: '图书馆',
        );
    NavFix fix(GeoPoint p, double acc) => NavFix(
          point: p,
          accuracyM: acc,
          at: DateTime(2026, 1, 1, 12),
        );

    test(
        'hand-over needs BOTH <= 30 m and accuracy <= 20 m: '
        '50 m does not fire, 28 m with accuracy 10 fires once',
        () {
      final NavigationTracker t = makeTracker();
      // ~50 m out with a good fix: inside the OLD 60 m
      // radius but outside the adjusted 30 m one -- no
      // arrived event (ordinary route processing only).
      final List<NavEvent> ev50 = t.onFix(fix(southOfLibrary(50), 10));
      expect(ev50.where((NavEvent e) => e.kind == NavEventKind.arrived),
          isEmpty);
      expect(t.arrived, isFalse);
      // 28 m with accuracy 10: hand-over fires, exactly
      // once.
      final List<NavEvent> ev = t.onFix(fix(southOfLibrary(28), 10));
      expect(ev.single.kind, NavEventKind.arrived);
      expect(ev.single.text, contains('已到达图书馆附近'));
      expect(t.arrived, isTrue);
      // Once handed over, no further route events at all.
      expect(t.onFix(fix(southOfLibrary(28), 10)), isEmpty);
      expect(t.onFix(fix(southOfLibrary(80), 10)), isEmpty);
    });

    test(
        'the accuracy gate alone can hold the hand-over: '
        '25 m with accuracy 30 waits, accuracy 15 hands over',
        () {
      final NavigationTracker t = makeTracker();
      final List<NavEvent> coarse = t.onFix(fix(southOfLibrary(25), 30));
      expect(
          coarse.where((NavEvent e) => e.kind == NavEventKind.arrived),
          isEmpty);
      expect(t.arrived, isFalse);
      // Same distance, accuracy now good enough: the gate
      // was the accuracy, not the position.
      final List<NavEvent> fine = t.onFix(fix(southOfLibrary(25), 15));
      expect(fine.single.kind, NavEventKind.arrived);
      expect(t.arrived, isTrue);
    });
  });

  group('production wiring (source)', () {
    final String mainDart = File('lib/main.dart').readAsStringSync();
    final String guidanceDart =
        File('lib/core/entrance_guidance.dart').readAsStringSync();

    test('main runs the entrance phase and ends the trip from it', () {
      expect(mainDart, contains('EntranceGuidance('));
      expect(mainDart, contains('_entranceActive'));
      expect(mainDart, contains('_handleEntranceFix'));
      expect(mainDart, contains('_finishEntranceTrip'));
      expect(mainDart, contains('入口指引中'));
    });

    test(
        'the arrived branch starts guidance and does not ask '
        'for the next destination itself', () {
      final int start = mainDart.indexOf('case NavEventKind.arrived:');
      final int end = mainDart.indexOf('case NavEventKind.offRoute:');
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final String branch = mainDart.substring(start, end);
      expect(branch, contains('EntranceGuidance('));
      expect(branch, contains('_entranceActive = true'));
      expect(branch, isNot(contains('_askDestination')));
      // The tracker's neutral hand-over text is not spoken.
      expect(branch, isNot(contains('text: e.text')));
    });

    test('the completion line lives in lib/', () {
      expect(guidanceDart, contains('小途已完成任务'));
      expect(guidanceDart, contains('entranceArrivedSpeech'));
    });
  });
}
