import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/adapters/current_location.dart';
import 'package:mingtu_ai/config/verified_locations.dart';
import 'package:mingtu_ai/core/navigation_tracker.dart';
import 'package:mingtu_ai/core/real_navigation.dart';
import 'package:mingtu_ai/core/voice_startup.dart';
import 'package:mingtu_ai/main.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';

/// Behavioural tests for the Codex re-test of Step C
/// (push-to-talk ordering) and the Step D danger-preemption
/// follow-up, replacing three source-slice assertions:
///
/// * the ASR-start-failure vibration + fixed notice (was a
///   source grep in codex_followup_test.dart) is proven at
///   the channel seam with recording fakes;
/// * the reroute-failure invariants (was a source slice in
///   voice_navigation_flow_test.dart) are proven at the
///   tracker + starter seam with fixtures;
/// * the no-forbidden-word rule for prompts (was a
///   per-builder unit assertion) is proven over texts the
///   app ACTUALLY spoke through the recording TTS channel.
///
/// Recording-fake pattern: same as
/// codex_d01a081_fix_test.dart -- the real app runs, the
/// real voice adapters drive mocked flutter_tts /
/// speech_to_text channels, and every call is recorded in
/// order ('vibrate', 'tts.speak:<text>', 'tts.stop',
/// 'asr.initialize', 'asr.listen', 'asr.stop'). Recognition
/// results are delivered as platform->Dart textRecognition
/// calls carrying the plugin JSON ({alternates:
/// [{recognizedWords, confidence}], resultType: 2}).
///
/// ORDER MATTERS in this file: speech_to_text's
/// SpeechToText is a process-wide singleton whose
/// initialize() short-circuits after its first success, so
/// the recogniser-UNAVAILABLE scenario must run before any
/// test that initialises it successfully.
class RecordingVoiceChannels {
  final List<String> events = <String>[];
  final List<MapEntry<String, Completer<dynamic>>> speakQueue =
      <MapEntry<String, Completer<dynamic>>>[];
  bool asrInitResult = true;
  bool asrListenThrows = false;

  void install() {
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
            events.add('tts.speak:${call.arguments}');
            final Completer<dynamic> c = Completer<dynamic>();
            speakQueue.add(MapEntry<String, Completer<dynamic>>(
                '${call.arguments}', c));
            return c.future;
          case 'stop':
            events.add('tts.stop');
            return 1;
          default:
            return null;
        }
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugin.csdcorp.com/speech_to_text'),
      (MethodCall call) async {
        switch (call.method) {
          case 'initialize':
            events.add('asr.initialize');
            return asrInitResult;
          case 'listen':
            events.add('asr.listen');
            if (asrListenThrows) {
              throw PlatformException(
                code: 'error_network',
                message: 'synthetic listen failure fixture',
              );
            }
            return true;
          case 'stop':
            events.add('asr.stop');
            return null;
          case 'cancel':
            events.add('asr.cancel');
            return null;
          case 'has_permission':
            return true;
          default:
            return null;
        }
      },
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform,
        (MethodCall call) async {
      if (call.method == 'HapticFeedback.vibrate') events.add('vibrate');
      return null;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/sensors/method'),
      (MethodCall call) async => null,
    );
    for (final String sensor in <String>[
      'gyroscope',
      'accelerometer',
      'user_accelerometer',
      'magnetometer',
      'barometer',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel('dev.fluttercommunity.plus/sensors/$sensor'),
        (MethodCall call) async => null,
      );
    }
  }

  void uninstall() {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('flutter_tts'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugin.csdcorp.com/speech_to_text'), null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/sensors/method'),
        null);
    for (final String sensor in <String>[
      'gyroscope',
      'accelerometer',
      'user_accelerometer',
      'magnetometer',
      'barometer',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel('dev.fluttercommunity.plus/sensors/$sensor'),
        null,
      );
    }
  }

  int count(String e) => events.where((String x) => x == e).length;

  List<Completer<dynamic>> pendingSpeaks() => speakQueue
      .where((MapEntry<String, Completer<dynamic>> e) => !e.value.isCompleted)
      .map((MapEntry<String, Completer<dynamic>> e) => e.value)
      .toList();

  bool completeSpeak([String? text]) {
    for (final MapEntry<String, Completer<dynamic>> e in speakQueue) {
      if (!e.value.isCompleted && (text == null || e.key == text)) {
        e.value.complete(1);
        return true;
      }
    }
    return false;
  }

  void completeAllSpeaks() {
    for (final Completer<dynamic> c in pendingSpeaks()) {
      c.complete(1);
    }
  }

  List<String> spokenTexts() =>
      speakQueue.map((MapEntry<String, Completer<dynamic>> e) => e.key).toList();
}

