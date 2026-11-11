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
  /// When set, the platform's answer to stop() stays in
  /// flight until the completer completes -- a slow
  /// engine stop. Null (the default) answers immediately,
  /// exactly as before.
  Completer<dynamic>? stopGate;

  /// When set, the platform's answer to cancel() stays in
  /// flight until the completer completes -- a slow engine
  /// cancel. Null (the default) answers immediately,
  /// exactly as before.
  Completer<dynamic>? cancelGate;

  /// Serialization barrier (production, this round): the
  /// adapter considers a session fully closed only once
  /// its stop()/cancel() has returned AND the closing
  /// status (notListening/done) has been received. A real
  /// platform always delivers that status, so by DEFAULT
  /// this fake answers every stop/cancel with an automatic
  /// notListening status on a microtask. Tests that need a
  /// session stuck in "closing" set this to false and
  /// deliver the status by hand via deliverCloseStatus().
  bool autoCloseStatus = true;

  /// Set by the watchdog-restart scenario: the platform
  /// cancel that follows is the adapter watchdog's prod,
  /// not a session close, so it queues no closing status.
  bool nextCancelIsWatchdogProd = false;

  /// Test-side bookkeeping: how many sessions have been
  /// fully closed so far. The automatic closing status is
  /// only delivered when a stop/cancel actually ends a
  /// session that a listen opened; with several sessions
  /// stopped (the mic-close before every scheduler speak,
  /// the release stop, the plugin's own pause timer), only
  /// the FIRST answer carries a status -- later stops find
  /// no open session and, exactly like the real platform,
  /// produce none. Without this the adapter's open-session
  /// bookkeeping and the app's session-id validation drift
  /// apart and unrelated prompts trigger phantom session
  /// ends downstream.
  int unclosedSessions = 0;
  int pendingCloseStatuses = 0;

  /// True once any session has been opened on this fake
  /// platform: from then on an 'initialize' call is the
  /// adapter's close-confirmation re-registration, and the
  /// platform answers it by delivering the oldest queued
  /// closing outcome (the stopped session's terminal
  /// no-match error, then its closing status) -- exactly
  /// what a real recogniser reports when its listeners
  /// are (re)registered after a stop.
  bool platformSessionSeen = false;

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
            if (identical(this, activeVoiceHarness) &&
                platformSessionSeen &&
                pendingCloseStatuses > 0) {
              // Close-confirmation flush: deliver the
              // queued closing outcome asynchronously, the
              // way the platform posts it to the channel.
              Future<void>(() async {
                await deliverAutoCloseStatus();
              });
            }
            return asrInitResult;
          case 'listen':
            events.add('asr.listen');
            platformSessionSeen = true;
            unclosedSessions++;
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
            noteSessionStopped();
            return null;
          case 'cancel':
            events.add('asr.cancel');
            if (nextCancelIsWatchdogProd) {
              nextCancelIsWatchdogProd = false;
            } else {
              noteSessionStopped();
            }
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
      // The app also SUBSCRIBES to the gyro/magnetometer
      // event streams. Without a mock stream handler the
      // subscription never activates, and when the widget
      // tree is torn down after a FAILED test the stream
      // deactivation throws MissingPluginException --
      // which poisons the NEXT test in this file. A no-op
      // handler makes listen/cancel on these channels
      // always succeed (same guard as the codex file).
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

  /// A stop/cancel ends the currently open session (if
  /// any): queue its automatic closing status, delivered
  /// once its gated future resolves. Mirrors the real
  /// platform, which answers a session-ending stop with
  /// exactly one notListening status -- and a stop that
  /// finds no open session with none.
  void noteSessionStopped() {
    if (unclosedSessions > 0) {
      unclosedSessions--;
      pendingCloseStatuses++;
    }
  }

  /// Deliver one queued automatic closing status, if the
  /// auto-status behaviour is on. Called by the test
  /// drivers after pumps, the same points at which the
  /// real platform's status would have landed.
  Future<void> deliverAutoCloseStatus() async {
    if (!autoCloseStatus || pendingCloseStatuses == 0) return;
    pendingCloseStatuses--;
    await deliverCloseStatus();
  }

  /// Deliver ALL queued closing statuses: a session that
  /// was stopped and then re-listened before its status
  /// landed leaves TWO statuses queued (one per close),
  /// and the adapter's pending-close count needs both.
  Future<void> deliverAllCloseStatuses() async {
    while (pendingCloseStatuses > 0) {
      await deliverAutoCloseStatus();
    }
  }

  /// Deliver the closing status (notListening) the way
  /// the platform does: a notifyStatus platform->Dart call
  /// on the plugin channel.
  /// Deliver ONLY the closing status (notListening),
  /// WITHOUT the session's terminal no-match outcome: used
  /// by scenarios that deliver the outcome separately, on
  /// their own schedule (e.g. the Xiaomi late-result
  /// sequence, where the outcome lands ~1.4 s after the
  /// status).
  Future<void> deliverCloseStatusOnly() async {
    final ByteData data = const StandardMethodCodec()
        .encodeMethodCall(const MethodCall('notifyStatus', 'notListening'));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'plugin.csdcorp.com/speech_to_text',
      data,
      (ByteData? _) {},
    );
  }

  Future<void> deliverCloseStatus() async {
    // A real recogniser closing a stopped session first
    // reports the session's terminal outcome. Under the
    // CURRENT plugin (speech_to_text 7.5.0), however,
    // a stop()-initiated end is a USER-ENDED session on
    // the Dart side, and the plugin SUPPRESSES that
    // session's notifyError entirely (its _onNotifyError
    // returns early when user-ended): the deliverable
    // outcome of a stopped session therefore never
    // reaches the adapter's error listener at all. What
    // CAN arrive is its closing status, and -- on the
    // Xiaomi engine, ~1.4 s late -- a delayed final
    // result. This driver therefore delivers the closing
    // status ONLY. (History: this driver used to inject
    // the terminal no-match error before the status, on
    // the theory that the plugin forwarded it; that
    // theory predates the plugin-source check in this
    // round and described a delivery the plugin never
    // makes -- scenarios built on it settled presses
    // through an event that cannot occur on device.)
    // [The original injected outcome call is retained
    // below, disabled, as the record of the old model.]
    // (The old model also injected a notifyError outcome
    // here, before the status; that delivery is removed
    // entirely -- see the note above.)
    final ByteData data = const StandardMethodCodec()
        .encodeMethodCall(const MethodCall('notifyStatus', 'notListening'));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'plugin.csdcorp.com/speech_to_text',
      data,
      (ByteData? _) {},
    );
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
/// Rebind the harness to the app instance THIS test
/// just created. The speech plugin is a process-wide
/// singleton whose initialize() latch is one-shot per
/// process: after the first test, later app instances'
/// adapters never reach the platform initialize again,
/// so their close confirmations must be driven through
/// this harness directly (the drivers deliver the
/// closing outcomes on the channel, which is where the
/// platform would put them). Each test installs a FRESH
/// harness, so the binding is (re)made here, per test.
RecordingVoiceChannels? activeVoiceHarness;

