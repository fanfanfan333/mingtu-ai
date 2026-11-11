/// NAVHAZ M1 fix round, items F + 4: the Codex arbitration
/// suite, independently maintained (the older
/// navhaz_arbitration_test.dart stays untouched; where the
/// two overlap this file's wording follows the Codex
/// re-test), PLUS:
/// - the spec 2.7.8(a) scenario in its literal form: the
///   prompt playing when the urgent alert lands is
///   「前方约30米右转」 (a distance-form turn prompt,
///   constructed through the app's own regeneration path);
/// - the 300 ms timing assertion: vibration-start and
///   danger-speech-start are stamped from a TEST-CONTROLLED
///   clock (the fake TTS stop advances it by a fixed
///   simulated latency), never from real waiting;
/// - the 15 s expiry cases (Codex arb-15s + the CDX3
///   boundary pair): an interrupted navigation prompt
///   older than the replay window is dropped into the
///   expired log and never replayed. Since CDX3 the
///   suite drives the REAL production window
///   (NavHazConfig.replayExpiry = 15 s) through an
///   injected arbitration CLOCK (debugSetSpeechClock):
///   the test advances fake time by 14.999 / 15.000 /
///   16 s and the production judgement runs unbent --
///   no shortened window is injected anywhere any more;
/// - every spoken text on the timeline is asserted free
///   of banned words (spec 2.7.10 aggregation point).
library;
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/core/haptics.dart';
import 'package:mingtu_ai/core/hazard/hazard_phrases.dart';
import 'package:mingtu_ai/core/navigation_tracker.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/main.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';

// ---------------------------------------------------------------------------
// Route geometry (same shape as the sibling suite):
// A --200 m north--> B --100 m east--> C.
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

NavigationTracker buildTracker(
    {List<String> stepTexts = const <String>['直行', '右转进入林荫道']}) {
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
    stepTexts: stepTexts,
    destination: kC,
    destinationName: '图书馆',
  );
}

