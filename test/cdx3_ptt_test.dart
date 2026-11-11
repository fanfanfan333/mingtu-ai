// CDX3 / MT-1111-PTT-4B tests in their OWN process:
// the cross-press error streak (channel-driven, real
// speech_to_text singleton) and the missed-watchdog-
// restart replay.
//
// Why a separate file: the cross-press sequence must be
// driven through the REAL plugin singleton and the
// simulated MethodChannel (the shape of Codex's
// synth-busy-pair scenario), not through an injected fake
// engine. Channel-driven adapters belong to the FIRST app
// instance of a process (the singleton's initialize latch
// and its single listener registration), so these tests
// live in a fresh process whose first app instance is
// theirs; the fake-engine files (cdx2 / mt1111) keep
// their own processes.
//
// The RecordingVoiceChannels harness and its drivers are
// copied from test/codex_ptt_fix_test.dart (the channel
// harness used by the watchdog-restart tests there) --
// plus the cloud-ASR CodexFakeRecorder that already
// ships with that harness. The replay test additionally
// uses the app's test-marker channel
// ('dev.mingtu.test/markers'): arming the adapter's
// restart-init marker makes the adapter report the next
// watchdog restart's platform initialize as a marker, so
// the app accounts that restart as MISSED at its next
// epoch check and replays it explicitly there.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/voice_recorder.dart';
import 'package:mingtu_ai/main.dart';
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


/// Deliver a recognition result on the plugin channel
/// (resultType: 0 = partial, 2 = finalResult) -- the same
/// driver the codex harness carries.
Future<void> deliverChannelRecognition(
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

Future<void> deliverChannelFinal(WidgetTester tester, String words) =>
    deliverChannelRecognition(tester, words, 2);

/// Send one app test marker over the app's own test
/// channel (harness -> app -> adapter forwarding).
Future<void> sendTestMarker(String marker) async {
  final ByteData data = const StandardMethodCodec().encodeMethodCall(
      MethodCall('noteTestMarker', marker));
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'dev.mingtu.test/markers',
    data,
    (ByteData? _) {},
  );
}

/// Inject one recognition error on the plugin channel,
/// the way speech_to_text 7.5.0's Android side reports it:
/// notifyError carrying {"errorMsg": <code>,
/// "permanent": true} -- permanent is true for EVERY
/// error the plugin sends (CDX1).
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

void main() {
  // The cross-press streak scenarios and the
  // missed-restart replay that used to live here moved
  // to test/codex_ptt_fix_test.dart (group 'cross-press
  // error streak (CDX3 / MT-1111-PTT-4B, channel-driven)'
  // and the watchdog-restart group): channel deliveries
  // reach only the adapter of the FIRST app instance of
  // a process (the speech_to_text singleton's initialize
  // latch and its single listener registration), and in
  // THIS process the first instance belongs to the
  // harness setups above, whose adapters never receive
  // the deliveries. What remains here is the production
  // discipline those scenarios rely on, guarded at the
  // source level.
  test(
      'CDX3 source guard: the streak is cleared ONLY at '
      'the submission point -- no reset at a listen start, '
      'no clearing on a result arrival or a partial', () {
    final String mainDart =
        File('lib/main.dart').readAsStringSync();
    final RegExp resets = RegExp(r'_resetAsrErrorStreak\(\)');
    expect(resets.allMatches(mainDart).length, 2,
        reason: 'the definition plus its one call inside '
            '_noteAsrSessionDelivered -- no other call site '
            'may exist');
    expect(mainDart.contains('_noteAsrResultForStreak'), isFalse,
        reason: 'the arrival-based clearing helper of the '
            'superseded reading must not exist');
    // The one call site sits inside _pttCompletePress's
    // submission branch (text != null), before the
    // submission executes.
    final int completeAt = mainDart.indexOf('_pttCompletePress(');
    final int noteAt =
        mainDart.indexOf('_noteAsrSessionDelivered();', completeAt);
    final int processAt =
        mainDart.indexOf('_processPushToTalkFinal(text)', completeAt);
    expect(noteAt, greaterThan(completeAt));
    expect(noteAt, lessThan(processAt),
        reason: 'clearing happens as the result submits');
  });

  test(
      'CDX3 source guard: the epoch accounting compares, '
      'replays, then records -- no unconditional epoch sync '
      'anywhere in the engine-subscription pass', () {
    final String mainDart =
        File('lib/main.dart').readAsStringSync();
    final int fnAt = mainDart.indexOf('void _ensureEngineSubscription()');
    final int fnEnd = mainDart.indexOf('void _onEngineRestarted()', fnAt);
    final String body = mainDart.substring(fnAt, fnEnd);
    expect(body.contains('_engineEpochSeen = input.engineEpoch;'),
        isFalse,
        reason: 'the CDX2-era unconditional sync (which '
            'rewrote the epoch difference before the replay '
            'could compare it) must not exist');
    expect(body.contains('_noteEngineEpochBump(input, e)'), isTrue,
        reason: 'each missed bump is accounted per epoch: '
            'recovery bumps consumed, watchdog bumps replayed');
  });
}

