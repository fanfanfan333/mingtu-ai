import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/main.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/adapters/current_location.dart';
import 'package:mingtu_ai/core/asr_errors.dart';
import 'package:mingtu_ai/core/danger_alerts.dart';
import 'package:mingtu_ai/core/destination_dialogue.dart';
import 'package:mingtu_ai/core/navigation_tracker.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';

/// Step 2 voice navigation flow: destination dialogue, live
/// tracking over a simulated GPS track, danger alerts, and
/// the ASR error whitelist. All fixtures -- no real API, no
/// real GPS.
void main() {
  group('destination dialogue', () {
    test('the question is asked verbatim', () {
      expect(destinationAskText, '你要去哪里？请说出目的地。');
    });

    test('plain and prefixed answers resolve to the library', () {
      expect(resolveDestinationAnswer('图书馆')?.id, 'library');
      expect(resolveDestinationAnswer('去图书馆')?.id, 'library');
      expect(resolveDestinationAnswer('我想去图书馆。')?.id, 'library');
      expect(resolveDestinationAnswer('带我去图书馆')?.id, 'library');
    });

    test('the school gate resolves by name and alias', () {
      expect(resolveDestinationAnswer('校门口')?.id, 'school-gate');
      expect(resolveDestinationAnswer('学校大门')?.id, 'school-gate');
    });

    test('unknown places are NEVER guessed', () {
      expect(resolveDestinationAnswer('火车站'), isNull);
      expect(resolveDestinationAnswer(''), isNull);
      expect(resolveDestinationAnswer('随便走走'), isNull);
    });

    test(
        're-ask and give-up texts list real choices and '
        'contain no safety promise', () {
      expect(destinationNotFoundText(), contains('图书馆'));
      expect(destinationNotFoundText(), isNot(contains('安全')));
      expect(destinationGiveUpText(), contains('停止询问'));
    });
  });

  group('navigation tracker over a simulated track', () {
    const GeoPoint gate = GeoPoint(latitude: 37.724409, longitude: 120.441723);
    const GeoPoint mid = GeoPoint(latitude: 37.724409, longitude: 120.442723);
    const GeoPoint library =
        GeoPoint(latitude: 37.723667, longitude: 120.443212);
    final List<AmapStep> steps = <AmapStep>[
      const AmapStep(
        action: '直行',
        orientation: '东',
        polyline: <GeoPoint>[gate, mid],
        distanceM: 89,
        durationS: 70,
      ),
      const AmapStep(
        action: '左转',
        orientation: '南',
        polyline: <GeoPoint>[mid, library],
        distanceM: 93,
        durationS: 80,
      ),
    ];
    NavigationTracker tracker() => NavigationTracker(
          steps: steps,
          stepTexts: const <String>['第一段：向东直行。', '第二段：左转，往南走。'],
          destination: library,
          destinationName: '图书馆',
        );
    NavFix fix(GeoPoint p, {double acc = 10}) => NavFix(
          point: p,
          accuracyM: acc,
          at: DateTime(2026, 1, 1, 12),
        );

    test('start: remaining is the whole route, no events', () {
      final NavigationTracker t = tracker();
      final List<NavEvent> ev = t.onFix(fix(gate));
      expect(ev, isEmpty);
      expect(t.remainingM!, greaterThan(150));
    });

    test('approaching the turn point announces the next step', () {
      final NavigationTracker t = tracker();
      t.onFix(fix(gate));
      // ~9 m west of the turn point: inside the 30 m window.
      final List<NavEvent> ev = t.onFix(
          fix(const GeoPoint(latitude: 37.724409, longitude: 120.442623)));
      expect(ev, hasLength(1));
      expect(ev.single.kind, NavEventKind.turnAhead);
      expect(ev.single.stepIndex, 1);
      expect(ev.single.text, '第二段：左转，往南走。');
      // Announced once only.
      expect(t.onFix(fix(mid)), isEmpty);
    });

    test('arrival fires once at the destination', () {
      final NavigationTracker t = tracker();
      final List<NavEvent> ev = t.onFix(fix(library));
      expect(ev.single.kind, NavEventKind.arrived);
      expect(ev.single.text, contains('已到达图书馆附近'));
      expect(t.onFix(fix(library)), isEmpty);
    });

    test(
        'sustained off-route fires once; reroute gate '
        'throttles and exhausts', () {
      final NavigationTracker t = tracker();
      const GeoPoint farNorth =
          GeoPoint(latitude: 37.725500, longitude: 120.441723);
      expect(t.onFix(fix(farNorth)), isEmpty); // streak 1
      final List<NavEvent> ev = t.onFix(fix(farNorth)); // streak 2
      expect(ev.single.kind, NavEventKind.offRoute);
      final DateTime t0 = DateTime(2026, 1, 1, 12);
      expect(t.rerouteDecision(t0), RerouteDecision.doIt);
      expect(
        t.rerouteDecision(t0.add(const Duration(seconds: 30))),
        RerouteDecision.throttled,
      );
      expect(
        t.rerouteDecision(t0.add(const Duration(seconds: 61))),
        RerouteDecision.doIt,
      );
      expect(
        t.rerouteDecision(t0.add(const Duration(seconds: 122))),
        RerouteDecision.doIt,
      );
      expect(
        t.rerouteDecision(t0.add(const Duration(seconds: 183))),
        RerouteDecision.exhausted,
      );
    });

    test(
        'weak GPS is announced, throttled, and derives no '
        'turns', () {
      final NavigationTracker t = tracker();
      final NavFix weak = NavFix(
        point: mid,
        accuracyM: 80,
        at: DateTime(2026, 1, 1, 12),
      );
      expect(t.onFix(weak).single.kind, NavEventKind.weakSignal);
      expect(
        t.onFix(NavFix(
          point: mid,
          accuracyM: 80,
          at: DateTime(2026, 1, 1, 12, 0, 30),
        )),
        isEmpty,
      );
    });
  });

  group('danger alerts', () {
    test('categories and texts', () {
      expect(dangerCategoryFor('car'), DangerCategory.vehicle);
      expect(dangerCategoryFor('truck'), DangerCategory.vehicle);
      expect(dangerCategoryFor('bicycle'), DangerCategory.vehicle);
      expect(dangerCategoryFor('person'), DangerCategory.person);
      expect(dangerCategoryFor('dog'), DangerCategory.other);
      expect(dangerTextFor(DangerCategory.vehicle), '前方有车，请停下。');
      expect(dangerTextFor(DangerCategory.person), '前方有人，请停下。');
      expect(
        dangerTextFor(DangerCategory.other, otherName: '行人'),
        '前方检测到行人，请停下。',
      );
    });

    test('the gate cools a category down for 10 seconds', () {
      final DangerAlertGate gate = DangerAlertGate();
      final DateTime t0 = DateTime(2026, 1, 1, 12);
      expect(gate.tryPass(DangerCategory.vehicle, t0), isTrue);
      expect(
        gate.tryPass(
            DangerCategory.vehicle, t0.add(const Duration(seconds: 5))),
        isFalse,
      );
      expect(
        gate.tryPass(
            DangerCategory.vehicle, t0.add(const Duration(seconds: 11))),
        isTrue,
      );
      // A different category is not blocked by the vehicle.
      expect(
        gate.tryPass(DangerCategory.person, t0.add(const Duration(seconds: 5))),
        isTrue,
      );
    });
  });

  group('ASR error whitelist', () {
    test('known codes survive; raw platform strings collapse', () {
      expect(asrErrorCode('error_permission'), 'error_permission');
      expect(asrErrorCode('error_no_match'), 'error_no_match');
      expect(
        asrErrorCode('a raw platform sentence with details'),
        'error_unknown',
      );
      expect(asrErrorCode(''), 'error_unknown');
    });

    test('every code has a fixed Chinese text', () {
      expect(asrErrorText('error_permission'), contains('权限'));
      expect(asrErrorText('error_unknown'), '语音识别出错。');
      for (final String code in knownAsrErrorCodes) {
        expect(asrErrorText(code), isNot(contains('error_')));
      }
    });
  });

  group(
      'location provider defaults (permission-denied '
      'degradation seam)', () {
    test('unavailable provider: permission refused, no stream', () async {
      const UnavailableCurrentLocation p = UnavailableCurrentLocation();
      expect(await p.ensurePermission(), isFalse);
      expect(await p.positions().isEmpty, isTrue);
    });
  });

  group('voice-first home (widget)', () {
    testWidgets(
        'the big status line and the two big companion '
        'buttons lead the page', (WidgetTester tester) async {
      await tester.pumpWidget(const MingtuApp());
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 1500));
      }
      // Big status (TalkBack live region): idle app shows 明途.
      expect(find.text('明途'), findsOneWidget);
      expect(
        find.widgetWithText(ElevatedButton, '停下'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(ElevatedButton, '重新问目的地'),
        findsOneWidget,
      );
    });
  });

  group('production wiring (source level)', () {
    final String mainDart = File('lib/main.dart').readAsStringSync();

    test(
        'speech pauses listening first, via the single choke '
        'point', () {
      final int speakActive = mainDart.indexOf('void _speakActive');
      final int pause = mainDart.indexOf('_pauseListeningForSpeech();');
      expect(speakActive, greaterThanOrEqualTo(0));
      expect(pause, greaterThan(speakActive));
      expect(mainDart, contains('unawaited(_kickoffVoiceNavFlow'));
      expect(mainDart, contains('_locationProvider.ensurePermission()'));
      expect(
          mainDart, contains('_beginLiveNavigation(outcome, destinationName)'));
      expect(mainDart, contains('_answerDestination(text)'));
      expect(mainDart, contains('SpeechKind.alert'));
    });
  });
}
