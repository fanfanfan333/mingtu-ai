import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/adapters/current_location.dart';
import 'package:mingtu_ai/config/verified_locations.dart';
import 'package:mingtu_ai/core/navigation_tracker.dart';
import 'package:mingtu_ai/core/real_navigation.dart';
import 'package:mingtu_ai/core/voice_commands.dart';
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

  /// When set, the platform's answer to listen() stays in
  /// flight until the completer completes -- a slow engine
  /// start. Null (the default) answers immediately, exactly
  /// as before.
  Completer<dynamic>? listenGate;

  /// When set, the platform's answer to stop() stays in
  /// flight until the completer completes -- a slow
  /// engine stop. Null (the default) answers immediately,
  /// exactly as before.
  Completer<dynamic>? stopGate;

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
            final Completer<dynamic>? gate = listenGate;
            if (gate != null) return gate.future;
            return true;
          case 'stop':
            events.add('asr.stop');
            final Completer<dynamic>? sGate = stopGate;
            if (sGate != null) return sGate.future;
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
      // The app also SUBSCRIBES to the gyro/magnetometer
      // event streams. Without a mock stream handler the
      // subscription never activates, and when the widget
      // tree is torn down after a FAILED test the stream
      // deactivation throws MissingPluginException --
      // which poisons the NEXT test in this file (the
      // pre-existing cascade behind the R3 / R3-variant /
      // corpus failures when run as a file). A no-op
      // handler makes listen/cancel on these channels
      // always succeed.
      messenger.setMockStreamHandler(
        EventChannel('dev.fluttercommunity.plus/sensors/$sensor'),
        MockStreamHandler.inline(
          onListen: (Object? arguments, MockStreamHandlerEventSink events) {},
          onCancel: (Object? arguments) {},
        ),
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
      messenger.setMockStreamHandler(
        EventChannel('dev.fluttercommunity.plus/sensors/$sensor'),
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

Future<void> holdPastThreshold(WidgetTester tester) async {
  // DateTime.now() is real in widget tests: a >300 ms hold
  // needs a real wait (fake pumps do not move it).
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 380)));
}