Future<void> settleRecordedApp(
    WidgetTester tester, RecordingVoiceChannels h) async {
  activeVoiceHarness = h;
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
    await h.deliverAllCloseStatuses();
    await tester.pump();
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

/// Press, complete the cue, and wait until the PTT session
/// has actually opened (an 'asr.listen' beyond the count
/// already on the channel). Completing the cue only STARTS
/// the session-open chain: the recogniser plugin's own
/// stop() future and the adapter's close-barrier wait sit
/// between the cue and the listen call, and fake-time pumps
/// can run ahead of those real-event-loop turns. Poll in
/// real time, delivering queued closing statuses, until the
/// listen lands.
Future<TestGesture> pressUntilPttListening(
    WidgetTester tester, RecordingVoiceChannels h) async {
  final int listensBefore = h.count('asr.listen');
  final TestGesture g = await pressPtt(tester, h);
  expect(h.completeSpeak('请说'), isTrue,
      reason: 'cue spoken: ${h.events}');
  for (int i = 0; i < 40; i++) {
    await h.deliverAllCloseStatuses();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
    if (h.count('asr.listen') > listensBefore) return g;
  }
  fail('press never opened its session: ${h.events}');
}

/// Variant of [pressUntilPttListening] for a press whose
/// cue was already requested (e.g. a press deferred by a
/// P0 prompt, or one whose cue completion is asserted
/// separately): completes the cue and polls until the
/// session opens. Returns the gesture unchanged (held
/// throughout).
Future<TestGesture> pressUntilPttListeningFrom(WidgetTester tester,
    RecordingVoiceChannels h, TestGesture g) async {
  final int listensBefore = h.count('asr.listen');
  expect(h.completeSpeak('请说'), isTrue,
      reason: 'cue spoken: ${h.events}');
  for (int i = 0; i < 40; i++) {
    await h.deliverAllCloseStatuses();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
    if (h.count('asr.listen') > listensBefore) return g;
  }
  fail('press never opened its session: ${h.events}');
}

/// State-line assertion, migrated (MT-1111-PTT-C): the
/// panel's rendered '当前任务状态：…' line is read from state.
void expectTaskState(String stateLine) {
  expect(mingtuHomeDebugHandle!.taskStateText, stateLine);
}

/// Prompt-line assertion, migrated.
void expectPromptLine(String promptLine, {required bool present}) {
  final String actual = mingtuHomeDebugHandle!.currentPromptText;
  if (present) {
    expect(actual, promptLine);
  } else {
    expect(actual, isNot(promptLine));
  }
}

Finder pttBlock() =>
      find.byKey(const ValueKey<String>('push-to-talk-area'));

/// Press and hold the push-to-talk button: the gesture must
/// pass the long-press timeout before the production press
/// sequence starts.
/// The raw gesture: starts the long-press and pumps the
/// long-press timeout, nothing more.
Future<TestGesture> startPttGesture(WidgetTester tester) async {
  final TestGesture g =
      await tester.startGesture(tester.getCenter(pttBlock()));
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return g;
}

/// Press and hold the push-to-talk button. Under the
/// serialization barrier a press whose predecessor session
/// is still closing waits in prompting (vibration only)
/// until the closing status lands, so after the gesture
/// this delivers any queued automatic closing statuses and
/// pumps until the press sequence has actually run (the
/// cue was requested, or a session started, or -- for a
/// press deferred by a still-playing P0 prompt -- nothing
/// further can happen and the pumps simply settle).
Future<TestGesture> pressPtt(WidgetTester tester,
    [RecordingVoiceChannels? h]) async {
  final TestGesture g = await startPttGesture(tester);
  if (h != null) {
    for (int i = 0; i < 10; i++) {
      await h.deliverAutoCloseStatus();
      await tester.pump(const Duration(milliseconds: 100));
      if (h.events.contains('tts.speak:请说') ||
          h.count('asr.listen') > 0) {
        break;
      }
    }
  }
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
    // A real platform posts a stopped session's closing
    // status promptly; deliver queued ones here too, the
    // same points the other drivers use. Without the
    // delivery a close can stay unconfirmed past the
    // adapter's watchdog while this driver waits for a
    // speak that the watchdog's restart would pre-empt.
    await h.deliverAutoCloseStatus();
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<void> tapPanelText(WidgetTester tester, String text) async {
  // MT-1111-PTT-C: no panel exists anymore; the label is
  // dispatched to the debug handle (same handlers).
  await drivePanelAction(tester, text);
}

/// MT-1111-PTT-C: the demo panel is gone from the app's
/// interface, so the flows its buttons drove are driven
/// through the app's debug handle -- the very handlers the
/// buttons called. Label mapping kept 1:1 with the old
/// panel so call sites read unchanged.
Future<void> drivePanelAction(WidgetTester tester, String label) async {
  final MingtuHomeDebugHandle h = mingtuHomeDebugHandle!;
  switch (label) {
    case '停止语音识别':
      h.stopVoiceRecognition();
    case '重新问目的地':
      h.askDestination();
    case '停下':
      h.voiceCommand('停下');
    case '语音开始（演示输入：带我去图书馆）':
      h.startVoiceDemo();
    case '理解并规划路线':
      h.planRoute();
    case '开始导航（直行节奏启动）':
      h.startNavigating();
    case '前方转弯（暂停直行）':
      h.turnAhead();
    case '模拟 YOLO 检测：前方行人（演示，无摄像头）':
      h.simulatePersonAhead();
    case '模拟 YOLO 检测：前方车辆（演示，无摄像头）':
      h.simulateVehicleAhead();
    case '模拟 YOLO：连续 3 帧前方无障碍（演示）':
      h.simulateClearFrames();
    case '打开摄像头（YOLO 实时检测）':
      await h.openYoloLive();
    case '云端视觉辅助（低频，经代理，本地检测仍为主）':
      h.triggerManualVision();
    case '高德真实路线（真实导航：需已核验目的地与路线代理）':
      h.fetchAmapRoute();
    case '开始语音识别（真机，单次最长 10 秒）':
      // The panel's listen button has no UI successor: the
      // app is press-and-hold only now (asserted elsewhere).
      break;
    default:
      fail('no debug-handle mapping for panel label: $label');
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> drainVoice(WidgetTester tester, RecordingVoiceChannels h,
    {int rounds = 14}) async {
  for (int i = 0; i < rounds; i++) {
    h.completeAllSpeaks();
    await h.deliverAllCloseStatuses();
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
  // MT-1111-PTT-C: the panel's 停止语音识别 button is gone;
  // the shutdown stop goes through the debug handle.
  mingtuHomeDebugHandle!.stopVoiceRecognition();
  await tester.pump();
  await drainVoice(tester, h, rounds: 6);
  // Settle ANY engine watchdog ladder the drains armed:
  // a close whose status was still in flight when the
  // drains ended arms the adapter's 3 s watchdog; if it
  // prods during these pumps it arms a 1 s retry timer
  // that must also fire (into the engineDisposed guard
  // after teardown below) rather than leak past the test.
  await tester.pump(const Duration(seconds: 5));
  await h.deliverAllCloseStatuses();
  await tester.pump(const Duration(seconds: 2));
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

/// Really sleep while the button is held, so the press
/// passes the production 300 ms threshold (which reads the
/// real clock, not fake test time).
Future<void> holdPastThreshold(WidgetTester tester) async {
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 380)));
}

void main() {
  group('step C push-to-talk layout', () {
    testWidgets(
        'the camera area shows its closed placeholder while '
        'the live view is closed', (WidgetTester tester) async {
      await tester.pumpWidget(const MingtuApp());
      await tester.pump();
      await settleStartup(tester);

      // First commit (panel-era layout still in place): the
      // closed camera area shows its placeholder label. The
      // blank-area form of this test belongs to the second
      // commit's zero-Text interface.
      expect(find.text('摄像头未开启'), findsOneWidget);
      final Finder area =
          find.byKey(const ValueKey<String>('camera-preview-area'));
      expect(area, findsOneWidget);
      final Size size = tester.getSize(area);
      expect(size.height, greaterThan(200), reason: 'camera area: $size');
    });

    testWidgets(
        'press order: vibrate, cue spoken and awaited, THEN '
        'listen; release stops and submits',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      // Press-and-hold only (real-device fix round): startup
      // opens NO session -- the microphone opens only while
      // the button is held. (This assertion replaces the old
      // auto-listen expectation.)
      expect(h.count('asr.listen'), 0,
          reason: 'no listen at startup: ${h.events}');
      h.events.clear();

      TestGesture gesture = await pressPtt(tester, h);
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
      // (The gesture is already held; re-drive the press
      // through the shared wait-until-listening driver.)
      gesture = await pressUntilPttListeningFrom(tester, h, gesture);
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
      h.events.clear();

      // Variant A: released while the cue is still playing.
      // The sequence discovers the release after the cue and
      // answers with the too-short notice.
      TestGesture gesture = await pressPtt(tester, h);
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
      gesture = await pressPtt(tester, h);
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
      h.events.clear();

      final TestGesture gesture =
          await pressUntilPttListening(tester, h);
      expect(h.count('asr.listen'), 1, reason: '${h.events}');

      // Held past the threshold, nothing recognised, then
      // released: the session stops and the fixed
      // not-heard notice is spoken instead of silence.
      // (Updated for the 3 s settle window: the window
      // deliberately outlasts the Xiaomi engine's ~1.4 s
      // late result; with no outcome at all the press
      // escalates to cancel-confirm only when it expires,
      // so run the fake clock past it.)
      await holdPastThreshold(tester);
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.stop'), greaterThanOrEqualTo(1),
          reason: '${h.events}');
      // pumpUntilSpeak (not raw clock pumps) must drive
      // the window: the settle chain after expiry goes
      // through real platform futures (cancel-confirm),
      // which fake-clock pumps alone do not run out.
      // The drivers also deliver the queued closing
      // status: a real platform posts it promptly, and
      // WITHOUT it the press's close stays unconfirmed
      // past the adapter's 3 s watchdog -- the watchdog
      // then force-restarts the engine and speaks its
      // restart notice INSTEAD of this press's notice
      // (the full-file failure mode of this test before
      // this round's driver fix: the restart notice is
      // correct watchdog behaviour for a close that never
      // confirms, so it is the delivery, not the
      // watchdog, that was missing).
      await pumpUntilSpeak(tester, h, '没有听清，请按住按钮再说一次。',
          rounds: 40);
      expect(h.events, contains('tts.speak:没有听清，请按住按钮再说一次。'),
          reason: '${h.events}');

      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    testWidgets(
        'no automatic listening anywhere: startup opens no '
        'session and a finished press never reopens one',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      // Startup: greeting spoken, ZERO sessions opened.
      expect(h.count('asr.listen'), 0,
          reason: 'no auto listen after startup: ${h.events}');
      h.events.clear();

      // One held press opens exactly one session...
      final TestGesture gesture =
          await pressUntilPttListening(tester, h);
      expect(h.count('asr.listen'), 1, reason: '${h.events}');
      await holdPastThreshold(tester);
      await deliverFinalResult(tester, '你好');
      await gesture.up();
      await tester.pump();
      // ...and after the press completes and its speech
      // finishes, NO further session opens (the old loop
      // resumed here). The closing status is delivered in
      // its two parts on purpose: notListening alone must
      // not re-listen (the Xiaomi collision), and the
      // session's late no-match outcome then settles the
      // press -- still without any new listen.
      await h.deliverCloseStatusOnly();
      await tester.pump(const Duration(milliseconds: 200));
      expect(h.count('asr.listen'), 1, reason: '${h.events}');
      await drainVoice(tester, h, rounds: 6);
      expect(h.count('asr.listen'), 1, reason: '${h.events}');

      await shutdownVoice(tester, h);
    });

    testWidgets(
        'a press during a P0 danger prompt only vibrates, '
        'then enters once the danger finishes',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);

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
      TestGesture gesture = await pressPtt(tester, h);
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
      expect(mingtuHomeDebugHandle!.logText,
          isNot(contains('已取消播报的迟到完成回调已忽略')));
      await pumpUntilSpeak(tester, h, '请说');
      gesture = await pressUntilPttListeningFrom(tester, h, gesture);
      expect(h.count('asr.listen'), 1, reason: '${h.events}');

      // Release: the session stops, and with nothing
      // recognised the fixed no-content notice follows
      // once the post-release grace has run out.
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.stop'), greaterThanOrEqualTo(1),
          reason: '${h.events}');
      await h.deliverAllCloseStatuses();
      await tester.pump(const Duration(milliseconds: 300));
      await pumpUntilSpeak(tester, h, '没有听清，请按住按钮再说一次。');

      // MT-1111-PTT-C: the panel's 停下 button is gone;
      // the same stop flow is driven by voice command.
      mingtuHomeDebugHandle!.voiceCommand('停下');
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
      TestGesture gesture = await pressPtt(tester, h);
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
      // The log line lives in state now (the panel log area
      // is gone); the same discard must be recorded there.
      expect(mingtuHomeDebugHandle!.logText,
          contains('已取消播报的迟到完成回调已忽略'));

      gesture = await pressUntilPttListeningFrom(tester, h, gesture);
      expect(h.count('asr.listen'), 1, reason: '${h.events}');
      await holdPastThreshold(tester);
      await gesture.up();
      await tester.pump();
      await pumpUntilSpeak(tester, h, '没有听清，请按住按钮再说一次。');

      // End the demo navigation before the shared cleanup.
      // MT-1111-PTT-C: the panel's 停下 button is gone;
      // the same stop flow is driven by voice command.
      mingtuHomeDebugHandle!.voiceCommand('停下');
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
      // The press first waits for the previous session's
      // full close (serialization barrier): deliver the
      // queued closing statuses until the cue is spoken.
      for (int i = 0;
          i < 10 && !h.events.contains('tts.speak:请说');
          i++) {
        await h.deliverAutoCloseStatus();
        await tester.pump(const Duration(milliseconds: 100));
      }
      final List<String> round = h.events.sublist(mark);
      expect(round, contains('vibrate'), reason: '$round');
      expect(round, contains('tts.speak:请说'), reason: '$round');
      expect(h.completeSpeak('请说'), isTrue);
      for (int i = 0; i < 40 && h.count('asr.listen') < 1; i++) {
        await h.deliverAutoCloseStatus();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(h.count('asr.listen'), 1, reason: '${h.events}');
      handle.dispose();

      // Run out the round's 10 s auto-end timer (fake time;
      // the round ends itself through it), then drain the
      // release notice so nothing is left pending.
      await tester.pump(const Duration(seconds: 11));
      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    testWidgets(
        'the demo flow handlers stay reachable through the '
        'debug handle (the panel itself is gone)',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MingtuApp());
      await tester.pump();
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 1000));
      }

      // The flow the scroll-region walk used to drive,
      // through the same handlers via the debug handle.
      await drivePanelAction(tester, '语音开始（演示输入：带我去图书馆）');
      await drivePanelAction(tester, '理解并规划路线');
      await drivePanelAction(tester, '开始导航（直行节奏启动）');
      expectTaskState('当前任务状态：正在导航');

      await drivePanelAction(tester, '模拟 YOLO 检测：前方车辆（演示，无摄像头）');
      expect(mingtuHomeDebugHandle!.currentPromptText,
          contains('当前提示：前方有机动车'));

      await drivePanelAction(tester, '停下');
      expectTaskState('当前任务状态：已暂停');
      await drivePanelAction(tester, '重新问目的地');

      for (int i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 1500));
      }
    });
  });
}