Future<void> settleRecordedApp(
    WidgetTester tester, RecordingVoiceChannels h) async {
  await tester.pumpWidget(const MingtuApp());
  await tester.pump();
  int quietRounds = 0;
  int lastEventCount = -1;
  for (int round = 0; round < 64; round++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (h.pendingSpeaks().isEmpty && h.events.length == lastEventCount) {
      quietRounds++;
    } else {
      quietRounds = 0;
    }
    lastEventCount = h.events.length;
    h.completeAllSpeaks();
    if (round >= 16 && quietRounds >= 3) break;
  }
}

Future<void> tapPanelText(WidgetTester tester, String text) async {
  final Finder finder = find.text(text);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> drainVoice(WidgetTester tester, RecordingVoiceChannels h,
    {int rounds = 14}) async {
  for (int i = 0; i < rounds; i++) {
    h.completeAllSpeaks();
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> shutdownVoice(
    WidgetTester tester, RecordingVoiceChannels h) async {
  final Finder stopButton =
      find.widgetWithText(ElevatedButton, '停止语音识别');
  if (stopButton.evaluate().isNotEmpty) {
    final ElevatedButton w = tester.widget<ElevatedButton>(stopButton);
    if (w.onPressed != null) {
      await tester.ensureVisible(stopButton);
      await tester.pump();
      await tester.tap(stopButton);
      await tester.pump();
    }
  }
  await drainVoice(tester, h, rounds: 6);
  await tester.pump(const Duration(seconds: 3));
  h.completeAllSpeaks();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> pumpUntilSpeak(
    WidgetTester tester, RecordingVoiceChannels h, String text,
    {int rounds = 20}) async {
  for (int i = 0; i < rounds; i++) {
    if (h.events.contains('tts.speak:$text')) return;
    h.completeAllSpeaks();
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Finder pttBlock() => find.ancestor(
      of: find.text('按住说话', findRichText: true),
      matching: find.byType(Container),
    );

Future<TestGesture> pressPtt(WidgetTester tester) async {
  final TestGesture g =
      await tester.startGesture(tester.getCenter(pttBlock()));
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return g;
}

/// Every text actually spoken through the recording TTS
/// channel anywhere in this file, for the final
/// forbidden-word sweep.
final List<String> spokenCorpus = <String>[];

void main() {
  group('ASR start failure: vibration + fixed notice (behavioural)', () {
    testWidgets(
        'recogniser unavailable: a press vibrates again and '
        'speaks the fixed notice verbatim',
        (WidgetTester tester) async {
      // FIRST widget test in the file: the recogniser
      // singleton has not been initialised successfully
      // yet, so initialize=false genuinely takes effect.
      final RecordingVoiceChannels h = RecordingVoiceChannels()
        ..asrInitResult = false
        ..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      spokenCorpus.addAll(h.spokenTexts());
      h.events.clear();

      final TestGesture gesture = await pressPtt(tester);
      expect(h.completeSpeak('请说'), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The press vibrated once; the FAILED start vibrates
      // again and speaks the fixed notice, verbatim from
      // the production text builder.
      final String notice = voiceNoticeText(VoiceNoticeKind.asrUnavailable);
      expect(h.count('vibrate'), 2, reason: '${h.events}');
      expect(h.events, contains('tts.speak:$notice'),
          reason: '${h.events}');
      // No session was ever opened.
      expect(h.count('asr.listen'), 0, reason: '${h.events}');
      spokenCorpus.add(notice);

      await gesture.up();
      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    testWidgets(
        'engine refuses listen: a press vibrates again and '
        'speaks the fixed notice verbatim',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()
        ..asrListenThrows = true
        ..install();
      addTearDown(h.uninstall);
      // Settle WITHOUT completing the greeting: the
      // automatic loop's first start attempt would fail the
      // same way and loop on every speech finish, so the
      // press is measured against the still-playing
      // greeting instead.
      await tester.pumpWidget(const MingtuApp());
      await tester.pump();
      for (int i = 0; i < 40 && h.events
              .where((String e) => e.startsWith('tts.speak:'))
              .isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        h.events.where((String e) => e.startsWith('tts.speak:')),
        isNotEmpty,
      );
      h.events.clear();

      final TestGesture gesture = await pressPtt(tester);
      expect(h.completeSpeak('请说'), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final String notice = voiceNoticeText(VoiceNoticeKind.asrUnavailable);
      // One listen was attempted and refused; the failure
      // vibrated (on top of the press vibration) and spoke
      // the fixed notice. No session is left listening:
      // exactly one attempt, and the recogniser was never
      // asked to stop a live session.
      expect(h.count('asr.listen'), 1, reason: '${h.events}');
      expect(h.count('vibrate'), greaterThanOrEqualTo(2),
          reason: '${h.events}');
      expect(h.events, contains('tts.speak:$notice'),
          reason: '${h.events}');

      await gesture.up();
      // Kill the automatic loop before draining, so the
      // failure cannot re-fire on speech finishes.
      await tapPanelText(tester, '停止语音识别');
      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });
  });

  group('danger preempts a turn-kind guidance prompt (Step D follow-up)',
      () {
    testWidgets(
        'a vehicle danger physically stops a playing turn '
        'prompt before speaking, and the turn is not replayed',
        (WidgetTester tester) async {
      // Evidence level: the app is driven through its real
      // demo navigation, and the prompt playing when the
      // danger lands is a SpeechKind.turn prompt -- the
      // same kind main uses for entrance-guidance
      // announcements, through the same sequenced speak
      // path that performs the physical stop. (Driving the
      // app INTO the entrance phase itself is not possible
      // from a test: the GPS stream has no injection seam.)
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await tapPanelText(tester, '停止语音识别');
      await tapPanelText(tester, '语音开始（演示输入：带我去图书馆）');
      await tapPanelText(tester, '理解并规划路线');
      await tapPanelText(tester, '开始导航（直行节奏启动）');
      await drainVoice(tester, h, rounds: 6);
      h.events.clear();

      // The turn prompt starts playing and stays playing.
      await tapPanelText(tester, '前方转弯（暂停直行）');
      await pumpUntilSpeak(tester, h, '前方左转（演示）');
      final int turnIdx = h.events.indexOf('tts.speak:前方左转（演示）');
      expect(turnIdx, greaterThanOrEqualTo(0), reason: '${h.events}');

      // The danger lands: a physical stop is issued AFTER
      // the turn speak and BEFORE the danger speak.
      await tapPanelText(tester, '模拟 YOLO 检测：前方车辆（演示，无摄像头）');
      await pumpUntilSpeak(tester, h, '前方有机动车，请停下。');
      final int dangerIdx = h.events.indexOf('tts.speak:前方有机动车，请停下。');
      expect(dangerIdx, greaterThan(turnIdx), reason: '${h.events}');
      final int stopIdx =
          h.events.indexWhere((String e) => e == 'tts.stop', turnIdx);
      expect(stopIdx, greaterThan(turnIdx), reason: '${h.events}');
      expect(stopIdx, lessThan(dangerIdx), reason: '${h.events}');
      // The interrupted turn prompt is never replayed.
      expect(h.count('tts.speak:前方左转（演示）'), 1, reason: '${h.events}');

      final Finder stopNav = find.widgetWithText(ElevatedButton, '停下');
      await tester.ensureVisible(stopNav);
      await tester.pump();
      await tester.tap(stopNav);
      await tester.pump();
      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });
  });

  group('spoken corpus for the forbidden-word sweep', () {
    testWidgets(
        'collect: greeting, demo navigation, dangers and '
        'push-to-talk notices', (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await tapPanelText(tester, '停止语音识别');

      await tapPanelText(tester, '语音开始（演示输入：带我去图书馆）');
      await drainVoice(tester, h, rounds: 5);
      await tapPanelText(tester, '理解并规划路线');
      await drainVoice(tester, h, rounds: 5);
      await tapPanelText(tester, '开始导航（直行节奏启动）');
      await drainVoice(tester, h, rounds: 5);
      await tapPanelText(tester, '前方转弯（暂停直行）');
      await drainVoice(tester, h, rounds: 5);
      await tapPanelText(tester, '模拟 YOLO 检测：前方行人（演示，无摄像头）');
      await drainVoice(tester, h, rounds: 5);
      await tapPanelText(tester, '模拟 YOLO 检测：前方车辆（演示，无摄像头）');
      await drainVoice(tester, h, rounds: 5);

      // Push-to-talk: a too-short press and a no-content
      // press contribute the cue and both fixed notices.
      TestGesture gesture = await pressPtt(tester);
      await gesture.up();
      await tester.pump();
      expect(h.completeSpeak('请说'), isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      await drainVoice(tester, h, rounds: 5);

      gesture = await pressPtt(tester);
      expect(h.completeSpeak('请说'), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 380)));
      await gesture.up();
      await tester.pump();
      await drainVoice(tester, h, rounds: 5);

      spokenCorpus.addAll(h.spokenTexts());

      final Finder stopNav = find.widgetWithText(ElevatedButton, '停下');
      await tester.ensureVisible(stopNav);
      await tester.pump();
      await tester.tap(stopNav);
      await tester.pump();
      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    test('no actually-spoken text contains the forbidden word', () {
      final Set<String> corpus = spokenCorpus.toSet();
      // The categories this sweep claims to cover -- each
      // must really have been spoken and collected.
      expect(corpus, isNotEmpty);
      expect(corpus.any((String t) => t.contains('明途已启动')), isTrue,
          reason: 'startup greeting collected: $corpus');
      expect(corpus, contains('直走'), reason: 'straight prompt: $corpus');
      expect(corpus, contains('前方左转（演示）'),
          reason: 'turn prompt: $corpus');
      expect(corpus.any((String t) => t.contains('请停下')), isTrue,
          reason: 'danger prompts: $corpus');
      expect(corpus, contains('请说'), reason: 'PTT cue: $corpus');
      expect(corpus, contains('请按住说话'),
          reason: 'too-short notice: $corpus');
      expect(corpus, contains('没有听清，请按住按钮再说一次。'),
          reason: 'no-content notice: $corpus');
      expect(
        corpus,
        contains(voiceNoticeText(VoiceNoticeKind.asrUnavailable)),
        reason: 'ASR failure notice: $corpus',
      );
      for (final String text in corpus) {
        expect(text, isNot(contains('安全')),
            reason: 'spoken text must never use the word: $text');
      }
    });
  });

  group('reroute failure seam (behavioural)', () {
    test(
        'off-route fires, the starter fails BEFORE any route '
        'request, and resetOffRouteStreak re-arms the retry',
        () async {
      const GeoPoint gate =
          GeoPoint(latitude: 37.724409, longitude: 120.441723);
      const GeoPoint mid =
          GeoPoint(latitude: 37.724409, longitude: 120.442723);
      const GeoPoint library =
          GeoPoint(latitude: 37.723667, longitude: 120.443212);
      const GeoPoint farNorth =
          GeoPoint(latitude: 37.725500, longitude: 120.441723);
      final NavigationTracker tracker = NavigationTracker(
        steps: const <AmapStep>[
          AmapStep(
            action: '直行',
            orientation: '东',
            polyline: <GeoPoint>[gate, mid],
            distanceM: 89,
            durationS: 70,
          ),
          AmapStep(
            action: '左转',
            orientation: '南',
            polyline: <GeoPoint>[mid, library],
            distanceM: 93,
            durationS: 80,
          ),
        ],
        stepTexts: const <String>['第一段：向东直行。', '第二段：左转，往南走。'],
        destination: library,
        destinationName: '图书馆',
      );
      NavFix fix(GeoPoint p) => NavFix(
            point: p,
            accuracyM: 10,
            at: DateTime(2026, 1, 1, 12),
          );
      // Sustained off-route: the event fires and the trip
      // budget allows a re-plan.
      expect(tracker.onFix(fix(farNorth)), isEmpty);
      expect(tracker.onFix(fix(farNorth)).single.kind,
          NavEventKind.offRoute);
      expect(tracker.rerouteDecision(DateTime(2026, 1, 1, 12)),
          RerouteDecision.doIt);

      // The re-plan attempt itself, at the starter seam:
      // the location fix fails, so the starter reports the
      // failure WITHOUT ever calling the route sender --
      // the failure path produces no route.
      int senderCalls = 0;
      final RealNavigationStarter starter = RealNavigationStarter(
        locationProvider: const _FailingLocation(),
        client: AmapWalkingClient(
          proxyBaseUrl: 'https://proxy.example.test',
          sender: (Uri url) async {
            senderCalls++;
            return '{}';
          },
        ),
        registry: const <VerifiedLocation>[
          VerifiedLocation(
            id: 'library',
            name: '图书馆',
            pointGcj02: GeoPoint(latitude: 39.900900, longitude: 116.401000),
          ),
        ],
      );
      final RealNavigationOutcome outcome = await starter.start('图书馆');
      expect(outcome.ready, isFalse);
      expect(outcome.failure, RealNavigationFailure.locationFailed);
      expect(senderCalls, 0);

      // What main does with that failure (its part of the
      // contract): re-arm the streak, so a later sustained
      // off-route produces the event -- and with it the
      // next budgeted re-plan attempt -- again.
      tracker.resetOffRouteStreak();
      expect(tracker.onFix(fix(farNorth)), isEmpty);
      expect(tracker.onFix(fix(farNorth)).single.kind,
          NavEventKind.offRoute);
    });
  });
}

/// Location provider whose fix always fails (fixture).
class _FailingLocation implements CurrentLocationProvider {
  const _FailingLocation();

  @override
  Future<LocationResult> currentLocation() async =>
      LocationResult.error(LocationFailure.failed, 'fixture: no fix');

  @override
  Future<bool> ensurePermission() async => false;

  @override
  Stream<LocationResult> positions() =>
      const Stream<LocationResult>.empty();
}