/// Deliver a recognition result the way the platform does:
/// a textRecognition platform->Dart call on the plugin
/// channel, carrying the plugin's JSON. The resultType
/// values follow the plugin's own ResultType enum
/// (speech_to_text 7.5.0, speech_recognition_result.dart):
/// 0 = partial, 1 = intermediate, 2 = finalResult. The
/// adapter routes final results to its transcripts stream
/// and non-final ones to its partials stream.
Future<void> deliverRecognition(
    WidgetTester tester, String words, int resultType) async {
  final String json = jsonEncode(<String, Object?>{
    'alternates': <Map<String, Object?>>[
      <String, Object?>{'recognizedWords': words, 'confidence': 0.95},
    ],
    'resultType': resultType,
  });
  final ByteData data = const StandardMethodCodec()
      .encodeMethodCall(MethodCall('textRecognition', json));
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'plugin.csdcorp.com/speech_to_text',
    data,
    (ByteData? _) {},
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> deliverFinalResult(WidgetTester tester, String words) =>
    deliverRecognition(tester, words, 2);

Future<void> deliverPartialResult(WidgetTester tester, String words) =>
    deliverRecognition(tester, words, 0);

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
  // Detach the tree NOW, while this test's mock stream
  // handlers are still installed: the orientation monitor
  // cancels its gyroscope/magnetometer subscriptions in
  // dispose(), and an EventChannel cancel that lands after
  // uninstall() has dropped the handlers throws
  // MissingPluginException and is charged to whichever
  // test runs next.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
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

  group('ptt state machine races (Codex re-test of c104dc7)', () {
    testWidgets(
        'R1: a release during the gated listen() start is '
        'honoured the moment the start returns',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      // The startup kickoff's permission answer resolves
      // on the real event loop and can land late; flush it
      // (and drain its fixed alert) up front so it cannot
      // speak in the middle of the race.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await drainVoice(tester, h, rounds: 8);
      await tapPanelText(tester, '停止语音识别');
      h.events.clear();

      // Gate the platform's listen answer: the start stays
      // in flight (state: starting) until this test lets
      // it return.
      h.listenGate = Completer<dynamic>();
      final TestGesture gesture = await pressPtt(tester);
      expect(h.completeSpeak('请说'), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // The start was ISSUED but the platform has not
      // answered: no session yet, and no stop either.
      expect(h.count('asr.listen'), 1, reason: '${h.events}');
      expect(h.count('asr.stop'), 0, reason: '${h.events}');

      // A result arriving inside the starting window is a
      // stale callback: it is dropped, never executed.
      await deliverFinalResult(tester, '你好');
      expect(
        h.events.where((String e) => e.startsWith('tts.speak:')).length,
        1, // the cue only
        reason: '${h.events}',
      );

      // Release inside the window: the stop is only
      // RECORDED (pendingStop) -- a session whose start
      // has not returned cannot be stopped yet.
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.stop'), 0, reason: '${h.events}');

      // The start returns: the sequence stops the session
      // it just opened immediately, and answers with the
      // too-short notice -- never the no-content one.
      h.listenGate!.complete(true);
      h.listenGate = null;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await pumpUntilSpeak(tester, h, '请按住说话');
      final int listenIdx = h.events.indexOf('asr.listen');
      final int stopIdx = h.events.indexOf('asr.stop');
      expect(stopIdx, greaterThan(listenIdx), reason: '${h.events}');
      expect(
        h.events,
        isNot(contains('tts.speak:没有听清，请按住按钮再说一次。')),
        reason: '${h.events}',
      );
      // The stale final from the starting window was never
      // submitted: no command processing happened at all.
      expect(
        h.events,
        isNot(contains('tts.speak:没听清。${voiceCommandHelpText()}')),
        reason: '${h.events}',
      );

      // The recogniser is not stuck listening: a fresh
      // press runs a complete normal cycle (second listen,
      // second stop, no-content notice after the grace).
      h.events.clear();
      final TestGesture gesture2 = await pressPtt(tester);
      expect(h.completeSpeak('请说'), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.listen'), 1, reason: '${h.events}');
      await holdPastThreshold(tester);
      await gesture2.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.stop'), 1, reason: '${h.events}');
      await tester.pump(const Duration(seconds: 2));
      await pumpUntilSpeak(tester, h, '没有听清，请按住按钮再说一次。');

      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    testWidgets(
        'R2: a final arriving while held is cached and '
        'submitted exactly once after the release',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      // The startup kickoff's permission answer resolves
      // on the real event loop and can land late; flush it
      // (and drain its fixed alert) up front so it cannot
      // speak in the middle of the race.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await drainVoice(tester, h, rounds: 8);
      await tapPanelText(tester, '停止语音识别');
      h.events.clear();

      final TestGesture gesture = await pressPtt(tester);
      expect(h.completeSpeak('请说'), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.listen'), 1, reason: '${h.events}');

      await holdPastThreshold(tester);
      // The final arrives WHILE HELD: it must only be
      // cached. '你好' parses as an unknown command whose
      // processing would speak the not-heard reply; none
      // of that may happen before the release.
      await deliverFinalResult(tester, '你好');
      await tester.pump(const Duration(milliseconds: 100));
      final String unknownReply = '没听清。${voiceCommandHelpText()}';
      expect(h.events, isNot(contains('tts.speak:$unknownReply')),
          reason: '${h.events}');
      expect(
        h.events.where((String e) => e.startsWith('tts.speak:')).length,
        1, // the cue only
        reason: '${h.events}',
      );

      // Release: the session stops, and only then is the
      // cached final submitted -- exactly once.
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final int stopIdx = h.events.lastIndexOf('asr.stop');
      final int replyIdx = h.events.indexOf('tts.speak:$unknownReply');
      expect(stopIdx, greaterThanOrEqualTo(0), reason: '${h.events}');
      expect(replyIdx, greaterThan(stopIdx), reason: '${h.events}');
      expect(h.count('tts.speak:$unknownReply'), 1,
          reason: '${h.events}');

      // A valid result suppresses the no-content notice,
      // even well past the post-release grace.
      await tester.pump(const Duration(seconds: 3));
      expect(
        h.events,
        isNot(contains('tts.speak:没有听清，请按住按钮再说一次。')),
        reason: '${h.events}',
      );
      expect(h.count('tts.speak:$unknownReply'), 1,
          reason: '${h.events}');

      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    testWidgets(
        'R2 variant: with only a partial cached, the '
        'post-stop final wins over the partial',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      // The startup kickoff's permission answer resolves
      // on the real event loop and can land late; flush it
      // (and drain its fixed alert) up front so it cannot
      // speak in the middle of the race.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await drainVoice(tester, h, rounds: 8);
      await tapPanelText(tester, '停止语音识别');
      h.events.clear();

      final TestGesture gesture = await pressPtt(tester);
      expect(h.completeSpeak('请说'), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.listen'), 1, reason: '${h.events}');

      await holdPastThreshold(tester);
      // A partial only: cached as the fallback, never
      // executed while held.
      await deliverPartialResult(tester, '你好');
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        h.events.where((String e) => e.startsWith('tts.speak:')).length,
        1, // the cue only
        reason: '${h.events}',
      );

      // Release: the session stops and the grace window
      // opens. (Fake time between here and the final
      // delivery stays far below the 1.5 s grace -- and
      // below the plugin's own 2 s final-conversion timer,
      // so the partial is not promoted by the plugin.)
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.stop'), greaterThanOrEqualTo(1),
          reason: '${h.events}');

      // The engine's post-stop final arrives inside the
      // grace. The word pair is chosen so the two texts
      // are distinguishable by their processing: the
      // partial '你好' would be answered with the
      // unknown-command reply, while the final '帮助' is
      // answered with the bare help text.
      //
      // Delivery mechanics under the stopping-window
      // rewrite: the final completes the press through
      // _onPttFinalInStopping WITHOUT waiting for stop()
      // to return, and completing SUBMITS the text --
      // _handleVoiceCommand then speaks the reply through
      // the scheduler, whose speak path first closes the
      // microphone (the adapter's stop). Processing the
      // submitted final therefore issues a SECOND platform
      // stop on top of the release stop. Pump until the
      // reply actually lands on the TTS channel, then
      // complete it so the speak-after-closing-mic
      // sequence can finish.
      await deliverFinalResult(tester, '帮助');
      await pumpUntilSpeak(tester, h, voiceCommandHelpText());
      expect(h.completeSpeak(voiceCommandHelpText()), isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      final String helpText = voiceCommandHelpText();
      final String unknownReply = '没听清。$helpText';
      expect(h.events, contains('tts.speak:$helpText'),
          reason: '${h.events}');
      expect(h.count('tts.speak:$helpText'), 1, reason: '${h.events}');
      expect(h.events, isNot(contains('tts.speak:$unknownReply')),
          reason: '${h.events}');

      // And the no-content notice never follows.
      await tester.pump(const Duration(seconds: 3));
      expect(
        h.events,
        isNot(contains('tts.speak:没有听清，请按住按钮再说一次。')),
        reason: '${h.events}',
      );

      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    testWidgets(
        'R3: pressed during a P0 danger prompt, the press '
        'defers and enters once the danger finishes',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      // The startup kickoff's permission answer resolves
      // on the real event loop and can land late; flush it
      // (and drain its fixed alert) up front so it cannot
      // speak in the middle of the race.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await drainVoice(tester, h, rounds: 8);
      await tapPanelText(tester, '停止语音识别');

      // Drive the demo navigation, then trigger the
      // vehicle danger and keep it PLAYING.
      await tapPanelText(tester, '语音开始（演示输入：带我去图书馆）');
      await tapPanelText(tester, '理解并规划路线');
      await tapPanelText(tester, '开始导航（直行节奏启动）');
      await drainVoice(tester, h, rounds: 6);
      h.events.clear();
      await tapPanelText(tester, '模拟 YOLO 检测：前方车辆（演示，无摄像头）');
      await pumpUntilSpeak(tester, h, '前方有机动车，请停下。');
      final int dangerIdx = h.events.indexOf('tts.speak:前方有机动车，请停下。');
      expect(dangerIdx, greaterThanOrEqualTo(0),
          reason: '${h.events}');

      // Press while the P0 prompt plays: vibration only.
      // No cue is spoken over the danger prompt, no
      // session starts, no stop is issued against it.
      final TestGesture gesture = await pressPtt(tester);
      final List<String> duringP0 = h.events.sublist(dangerIdx + 1);
      expect(duringP0, contains('vibrate'), reason: '${h.events}');
      expect(duringP0, isNot(contains('tts.speak:请说')),
          reason: '${h.events}');
      expect(h.count('asr.listen'), 0, reason: '${h.events}');
      expect(duringP0, isNot(contains('tts.stop')),
          reason: '${h.events}');
      expect(
        h.speakQueue.any((MapEntry<String, Completer<dynamic>> e) =>
            e.key == '前方有机动车，请停下。' && !e.value.isCompleted),
        isTrue,
        reason: '${h.events}',
      );

      // Keep holding in REAL time past the production
      // 1.5 s just-started-P0 recency window, so the
      // deferred press can enter prompting the moment the
      // danger completes.
      await holdPastThreshold(tester);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1300)));

      // The danger finishes NORMALLY: the still-held
      // press now enters prompting on its own.
      expect(h.completeSpeak('前方有机动车，请停下。'), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await pumpUntilSpeak(tester, h, '请说');
      expect(h.completeSpeak('请说'), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.listen'), 1, reason: '${h.events}');

      // Release: the session stops; with nothing
      // recognised, the fixed no-content notice follows
      // after the post-release grace.
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.stop'), greaterThanOrEqualTo(1),
          reason: '${h.events}');
      await tester.pump(const Duration(seconds: 2));
      await pumpUntilSpeak(tester, h, '没有听清，请按住按钮再说一次。');

      final Finder stopNav = find.widgetWithText(ElevatedButton, '停下');
      await tester.ensureVisible(stopNav);
      await tester.pump();
      await tester.tap(stopNav);
      await tester.pump();
      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    testWidgets(
        'R3 variant: a deferred press released before the '
        'P0 prompt ends is cancelled silently',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      // The startup kickoff's permission answer resolves
      // on the real event loop and can land late; flush it
      // (and drain its fixed alert) up front so it cannot
      // speak in the middle of the race.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await drainVoice(tester, h, rounds: 8);
      await tapPanelText(tester, '停止语音识别');

      await tapPanelText(tester, '语音开始（演示输入：带我去图书馆）');
      await tapPanelText(tester, '理解并规划路线');
      await tapPanelText(tester, '开始导航（直行节奏启动）');
      await drainVoice(tester, h, rounds: 6);
      h.events.clear();
      await tapPanelText(tester, '模拟 YOLO 检测：前方车辆（演示，无摄像头）');
      await pumpUntilSpeak(tester, h, '前方有机动车，请停下。');

      // Press during the P0 prompt: vibration only.
      final TestGesture gesture = await pressPtt(tester);
      expect(h.events, contains('vibrate'), reason: '${h.events}');
      expect(h.events, isNot(contains('tts.speak:请说')),
          reason: '${h.events}');
      expect(h.count('asr.listen'), 0, reason: '${h.events}');

      // Release BEFORE the danger finishes: the deferred
      // press is cancelled quietly.
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The danger now finishes normally -- and nothing
      // about the dead press may appear afterwards: no
      // cue, no session, no PTT notice of any kind.
      expect(h.completeSpeak('前方有机动车，请停下。'), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 2));
      expect(h.events, isNot(contains('tts.speak:请说')),
          reason: '${h.events}');
      expect(h.count('asr.listen'), 0, reason: '${h.events}');
      expect(h.events, isNot(contains('tts.speak:请按住说话')),
          reason: '${h.events}');
      expect(
        h.events,
        isNot(contains('tts.speak:没有听清，请按住按钮再说一次。')),
        reason: '${h.events}',
      );

      final Finder stopNav = find.widgetWithText(ElevatedButton, '停下');
      await tester.ensureVisible(stopNav);
      await tester.pump();
      await tester.tap(stopNav);
      await tester.pump();
      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });
  });

  group('ptt stopping window + session ids (Codex re-test of 97e9c75)', () {
    // Shared driver for this group: press and wait until
    // the production sequence has FULLY reached the
    // listening state. Completing the cue's channel future
    // is only half of the cue playback: the app also
    // awaits the speech_to_text package's own stop() future
    // (and the microtask chain around it) before it issues
    // listen(), and fake-time pumps can run ahead of those
    // real-event-loop turns -- a result delivered then
    // lands in prompting, where production (correctly)
    // drops it as stale. Poll in real time until the
    // listen call is on the channel.
    Future<TestGesture> pressUntilListening(
        WidgetTester tester, RecordingVoiceChannels h) async {
      final TestGesture g = await pressPtt(tester);
      expect(h.completeSpeak('请说'), isTrue);
      for (int i = 0; i < 40; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
        if (h.count('asr.listen') >= 1) return g;
      }
      fail('press never reached listening: ${h.events}');
    }

    testWidgets(
        'R4: a final arriving while stop() is still in flight '
        'is submitted at once, before the stop even returns',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      // Flush the startup kickoff's late permission answer
      // so it cannot speak in the middle of the window.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await drainVoice(tester, h, rounds: 8);
      await tapPanelText(tester, '停止语音识别');
      h.events.clear();

      final TestGesture gesture = await pressUntilListening(tester, h);
      expect(h.count('asr.listen'), 1, reason: '${h.events}');

      await holdPastThreshold(tester);
      // Only a partial while held: cached as the fallback,
      // never executed.
      await deliverPartialResult(tester, '你好');
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        h.events.where((String e) => e.startsWith('tts.speak:')).length,
        1, // the cue only
        reason: '${h.events}',
      );

      // Release with the platform stop GATED: the app is
      // inside the stopping window and stop() has not
      // returned yet.
      h.stopGate = Completer<dynamic>();
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.stop'), greaterThanOrEqualTo(1),
          reason: '${h.events}');
      // The final word is '前面有什么' (the environment
      // command) ON PURPOSE: its reply is a fixed template
      // over state no other path mutates during this test
      // ('前方情况：尚未模拟感知帧。'), so the reply is
      // attributable to exactly one submission.
      const String envReply = '前方情况：尚未模拟感知帧。';
      final String unknownReply = '没听清。${voiceCommandHelpText()}';
      expect(h.events, isNot(contains('tts.speak:$envReply')),
          reason: '${h.events}');

      // The session's final arrives BEFORE stop() returns.
      // Under the rewrite it is accepted and submitted
      // immediately (first of stop-return / final-arrival
      // wins) and it beats the cached partial '你好' (whose
      // processing would be the unknown-command reply).
      await deliverFinalResult(tester, '前面有什么');
      // The completion's speak chain crosses the plugin's
      // own stop() future and several fake-clock timers
      // (the scheduler's simulated-completion fallbacks):
      // advancing fake time in small steps, completing
      // speaks as they surface, is what carries the reply
      // onto the prompt. A single long pump deadlocks
      // against the gated stop (the reply's speak waits
      // for it), so step in 250 ms increments.
      for (int i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        h.completeAllSpeaks();
        final String? d =
            tester.widget<Text>(find.textContaining('当前提示：')).data;
        if ((d ?? '').contains(envReply)) break;
      }
      // The submit half of the completion (the scheduler
      // taking the reply as its active prompt, mirrored to
      // the on-screen current prompt) lands within a few
      // pumps of the delivery. The CHANNEL speak, however,
      // is parked behind the still-gated platform stop by
      // speakAfterClosingMic: by design it is emitted only
      // once the microphone is really closed, so it cannot
      // precede the stop's return.
      final String? promptText =
          tester.widget<Text>(find.textContaining('当前提示：')).data;
      expect(
        promptText,
        contains(envReply),
        reason: 'the final was submitted during the stop',
      );
      await pumpUntilSpeak(tester, h, envReply, rounds: 10);
      expect(h.count('tts.speak:$envReply'), 0,
          reason: 'speak must stay parked behind the gated mic stop');
      expect(h.events, isNot(contains('tts.speak:$unknownReply')),
          reason: '${h.events}');

      // Release the gated stop: the parked speak is
      // emitted now -- proof that the reply heard after
      // the stop belongs to the final delivered DURING it.
      // The press stays completed exactly once: no
      // duplicate submission, no fallback to the partial,
      // no no-content notice, and nothing more even after
      // the 1.5 s deadline has long passed.
      h.stopGate!.complete(null);
      h.stopGate = null;
      await pumpUntilSpeak(tester, h, envReply);
      expect(h.completeSpeak(envReply), isTrue);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(h.count('tts.speak:$envReply'), 1, reason: '${h.events}');
      expect(h.events, isNot(contains('tts.speak:$unknownReply')),
          reason: '${h.events}');
      expect(
        h.events,
        isNot(contains('tts.speak:没有听清，请按住按钮再说一次。')),
        reason: '${h.events}',
      );

      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    testWidgets(
        'R5: a press completed by its final is never '
        're-completed by a later delivery',
        (WidgetTester tester) async {
      // Evidence chain for "stale callbacks are dropped"
      // at the app layer. Channel deliveries carry no id:
      // the id is stamped by the adapter's per-listen
      // onResult closure, and the plugin routes every
      // channel result to the LAST registered closure --
      // so a genuinely old-closure event cannot be
      // synthesised through the channel at all. The
      // adapter-level stamping proof lives in
      // voice_adapter_test.dart (two sessions, strictly
      // increasing ids on results AND status). What CAN be
      // proven here: once a press has completed, the app
      // is idle, and a delivery that arrives now belongs to
      // whatever session is current (the auto-listen the
      // completion restored, or no session at all) -- it
      // must be handled under THAT session's rules, never
      // attributed to the dead press: the PTT completion
      // happens exactly once and its notices never fire
      // retroactively.
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await drainVoice(tester, h, rounds: 8);
      await tapPanelText(tester, '停止语音识别');
      h.events.clear();

      // One complete press: final cached while held,
      // submitted exactly once on release.
      final TestGesture gesture = await pressUntilListening(tester, h);
      expect(h.count('asr.listen'), 1, reason: '${h.events}');
      await holdPastThreshold(tester);
      await deliverFinalResult(tester, '你好');
      await tester.pump(const Duration(milliseconds: 100));
      final String unknownReply = '没听清。${voiceCommandHelpText()}';
      await gesture.up();
      await tester.pump();
      await pumpUntilSpeak(tester, h, unknownReply);
      expect(h.completeSpeak(unknownReply), isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('tts.speak:$unknownReply'), 1,
          reason: '${h.events}');

      // A "late" delivery now: it can only be stamped with
      // the CURRENT session's id (the restored auto-listen,
      // whose listen call is visible below) or dropped when
      // no session is live. Either way the dead press must
      // not complete a second time: no second submission
      // reply attributable to it and -- critically -- the
      // no-content notice, which only a live stopping
      // window can produce, never appears.
      await deliverFinalResult(tester, '帮助');
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await drainVoice(tester, h, rounds: 6);
      expect(h.count('tts.speak:$unknownReply'), 1,
          reason: '${h.events}');
      expect(
        h.events,
        isNot(contains('tts.speak:没有听清，请按住按钮再说一次。')),
        reason: '${h.events}',
      );
      expect(h.events, isNot(contains('tts.speak:请按住说话')),
          reason: '${h.events}');

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
      // The vehicle danger above finished only moments ago
      // in REAL time, and a press inside the production
      // 1.5 s just-finished-P0 window is DEFERRED by the
      // state machine's P0 gate (no cue at all) instead of
      // speaking the cue -- so let the window lapse first,
      // the same wait a real user pressing after the
      // announcement has ended would experience.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1700)));
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
      // The no-content notice now fires only after the
      // post-release 1.5 s grace for a late final has run
      // out: advance the fake clock past it before the
      // notice can be collected.
      await tester.pump(const Duration(seconds: 2));
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
