/// NAVHAZ M1, spec sections 2.6 / 2.7.8: speech
/// arbitration. Unit layer: the scheduler keeps interrupted
/// requests as objects (the id view stays compatible), and
/// NavigationTracker regenerates an interrupted turn from
/// the latest fix. Widget layer: the real app with a
/// recording fake TTS and a recording fake haptics on one
/// shared timeline -- danger interrupts a turn, vibration
/// precedes the danger voice, and the turn is replayed with
/// a RECOMPUTED distance once the danger finishes.
library;
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/core/haptics.dart';
import 'package:mingtu_ai/core/navigation_tracker.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/main.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';

// ---------------------------------------------------------------------------
// Shared route geometry for the tracker unit tests and the
// widget scenarios: A --200 m north--> B --100 m east--> C.
// ---------------------------------------------------------------------------
const GeoPoint kA = GeoPoint(latitude: 37.724409, longitude: 120.441723);
const GeoPoint kB = GeoPoint(latitude: 37.726206, longitude: 120.441723);
const GeoPoint kC = GeoPoint(latitude: 37.726206, longitude: 120.442859);

GeoPoint southOfB(double metres) => GeoPoint(
      latitude: kB.latitude! - metres / 111194.9,
      longitude: kB.longitude,
    );

GeoPoint eastOfB(double metres) => GeoPoint(
      latitude: kB.latitude,
      longitude: kB.longitude! + metres / 111194.9 / 0.7912,
    );

NavigationTracker buildTracker() {
  return NavigationTracker(
    steps: const <AmapStep>[
      AmapStep(
        action: '直行',
        orientation: '北',
        polyline: <GeoPoint>[kA, kB],
        distanceM: 200,
        durationS: 150,
      ),
      AmapStep(
        action: '右转',
        orientation: '东',
        polyline: <GeoPoint>[kB, kC],
        distanceM: 100,
        durationS: 75,
      ),
    ],
    stepTexts: const <String>['直行', '右转进入林荫道'],
    destination: kC,
    destinationName: '图书馆',
  );
}

NavFix fixAt(GeoPoint p) =>
    NavFix(point: p, accuracyM: 5, at: DateTime.now());

