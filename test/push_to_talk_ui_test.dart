import 'dart:async';
import 'dart:convert';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsData, SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/main.dart';

/// Step C push-to-talk UI: the home screen leads with the big
/// status line and the camera area (upper part), then ONE very
/// large push-to-talk button; the original demo panel stays
/// reachable in the scroll region below the button.
///
/// Assertions are behavioural. The layout tests run in the
/// plain environment (no engines). The ordering tests use
/// RECORDING fakes at the platform-channel seam (the pattern
/// of codex_d01a081_fix_test.dart): the real app runs, the
/// real SystemVoiceOutput / SystemVoiceInput drive mocked
/// flutter_tts and speech_to_text channels, and every call
/// is recorded in order. The recogniser protocol (from the
/// speech_to_text platform interface): Dart calls
/// initialize/listen/stop on the channel; the platform
/// answers through platform->Dart calls on the SAME channel
/// -- textRecognition with a JSON string
/// ({alternates:[{recognizedWords, confidence}],
/// resultType: 2 = final}) and notifyStatus with
/// listening/notListening/done.
///
/// One platform fact these tests are built around: in
/// widget tests DateTime.now() is REAL time and does NOT
/// advance with tester.pump (fake time). The production
/// 300 ms too-short threshold reads DateTime.now(), so a
/// "full" press is proven by really sleeping while held
/// (tester.runAsync), and a "too short" press by acting
/// within a few real milliseconds.

/// Let the startup engine probes (which run on fake timers)
/// finish, so no timer is pending at teardown.
Future<void> settleStartup(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 1000));
  }
}

/// Recording fakes for the three channels the voice stack
/// touches. Every call lands in [events] in arrival order:
/// 'vibrate', 'tts.speak:<text>', 'tts.stop',
/// 'asr.initialize', 'asr.listen', 'asr.stop'.
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
    // The orientation monitor subscribes to the gyroscope
    // at startup; on a host without the plugin its method
    // call fails as an UNHANDLED async error whenever it
    // happens to land. Give the sensors channels silent
    // handlers (stream activates, never emits, never
    // errors) so the voice assertions are measured without
    // that race.
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

  /// Complete the oldest still-pending speak (or the one
  /// for [text]); false when none is pending.
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
}

