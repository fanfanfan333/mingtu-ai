import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/adapters/current_location.dart';
import 'package:mingtu_ai/adapters/voice_recorder.dart';
import 'package:mingtu_ai/config/verified_locations.dart';
import 'package:mingtu_ai/core/navigation_tracker.dart';
import 'package:mingtu_ai/core/real_navigation.dart';
import 'package:mingtu_ai/core/voice_commands.dart';
import 'package:mingtu_ai/core/cloud_asr.dart';
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

  /// When set, the platform's answer to cancel() stays in
  /// flight until the completer completes -- a slow engine
  /// cancel. Null (the default) answers immediately,
  /// exactly as before.
  Completer<dynamic>? cancelGate;

  /// Unconfirmed-close rule (production, this round):
  /// the adapter considers a session closed only once
  /// its closing status (notListening/done) has been
  /// received, and no new listen may start before that.
  /// This fake queues one closing status per session-
  /// ending stop/cancel; tests deliver them via
  /// deliverAutoCloseStatus()/deliverCloseStatus().
  /// Tests that need a session stuck in "closing" set
  /// this to false and deliver the status by hand.
  bool autoCloseStatus = true;

  /// Set by the watchdog-restart scenario: the platform
  /// cancel that follows is the adapter watchdog's prod,
  /// not a session close. A real recogniser answers a
  /// cancel issued while a session is already closing by
  /// closing THAT session (one status); it does not open
  /// a second close. While this is set, a cancel queues
  /// no additional closing status.
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
            final Completer<dynamic>? sGate = stopGate;
            if (sGate != null) return sGate.future;
            return null;
          case 'cancel':
            events.add('asr.cancel');
            if (nextCancelIsWatchdogProd) {
              nextCancelIsWatchdogProd = false;
            } else {
              noteSessionStopped();
            }
            final Completer<dynamic>? cg = cancelGate;
            if (cg != null) return cg.future;
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

/// Deliver a recognition ERROR the way the platform does:
/// a notifyError platform->Dart call on the plugin
/// channel, its argument the plugin's JSON string
/// ({"errorMsg": <code>, "permanent": <bool>} -- the
/// platform-channel speech_to_text dispatches the String
/// argument to the singleton's onError, which decodes
/// it). speech_to_text 7.5.0's Android sendError passes
/// permanent=true for EVERY error (CDX1), so the
/// cross-press streak scenarios always send true.
Future<void> deliverChannelError(String code) async {
  final String json = jsonEncode(<String, Object?>{
    'errorMsg': code,
    'permanent': true,
  });
  final ByteData data = const StandardMethodCodec()
      .encodeMethodCall(MethodCall('notifyError', json));
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'plugin.csdcorp.com/speech_to_text',
    data,
    (ByteData? _) {},
  );
}