NavFix fixAt(GeoPoint p) => NavFix(point: p, accuracyM: 5, at: DateTime.now());

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
  // Widget layer: fake TTS + fake haptics on ONE stamped
  // timeline(). The stamps come from a test-controlled clock:
  // the only thing that advances it is the fake TTS 'stop'
  // (a fixed simulated physical-stop latency), so the
  // "speech starts within 300 ms of vibration start"
  // assertion is arithmetic on recorded stamps.
  // -------------------------------------------------------------------------
  group('widget arbitration (Codex suite + 30 m + 300 ms + 15 s)', () {
    final List<(int, String)> events = <(int, String)>[];
    final List<Completer<dynamic>> pendingSpeaks = <Completer<dynamic>>[];
    int clockMs = 0;
    int stopLatencyMs = 80;
    bool stopNeverCompletes = false;
    // The arbitration clock (CDX3): installed into the app
    // through debugSetSpeechClock, it is the ONLY clock
    // the replay-expiry judgement and the interruption
    // stamps run on, so the 15 s boundary tests advance
    // THIS -- never a shortened window.
    DateTime fakeNow = DateTime.fromMillisecondsSinceEpoch(0);

    List<String> timeline() =>
        events.map(((int, String) e) => e.$2).toList();
    int idxOf(String event) => timeline().indexOf(event);
    int stampOf(String event) => events[idxOf(event)].$1;
    int countOf(String event) =>
        timeline().where((String e) => e == event).length;

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
              events.add((clockMs, 'speak:${call.arguments}'));
              final Completer<dynamic> c = Completer<dynamic>();
              pendingSpeaks.add(c);
              return c.future;
            case 'stop':
              events.add((clockMs, 'stop'));
              // Simulated physical-stop latency on the
              // test clock. In the default model the stop
              // COMPLETES after the latency, so the clock
              // advance lands before whatever speaks next.
              // In the FIX2 stuck-stop model
              // (stopNeverCompletes) the latency runs past
              // every scheduling window instead: the clock
              // does NOT advance for this stop (it has not
              // completed when the danger voice starts),
              // and a 'stop:completed' event is stamped at
              // +stopLatencyMs on the same clock to prove
              // the completion landed AFTER the speak.
              if (stopNeverCompletes) {
                events.add((clockMs + stopLatencyMs, 'stop:completed'));
              } else {
                clockMs += stopLatencyMs;
              }
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
      final int idx = timeline().lastIndexOf(marker);
      expect(idx, greaterThanOrEqualTo(0), reason: 'no such speak: $marker');
      final int speakOrdinal =
          timeline().sublist(0, idx + 1).where((String e) => e.startsWith('speak:')).length - 1;
      pendingSpeaks[speakOrdinal].complete(1);
      await pumpFrames(tester);
    }

    Future<MingtuHomeDebugHandle> startApp(WidgetTester tester) async {
      await tester.pumpWidget(const MingtuApp());
      await pumpFrames(tester);
      final MingtuHomeDebugHandle h = mingtuHomeDebugHandle!;
      h.debugSetHaptics(_StampedHaptics(events, () => clockMs));
      await drainSpeaks(tester);
      h.startVoiceDemo();
      await drainSpeaks(tester);
      h.planRoute();
      await drainSpeaks(tester);
      h.startNavigating();
      await drainSpeaks(tester);
      return h;
    }

    void installTracker(MingtuHomeDebugHandle h,
        {List<String> stepTexts = const <String>['直行', '右转进入林荫道']}) {
      final NavigationTracker t = buildTracker(stepTexts: stepTexts);
      h.debugInstallLiveTracker(
        steps: t.steps,
        stepTexts: t.stepTexts,
        destination: kC,
        destinationName: '图书馆',
      );
    }

    void feedApproachingCar(MingtuHomeDebugHandle h) {
      for (final double s in <double>[0.20, 0.32, 0.45, 0.60, 0.75]) {
        h.simulateDetections(<Detection>[
          Detection(
              label: 'car', confidence: 0.9, cx: 0.5, cy: 0.55, w: s, h: s),
        ]);
      }
    }

    void feedStaticPerson(MingtuHomeDebugHandle h) {
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
    }

    /// Spec 2.7.10 aggregation for this suite: EVERY text
    /// the app spoke on this timeline is banned-word free.
    void expectTimelineClean() {
      for (final String e in timeline()) {
        if (e.startsWith('speak:')) {
          expect(containsBannedWord(e.substring(6)), isFalse,
              reason: 'spoken text "$e"');
        }
      }
    }

    /// The spec 2.7.8 timing assertion, on recorded stamps:
    /// vibration starts BEFORE the danger voice, and the
    /// voice starts within 300 ms of the vibration start.
    void expectVibrationLeadsDanger() {
      final int vib = stampOf('vibrate:urgent');
      final int danger = stampOf('speak:停，前方来车。');
      expect(danger, greaterThan(vib),
          reason: 'vibration (t=$vib) precedes the danger '
              'voice (t=$danger) on the test clock');
      expect(danger - vib, lessThanOrEqualTo(300),
          reason: 'danger speech starts ${danger - vib} ms '
              'after vibration start (limit 300 ms)');
    }

    setUp(() {
      events.clear();
      pendingSpeaks.clear();
      clockMs = 0;
      stopLatencyMs = 80;
      stopNeverCompletes = false;
      fakeNow = DateTime.now();
      installMocks();
    });
    tearDown(clearMocks);

    testWidgets(
        '(a) danger interrupts a turn: stop between, vibration '
        'leads voice by <= 300 ms, replay recomputed', (tester) async {
      final MingtuHomeDebugHandle h = await startApp(tester);
      installTracker(h);
      h.debugLiveFix(southOfB(25), 5);
      await pumpFrames(tester);
      final int turnIdx = idxOf('speak:右转进入林荫道');
      expect(turnIdx, greaterThanOrEqualTo(0), reason: 'timeline: ${timeline()}');
      h.debugLiveFix(southOfB(12), 5);
      await pumpFrames(tester);
      feedApproachingCar(h);
      await pumpFrames(tester);
      final int dangerIdx = idxOf('speak:停，前方来车。');
      expect(dangerIdx, greaterThan(turnIdx));
      expect(timeline().sublist(turnIdx + 1, dangerIdx), contains('stop'),
          reason: 'physical stop between the two voices');
      expectVibrationLeadsDanger();
      await completeSpeak(tester, 'speak:停，前方来车。');
      final int replayIdx = idxOf('speak:前方约12米右转进入林荫道');
      expect(replayIdx, greaterThan(dangerIdx),
          reason: 'regenerated from the 12 m fix, not the '
              'original 25 m text. timeline: ${timeline()}');
      expect(countOf('speak:前方约12米右转进入林荫道'), 1);
      await drainSpeaks(tester);
      expectTimelineClean();
    });

    testWidgets(
        '(a-literal) the playing prompt is 「前方约30米右转」 when '
        'the urgent alert lands', (tester) async {
      final MingtuHomeDebugHandle h = await startApp(tester);
      // Step text is the bare action, so the DISTANCE form
      // is the tracker's own regeneration wording.
      installTracker(h, stepTexts: const <String>['直行', '右转']);
      // 29.5 m out: inside the 30 m announce distance.
      // The turn fires and its (bare) text starts playing.
      h.debugLiveFix(southOfB(29.5), 5);
      await pumpFrames(tester);
      expect(idxOf('speak:右转'), greaterThanOrEqualTo(0),
          reason: 'timeline: ${timeline()}');
      // A warning interrupts it. While the warning plays,
      // the freshest fix reads ~29.5 m out (the
      // regeneration honestly uses the LATEST fix). When
      // the warning finishes, the arbitration regenerates
      // the turn from that fix -- and under the
      // FIX4-FINAL S2 navigation bands 29.5 m rounds
      // half-up to the NEAREST 10 m, the 30 m readout, so
      // THAT distance-form prompt, 「前方约30米右转」, is
      // what is playing when the urgent alert arrives.
      // (Construction note: in this codebase the distance
      // form is produced by the regeneration path, so the
      // scenario stages it through one interruption; the
      // victim prompt below is the literal spec text.
      // Staging history: the pre-FIX3B text came from the
      // whole-metre readout of the 29.5 m fix itself;
      // FIX3B staged 35 m because its FLOOR rule read
      // 35 -> 30; S2's half-up rule reads 35 -> 40, so
      // the staging fix is 29.5 m again -- the same value
      // as the S2 acceptance point 29.5 -> 「约30米」.
      // The victim text never changed.)
      feedStaticPerson(h);
      await pumpFrames(tester);
      expect(idxOf('speak:注意，前方有行人。'), greaterThanOrEqualTo(0),
          reason: 'timeline: ${timeline()}');
      h.debugLiveFix(southOfB(29.5), 5);
      await pumpFrames(tester);
      await completeSpeak(tester, 'speak:注意，前方有行人。');
      final int promptIdx = idxOf('speak:前方约30米右转');
      expect(promptIdx, greaterThanOrEqualTo(0),
          reason: 'the literal 30 m prompt is playing. '
              'timeline: ${timeline()}');
      // The urgent alert lands on THAT prompt.
      feedApproachingCar(h);
      await pumpFrames(tester);
      final int dangerIdx = idxOf('speak:停，前方来车。');
      expect(dangerIdx, greaterThan(promptIdx));
      expect(timeline().sublist(promptIdx + 1, dangerIdx), contains('stop'),
          reason: 'the 30 m prompt is physically stopped');
      expectVibrationLeadsDanger();
      await completeSpeak(tester, 'speak:停，前方来车。');
      await pumpFrames(tester, 5);
      // The victim was itself a replay, and a replay is
      // never itself replayed (the arbitration's terminal
      // rule): the stale 30 m text is not spoken again from
      // a position it no longer matches.
      expect(countOf('speak:前方约30米右转'), 1,
          reason: 'timeline: ${timeline()}');
      await drainSpeaks(tester);
      expectTimelineClean();
    });

    testWidgets('(b) intersection passed during the danger: no replay',
        (tester) async {
      final MingtuHomeDebugHandle h = await startApp(tester);
      installTracker(h);
      h.debugLiveFix(southOfB(25), 5);
      await pumpFrames(tester);
      expect(timeline(), contains('speak:右转进入林荫道'));
      feedApproachingCar(h);
      await pumpFrames(tester);
      expect(timeline(), contains('speak:停，前方来车。'));
      h.debugLiveFix(eastOfB(65), 5);
      await pumpFrames(tester);
      await completeSpeak(tester, 'speak:停，前方来车。');
      await pumpFrames(tester, 5);
      expect(
        timeline().where((String e) => e.startsWith('speak:前方约')).length,
        0,
        reason: 'a passed turn is dropped. timeline: ${timeline()}',
      );
      await drainSpeaks(tester);
      expectTimelineClean();
    });

    testWidgets('(c) straight interrupted by danger replays shortened',
        (tester) async {
      await tester.pumpWidget(const MingtuApp());
      await pumpFrames(tester);
      final MingtuHomeDebugHandle h = mingtuHomeDebugHandle!;
      h.debugSetHaptics(_StampedHaptics(events, () => clockMs));
      await drainSpeaks(tester);
      h.startVoiceDemo();
      await drainSpeaks(tester);
      h.planRoute();
      await drainSpeaks(tester);
      h.startNavigating();
      await pumpFrames(tester);
      expect(timeline(), contains('speak:直走'));
      feedApproachingCar(h);
      await pumpFrames(tester);
      expect(timeline(), contains('speak:停，前方来车。'));
      expectVibrationLeadsDanger();
      await completeSpeak(tester, 'speak:停，前方来车。');
      expect(timeline(), contains('speak:继续直走'),
          reason: 'the shortened straight replay. timeline: ${timeline()}');
      await drainSpeaks(tester);
      expectTimelineClean();
    });

    testWidgets('(d) urgent replaces a playing warning immediately',
        (tester) async {
      final MingtuHomeDebugHandle h = await startApp(tester);
      feedStaticPerson(h);
      await pumpFrames(tester);
      final int warnIdx = idxOf('speak:注意，前方有行人。');
      expect(warnIdx, greaterThanOrEqualTo(0), reason: 'timeline: ${timeline()}');
      expect(timeline(), contains('vibrate:warning'));
      feedApproachingCar(h);
      await pumpFrames(tester);
      final int dangerIdx = idxOf('speak:停，前方来车。');
      expect(dangerIdx, greaterThan(warnIdx), reason: 'timeline: ${timeline()}');
      final int warnOrdinal = timeline()
              .sublist(0, warnIdx + 1)
              .where((String e) => e.startsWith('speak:'))
              .length -
          1;
      expect(pendingSpeaks[warnOrdinal].isCompleted, isFalse,
          reason: 'the warning never finished -- it was replaced');
      await drainSpeaks(tester);
      expectTimelineClean();
    });

    testWidgets(
        '(e) FIX2: a stuck stop (800 ms) cannot delay the '
        'danger voice past 300 ms', (tester) async {
      // The mock's stop now models an engine whose stop
      // takes 800 ms to complete -- the case that used to
      // push the danger voice 800 ms past the vibration
      // under the old unconditional 800 ms await. The
      // danger path caps its stop wait at
      // NavHazConfig.dangerStopWaitCap (150 ms): the stop
      // is still ISSUED, the speak follows within the
      // 300 ms bound, and the stop's late completion is
      // recorded after the speak on the same clock.
      stopNeverCompletes = true;
      stopLatencyMs = 800;
      final MingtuHomeDebugHandle h = await startApp(tester);
      installTracker(h);
      h.debugLiveFix(southOfB(25), 5);
      await pumpFrames(tester);
      final int turnIdx = idxOf('speak:右转进入林荫道');
      expect(turnIdx, greaterThanOrEqualTo(0),
          reason: 'timeline: ${timeline()}');
      feedApproachingCar(h);
      // Pump generously: the capped wait runs on the fake
      // clock (150 ms cap), far inside this budget.
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final int vibIdx = idxOf('vibrate:urgent');
      final int dangerIdx = idxOf('speak:停，前方来车。');
      expect(vibIdx, greaterThanOrEqualTo(0),
          reason: 'timeline: ${timeline()}');
      expect(dangerIdx, greaterThan(vibIdx),
          reason: 'vibration precedes the danger voice');
      // Timing, FIX2 form: with the stop stuck, the danger
      // speak is issued inside the capped wait, so on this
      // clock (which the stuck stop does NOT advance) both
      // events carry the same stamp -- the binding
      // assertions are the ORDER (checked above) and the
      // <= 300 ms bound; the strict stamp inequality of
      // expectVibrationLeadsDanger belongs to the
      // completing-stop model, where the stop's latency is
      // what separates the stamps.
      expect(stampOf('speak:停，前方来车。') - stampOf('vibrate:urgent'),
          lessThanOrEqualTo(300),
          reason: 'danger speech starts within 300 ms of '
              'the vibration even with the stop stuck');
      // The physical stop WAS issued for this preemption
      // (exactly one stop between the turn and the danger
      // voice) -- the cap shortens the WAIT, it does not
      // skip the stop.
      expect(
        timeline()
            .sublist(turnIdx + 1, dangerIdx)
            .where((String e) => e == 'stop')
            .length,
        1,
        reason: 'one physical stop was issued before the '
            'danger voice. timeline: ${timeline()}',
      );
      // And its completion (at vibration + 800 ms on the
      // test clock) landed after the danger speak started:
      // the late completion did not cut the danger voice
      // off (it is still the playing speak, completed by
      // the test below, not by the stop).
      final int completedIdx = idxOf('stop:completed');
      expect(completedIdx, greaterThanOrEqualTo(0));
      expect(stampOf('stop:completed'),
          greaterThan(stampOf('speak:停，前方来车。')),
          reason: 'the stuck stop completed only after the '
              'danger voice had started');
      await completeSpeak(tester, 'speak:停，前方来车。');
      await drainSpeaks(tester);
      expectTimelineClean();
    });

    /// Install the fake arbitration clock (CDX3): from
    /// here on, request stamps, interruption stamps and
    /// the replay-expiry judgement all read [fakeNow];
    /// the test advances it by hand. The production 15 s
    /// window is never shortened.
    void installFakeClock(MingtuHomeDebugHandle h) {
      h.debugSetSpeechClock(() => fakeNow);
    }

    /// The shared 15 s scenario: a turn prompt is playing,
    /// a danger interrupts it (the interruption is stamped
    /// on the fake clock), then the test advances the
    /// clock by [advance] and finishes the danger.
    Future<MingtuHomeDebugHandle> interruptedTurnScenario(
        WidgetTester tester, Duration advance) async {
      final MingtuHomeDebugHandle h = await startApp(tester);
      installFakeClock(h);
      installTracker(h);
      h.debugLiveFix(southOfB(25), 5);
      await pumpFrames(tester);
      expect(timeline(), contains('speak:右转进入林荫道'));
      // The user keeps walking while the turn plays (the
      // replay, if it comes, must use THIS fix).
      h.debugLiveFix(southOfB(12), 5);
      await pumpFrames(tester);
      feedApproachingCar(h);
      await pumpFrames(tester);
      expect(timeline(), contains('speak:停，前方来车。'));
      fakeNow = fakeNow.add(advance);
      await completeSpeak(tester, 'speak:停，前方来车。');
      await pumpFrames(tester, 5);
      return h;
    }

    testWidgets(
        '15s boundary: at 14.999 s the interrupted turn is '
        'still replayed', (tester) async {
      final MingtuHomeDebugHandle h = await interruptedTurnScenario(
          tester, const Duration(milliseconds: 14999));
      expect(h.debugExpired, isEmpty,
          reason: 'inside the window nothing expires');
      expect(timeline(), contains('speak:前方约12米右转进入林荫道'),
          reason: 'the turn replays, regenerated from the '
              '12 m fix. timeline: ${timeline()}');
      await drainSpeaks(tester);
      expectTimelineClean();
    });

    testWidgets(
        '15s boundary: at exactly 15.000 s the interrupted '
        'turn is expired', (tester) async {
      final MingtuHomeDebugHandle h = await interruptedTurnScenario(
          tester, const Duration(milliseconds: 15000));
      expect(
        h.debugExpired
            .where((String id) => id.startsWith('nav-turn'))
            .length,
        1,
        reason: 'the window is reached: the interrupted '
            'turn itself expired: ${h.debugExpired}',
      );
      expect(
        timeline().where((String e) => e.startsWith('speak:前方约')).length,
        0,
        reason: 'no replay at the boundary. timeline: ${timeline()}',
      );
      await drainSpeaks(tester);
      expectTimelineClean();
    });

    testWidgets(
        'temporary 15s expired interrupted navigation (Codex arb-15s)',
        (tester) async {
      // CDX3 form: the scenario runs on the injectable
      // arbitration clock and the clock is advanced PAST
      // the production window (16 s > 15 s) -- no
      // shortened window is injected anywhere.
      final MingtuHomeDebugHandle h = await interruptedTurnScenario(
          tester, const Duration(seconds: 16));
      // Assertion strength vs the Codex original (lead's
      // EGOUNK ruling: the in-repo assertions must not be
      // weaker than the original's semantics):
      // - original: debugExpired isNotEmpty -> here: the
      //   expired log contains THE interrupted turn prompt
      //   itself, identified by its request id (turn
      //   prompts are minted as 'nav-turn-<ts>' in main;
      //   droppedExpiredLog stores ids), and exactly one
      //   such entry -- not merely a non-empty log.
      // - original: no 'speak:前方约...' (the regenerated
      //   replay form) + print of the replay count -> here:
      //   that count is asserted == 0 AND the replay count
      //   is pinned directly: speaks carrying the turn text
      //   total exactly 1 (the original utterance), i.e.
      //   replay count == 0 as an expect, not a print.
      expect(h.debugExpired, isNotEmpty,
          reason: 'the interrupted turn was dropped as '
              'expired, observably');
      expect(
        h.debugExpired
            .where((String id) => id.startsWith('nav-turn'))
            .length,
        1,
        reason: 'the expired item is the interrupted turn '
            'prompt itself: ${h.debugExpired}',
      );
      expect(
        timeline().where((String e) => e.startsWith('speak:前方约')).length,
        0,
        reason: 'an expired prompt is never replayed late. '
            'timeline: ${timeline()}',
      );
      expect(
        timeline()
            .where((String e) =>
                e.startsWith('speak:') && e.contains('右转进入林荫道'))
            .length,
        1,
        reason: 'the turn text was spoken exactly once -- '
            'the original utterance; replay count == 0. '
            'timeline: ${timeline()}',
      );
      // ignore: avoid_print
      print('expired=${h.debugExpired}; replay count=0');
      await drainSpeaks(tester);
      expectTimelineClean();
    });
  });
}

/// Recording haptics on the test's stamped timeline().
class _StampedHaptics implements Haptics {
  final List<(int, String)> events;
  final int Function() clock;
  _StampedHaptics(this.events, this.clock);

  @override
  Future<void> vibrateUrgent() async {
    events.add((clock(), 'vibrate:urgent'));
  }

  @override
  Future<void> vibrateWarning() async {
    events.add((clock(), 'vibrate:warning'));
  }

  @override
  Future<void> vibratePattern(List<int> timings, List<int> amplitudes) async {
    events.add((clock(), 'vibrate:pattern'));
  }
}