/// Pump the real app under the recording channels and drive
/// the startup speech chain to quiescence: every speak is
/// completed as it appears, until two consecutive rounds
/// produce no new pending speak.
Future<void> settleRecordedApp(
    WidgetTester tester, RecordingVoiceChannels h) async {
  await tester.pumpWidget(const MingtuApp());
  await tester.pump();
  // The startup chain includes a permission kickoff whose
  // failure announcement can land seconds of fake time
  // after the greeting (platform timeouts), so quiescence
  // requires BOTH a minimum fake-time budget and several
  // consecutive rounds with no new channel event and no
  // pending speak.
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

/// Deliver a final recognition result the way the platform
/// does: a textRecognition platform->Dart call carrying the
/// plugin's JSON shape (resultType 2 = final).
Future<void> deliverFinalResult(WidgetTester tester, String words) async {
  final String json = jsonEncode(<String, Object?>{
    'alternates': <Map<String, Object?>>[
      <String, Object?>{'recognizedWords': words, 'confidence': 0.95},
    ],
    'resultType': 2,
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

Finder pttBlock() => find.ancestor(
      of: find.text('按住说话', findRichText: true),
      matching: find.byType(Container),
    );

/// Press and hold the push-to-talk button: the gesture must
/// pass the long-press timeout before the production press
/// sequence starts.
Future<TestGesture> pressPtt(WidgetTester tester) async {
  final TestGesture g =
      await tester.startGesture(tester.getCenter(pttBlock()));
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return g;
}

/// Pump (completing intervening speaks) until [text] has
/// been spoken through the TTS channel. Needed when an
/// unrelated queued startup prompt (the location-permission
/// announcement, whose platform future only resolves late)
/// legitimately speaks first: the assertion is that the
/// target prompt IS spoken, in sequence, not that nothing
/// else was queued ahead of it.
Future<void> pumpUntilSpeak(
    WidgetTester tester, RecordingVoiceChannels h, String text,
    {int rounds = 20}) async {
  for (int i = 0; i < rounds; i++) {
    if (h.events.contains('tts.speak:$text')) return;
    h.completeAllSpeaks();
    await tester.pump(const Duration(milliseconds: 150));
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

/// End-of-test hygiene: switch the automatic loop off via
/// its real UI entry (when enabled), drain speech, and run
/// out the recogniser plugin's own timers (its 3 s pause
/// timer is cancelled by stop; its 2 s final-result timer
/// must be allowed to fire).
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

/// Really sleep while the button is held, so the press
/// passes the production 300 ms threshold (which reads the
/// real clock, not fake test time).
Future<void> holdPastThreshold(WidgetTester tester) async {
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 380)));
}

void main() {
  group('step C push-to-talk layout', () {
    testWidgets('the push-to-talk button is large and in the fixed zone',
        (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(const MingtuApp());
      await tester.pump();
      await settleStartup(tester);

      // find.text matches substrings, so scope to the exact
      // label of the push-to-talk text widget itself.
      final Finder button = find.text('按住说话', findRichText: true).hitTestable();
      expect(button, findsOneWidget);
      // The text sits in the big tappable block: measure the
      // block (the Container ancestor), not the glyph run.
      final Finder block = find.ancestor(
        of: button,
        matching: find.byType(Container),
      );
      final Size size = tester.getSize(block);
      expect(size.height, greaterThanOrEqualTo(120),
          reason: 'button size: $size');
      expect(size.width, greaterThan(200), reason: 'button size: $size');

      // TalkBack contract: the push-to-talk semantics node
      // carries the explicit label. (The node is located by
      // its label: since the node gained its long-press
      // action it is a separate node from the button text's
      // own node, which is what the Container resolves to.)
      final SemanticsData data = tester
          .getSemantics(
              find.bySemanticsLabel('按住说话按钮，按住后说话，松开结束'))
          .getSemanticsData();
      handle.dispose();
      expect(data.label, contains('按住说话按钮，按住后说话，松开结束'));
    });

    testWidgets(
        'the camera area placeholder shows while the live view '
        'is closed', (WidgetTester tester) async {
      await tester.pumpWidget(const MingtuApp());
      await tester.pump();
      await settleStartup(tester);

      expect(find.text('摄像头未开启'), findsOneWidget);
      // The placeholder container fills the camera SizedBox:
      // measure the Container ancestor of the placeholder text.
      final Finder area = find.ancestor(
        of: find.text('摄像头未开启'),
        matching: find.byType(Container),
      );
      final Size size = tester.getSize(area);
      expect(size.height, greaterThan(200), reason: 'camera area: $size');
      // The placeholder offers the existing open flow.
      expect(find.text('打开摄像头（YOLO 实时检测）'), findsOneWidget);
    });

    testWidgets(
        'press order: vibrate, cue spoken and awaited, THEN '
        'listen; release stops and submits',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      // The automatic loop opened a session after the
      // greeting; switch it off through its real UI entry so
      // the press phase is measured in isolation.
      expect(h.count('asr.listen'), greaterThanOrEqualTo(1),
          reason: 'auto listen after startup: ${h.events}');
      await tapPanelText(tester, '停止语音识别');
      h.events.clear();

      final TestGesture gesture = await pressPtt(tester);
      // Vibration comes first; the cue is spoken after it.
      expect(h.events.first, 'vibrate', reason: '${h.events}');
      final int cueIdx = h.events.indexOf('tts.speak:请说');
      expect(cueIdx, greaterThan(0), reason: '${h.events}');
      // While the cue is still playing (its future is held
      // by this test), recognition must NOT have started:
      // the cue itself would be recorded.
      await tester.pump(const Duration(milliseconds: 200));
      expect(h.count('asr.listen'), 0, reason: '${h.events}');

      // Cue completes -> only now does the session start.
      expect(h.completeSpeak('请说'), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.listen'), 1, reason: '${h.events}');

      // A full press (real time past 300 ms), a final result
      // delivered through the recogniser protocol, then the
      // release stops the session. The transcript word is
      // deliberately inert: it parses as an unknown command
      // (the app answers with its standard not-heard info
      // prompt) and starts no navigation or destination
      // flow. Across the whole press exactly ONE session
      // was opened.
      await holdPastThreshold(tester);
      await deliverFinalResult(tester, '你好');
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.stop'), greaterThanOrEqualTo(1),
          reason: '${h.events}');
      expect(h.count('asr.listen'), 1, reason: '${h.events}');

      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    testWidgets(
        'a press released under 300 ms speaks the fixed '
        'hold-the-button notice and never starts a session',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await tapPanelText(tester, '停止语音识别');
      h.events.clear();

      // Variant A: released while the cue is still playing.
      // The sequence discovers the release after the cue and
      // answers with the too-short notice.
      TestGesture gesture = await pressPtt(tester);
      expect(h.events, contains('tts.speak:请说'),
          reason: '${h.events}');
      await gesture.up();
      await tester.pump();
      expect(h.completeSpeak('请说'), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.events, contains('tts.speak:请按住说话'),
          reason: '${h.events}');
      expect(h.count('asr.listen'), 0, reason: '${h.events}');
      expect(h.completeSpeak('请按住说话'), isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      h.events.clear();

      // Variant B: the cue's completion and the release land
      // back to back, before the sequence's next step runs.
      // Same outcome: notice spoken, no session started.
      gesture = await pressPtt(tester);
      expect(h.events, contains('tts.speak:请说'),
          reason: '${h.events}');
      expect(h.completeSpeak('请说'), isTrue);
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.events, contains('tts.speak:请按住说话'),
          reason: '${h.events}');
      expect(h.count('asr.listen'), 0, reason: '${h.events}');

      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    testWidgets(
        'a full press with no recognised content speaks the '
        'fixed not-heard notice', (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await tapPanelText(tester, '停止语音识别');
      h.events.clear();

      final TestGesture gesture = await pressPtt(tester);
      expect(h.completeSpeak('请说'), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.listen'), 1, reason: '${h.events}');

      // Held past the threshold, nothing recognised, then
      // released: the session stops and the fixed
      // not-heard notice is spoken instead of silence.
      await holdPastThreshold(tester);
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.stop'), greaterThanOrEqualTo(1),
          reason: '${h.events}');
      await pumpUntilSpeak(tester, h, '没有听清，请按住按钮再说一次。');
      expect(h.events, contains('tts.speak:没有听清，请按住按钮再说一次。'),
          reason: '${h.events}');

      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    testWidgets(
        'crossover with the automatic loop: press stops it '
        'first, release hands the microphone back',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      // The automatic loop IS running (that is the point of
      // this test): a session was opened after startup.
      expect(h.count('asr.listen'), greaterThanOrEqualTo(1),
          reason: 'auto listen after startup: ${h.events}');
      h.events.clear();

      final TestGesture gesture = await pressPtt(tester);
      // The automatic session yields BEFORE the cue: an
      // asr.stop precedes the cue speak, and no session of
      // any kind starts before the cue completes.
      final int cueIdx = h.events.indexOf('tts.speak:请说');
      expect(cueIdx, greaterThan(0), reason: '${h.events}');
      expect(h.events.first, 'vibrate', reason: '${h.events}');
      final int yieldStop = h.events.indexOf('asr.stop');
      expect(yieldStop, greaterThanOrEqualTo(0),
          reason: '${h.events}');
      expect(yieldStop, lessThan(cueIdx), reason: '${h.events}');
      expect(h.count('asr.listen'), 0, reason: '${h.events}');

      expect(h.completeSpeak('请说'), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.listen'), 1, reason: '${h.events}');

      // While the button is held, the automatic loop must
      // not insert a session of its own.
      await tester.pump(const Duration(milliseconds: 500));
      expect(h.count('asr.listen'), 1, reason: '${h.events}');

      // Content, then release: the session stops, and after
      // the resulting speech finishes the automatic loop
      // resumes -- exactly one more listen, in order:
      // auto(1) -> stop -> PTT(1) -> stop -> auto restored(1).
      await holdPastThreshold(tester);
      await deliverFinalResult(tester, '你好');
      await gesture.up();
      await tester.pump();
      for (int i = 0; i < 24 && h.count('asr.listen') < 2; i++) {
        h.completeAllSpeaks();
        await tester.pump(const Duration(milliseconds: 150));
      }
      expect(h.count('asr.listen'), 2, reason: '${h.events}');
      final List<int> listens = <int>[
        for (int i = 0; i < h.events.length; i++)
          if (h.events[i] == 'asr.listen') i,
      ];
      final int stopBetween = h.events
          .sublist(listens[0], listens[1])
          .indexOf('asr.stop');
      expect(stopBetween, greaterThanOrEqualTo(0),
          reason: '${h.events}');

      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    testWidgets(
        'a press during a P0 danger prompt only vibrates, '
        'then enters once the danger finishes',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await tapPanelText(tester, '停止语音识别');

      // The simulated-danger buttons are only enabled while
      // navigating, so drive the demo navigation first
      // (completing its prompts as they come), then trigger
      // the vehicle danger and keep it PLAYING (its speak
      // future is held by this test).
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

      // Press while the P0 prompt plays (state machine,
      // Codex re-test of c104dc7): the press is DEFERRED --
      // vibration only. The cue is NOT spoken over the
      // danger prompt, no session starts, and no physical
      // stop is issued against the danger utterance: the
      // P0 announcement is never interrupted.
      final TestGesture gesture = await pressPtt(tester);
      final List<String> duringP0 = h.events.sublist(dangerIdx + 1);
      expect(duringP0, contains('vibrate'), reason: '${h.events}');
      expect(duringP0, isNot(contains('tts.speak:请说')),
          reason: '${h.events}');
      expect(h.count('asr.listen'), 0, reason: '${h.events}');
      expect(duringP0, isNot(contains('tts.stop')),
          reason: '${h.events}');
      // The danger prompt is STILL playing: not cancelled,
      // not completed early.
      expect(
        h.speakQueue.any((MapEntry<String, Completer<dynamic>> e) =>
            e.key == '前方有机动车，请停下。' && !e.value.isCompleted),
        isTrue,
        reason: '${h.events}',
      );

      // Keep holding in REAL time past the production
      // 1.5 s just-started-P0 recency window, so that when
      // the danger completes, the deferred press can enter
      // prompting right away (in fake time nothing else
      // speaks meanwhile, so the held danger stays the
      // active prompt throughout the wait).
      await holdPastThreshold(tester);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1300)));

      // The danger prompt finishes NORMALLY (never
      // cancelled): the still-held deferred press now
      // enters prompting -- the cue is spoken, and
      // completing it opens the session.
      expect(h.completeSpeak('前方有机动车，请停下。'), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('已取消播报的迟到完成'), findsNothing);
      await pumpUntilSpeak(tester, h, '请说');
      expect(h.completeSpeak('请说'), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.listen'), 1, reason: '${h.events}');

      // Release: the session stops, and with nothing
      // recognised the fixed no-content notice follows
      // once the post-release grace has run out.
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
        'a press interrupts a playing non-P0 straight prompt '
        'with a physical stop', (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await tapPanelText(tester, '停止语音识别');
      h.events.clear();

      // Drive the demo navigation until the straight prompt
      // is genuinely PLAYING (speak future held open).
      await tapPanelText(tester, '语音开始（演示输入：带我去图书馆）');
      await tapPanelText(tester, '理解并规划路线');
      await tapPanelText(tester, '开始导航（直行节奏启动）');
      for (int i = 0;
          i < 24 && !h.events.contains('tts.speak:直走');
          i++) {
        for (final MapEntry<String, Completer<dynamic>> e in h.speakQueue) {
          if (!e.value.isCompleted && e.key != '直走') e.value.complete(1);
        }
        await tester.pump(const Duration(milliseconds: 150));
      }
      final int straightIdx = h.events.indexOf('tts.speak:直走');
      expect(straightIdx, greaterThanOrEqualTo(0),
          reason: '${h.events}');
      h.events.removeRange(0, straightIdx + 1);

      // Press: a physical stop lands on the straight
      // utterance, before the cue is spoken.
      final TestGesture gesture = await pressPtt(tester);
      await pumpUntilSpeak(tester, h, '请说');
      final int stopIdx = h.events.indexOf('tts.stop');
      final int cueIdx = h.events.indexOf('tts.speak:请说');
      expect(stopIdx, greaterThanOrEqualTo(0), reason: '${h.events}');
      expect(stopIdx, lessThan(cueIdx), reason: '${h.events}');

      // The cancelled straight prompt's late completion is
      // discarded by the stop-race guard (visible in the
      // app log), never driven into a finish.
      expect(h.completeSpeak('直走'), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('已取消播报的迟到'), findsWidgets);

      expect(h.completeSpeak('请说'), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.listen'), 1, reason: '${h.events}');
      await holdPastThreshold(tester);
      await gesture.up();
      await tester.pump();
      await pumpUntilSpeak(tester, h, '没有听清，请按住按钮再说一次。');

      // End the demo navigation before the shared cleanup.
      final Finder stopNav = find.widgetWithText(ElevatedButton, '停下');
      await tester.ensureVisible(stopNav);
      await tester.pump();
      await tester.tap(stopNav);
      await tester.pump();
      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    testWidgets(
        'small surface with large text: no overflow, TalkBack '
        'node still reachable', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      // ignore: deprecated_member_use
      tester.platformDispatcher.textScaleFactorTestValue = 1.2;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(const MingtuApp());
      await tester.pump();
      await settleStartup(tester);

      // Phase 1 (320x568, text x1.2): no exception at all,
      // and the push-to-talk TalkBack node is reachable.
      expect(tester.takeException(), isNull);
      SemanticsData data = tester
          .getSemantics(
              find.bySemanticsLabel('按住说话按钮，按住后说话，松开结束'))
          .getSemanticsData();
      expect(data.label, contains('按住说话按钮，按住后说话，松开结束'));

      // Phase 2 (same surface, text x2.0): strictly no
      // exception either. The camera placeholder used to
      // overflow the fixed camera area at large text
      // scales; it now scales down / scrolls internally,
      // so large-text small-screen layout is a hard
      // guarantee, not a tolerated known defect.
      // ignore: deprecated_member_use
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      data = tester
          .getSemantics(
              find.bySemanticsLabel('按住说话按钮，按住后说话，松开结束'))
          .getSemanticsData();
      handle.dispose();
      expect(data.label, contains('按住说话按钮，按住后说话，松开结束'));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'TalkBack: the PTT semantics node carries the '
        'long-press action and the unchanged label',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      final SemanticsHandle handle = tester.ensureSemantics();
      await settleRecordedApp(tester, h);

      final SemanticsNode node = tester
          .getSemantics(find.bySemanticsLabel('按住说话按钮，按住后说话，松开结束'));
      final SemanticsData data = node.getSemanticsData();
      expect(data.label, '按住说话按钮，按住后说话，松开结束');
      expect(data.hasAction(SemanticsAction.longPress), isTrue);

      // Trigger the action once and prove a push-to-talk
      // round actually started -- vibration, then the cue,
      // then (once the cue completes) the PTT session --
      // without waiting out the round's 10 s window.
      final int mark = h.events.length;
      node.owner!.performAction(node.id, SemanticsAction.longPress);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final List<String> round = h.events.sublist(mark);
      expect(round, contains('vibrate'), reason: '$round');
      expect(round, contains('tts.speak:请说'), reason: '$round');
      expect(h.completeSpeak('请说'), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.listen'), greaterThanOrEqualTo(1),
          reason: '${h.events}');
      handle.dispose();

      // Run out the round's 10 s auto-end timer (fake time;
      // the round ends itself through it), then drain the
      // release notice so nothing is left pending.
      await tester.pump(const Duration(seconds: 11));
      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    testWidgets('demo panel controls stay reachable below the button',
        (WidgetTester tester) async {
      Future<void> tapScrollableText(String text,
          {String? semanticsLabel}) async {
        // Scroll the panel by hand until the control is
        // hit-testable, then tap it. (scrollUntilVisible was
        // tried first and cannot be used here: it resolves
        // the finder through widget(), which throws when a
        // semantics label matches both the Semantics widget
        // and its merged button node.) The semanticsLabel
        // parameter documents which control is meant where
        // the visible text alone is ambiguous.
        final Finder finder = find.text(text).hitTestable();
        final Finder scrollable = find.byWidgetPredicate(
          (Widget w) => w is Scrollable && w.axis == Axis.vertical,
        );
        expect(scrollable, findsOneWidget);
        final ScrollPosition pos =
            tester.state<ScrollableState>(scrollable).position;
        // A control is hit-testable only while it intersects
        // BOTH the scroll viewport and the root viewport (the
        // fixed header clips the overlap). That window can be
        // narrower than the coarse steps a drag produces, so
        // probe the whole extent in fine steps (earlier taps
        // may have left the panel scrolled past this control).
        bool found = false;
        for (double t = 0; t <= pos.maxScrollExtent && !found; t += 40) {
          pos.jumpTo(t);
          await tester.pump();
          found = finder.evaluate().isNotEmpty;
        }
        expect(found, isTrue, reason: 'reachable: $text');
        expect(finder, findsOneWidget, reason: 'control: $text');
        await tester.tap(finder);
        await tester.pump();
      }

      await tester.pumpWidget(const MingtuApp());
      await tester.pump();
      // Let startup settle: engine probes run on fake timers,
      // the camera area finishes its first layout and the
      // scroll region's activity settles so drags move it.
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 1000));
      }

      // Walk the demo flow to navigation using only controls
      // inside the scroll region.
      await tapScrollableText('语音开始（演示输入：带我去图书馆）',
          semanticsLabel: '语音开始，演示输入带我去图书馆');
      await tapScrollableText('理解并规划路线');
      await tapScrollableText('开始导航（直行节奏启动）', semanticsLabel: '开始导航');
      expect(find.text('当前任务状态：正在导航'), findsOneWidget);

      // The simulated-danger button is still there and works.
      await tapScrollableText('模拟 YOLO 检测：前方车辆（演示，无摄像头）',
          semanticsLabel: '模拟 YOLO 检测前方车辆');
      expect(find.textContaining('当前提示：前方有机动车'), findsOneWidget);

      // Stop and re-ask live at the top of the scroll region.
      await tapScrollableText('停下');
      expect(find.text('当前任务状态：已暂停'), findsOneWidget);
      await tapScrollableText('重新问目的地');

      for (int i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 1500));
      }
    });
  });
}