Future<void> drainVoice(WidgetTester tester, RecordingVoiceChannels h,
    {int rounds = 14}) async {
  for (int i = 0; i < rounds; i++) {
    h.completeAllSpeaks();
    await h.deliverAllCloseStatuses();
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> shutdownVoice(
    WidgetTester tester, RecordingVoiceChannels h) async {
  // Tests that withheld closing statuses (autoCloseStatus
  // = false) restore it before cleanup; deliver whatever
  // is still queued so no session is left half-closed
  // into the tree detach.
  while (h.pendingCloseStatuses > 0) {
    await h.deliverAutoCloseStatus();
  }
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

Future<void> pumpUntilSpeak(
    WidgetTester tester, RecordingVoiceChannels h, String text,
    {int rounds = 20}) async {
  for (int i = 0; i < rounds; i++) {
    if (h.events.contains('tts.speak:$text')) return;
    h.completeAllSpeaks();
    await tester.pump(const Duration(milliseconds: 150));
  }
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
  // The cue may still be QUEUED behind earlier speech when
  // pressPtt returns (its speak was requested but not yet
  // the pending one): poll in REAL time until it is the
  // pending speak, completing whatever IS pending meanwhile
  // -- the same real-time discipline the UI-file driver
  // uses. (A single immediate completeSpeak here raced the
  // cue's queueing whenever a previous announcement was
  // still draining, and failed with an empty event log.)
  for (int i = 0;
      i < 40 &&
          !h.speakQueue.any(
              (MapEntry<String, Completer<dynamic>> e) =>
                  e.key == '请说' && !e.value.isCompleted);
      i++) {
    h.completeAllSpeaks();
    await h.deliverAllCloseStatuses();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
  }
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
  int cuesBefore = h.count('tts.speak:请说');
  expect(h.completeSpeak('请说'), isTrue,
      reason: 'cue spoken: ${h.events}');
  for (int i = 0; i < 40; i++) {
    await h.deliverAutoCloseStatus();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
    if (h.count('asr.listen') > listensBefore) return g;
    if (h.count('tts.speak:请说') > cuesBefore) {
      // A NEW cue appeared while waiting (the caller's cue
      // went stale and this press spoke its own later):
      // complete it and keep waiting.
      cuesBefore = h.count('tts.speak:请说');
      h.completeSpeak('请说');
    }
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
  if (h != null) {
    // The platform delivers a stopped session's closing
    // outcome on its own, promptly: anything still queued
    // from this test's setup (a manual stop tap, a
    // scheduler speak's mic-close) is delivered BEFORE
    // the finger lands, so the press starts from the
    // state the real device would present. A test that
    // deliberately withholds the outcome (autoCloseStatus
    // = false) is unaffected: delivery is a no-op then,
    // and the press waits -- that case is driven through
    // startPttGesture directly.
    await h.deliverAllCloseStatuses();
    await tester.pump();
  }
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

/// Fake recorder for the cloud ASR fallback route
/// (MT-1111-PTT-D(5): startup-unavailable presses record).
class CodexFakeRecorder implements VoiceRecorder {
  bool started = false;
  bool cancelled = false;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<Uint8List?> stop() async {
    started = false;
    return Uint8List.fromList(List<int>.filled(2000, 3));
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    started = false;
  }

  @override
  bool get isRecording => started;
}

/// Every text actually spoken through the recording TTS
/// channel anywhere in this file, for the final
/// forbidden-word sweep.
final List<String> spokenCorpus = <String>[];

void main() {
  group('ASR start failure: vibration + fixed notice (behavioural)', () {
    testWidgets(
        'recogniser unavailable: startup arms the fallback '
        'and the FIRST press records directly (PTT-D(5))',
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

      // MT-1111-PTT-D(5): an engine unavailable AT STARTUP
      // arms the cloud fallback, so the very first press
      // records with the app's own recorder instead of
      // attempting (and failing) a system ASR start. (The
      // old shape of this test asserted the failed-start
      // vibration + notice; that path is still covered by
      // 'engine refuses listen' below, where startup
      // succeeded and the start itself is refused.)
      expect(mingtuHomeDebugHandle!.localAsrBroken, isTrue,
          reason: 'startup unavailability must arm the fallback');
      final CodexFakeRecorder recorder = CodexFakeRecorder();
      mingtuHomeDebugHandle!.setRecorder(recorder);

      final TestGesture gesture = await pressPtt(tester, h);
      expect(h.completeSpeak('请说'), isTrue);
      for (int i = 0; i < 20 && !recorder.started; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(recorder.started, isTrue, reason: '${h.events}');
      // No system session was ever opened, and the press
      // vibrated as every press does.
      expect(h.count('asr.listen'), 0, reason: '${h.events}');
      expect(h.count('vibrate'), greaterThanOrEqualTo(1),
          reason: '${h.events}');

      // Release: the clip goes to the cloud route; with no
      // ASR proxy configured in this environment the press
      // ends with the fixed not-configured text, verbatim.
      await holdPastThreshold(tester);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));
      await pumpUntilSpeak(tester, h, '云端识别未配置，无法识别。');
      spokenCorpus.addAll(h.spokenTexts());

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

      final TestGesture gesture = await pressPtt(tester, h);
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
      // This test genuinely speaks the notice: it enters
      // the spoken corpus for the forbidden-word sweep.
      spokenCorpus.add(notice);

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

      // MT-1111-PTT-C: the panel's 停下 button is gone;
      // the same stop flow is driven by voice command.
      mingtuHomeDebugHandle!.voiceCommand('停下');
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
      final TestGesture gesture = await pressPtt(tester, h);
      expect(h.completeSpeak('请说'), isTrue);
      // The start is issued only once the previous session
      // is fully closed (serialization barrier): poll in
      // real time, delivering queued closing statuses,
      // until the gated listen call lands on the channel.
      for (int i = 0; i < 40 && h.count('asr.listen') < 1; i++) {
        await h.deliverAutoCloseStatus();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump(const Duration(milliseconds: 25));
      }
      // The start was ISSUED but the platform has not
      // answered: no session yet, and no stop either.
      expect(h.count('asr.listen'), 1, reason: '${h.events}');
      expect(h.count('asr.stop'), 0, reason: '${h.events}');
      expect(h.count('asr.cancel'), 0, reason: '${h.events}');

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
      expect(h.count('asr.cancel'), 0, reason: '${h.events}');

      // The start returns: the sequence VOIDS the session
      // it just opened immediately -- under the short-press
      // mechanism that is a cancel, never a stop -- and
      // answers with the too-short notice, never the
      // no-content one.
      h.listenGate!.complete(true);
      h.listenGate = null;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await pumpUntilSpeak(tester, h, '请按住说话');
      final int listenIdx = h.events.indexOf('asr.listen');
      final int cancelIdx = h.events.indexOf('asr.cancel');
      expect(cancelIdx, greaterThan(listenIdx), reason: '${h.events}');
      expect(h.count('asr.stop'), 0,
          reason: 'a voided session is cancelled, not stopped: '
              '${h.events}');
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
      final TestGesture gesture2 =
          await pressUntilPttListening(tester, h);
      expect(h.count('asr.listen'), 1, reason: '${h.events}');
      await holdPastThreshold(tester);
      await gesture2.up();
      for (int i = 0; i < 20 && h.count('asr.stop') < 1; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
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

      final TestGesture gesture =
          await pressUntilPttListening(tester, h);
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
        'post-stop final is accepted through the stopping '
        'window, wins over the partial, and is submitted '
        'once', (WidgetTester tester) async {
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

      final TestGesture gesture = await pressUntilPttListening(tester, h);
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

      // Release: the stop begins AND the app opens the
      // adapter's stopping pass-through window
      // (acceptStoppingResults) for exactly this stop.
      // Fake time between here and the final delivery
      // stays far below the 1.5 s deadline.
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.stop'), greaterThanOrEqualTo(1),
          reason: '${h.events}');

      // The engine's post-stop final arrives inside the
      // window. STOPPING-WINDOW MECHANISM (final form):
      // the window keeps this press's results acceptable
      // while stop() is in flight and in the grace right
      // after, so the final reaches the app and completes
      // the press IMMEDIATELY via _onPttFinalInStopping --
      // it wins over the cached partial. The word pair
      // keeps the two texts distinguishable: the final
      // '帮助' is answered with the bare help text, the
      // cached partial '你好' with the unknown-command
      // reply. Only the final's reply may ever appear.
      final String helpText = voiceCommandHelpText();
      final String unknownReply = '没听清。$helpText';
      await deliverFinalResult(tester, '帮助');
      await pumpUntilSpeak(tester, h, helpText);
      expect(h.count('tts.speak:$helpText'), 1, reason: '${h.events}');
      expect(h.events, isNot(contains('tts.speak:$unknownReply')),
          reason: '${h.events}');

      // The completion closed the window: the deadline
      // must not submit anything a second time, and the
      // no-content notice never follows (a final existed).
      await tester.pump(const Duration(seconds: 3));
      expect(h.count('tts.speak:$helpText'), 1, reason: '${h.events}');
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
      final TestGesture gesture = await pressPtt(tester, h);
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
      await pressUntilPttListeningFrom(tester, h, gesture);
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

      // MT-1111-PTT-C: the panel's 停下 button is gone;
      // the same stop flow is driven by voice command.
      mingtuHomeDebugHandle!.voiceCommand('停下');
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
      final TestGesture gesture = await pressPtt(tester, h);
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

      // MT-1111-PTT-C: the panel's 停下 button is gone;
      // the same stop flow is driven by voice command.
      mingtuHomeDebugHandle!.voiceCommand('停下');
      await tester.pump();
      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });
  });

    testWidgets(
        'R6 (new a): a too-short press is voided by cancel; '
        'a final delivered after the 300 ms boundary has '
        'passed is still never executed',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await drainVoice(tester, h, rounds: 8);
      await tapPanelText(tester, '停止语音识别');
      h.events.clear();
      // Pre-close every queued session so the press below
      // is not close-deferred: its prompt step runs at
      // once and the gated listen below is issued
      // immediately.
      for (int i = 0; i < 6 && h.pendingCloseStatuses > 0; i++) {
        await h.deliverAutoCloseStatus();
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Gate the platform's LISTEN answer instead: the
      // press is held inside the starting window (its
      // session has not opened), and the release there --
      // which production times from the press start, not
      // from any session event -- lands inside 300 ms of
      // real time no matter how slow the session drive is,
      // because the long-press recogniser fired only
      // moments ago in real time. (Driving all the way to
      // listening first would make the short-press window
      // a hostage of the harness's session-open latency:
      // the barrier wait plus the plugin's stop future
      // routinely exceed 300 ms of real time between the
      // press start and the listen call.) The pendingStop
      //收尾 then opens the session and voids it with the
      // gated cancel below.
      h.listenGate = Completer<dynamic>();
      // Gate the platform's cancel answer too: the
      // voiding cancel stays in flight while the late
      // final is delivered.
      h.cancelGate = Completer<dynamic>();
      final TestGesture gesture = await pressPtt(tester, h);
      expect(h.completeSpeak('请说'), isTrue);
      for (int i = 0; i < 40 && h.count('asr.listen') < 1; i++) {
        await h.deliverAutoCloseStatus();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(h.count('asr.listen'), 1, reason: '${h.events}');
      final int stopsAtListening = h.count('asr.stop');
      final String helpText = voiceCommandHelpText();
      final String unknownReply = '没听清。$helpText';

      // Release INSIDE the starting window (moments after
      // the press start in real time): the release is
      // recorded as pendingStop while the start is still
      // in flight. Then let the start return: the sequence
      // voids the just-opened session with a CANCEL, not
      // a stop -- the short-press mechanism -- and from
      // that moment nothing from it may be executed. If
      // the收尾 nevertheless took the stop path, the
      // pendingStop mechanism did not engage and the
      // premise of this test does not hold -- fail loudly
      // with that diagnosis instead of asserting against
      // the wrong path.
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(h.count('asr.cancel'), 0, reason: '${h.events}');
      h.listenGate!.complete(true);
      h.listenGate = null;
      for (int i = 0;
          i < 20 && h.count('asr.cancel') + (h.count('asr.stop') - stopsAtListening) < 1;
          i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      if (h.count('asr.cancel') < 1) {
        fail('the release did not engage the short-press '
            'void (no asr.cancel; the drive to listening '
            'must have consumed the 300 ms budget): '
            '${h.events}');
      }
      expect(h.count('asr.stop'), stopsAtListening,
          reason: 'the voided session must be cancelled, '
              'not stopped: ${h.events}');

      // Let REAL time carry the press's total age past
      // the 300 ms boundary (cancel still in flight), and
      // only THEN deliver the session's final. tooShort
      // was fixed at the release instant and the session
      // is void: the final must not be executed even
      // though, measured from the press start, it arrives
      // "late enough" to look like a full press.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 450)));
      await deliverFinalResult(tester, '帮助');
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.events, isNot(contains('tts.speak:$helpText')),
          reason: '${h.events}');
      expect(h.events, isNot(contains('tts.speak:$unknownReply')),
          reason: '${h.events}');

      // The cancel returns: the ONLY PTT text is the
      // too-short notice.
      h.cancelGate!.complete(null);
      h.cancelGate = null;
      await pumpUntilSpeak(tester, h, '请按住说话');
      expect(h.count('tts.speak:请按住说话'), 1, reason: '${h.events}');
      expect(h.events, isNot(contains('tts.speak:$helpText')),
          reason: '${h.events}');

      // Further late results from the voided session are
      // dropped too, and no grace-period text follows.
      await deliverFinalResult(tester, '帮助');
      await deliverPartialResult(tester, '帮助');
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.events, isNot(contains('tts.speak:$helpText')),
          reason: '${h.events}');
      expect(h.events, isNot(contains('tts.speak:$unknownReply')),
          reason: '${h.events}');
      expect(
        h.events,
        isNot(contains('tts.speak:没有听清，请按住按钮再说一次。')),
        reason: '${h.events}',
      );
      expect(h.count('tts.speak:请按住说话'), 1, reason: '${h.events}');

      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    testWidgets(
        'R7 (new b): while the previous session is still '
        'closing, a press only vibrates; a late final of '
        'the old session is not the press\'s input; once '
        'closed, the still-held press proceeds',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await drainVoice(tester, h, rounds: 8);
      // SCENARIO, rewritten for press-and-hold only
      // (real-device fix round): there is no automatic
      // session to wedge anymore. The "previous session
      // still closing" state is the one production actually
      // produces now: a press released moments ago whose
      // session stop has landed but whose closing status
      // has NOT. The first press's late final settles it
      // inside its 3 s stopping window; the second press
      // then lands on an idle state machine whose adapter
      // ledger still holds the first session's unconfirmed
      // close, and waits at the close barrier. Both layers
      // are asserted below.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1700)));
      final TestGesture first = await pressUntilPttListening(tester, h);
      expect(h.count('asr.listen'), 1, reason: '${h.events}');
      await holdPastThreshold(tester);
      // Withhold every closing status from here on: the
      // first press's close never confirms.
      h.autoCloseStatus = false;
      await first.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.stop'), greaterThanOrEqualTo(1),
          reason: '${h.events}');
      expect(h.pendingCloseStatuses, greaterThanOrEqualTo(1),
          reason: '${h.events}');
      h.events.clear();

      // A late final of the OLD session arrives while
      // the first press is in its stopping window: it
      // belongs to that window and settles THAT press
      // (its reply is the first session's own submission)
      // -- it is never another press's input, and it
      // opens no session.
      final String helpText = voiceCommandHelpText();
      await deliverFinalResult(tester, '帮助');
      // UI-A11Y UI-06 adjustment: the help command now
      // speaks the first-launch guide BEFORE the command
      // list, so the list lands later than the old fixed
      // 200 ms pump allowed for; wait for the list itself
      // (this driver completes the guide on the way). The
      // assertion below is unchanged.
      await pumpUntilSpeak(tester, h, helpText);
      expect(h.count('tts.speak:$helpText'), 1,
          reason: 'the late final settled the FIRST press: '
              '${h.events}');
      expect(h.completeSpeak(helpText), isTrue);
      expect(h.count('asr.listen'), 0, reason: '${h.events}');
      h.events.clear();

      // The first press has now SETTLED, but its close is
      // STILL unconfirmed (the closing status is still
      // withheld): a press landing now finds the state
      // machine idle but the adapter's close barrier shut.
      // It vibrates and speaks the one-time wait notice --
      // no cue, and above all NO new listen (the Xiaomi
      // collision shape: a listen here would hit the
      // still-open session). (A press landing DURING the
      // stopping window itself is not this case: the
      // state machine is busy then and the gesture is not
      // a press at all.)
      final TestGesture gesture = await startPttGesture(tester);
      for (int i = 0; i < 10; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(h.count('vibrate'), 1, reason: '${h.events}');
      expect(h.events, contains('tts.speak:请稍等'),
          reason: '${h.events}');
      expect(h.count('asr.listen'), 0, reason: '${h.events}');
      expect(h.events, isNot(contains('tts.speak:请说')),
          reason: '${h.events}');

      // More fake time passes and the waiting press still
      // does not open a session: the close wait has no
      // timeout release. (The one timed resolution the
      // design allows is the adapter's close watchdog --
      // it voids the old session by RESTARTING the engine
      // rather than guessing its status, on a 3 s fuse
      // from the stop. This beat stays inside that fuse;
      // the close is then confirmed by delivery below.)
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      expect(h.count('asr.listen'), 0, reason: '${h.events}');
      expect(h.events, isNot(contains('tts.speak:请说')),
          reason: '${h.events}');

      // Deliver the closing status: the close confirms,
      // and the still-held second press now proceeds --
      // cue first, then its session, in that order.
      await h.deliverCloseStatus();
      for (int i = 0;
          i < 30 && !h.events.contains('tts.speak:请说');
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(h.events, contains('tts.speak:请说'),
          reason: '${h.events}');
      await pressUntilPttListeningFrom(tester, h, gesture);
      expect(h.count('asr.listen'), 1, reason: '${h.events}');
      expect(
        h.events.indexOf('tts.speak:请说') <
            h.events.lastIndexOf('asr.listen'),
        isTrue,
        reason: '${h.events}',
      );

      h.autoCloseStatus = true;
      await holdPastThreshold(tester);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));
      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
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
      final TestGesture g = await pressPtt(tester, h);
      expect(h.completeSpeak('请说'), isTrue);
      for (int i = 0; i < 40; i++) {
        await h.deliverAutoCloseStatus();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
        if (h.count('asr.listen') >= 1) return g;
      }
      fail('press never reached listening: ${h.events}');
    }

    testWidgets(
        'R4: a final arriving while stop() is still in '
        'flight is accepted through the stopping window '
        'and submitted before stop() returns',
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
      // inside the 1.5 s final-wait, stop() has not
      // returned yet, and the app has opened the adapter's
      // stopping pass-through window
      // (acceptStoppingResults) for exactly this stop.
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
      // FINAL-WAIT MECHANISM: the open pass-through
      // window lets the result through the adapter, main
      // accepts it in stopping and completes the press
      // IMMEDIATELY (_onPttFinalInStopping) -- the
      // submission itself (the scheduler taking the reply
      // as the active prompt, mirrored on screen) happens
      // NOW, before stop() is released, so the press
      // never reaches the cancel step at all. The reply's
      // CHANNEL speak stays parked behind the still-gated
      // platform stop (speakAfterClosingMic): the mic must
      // be fully closed before speech starts, which is a
      // separate, established invariant -- not a delay of
      // the submission.
      await deliverFinalResult(tester, '前面有什么');
      await tester.pump(const Duration(milliseconds: 300));
      // MT-1111-PTT-C: the prompt is no longer rendered;
      // the submission is read from the same state field
      // the panel line used to mirror.
      final String promptDuringStop =
          mingtuHomeDebugHandle!.currentPrompt;
      expect(
        promptDuringStop,
        contains(envReply),
        reason: 'the final was submitted during the '
            'stopping window, before stop() returned',
      );
      expect(h.count('tts.speak:$envReply'), 0,
          reason: 'speak stays parked behind the gated mic stop');
      // The cached partial's reply never appears: the
      // final won.
      expect(h.events, isNot(contains('tts.speak:$unknownReply')),
          reason: '${h.events}');

      // Release the gated stop: the parked speak of the
      // FINAL's reply is emitted now, exactly once. No
      // second submission past the deadline, no partial
      // reply, no no-content notice.
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
      // Settle until the scheduler is genuinely idle: in a
      // full-file run the danger prompt's finish can still
      // be in flight when its channel future completes, and
      // a press landing while a P0 entry is still active is
      // DEFERRED by the state machine and then silently
      // cancelled by the immediate release -- the cue would
      // never be spoken at all.
      await settleRecordedApp(tester, h);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1700)));
      // Press and HOLD: if the previous session is still
      // closing, the press waits in prompting for the
      // close (log: '等待上一个识别会话完全关闭'), and the
      // barrier's 800 ms bound runs on the REAL clock --
      // fake pumps cannot advance it. Hold in real time,
      // delivering queued closing statuses, until the cue
      // is actually spoken; only then release (a release
      // inside the wait would cancel the press silently
      // and no cue would ever exist to complete).
      TestGesture gesture = await startPttGesture(tester);
      for (int i = 0;
          i < 20 && !h.events.contains('tts.speak:请说');
          i++) {
        await h.deliverAutoCloseStatus();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(h.events, contains('tts.speak:请说'),
          reason: '${h.events}');
      await gesture.up();
      await tester.pump();
      expect(h.completeSpeak('请说'), isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      await drainVoice(tester, h, rounds: 5);

      // The second press can be close-deferred the same
      // way: hold in real time until its cue is spoken AND
      // still in flight (an older completed cue of the
      // same text may sit in the channel history -- what
      // matters is the pending one), then run the shared
      // wait-until-listening driver.
      gesture = await startPttGesture(tester);
      for (int i = 0;
          i < 20 &&
              !h.speakQueue.any((MapEntry<String, Completer<dynamic>> e) =>
                  e.key == '请说' && !e.value.isCompleted);
          i++) {
        await h.deliverAutoCloseStatus();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        h.speakQueue.any((MapEntry<String, Completer<dynamic>> e) =>
            e.key == '请说' && !e.value.isCompleted),
        isTrue,
        reason: '${h.events}',
      );
      gesture = await pressUntilPttListeningFrom(tester, h, gesture);
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

      // MT-1111-PTT-C: the panel's 停下 button is gone;
      // the same stop flow is driven by voice command.
      mingtuHomeDebugHandle!.voiceCommand('停下');
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

  group('settle-by-order release (no residue heuristics)', () {
    // Shared shape (the stopping-window group's driver):
    // settle, drain, stop the automatic loop, clear the
    // event log, then press until PTT listening.
    testWidgets(
        'N1: a genuine final arriving fast in a fresh '
        'session is accepted and executed; no extra '
        'listen, no no-content notice',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await drainVoice(tester, h, rounds: 8);
      h.events.clear();

      // SCENARIO SETUP, rewritten for press-and-hold only
      // (real-device fix round): this test used to wedge
      // the AUTOMATIC session's close (manual stop with
      // statuses withheld) and open the press through the
      // close-wait branch, because startup always had a
      // session closing. There is no automatic session
      // anymore: the press opens its session directly.
      // The close-wait behaviour itself is covered by the
      // R7 scenario. What this test pins is unchanged: a
      // genuine FAST final in a fresh session is accepted.
      final TestGesture gesture =
          await pressUntilPttListening(tester, h);
      expect(h.count('asr.listen'), 1, reason: '${h.events}');

      // A genuine final FAST (fake milliseconds after the
      // listen -- deep inside the removed 300 ms window,
      // as the session's very first result): accepted,
      // cached, never judged.
      const String envReply = '前方情况：尚未模拟感知帧。';
      await deliverFinalResult(tester, '前面有什么');
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.listen'), 1,
          reason: 'no recovery re-listen: ${h.events}');
      expect(h.events, isNot(contains('tts.speak:$envReply')),
          reason: 'cached while held: ${h.events}');

      await holdPastThreshold(tester);
      await gesture.up();
      await pumpUntilSpeak(tester, h, envReply);
      expect(h.count('tts.speak:$envReply'), 1,
          reason: '${h.events}');
      expect(h.count('asr.listen'), 1, reason: '${h.events}');
      expect(
        h.events,
        isNot(contains('tts.speak:没有听清，请按住按钮再说一次。')),
        reason: '${h.events}',
      );
      h.autoCloseStatus = true;
      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    testWidgets(
        'N2: the same word spoken in two consecutive '
        'sessions is executed twice',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await drainVoice(tester, h, rounds: 8);
      await tapPanelText(tester, '停止语音识别');
      h.events.clear();
      final String helpText = voiceCommandHelpText();

      for (int round = 1; round <= 2; round++) {
        final TestGesture gesture =
            await pressUntilPttListening(tester, h);
        expect(h.count('asr.listen'), round,
            reason: 'round $round: ${h.events}');
        await holdPastThreshold(tester);
        // The SAME word as the previous session, as this
        // session's first (fast) final: the removed gate
        // dropped exactly this (same text, no time
        // limit). Now it is this session's own result.
        await deliverFinalResult(tester, '帮助');
        await tester.pump(const Duration(milliseconds: 100));
        await gesture.up();
        // UI-A11Y UI-06 adjustment: the help command now
        // speaks the first-launch guide before the command
        // list, and the list's promotion through the
        // scheduler takes more driver rounds than the old
        // single pumpUntilSpeak budget; pump until this
        // round's list announcement has actually been
        // spoken. The assertion below is unchanged.
        for (int i = 0;
            i < 90 && h.count('tts.speak:$helpText') < round;
            i++) {
          h.completeAllSpeaks();
          await h.deliverAllCloseStatuses();
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(h.count('tts.speak:$helpText'), round,
            reason: 'round $round executed: ${h.events}');
        expect(h.completeSpeak(helpText), isTrue);
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          h.events,
          isNot(contains('tts.speak:没有听清，请按住按钮再说一次。')),
          reason: 'round $round: ${h.events}',
        );
      }
      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    testWidgets(
        'N3: late old traffic after a confirmed close '
        'never executes out of turn; session 2 stays '
        'listening and only its own result is submitted',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await drainVoice(tester, h, rounds: 8);
      await tapPanelText(tester, '停止语音识别');
      h.events.clear();

      // Session 1 (a complete PTT press): its own final
      // is delivered while held, submitted on release and
      // executed; the release stop's close is then
      // CONFIRMED (its queued statuses delivered) before
      // anything else happens.
      final String helpText = voiceCommandHelpText();
      final TestGesture g1 = await pressUntilPttListening(tester, h);
      await holdPastThreshold(tester);
      await deliverFinalResult(tester, '帮助');
      await tester.pump(const Duration(milliseconds: 100));
      await g1.up();
      await pumpUntilSpeak(tester, h, helpText);
      expect(h.count('tts.speak:$helpText'), 1,
          reason: 'session 1 executed its own result: '
              '${h.events}');
      expect(h.completeSpeak(helpText), isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      for (int i = 0; i < 10 && h.pendingCloseStatuses > 0; i++) {
        await h.deliverAutoCloseStatus();
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(h.pendingCloseStatuses, 0,
          reason: 'session 1 close confirmed: ${h.events}');
      h.events.clear();

      // Session 2 opens (a PTT press) whose cue stays
      // IN FLIGHT (its speak is gated): the press is in
      // prompting and its platform listen has NOT been
      // issued yet.
      final TestGesture gesture = await pressPtt(tester, h);
      expect(h.count('tts.speak:请说'), 1, reason: '${h.events}');
      expect(h.count('asr.listen'), 0, reason: '${h.events}');

      // Session 1's LEFTOVER final arrives now. This is
      // the shape task scene 3 targets at the app layer:
      // the final is routed through the OLD session's
      // plugin closure (no new listen exists yet to
      // replace it), the adapter's generation gate for
      // that closed session drops it, and the app --
      // whose press is only prompting, never listening --
      // has no path that could execute or cache it. It
      // is NOT judged by text or timing: it belongs to a
      // voided generation, full stop.
      await deliverFinalResult(tester, '帮助');
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('tts.speak:$helpText'), 0,
          reason: 'the leftover never executed: ${h.events}');
      expect(h.count('asr.listen'), 0,
          reason: 'still only prompting: ${h.events}');

      // Session 1's duplicate closing status arrives in
      // the same window: repaid from session 1's
      // owed-status ledger (and the close ledger), and
      // PTT mode never lets a status event relisten.
      await h.deliverCloseStatus();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.listen'), 0,
          reason: 'no status-driven relisten: ${h.events}');

      // The cue completes (the driver completes its
      // speak): the press enters its own listening
      // session (session 2 proper).
      await pressUntilPttListeningFrom(tester, h, gesture);
      expect(h.count('asr.listen'), 1, reason: '${h.events}');

      // Session 2's OWN final while still held: cached,
      // and on release it is the ONLY submission.
      const String envReply = '前方情况：尚未模拟感知帧。';
      await deliverFinalResult(tester, '前面有什么');
      await tester.pump(const Duration(milliseconds: 100));
      await holdPastThreshold(tester);
      await gesture.up();
      await pumpUntilSpeak(tester, h, envReply);
      expect(h.count('tts.speak:$envReply'), 1,
          reason: 'only session 2 own result submitted: '
              '${h.events}');
      expect(h.count('tts.speak:$helpText'), 0,
          reason: 'the leftover was never submitted: '
              '${h.events}');
      await tester.pump(const Duration(seconds: 3));
      expect(h.count('tts.speak:$envReply'), 1,
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
        'N4: no final within the 3 s window after the '
        'release: the '
        'session is cancelled, its close confirmed, and '
        'the cached partial is submitted exactly once',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await drainVoice(tester, h, rounds: 8);
      await tapPanelText(tester, '停止语音识别');
      h.events.clear();

      final TestGesture gesture =
          await pressUntilPttListening(tester, h);
      expect(h.count('asr.listen'), 1, reason: '${h.events}');
      await holdPastThreshold(tester);
      // A partial only -- never a final.
      final String helpText = voiceCommandHelpText();
      await deliverPartialResult(tester, '帮助');
      await tester.pump(const Duration(milliseconds: 100));

      // Release with the platform stop GATED: the stop
      // stays in flight, so the plugin cannot forward
      // the partial as the stop's terminal final during
      // the wait -- the session genuinely has no final.
      // The final-wait starts at the release (3 s since
      // the real-device fix round B: the Xiaomi engine's
      // late result lands ~1.4 s after the stop).
      h.stopGate = Completer<dynamic>();
      final int cancelsBefore = h.count('asr.cancel');
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.count('asr.stop'), greaterThanOrEqualTo(1),
          reason: '${h.events}');
      for (int i = 0; i < 16; i++) {
        await h.deliverAutoCloseStatus();
        h.completeAllSpeaks();
        await tester.pump(const Duration(milliseconds: 250));
      }
      // Release the gated stop (its answer changes
      // nothing: the final-wait already expired with no
      // final). The escalation then shows exactly ONE
      // cancel (the watchdog never gets near this -- its
      // ladder is 3 s and the confirmation lands first).
      h.stopGate!.complete(null);
      h.stopGate = null;
      for (int i = 0; i < 10; i++) {
        await h.deliverAutoCloseStatus();
        h.completeAllSpeaks();
        await tester.pump(const Duration(milliseconds: 150));
      }
      // The confirm step's wait runs on the adapter's
      // close future, completed by the harness's
      // initialize flush -- which fires only while this
      // harness is the ACTIVE binding (settleRecordedApp
      // bound it) AND a close is queued. Both hold here,
      // but the flush posts on the real event loop: give
      // it real turns alongside the fake pumps so the
      // confirm actually lands before the assertions.
      for (int i = 0;
          i < 20 && !h.events.contains('tts.speak:$helpText');
          i++) {
        await h.deliverAutoCloseStatus();
        h.completeAllSpeaks();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      // The timeout's own cancel landed, and it landed
      // BEFORE the submission: the press settled by
      // cancel, then completed. (If this harness's
      // confirmation flush runs past the adapter's 3 s
      // watchdog ladder under the pumped fake clock, the
      // ladder's prod and restart notice may legitimately
      // follow as the standing backstop -- they change
      // nothing about the settled press, asserted below
      // by the exactly-once submission.)
      expect(h.count('asr.cancel'), greaterThanOrEqualTo(cancelsBefore + 1),
          reason: 'the timeout cancel landed: ${h.events}');
      expect(
        h.events.indexOf('asr.cancel') <
            h.events.indexOf('tts.speak:$helpText'),
        isTrue,
        reason: 'cancel settled the session BEFORE the '
            'partial was submitted: ${h.events}',
      );
      // The close confirmed, the press completed with
      // the cached partial: the help reply, exactly once.
      await pumpUntilSpeak(tester, h, helpText);
      expect(h.count('tts.speak:$helpText'), 1,
          reason: '${h.events}');
      await tester.pump(const Duration(seconds: 3));
      expect(h.count('tts.speak:$helpText'), 1,
          reason: 'submitted exactly once: ${h.events}');
      expect(
        h.events,
        isNot(contains('tts.speak:没有听清，请按住按钮再说一次。')),
        reason: '${h.events}',
      );
      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });
  });

  group('cross-press error streak (CDX3 / MT-1111-PTT-4B, '
      'channel-driven)', () {
    // The cross-press streak scenarios, driven through
    // the REAL plugin singleton and this file's simulated
    // MethodChannel (the shape of Codex's synth-busy-pair
    // scenario). They live HERE because channel deliveries
    // reach the adapter of the FIRST app instance of the
    // process (the singleton's initialize latch and its
    // single listener registration -- see this file's
    // header note): the groups above run on that instance,
    // and so do these. The fake-engine files (cdx2 /
    // mt1111 / cdx3) drive their own processes' adapters
    // through injected fakes instead.
    //
    // One press whose session errors once with [code]
    // (injected on the channel, permanent=true), released
    // and settled. Mirrors the settle discipline of the
    // other drivers: closing statuses are delivered while
    // pumping until the press is fully settled.
    Future<void> channelErrorPress(
        WidgetTester tester, RecordingVoiceChannels h,
        String code) async {
      final TestGesture g = await pressUntilPttListening(tester, h);
      await deliverChannelError(code);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await holdPastThreshold(tester);
      await g.up();
      for (int i = 0; i < 29; i++) {
        h.completeAllSpeaks();
        await h.deliverAllCloseStatuses();
        await tester.pump(const Duration(milliseconds: 100));
      }
      h.events.clear();
    }

    testWidgets(
        'E1: two presses each error busy once (channel, '
        'permanent=true) -- streak 2 across presses; the '
        'third press RECORDS and speaks 改用云端识别 once',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await drainVoice(tester, h, rounds: 8);
      final CodexFakeRecorder recorder = CodexFakeRecorder();
      mingtuHomeDebugHandle!.setRecorder(recorder);
      h.events.clear();

      // Press 1: listens on the channel, errors busy once.
      await channelErrorPress(tester, h, 'error_busy');
      expect(mingtuHomeDebugHandle!.asrStreakCode, 'error_busy');
      expect(mingtuHomeDebugHandle!.asrStreakCount, 1,
          reason: 'the first busy opens the streak');
      expect(mingtuHomeDebugHandle!.localAsrBroken, isFalse);
      expect(mingtuHomeDebugHandle!.recoveryPending, isTrue);

      // Press 2: the recovery runs (cancel -> channel
      // initialize -> listen); its listen STARTS fine --
      // which clears NOTHING under PTT-4B -- and then it
      // errors busy once more: the streak reaches 2
      // ACROSS the two presses.
      await channelErrorPress(tester, h, 'error_busy');
      expect(mingtuHomeDebugHandle!.asrStreakCode, 'error_busy');
      expect(mingtuHomeDebugHandle!.asrStreakCount, 2,
          reason: 'busy, a recovery listen that started but '
              'submitted nothing, busy = a streak of 2');
      expect(mingtuHomeDebugHandle!.localAsrBroken, isTrue,
          reason: 'the second consecutive busy escalates');

      // Press 3: no listen at all -- it records through
      // the app recorder and speaks the switch notice
      // exactly once.
      final int listensBefore = h.count('asr.listen');
      final TestGesture g3 = await startPttGesture(tester);
      for (int i = 0; i < 40 && !recorder.started; i++) {
        h.completeAllSpeaks();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(recorder.started, isTrue,
          reason: 'the third press records: ${h.events}');
      expect(h.count('asr.listen'), listensBefore,
          reason: 'no listen on the escalation press');
      await pumpUntilSpeak(tester, h, asrCloudSwitchSpeechText);
      expect(h.count('tts.speak:$asrCloudSwitchSpeechText'), 1,
          reason: 'switch notice exactly once: ${h.events}');
      await holdPastThreshold(tester);
      await g3.up();
      await tester.pump(const Duration(milliseconds: 300));
      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    testWidgets(
        'E2: busy, client, busy does NOT escalate -- the '
        'different code restarts the streak, and a later '
        'press still listens locally',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await drainVoice(tester, h, rounds: 8);
      h.events.clear();

      await channelErrorPress(tester, h, 'error_busy');
      expect(mingtuHomeDebugHandle!.asrStreakCount, 1);
      await channelErrorPress(tester, h, 'error_client');
      expect(mingtuHomeDebugHandle!.asrStreakCode, 'error_client');
      expect(mingtuHomeDebugHandle!.asrStreakCount, 1,
          reason: 'a different code restarts the streak at 1');
      await channelErrorPress(tester, h, 'error_busy');
      expect(mingtuHomeDebugHandle!.asrStreakCode, 'error_busy');
      expect(mingtuHomeDebugHandle!.asrStreakCount, 1);
      expect(mingtuHomeDebugHandle!.localAsrBroken, isFalse,
          reason: 'busy, client, busy must not route to cloud');

      // The next press still listens locally.
      final TestGesture g = await pressUntilPttListening(tester, h);
      await holdPastThreshold(tester);
      await g.up();
      await tester.pump(const Duration(milliseconds: 100));
      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    testWidgets(
        'E3: busy, then a press whose result is really '
        'SUBMITTED, then busy -- no escalation (the '
        'submission cleared the streak)',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await drainVoice(tester, h, rounds: 8);
      h.events.clear();

      await channelErrorPress(tester, h, 'error_busy');
      expect(mingtuHomeDebugHandle!.asrStreakCount, 1);

      // A press that recognises and SUBMITS: the final is
      // delivered on the channel while held, the release
      // completes the press through the completion point
      // (submission + command execution + its reply).
      final TestGesture g2 = await pressUntilPttListening(tester, h);
      await deliverFinalResult(tester, '你好');
      await tester.pump(const Duration(milliseconds: 100));
      await holdPastThreshold(tester);
      await g2.up();
      await tester.pump(const Duration(milliseconds: 100));
      final String unknownReply = '没听清。${voiceCommandHelpText()}';
      await pumpUntilSpeak(tester, h, unknownReply);
      expect(h.count('tts.speak:$unknownReply'), 1,
          reason: 'the submitted result was executed: ${h.events}');
      for (int i = 0; i < 29; i++) {
        h.completeAllSpeaks();
        await h.deliverAllCloseStatuses();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(mingtuHomeDebugHandle!.asrStreakCode, isNull,
          reason: 'the submission cleared the streak');
      expect(mingtuHomeDebugHandle!.asrStreakCount, 0);
      h.events.clear();

      // busy again: a FRESH streak of 1, no escalation --
      // and the press after it still listens locally.
      await channelErrorPress(tester, h, 'error_busy');
      expect(mingtuHomeDebugHandle!.asrStreakCode, 'error_busy');
      expect(mingtuHomeDebugHandle!.asrStreakCount, 1);
      expect(mingtuHomeDebugHandle!.localAsrBroken, isFalse);
      final TestGesture g4 = await pressUntilPttListening(tester, h);
      await holdPastThreshold(tester);
      await g4.up();
      await tester.pump(const Duration(milliseconds: 100));
      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });
  });

  group('engine watchdog restart (app level)', () {
    testWidgets(
        'a close unconfirmed past 3 s prods one cancel; '
        'the engine restarts right after the prod and '
        'the app speaks the restart notice',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await drainVoice(tester, h, rounds: 8);
      // SCENARIO SETUP, rewritten for press-and-hold only
      // (real-device fix round): no automatic session
      // exists anymore. The unconfirmed close is produced
      // the way it now occurs in production: a held press
      // released while its closing status is withheld.
      h.autoCloseStatus = false;
      final TestGesture wedged = await pressUntilPttListening(tester, h);
      await holdPastThreshold(tester);
      await wedged.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.pendingCloseStatuses, greaterThanOrEqualTo(1),
          reason: '${h.events}');
      final int cancelsBefore = h.count('asr.cancel');
      h.events.clear();

      // The next cancel on the channel will be the
      // adapter watchdog's prod: the recogniser closes
      // the already-closing session for it, so it queues
      // no second closing status.
      h.nextCancelIsWatchdogProd = true;

      // ~3 s pass with the close still unconfirmed:
      // exactly one prod cancel. The adapter's watchdog
      // Timer runs on the widget test's fake clock, so
      // the fake clock is advanced past the same 3 s
      // alongside the real-time wait.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 3400)));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(h.count('asr.cancel'), cancelsBefore + 1,
          reason: 'one watchdog prod: ${h.events}');

      // Ladder semantics (this round): there is no
      // second waiting step -- the restart follows the
      // prod as soon as its future settles (here it
      // settles at once) or the 1 s cap elapses, so by
      // now the restart may already be in flight; the
      // old "restart has not happened yet" observation
      // is no longer a stable point. Settle the same
      // extra window as before, then assert the fixed
      // restart notice, exactly once.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1400)));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await pumpUntilSpeak(tester, h, '语音已重启，请重新按住说话');
      expect(h.count('tts.speak:语音已重启，请重新按住说话'), 1,
          reason: '${h.events}');
      expect(h.completeSpeak('语音已重启，请重新按住说话'), isTrue);

      // The pending closes are forgiven: the close of
      // the notice's own mic-stop confirms nothing (it is
      // a no-op in the adapter), and normal operation
      // resumes -- a fresh press runs its full cycle.
      h.autoCloseStatus = true;
      await drainVoice(tester, h, rounds: 6);
      h.events.clear();
      final TestGesture gesture = await pressUntilPttListening(tester, h);
      expect(h.count('asr.listen'), 1, reason: '${h.events}');
      await holdPastThreshold(tester);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));
      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });

    testWidgets(
        'a prod cancel whose future NEVER returns still '
        'restarts the engine: the platform is really '
        're-initialized (a second channel initialize), '
        'the restart notice is spoken once, and a fresh '
        'press listens and submits',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await drainVoice(tester, h, rounds: 8);
      // SCENARIO SETUP, rewritten for press-and-hold only
      // (real-device fix round): the unconfirmed close is
      // a released press's close, as in production now.
      // Wedge BOTH ways: no closing status is ever
      // delivered, and every platform cancel hangs
      // forever (its future never completes) -- the
      // watchdog prod included.
      h.autoCloseStatus = false;
      h.cancelGate = Completer<dynamic>();
      final TestGesture wedged = await pressUntilPttListening(tester, h);
      await holdPastThreshold(tester);
      await wedged.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.pendingCloseStatuses, greaterThanOrEqualTo(1),
          reason: '${h.events}');
      h.events.clear();
      final int initAtWedge = h.count('asr.initialize');
      h.nextCancelIsWatchdogProd = true;

      // ~3 s pass (fake clock alongside real time, as
      // in the sibling test): exactly one prod cancel,
      // which hangs on the gate.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 3400)));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(h.count('asr.cancel'), 1,
          reason: 'one watchdog prod: ${h.events}');
      expect(
        h.events,
        isNot(contains('tts.speak:语音已重启，请重新按住说话')),
        reason: 'no restart before the prod cap: ${h.events}',
      );

      // The prod cap (1 s of fake time) elapses: despite
      // the hanging cancel the engine restarts, and the
      // restart REALLY re-initializes the platform -- a
      // further initialize reaches the channel (the
      // plugin singleton's Dart-side latch would have
      // swallowed a plain initialize() call, which is
      // why the adapter issues it on the channel).
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1400)));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(h.count('asr.initialize'), initAtWedge + 1,
          reason: 'the restart re-initialized the platform: '
              '${h.events}');
      await pumpUntilSpeak(tester, h, '语音已重启，请重新按住说话');
      expect(h.count('tts.speak:语音已重启，请重新按住说话'), 1,
          reason: '${h.events}');
      expect(h.completeSpeak('语音已重启，请重新按住说话'), isTrue);

      // Recovery: release the hanging cancels and
      // restore automatic closing statuses; a fresh
      // press runs its full cycle and its result is
      // submitted exactly once.
      h.cancelGate!.complete(null);
      h.cancelGate = null;
      h.autoCloseStatus = true;
      await drainVoice(tester, h, rounds: 6);
      h.events.clear();
      final TestGesture gesture = await pressUntilPttListening(tester, h);
      expect(h.count('asr.listen'), 1, reason: '${h.events}');
      await holdPastThreshold(tester);
      await deliverFinalResult(tester, '你好');
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pump();
      final String unknownReply = '没听清。${voiceCommandHelpText()}';
      await pumpUntilSpeak(tester, h, unknownReply);
      expect(h.count('tts.speak:$unknownReply'), 1,
          reason: '${h.events}');
      expect(h.completeSpeak(unknownReply), isTrue);
      await drainVoice(tester, h);
      await shutdownVoice(tester, h);
    });
  });

  group('missed watchdog restart replay (CDX3 / MT-1111-PTT-4B)', () {
    testWidgets(
        'RPL: a watchdog restart whose notification was '
        'missed is replayed exactly once by the next epoch '
        'check (compare, replay, then record); a recovery '
        're-initialize bump is never replayed',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await drainVoice(tester, h, rounds: 8);
      expect(mingtuHomeDebugHandle!.debugEngineEvents, isEmpty);

      // Baseline: the epoch accounting has observed the
      // adapter (every listen attempt runs it).
      mingtuHomeDebugHandle!.debugEnsureEngineSubscription();
      expect(mingtuHomeDebugHandle!.debugEngineEvents, isEmpty,
          reason: 'baseline observation handles nothing');

      // Wedge a press's close (no closing status ever),
      // drop this page's engine-events subscription (the
      // subscription-rebuild gap), and arm the adapter's
      // restart-init marker: the
      // coming watchdog restart's platform initialize is
      // recorded as a test marker, so when the release
      // path's recovery listen runs the app's epoch check
      // it accounts the restart as MISSED -- its live
      // 'restarted' notification is delivered on the
      // adapter's broadcast stream, but the epoch
      // bookkeeping is what guarantees delivery, and the
      // marker makes the bookkeeping treat the window's
      // check as the subscription-rebuild gap.
      h.autoCloseStatus = false;
      mingtuHomeDebugHandle!.debugDropEngineSubscription();
      {
        final ByteData markerData = const StandardMethodCodec()
            .encodeMethodCall(const MethodCall(
                'noteTestMarker', 'armRestartInitMarker'));
        await TestDefaultBinaryMessengerBinding
            .instance.defaultBinaryMessenger
            .handlePlatformMessage(
          'dev.mingtu.test/markers',
          markerData,
          (ByteData? _) {},
        );
      }
      final TestGesture wedged = await pressUntilPttListening(tester, h);
      await holdPastThreshold(tester);
      await wedged.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.pendingCloseStatuses, greaterThanOrEqualTo(1),
          reason: '${h.events}');
      // Stay INSIDE the restart window with a live waiter:
      // the unbounded close-confirmation wait (the same
      // one a stuck press's final-wait expiry runs). The
      // watchdog restart is what resolves it -- and the
      // restart's completion tail (its close-completer
      // resolution, processed microtasks later) is what
      // unblocks the app-side waiter whose continuation
      // re-enters the listen path and runs the epoch
      // check that must account the restart as missed.
      // Without a live waiter, nothing runs that check
      // after the restart inside the window, and the
      // marker would just drain at some later settle.
      mingtuHomeDebugHandle!.debugConfirmClose();
      h.nextCancelIsWatchdogProd = true;
      h.events.clear();
      final int emittedBefore =
          mingtuHomeDebugHandle!.debugAdapterEngineEventsEmittedCount;

      // ~3 s pass (fake clock alongside real time, as in
      // the sibling watchdog tests): exactly one prod
      // cancel, then the engine restarts -- and NOTHING
      // is handled yet: the restart was missed.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 3400)));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(h.count('asr.cancel'), 1,
          reason: 'one watchdog prod: ${h.events}');
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1400)));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      // The restart REALLY happened on this app's own
      // adapter (its emission log grew by one) while the
      // app handled none of it: genuinely missed.
      expect(
          mingtuHomeDebugHandle!.debugAdapterEngineEventsEmittedCount,
          emittedBefore + 1,
          reason: 'the watchdog restart fired on this adapter');
      expect(mingtuHomeDebugHandle!.debugEngineEvents, isEmpty,
          reason: 'the restart notification was missed: ${h.events}');
      expect(h.count('tts.speak:语音已重启，请重新按住说话'), 0,
          reason: '${h.events}');

      // Meanwhile the wedged press's own 3 s final-wait
      // expired into its cancel-confirm step: the
      // unbounded confirmation wait it opened is resolved
      // BY the restart -- and the resolution's app-side
      // continuation re-enters the epoch accounting (the
      // confirmation helper re-registers the adapter's
      // listeners through the startup wiring, whose epoch
      // fields the listen path then reads). That
      // continuation plus the explicit check below are
      // the two chances the bookkeeping has to account
      // the restart; both must agree it was MISSED (the
      // marker said so) and replay it exactly once.
      await tester.pump(const Duration(seconds: 3));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();

      // The explicit epoch check now replays the missed
      // restart EXACTLY ONCE (compare -> replay ->
      // record), with the existing success handling: the
      // fixed restart notice is spoken once.
      mingtuHomeDebugHandle!.debugEnsureEngineSubscription();
      await tester.pump();
      expect(mingtuHomeDebugHandle!.debugEngineEvents,
          <String>['restarted'],
          reason: 'the missed restart replayed once');
      await pumpUntilSpeak(tester, h, '语音已重启，请重新按住说话');
      expect(h.count('tts.speak:语音已重启，请重新按住说话'), 1,
          reason: '${h.events}');
      expect(h.completeSpeak('语音已重启，请重新按住说话'), isTrue);

      // A second check at the same epoch replays NOTHING.
      mingtuHomeDebugHandle!.debugEnsureEngineSubscription();
      await tester.pump();
      expect(mingtuHomeDebugHandle!.debugEngineEvents,
          <String>['restarted'],
          reason: 'no double replay');
      expect(h.count('tts.speak:语音已重启，请重新按住说话'), 1);

      h.autoCloseStatus = true;
      await drainVoice(tester, h, rounds: 6);
      await shutdownVoice(tester, h);
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