void main() {
  group('scheduler interrupted-request objects', () {
    SpeechRequest req(
      String id,
      SpeechKind kind, {
      NavReplay replay = NavReplay.drop,
      int? step,
    }) {
      final DateTime now = DateTime.now();
      return SpeechRequest(
        id: id,
        eventId: id,
        text: 'text-$id',
        kind: kind,
        createdAt: now,
        expiresAt: now.add(const Duration(minutes: 1)),
        navigationStateVersion: 'v',
        navStepIndex: step,
        replay: replay,
      );
    }

    test('interruption stores the object; the id view stays readable', () {
      final SpeechScheduler s = SpeechScheduler();
      final SpeechRequest turn =
          req('turn-1', SpeechKind.turn, replay: NavReplay.regenerate, step: 1);
      s.submit(turn, DateTime.now());
      expect(s.active?.id, 'turn-1');
      s.submit(req('danger-1', SpeechKind.danger), DateTime.now());
      expect(s.active?.id, 'danger-1');
      expect(s.interruptedRequests, hasLength(1));
      expect(s.interruptedRequests.single.navStepIndex, 1);
      expect(s.interruptedRequests.single.replay, NavReplay.regenerate);
      expect(s.interruptedLog, <String>['turn-1'],
          reason: 'the legacy id view is derived from the objects');
      expect(s.interruptedAtOf(turn), isNotNull);
    });

    test('only navigation items with a replay policy are arbitrable', () {
      final SpeechScheduler s = SpeechScheduler();
      s.submit(req('info-1', SpeechKind.info), DateTime.now());
      s.submit(req('danger-1', SpeechKind.danger), DateTime.now());
      // info has replay=drop: not arbitrable, but the
      // interruption itself stays on record.
      expect(s.interruptedNavigationRequests(), isEmpty);
      expect(s.interruptedLog, contains('info-1'));
      final SpeechRequest straight = req('straight-1', SpeechKind.straight,
          replay: NavReplay.shortenedReplay);
      s.completeActive();
      s.submit(straight, DateTime.now());
      s.submit(req('danger-2', SpeechKind.danger), DateTime.now());
      final List<SpeechRequest> nav = s.interruptedNavigationRequests();
      expect(nav.map((SpeechRequest r) => r.id), <String>['straight-1']);
      s.discardInterrupted(straight);
      expect(s.interruptedNavigationRequests(), isEmpty);
      expect(s.interruptedAtOf(straight), isNull);
    });
  });

  group('NavigationTracker.regenerateTurnPrompt', () {
    test('an emitted (even interrupted) turn regenerates with a fresh distance',
        () {
      final NavigationTracker tracker = buildTracker();
      final List<NavEvent> events = tracker.onFix(fixAt(southOfB(25)));
      final List<NavEvent> turns = events
          .where((NavEvent e) => e.kind == NavEventKind.turnAhead)
          .toList();
      expect(turns, hasLength(1));
      expect(turns.single.stepIndex, 1);
      // The spam guard still holds: no second event.
      expect(
        tracker
            .onFix(fixAt(southOfB(20)))
            .where((NavEvent e) => e.kind == NavEventKind.turnAhead),
        isEmpty,
      );
      // ...but regeneration does not consult that guard --
      // this is the fix for the swallowed-turn defect.
      final String? prompt =
          tracker.regenerateTurnPrompt(1, fixAt(southOfB(12)));
      expect(prompt, '前方约12米右转进入林荫道');
    });

    test('drops when the intersection is passed or too close', () {
      final NavigationTracker tracker = buildTracker();
      tracker.onFix(fixAt(southOfB(25)));
      // 65 m east of B: nearest route point is C, beyond the
      // step start -> the turn is behind the user.
      expect(tracker.regenerateTurnPrompt(1, fixAt(eastOfB(65))), isNull);
      // 2 m from the step start: too close to be useful.
      expect(tracker.regenerateTurnPrompt(1, fixAt(southOfB(2))), isNull);
      // No such step.
      expect(tracker.regenerateTurnPrompt(7, fixAt(southOfB(12))), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Widget layer (spec 2.7.8): the real app, a recording
  // fake TTS whose speaks stay "playing" until the test
  // completes them, and a recording fake haptics -- both on
  // ONE ordered timeline, so "vibration before voice" and
  // "physical stop between the two voices" are assertions
  // about observed order, not about source code.
  // -------------------------------------------------------------------------
  group('widget arbitration with fake TTS + fake vibration', () {
    final List<String> timeline = <String>[];
    final List<Completer<dynamic>> pendingSpeaks = <Completer<dynamic>>[];

    void installMocks() {
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('flutter_tts'),
        (MethodCall call) async {
          switch (call.method) {
            case 'getLanguages':
              return <String>['zh-CN', 'en-US'];
            case 'setLanguage':
              return 1;
            case 'speak':
              timeline.add('speak:${call.arguments}');
              final Completer<dynamic> c = Completer<dynamic>();
              pendingSpeaks.add(c);
              return c.future;
            case 'stop':
              timeline.add('stop');
              return 1;
            default:
              return 1;
          }
        },
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugin.csdcorp.com/speech_to_text'),
        (MethodCall call) async {
          if (call.method == 'initialize') return false;
          return null;
        },
      );
      messenger.setMockMethodCallHandler(SystemChannels.platform,
          (MethodCall call) async {
        return null;
      });
    }

    void clearMocks() {
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          const MethodChannel('flutter_tts'), null);
      messenger.setMockMethodCallHandler(
          const MethodChannel('plugin.csdcorp.com/speech_to_text'), null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    }

    Future<void> pumpFrames(WidgetTester tester, [int n = 3]) async {
      for (int i = 0; i < n; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    /// Complete every in-flight speak until the app goes
    /// quiet (each completion may promote the next prompt).
    Future<void> drainSpeaks(WidgetTester tester) async {
      for (int i = 0; i < 40; i++) {
        final List<Completer<dynamic>> pending = pendingSpeaks
            .where((Completer<dynamic> c) => !c.isCompleted)
            .toList();
        if (pending.isEmpty) {
          await pumpFrames(tester, 2);
          if (pendingSpeaks.every((Completer<dynamic> c) => c.isCompleted)) {
            return;
          }
          continue;
        }
        for (final Completer<dynamic> c in pending) {
          c.complete(1);
        }
        await pumpFrames(tester, 2);
      }
      fail('speaks did not drain');
    }

    Future<void> completeSpeak(WidgetTester tester, String marker) async {
      final int idx = timeline.lastIndexOf(marker);
      expect(idx, greaterThanOrEqualTo(0), reason: 'no such speak: $marker');
      // Speak calls and completers are appended in the same
      // order; complete the completer belonging to this one.
      final int speakOrdinal =
          timeline.sublist(0, idx + 1).where((String e) => e.startsWith('speak:')).length - 1;
      pendingSpeaks[speakOrdinal].complete(1);
      await pumpFrames(tester);
    }

    /// Bring the app up and into demo navigation, with all
    /// startup / planning speech drained.
    Future<MingtuHomeDebugHandle> startApp(WidgetTester tester) async {
      await tester.pumpWidget(const MingtuApp());
      await pumpFrames(tester);
      final MingtuHomeDebugHandle h = mingtuHomeDebugHandle!;
      h.debugSetHaptics(_FakeHaptics(timeline));
      await drainSpeaks(tester);
      h.startVoiceDemo();
      await drainSpeaks(tester);
      h.planRoute();
      await drainSpeaks(tester);
      h.startNavigating();
      await drainSpeaks(tester);
      return h;
    }

    void feedApproachingCar(MingtuHomeDebugHandle h) {
      // Five frames, box growing fast dead ahead: the
      // pipeline confirms on frame 3 and the scale TTC is
      // far below the urgent threshold (pitch is unknown in
      // the widget environment, so no ground range -- the
      // vehicle fallback in the policy covers exactly this).
      for (final double s in <double>[0.20, 0.32, 0.45, 0.60, 0.75]) {
        h.simulateDetections(<Detection>[
          Detection(
              label: 'car', confidence: 0.9, cx: 0.5, cy: 0.55, w: s, h: s),
        ]);
      }
    }

    setUp(() {
      timeline.clear();
      pendingSpeaks.clear();
      installMocks();
    });
    tearDown(clearMocks);

    testWidgets(
        '(a) danger interrupts a turn: vibration first, stop between, '
        'turn replayed with a recomputed distance', (tester) async {
      final MingtuHomeDebugHandle h = await startApp(tester);
      h.debugInstallLiveTracker(
        steps: buildTracker().steps,
        stepTexts: buildTracker().stepTexts,
        destination: kC,
        destinationName: '图书馆',
      );
      // 25 m out: the turn-ahead fires and starts speaking.
      h.debugLiveFix(southOfB(25), 5);
      await pumpFrames(tester);
      final int turnIdx = timeline.indexOf('speak:右转进入林荫道');
      expect(turnIdx, greaterThanOrEqualTo(0),
          reason: 'timeline: $timeline');
      // The user keeps walking while the turn plays.
      h.debugLiveFix(southOfB(12), 5);
      await pumpFrames(tester);
      // Danger: the urgent alert interrupts.
      feedApproachingCar(h);
      await pumpFrames(tester);
      final int vibIdx = timeline.indexOf('vibrate:urgent');
      final int dangerIdx = timeline.indexOf('speak:停，前方来车。');
      expect(vibIdx, greaterThanOrEqualTo(0), reason: 'timeline: $timeline');
      expect(dangerIdx, greaterThan(vibIdx),
          reason: 'vibration starts before the danger voice');
      expect(dangerIdx, greaterThan(turnIdx));
      expect(
        timeline.sublist(turnIdx + 1, dangerIdx),
        contains('stop'),
        reason: 'the turn playback is physically stopped '
            'before the danger voice starts',
      );
      // Danger finishes: the turn is replayed REGENERATED
      // from the latest fix -- 12 m, not the original 25 m.
      await completeSpeak(tester, 'speak:停，前方来车。');
      final int replayIdx = timeline.indexOf('speak:前方约12米右转进入林荫道');
      expect(replayIdx, greaterThan(dangerIdx),
          reason: 'timeline: $timeline');
      expect(
        timeline.where((String e) => e.contains('右转进入林荫道')).length,
        2,
        reason: 'original + regenerated replay, nothing else',
      );
      await drainSpeaks(tester);
    });

    testWidgets('(b) intersection passed during the danger: no replay',
        (tester) async {
      final MingtuHomeDebugHandle h = await startApp(tester);
      h.debugInstallLiveTracker(
        steps: buildTracker().steps,
        stepTexts: buildTracker().stepTexts,
        destination: kC,
        destinationName: '图书馆',
      );
      h.debugLiveFix(southOfB(25), 5);
      await pumpFrames(tester);
      expect(timeline, contains('speak:右转进入林荫道'));
      feedApproachingCar(h);
      await pumpFrames(tester);
      expect(timeline, contains('speak:停，前方来车。'));
      // While the danger plays, the user walks PAST the
      // intersection (nearest route point is now C).
      h.debugLiveFix(eastOfB(65), 5);
      await pumpFrames(tester);
      await completeSpeak(tester, 'speak:停，前方来车。');
      await pumpFrames(tester, 5);
      expect(
        timeline.where((String e) => e.startsWith('speak:前方约')).length,
        0,
        reason: 'a passed turn is dropped, never replayed late. '
            'timeline: $timeline',
      );
      await drainSpeaks(tester);
    });

    testWidgets('(c) straight interrupted by danger replays shortened',
        (tester) async {
      await tester.pumpWidget(const MingtuApp());
      await pumpFrames(tester);
      final MingtuHomeDebugHandle h = mingtuHomeDebugHandle!;
      h.debugSetHaptics(_FakeHaptics(timeline));
      await drainSpeaks(tester);
      h.startVoiceDemo();
      await drainSpeaks(tester);
      h.planRoute();
      await drainSpeaks(tester);
      h.startNavigating();
      await pumpFrames(tester);
      // The nav-start straight prompt is now PLAYING (its
      // completer is deliberately left open).
      expect(timeline, contains('speak:直走'));
      feedApproachingCar(h);
      await pumpFrames(tester);
      expect(timeline, contains('speak:停，前方来车。'));
      await completeSpeak(tester, 'speak:停，前方来车。');
      expect(timeline, contains('speak:继续直走'),
          reason: 'the shortened straight replay. timeline: $timeline');
      await drainSpeaks(tester);
    });

    testWidgets('(d) urgent replaces a playing warning immediately',
        (tester) async {
      final MingtuHomeDebugHandle h = await startApp(tester);
      // Static near person: W after 3 confirmed frames.
      for (int i = 0; i < 3; i++) {
        h.simulateDetections(const <Detection>[
          Detection(
              label: 'person',
              confidence: 0.9,
              cx: 0.5,
              cy: 0.7,
              w: 0.2,
              h: 0.4),
        ]);
      }
      await pumpFrames(tester);
      // M2-B item 2: the static person's warning has no
      // range in the widget harness (no pitch), so its
      // full sentence is the no-range clock form, not
      // the old null-range zone form.
      final int warnIdx =
          timeline.indexOf('speak:注意，十二点钟方向，行人靠近。');
      expect(warnIdx, greaterThanOrEqualTo(0),
          reason: 'timeline: $timeline');
      expect(timeline, contains('vibrate:warning'));
      // The warning is still playing when the car arrives:
      // the urgent alert replaces it without waiting.
      feedApproachingCar(h);
      await pumpFrames(tester);
      final int dangerIdx = timeline.indexOf('speak:停，前方来车。');
      expect(dangerIdx, greaterThan(warnIdx),
          reason: 'timeline: $timeline');
      final int warnOrdinal = timeline
              .sublist(0, warnIdx + 1)
              .where((String e) => e.startsWith('speak:'))
              .length -
          1;
      expect(pendingSpeaks[warnOrdinal].isCompleted, isFalse,
          reason: 'the warning never finished -- it was replaced');
      await drainSpeaks(tester);
    });
  });
}

/// Recording haptics on the test's shared timeline.
class _FakeHaptics implements Haptics {
  final List<String> timeline;
  _FakeHaptics(this.timeline);

  @override
  Future<void> vibrateUrgent() async {
    timeline.add('vibrate:urgent');
  }

  @override
  Future<void> vibrateWarning() async {
    timeline.add('vibrate:warning');
  }

  @override
  Future<void> vibratePattern(List<int> timings, List<int> amplitudes) async {
    timeline.add('vibrate:pattern');
  }
}
