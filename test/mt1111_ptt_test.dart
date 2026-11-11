import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/cloud_asr_client.dart';
import 'package:mingtu_ai/core/cloud_asr.dart';
import 'package:mingtu_ai/adapters/system_voice_io.dart';
import 'package:mingtu_ai/adapters/voice_recorder.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart'
    as stt_result;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:mingtu_ai/core/asr_errors.dart';
import 'package:mingtu_ai/main.dart';

/// MT-1111-PTT real-device fix round: app-level behaviour
/// tests for the Xiaomi sequence (E), the permission-error
/// dedup (a), the recording + cloud ASR fallback (b, c, d),
/// the no-automatic-listen counts (e), and the PTT-D checks
/// (listenFor=30 s, initialize discipline, background
/// release, startup-unavailable fallback, TTS-stop order).
///
/// The channel harness mirrors test/codex_ptt_fix_test.dart
/// (same plugin contract): the platform's notifyError for a
/// session the app stopped is SUPPRESSED by the plugin
/// (speech_to_text 7.5.0 _onNotifyError returns early for
/// user-ended sessions), so a late no-match after a stop is
/// delivered as the adapter-level outcome it becomes on
/// device only when it belongs to a still-live session --
/// here the scenarios deliver it while the session is live
/// (held) or rely on the adapter's pending-close branch,
/// which is the path the Xiaomi engine's late outcome takes
/// when the close is still unconfirmed.

class RecordingVoiceChannels {
  final List<String> events = <String>[];
  final List<MapEntry<String, Completer<dynamic>>> speakQueue =
      <MapEntry<String, Completer<dynamic>>>[];
  bool asrInitResult = true;

  /// Last listen() call's arguments (for the listenFor check).
  Map<dynamic, dynamic>? lastListenArgs;

  int unclosedSessions = 0;
  int pendingCloseStatuses = 0;
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
            if (identical(this, activeHarness) &&
                platformSessionSeen &&
                pendingCloseStatuses > 0) {
              Future<void>(() async {
                await deliverAutoCloseStatus();
              });
            }
            return asrInitResult;
          case 'listen':
            events.add('asr.listen');
            lastListenArgs =
                call.arguments as Map<dynamic, dynamic>?;
            platformSessionSeen = true;
            unclosedSessions++;
            return true;
          case 'stop':
            events.add('asr.stop');
            noteSessionStopped();
            return null;
          case 'cancel':
            events.add('asr.cancel');
            noteSessionStopped();
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

  void noteSessionStopped() {
    if (unclosedSessions > 0) {
      unclosedSessions--;
      pendingCloseStatuses++;
    }
  }

  Future<void> deliverAutoCloseStatus() async {
    if (pendingCloseStatuses == 0) return;
    pendingCloseStatuses--;
    await deliverCloseStatusOnly();
  }

  Future<void> deliverAllCloseStatuses() async {
    while (pendingCloseStatuses > 0) {
      await deliverAutoCloseStatus();
    }
  }

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

  int count(String e) => events.where((String x) => x == e).length;

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
    for (final MapEntry<String, Completer<dynamic>> e in speakQueue) {
      if (!e.value.isCompleted) e.value.complete(1);
    }
  }
}

RecordingVoiceChannels? activeHarness;

Future<void> settleRecordedApp(
    WidgetTester tester, RecordingVoiceChannels h) async {
  activeHarness = h;
  await tester.pumpWidget(const MingtuApp());
  await tester.pump();
  int quietRounds = 0;
  int lastEventCount = -1;
  for (int round = 0; round < 64; round++) {
    await tester.pump(const Duration(milliseconds: 250));
    await h.deliverAllCloseStatuses();
    h.completeAllSpeaks();
    // The startup kickoff's location-permission answer
    // resolves on the REAL event loop and can land late:
    // if it lands mid-press instead, its alert is spoken
    // through the scheduler and the speech path closes
    // the just-opened microphone session. Give the real
    // loop turns during the settle so the answer (and its
    // fixed alert) always land HERE, never mid-test.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
    final bool speaksPending = h.speakQueue
        .any((MapEntry<String, Completer<dynamic>> e) =>
            !e.value.isCompleted);
    if (h.events.length == lastEventCount && !speaksPending) {
      quietRounds++;
      if (quietRounds >= 3) break;
    } else {
      quietRounds = 0;
      lastEventCount = h.events.length;
    }
  }
  // Final flush, mirroring the codex harness: one longer
  // real-time wait, then drain whatever it produced.
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)));
  for (int round = 0; round < 8; round++) {
    h.completeAllSpeaks();
    await h.deliverAllCloseStatuses();
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Finder pttBlock() =>
    find.byKey(const ValueKey<String>('push-to-talk-area'));

Future<TestGesture> startPttGesture(WidgetTester tester) async {
  final TestGesture g =
      await tester.startGesture(tester.getCenter(pttBlock()));
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return g;
}

/// Press and poll in REAL time until the cue speak is the
/// pending one, then complete it and poll until the session
/// (or the recorder) has started.
Future<void> pressUntilCapture(WidgetTester tester,
    RecordingVoiceChannels h, TestGesture g,
    {required bool expectRecorder,
    FakeRecorder? recorder,
    bool useFakeListen = false,
    bool tightTiming = false}) async {
  // tightTiming: the caller releases immediately after
  // capture and must stay under the app's 300 ms
  // too-short floor. The app measures the hold with
  // DateTime.now(), which is REAL time in this harness,
  // so the tight drive burns neither fake nor real time:
  // no runAsync sleeps, only microtask-flushing pumps
  // (the cue -> capture chain is microtask-driven).
  final Duration step =
      tightTiming ? Duration.zero : const Duration(milliseconds: 50);
  for (int i = 0;
      i < 40 &&
          !h.speakQueue.any(
              (MapEntry<String, Completer<dynamic>> e) => e.key == '请说');
      i++) {
    h.completeAllSpeaks();
    await h.deliverAllCloseStatuses();
    if (!tightTiming) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    await tester.pump(step);
  }
  // The cue counts as spoken once it was ISSUED; a drain
  // may already have completed it (the app then proceeds
  // on its own), so completion here is best-effort.
  expect(
      h.speakQueue.any(
          (MapEntry<String, Completer<dynamic>> e) => e.key == '请说'),
      isTrue,
      reason: 'cue spoken: ${h.events}');
  h.completeSpeak('请说');
  bool started() {
    if (expectRecorder) return recorder != null && recorder.started;
    if (useFakeListen) {
      return processFakeStt != null && processFakeStt!.listenCalls > 0;
    }
    return h.count('asr.listen') > 0;
  }

  for (int i = 0; i < 40 && !started(); i++) {
    await h.deliverAllCloseStatuses();
    if (!tightTiming) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    await tester.pump(step);
  }
  if (!started()) fail('capture never started: ${h.events}');
  // The listen CALL lands before the app's state machine
  // finishes entering `listening` (the start future and
  // the prompt step's tail settle a few microtasks later):
  // give it rounds so deliveries made by the caller land
  // in the listening state, as on device. Zero-duration
  // pumps flush microtasks without advancing fake time;
  // in tight mode the real-time sleeps are skipped too
  // (see above).
  for (int i = 0; i < 6; i++) {
    if (!tightTiming) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    await tester.pump(Duration.zero);
  }
}

/// After a release, let the press fully settle: the
/// release window is 3 s of fake time and an unconfirmed
/// close can add its own confirm wait, so pump a generous
/// stretch of fake time while completing speech and
/// delivering any channel close statuses.
Future<void> settleReleasedPress(
    WidgetTester tester, RecordingVoiceChannels h) async {
  for (int i = 0; i < 70; i++) {
    h.completeAllSpeaks();
    await h.deliverAllCloseStatuses();
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> holdPastThreshold(WidgetTester tester) async {
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 380)));
}

Future<void> drainVoice(WidgetTester tester, RecordingVoiceChannels h,
    {int rounds = 14}) async {
  for (int i = 0; i < rounds; i++) {
    h.completeAllSpeaks();
    await h.deliverAllCloseStatuses();
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> pumpUntilSpeak(WidgetTester tester,
    RecordingVoiceChannels h, String text,
    {int rounds = 30}) async {
  for (int i = 0; i < rounds; i++) {
    await h.deliverAllCloseStatuses();
    await tester.pump(const Duration(milliseconds: 100));
    if (h.events.contains('tts.speak:$text') ||
        h.events.any((String e) => e.startsWith('tts.speak:$text'))) {
      return;
    }
    h.completeAllSpeaks();
  }
  fail('never spoke "$text": ${h.events}');
}

/// Deliver a recognition result on the plugin channel
/// (resultType: 0 = partial, 2 = finalResult).
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

/// Deliver a recognition result through the fake-backed
/// adapter's latest listen closure (finalResult when
/// [finalResult] is true, partial otherwise).
Future<void> deliverFakeResult(
    WidgetTester tester, String words, bool finalResult) async {
  processFakeStt!.resultListener!(stt_result.SpeechRecognitionResult(
    <stt_result.SpeechRecognitionWords>[
      stt_result.SpeechRecognitionWords(words, null, 0.95)
    ],
    finalResult ? 2 : 0,
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// Deliver a session status through the fake-backed
/// adapter's registered status listener.
Future<void> deliverFakeStatus(WidgetTester tester, String status) async {
  processFakeStt!.statusListener!(status);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// Deliver a recognition ERROR on the plugin channel
/// (notifyError with the plugin's JSON shape).
/// A fake recogniser attached to the app's LIVE adapter:
/// errors delivered through it take the adapter's real
/// onError path (whitelist, pending-close bookkeeping,
/// errors stream) into the app's error handler -- the path
/// a live-session error takes on device. (Channel-level
/// notifyError cannot reach it in widget tests: the plugin
/// object behind the adapter belongs to the FIRST app
/// instance in the process, whose listener registrations
/// were captured at ITS initialize; platform messages land
/// on that stale adapter instead.)
class FakeStt implements stt.SpeechToText {
  @override
  stt.SpeechErrorListener? errorListener;
  @override
  stt.SpeechStatusListener? statusListener;

  /// The onResult listener of the latest listen() call.
  stt.SpeechResultListener? resultListener;

  /// Listen calls seen (adapter-level count for this file).
  int listenCalls = 0;

  /// initialize / cancel calls seen, and the ordered op
  /// log -- the MT-1111-PTT-2 recovery tests assert the
  /// cancel -> initialize -> listen ORDER on these.
  int initializeCalls = 0;
  int cancelCalls = 0;
  final List<String> ops = <String>[];

  /// When false, initialize() reports failure (the PTT-2
  /// recovery init-failure test arms this).
  bool initializeResult = true;

  @override
  Future<bool> initialize({
    stt.SpeechErrorListener? onError,
    stt.SpeechStatusListener? onStatus,
    dynamic debugLogging = false,
    Duration finalTimeout = const Duration(seconds: 2),
    List<stt.SpeechConfigOption>? options,
  }) async {
    initializeCalls++;
    ops.add('initialize');
    errorListener = onError;
    statusListener = onStatus;
    return initializeResult;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    ops.add('cancel');
  }

  @override
  Future<void> stop() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #listen) {
      resultListener = invocation.namedArguments[#onResult]
          as stt.SpeechResultListener?;
      listenCalls++;
      ops.add('listen');
      return Future<void>.value();
    }
    if (invocation.memberName == #hasPermission) {
      return Future<bool>.value(true);
    }
    if (invocation.memberName == #isListening) return false;
    if (invocation.memberName == #isNotListening) return true;
    return Future<void>.value();
  }
}

/// The fake recogniser installed for THIS test process.
/// The adapter keeps the plugin object it was constructed
/// with; the app's startup builds its adapter with the
/// default (real) plugin, so the fake can only be attached
/// by replacing the app's input -- done once per process by
/// [attachFakeSttToLiveInput] before the first error test.
FakeStt? processFakeStt;

/// The app instance's adapter backed by the fake
/// recogniser, installed by [installFakeBackedInput].
SystemVoiceInput? fakeBackedInput;

/// Swap the live app's voice input for one backed by the
/// fake recogniser, so adapter-level deliveries (errors,
/// results, statuses) reach THIS app through the adapter's
/// real paths. The swap re-runs the app's startup wiring,
/// so the app's subscriptions land on the new input; the
/// fake-backed adapter is then initialized (its own
/// initialize registers the adapter's closures on the
/// fake).
Future<void> installFakeBackedInput(WidgetTester tester) async {
  processFakeStt ??= FakeStt();
  // The fake is shared process-wide, but its counters are
  // per-attachment: each test asserts the listen count of
  // ITS OWN presses only.
  processFakeStt!.listenCalls = 0;
  processFakeStt!.initializeCalls = 0;
  processFakeStt!.cancelCalls = 0;
  processFakeStt!.ops.clear();
  processFakeStt!.initializeResult = true;
  fakeBackedInput =
      mingtuHomeDebugHandle!.debugVoiceInput as SystemVoiceInput;
  await mingtuHomeDebugHandle!.debugAttachFakeSpeech(processFakeStt!);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// Deliver a recognition error through the fake-backed
/// adapter's real onError path (see [FakeStt]).
Future<void> deliverError(
    WidgetTester tester, String code, bool permanent) async {
  processFakeStt!.errorListener!(
      SpeechRecognitionError(code, permanent));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// Fake recorder for the cloud ASR fallback tests.
class FakeRecorder implements VoiceRecorder {
  bool permission = true;
  bool started = false;
  bool cancelled = false;
  int startCount = 0;
  Uint8List? clip = Uint8List.fromList(List<int>.filled(2000, 3));

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<void> start() async {
    started = true;
    startCount++;
  }

  @override
  Future<Uint8List?> stop() async {
    started = false;
    return clip;
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    started = false;
  }

  @override
  bool get isRecording => started;
}

void main() {
  // PTT-D(5) runs FIRST in this file on purpose: the
  // speech_to_text plugin object is a process singleton
  // whose initialize() latches after its first success,
  // so only the first app instance in the process can
  // observe a failed startup initialize on the channel.
  group('PTT-D(5): startup unavailability (first in file)', () {
    testWidgets(
        'PTT-D(5): ASR unavailable at startup -- the FIRST '
        'press records directly, with no asr.listen',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()
        ..asrInitResult = false
        ..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);

      final FakeRecorder recorder = FakeRecorder()..permission = true;
      mingtuHomeDebugHandle!.setRecorder(recorder);
      expect(mingtuHomeDebugHandle!.localAsrBroken, isTrue,
          reason: 'startup unavailability must arm the fallback');
      h.events.clear();

      final TestGesture g = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g,
          expectRecorder: true, recorder: recorder);
      expect(recorder.started, isTrue);
      expect(h.count('asr.listen'), 0, reason: '${h.events}');

      await holdPastThreshold(tester);
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
      await drainVoice(tester, h);
    });
  });

  group('xiaomi sequence (E): late outcomes after release', () {
    testWidgets(
        'xiaomi sequence: late error7 after stop -- no new listen, '
        'cached partial submitted, no no-content notice',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      // Adapter-level delivery for this scenario: swap in
      // the fake-backed input (the platform channel's
      // plugin object belongs to the first app in the
      // process and cannot reach this app's adapter).
      await installFakeBackedInput(tester);
      h.events.clear();

      final TestGesture g = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g,
          expectRecorder: false, useFakeListen: true);
      expect(processFakeStt!.listenCalls, 1);

      // While held, a partial arrives and is cached.
      // (The partial is an environment query: a completed
      // submission of it speaks the environment
      // description, which is how the cached-partial
      // settlement is observed.)
      await deliverFakeResult(tester, '前面有什么', false);
      await holdPastThreshold(tester);

      // Release: stop() returns immediately; the closing
      // status lands; NO new listen may follow (the old
      // bug's collision point).
      await g.up();
      await tester.pump(const Duration(milliseconds: 100));
      await deliverFakeStatus(tester, 'notListening');
      await tester.pump(const Duration(milliseconds: 200));
      expect(processFakeStt!.listenCalls, 1,
          reason: 'notListening must never re-listen');

      // +1.4 s (fake time): the engine's late no-match
      // outcome for the stopped session. The plugin
      // suppresses a stopped session's notifyError, so the
      // deliverable shape here is the adapter-level outcome
      // arriving while the close is still the live ledger
      // entry -- modelled by delivering the error against
      // the still-unconfirmed close. The press must settle
      // with its cached partial, never with 没有听清.
      await tester.pump(const Duration(milliseconds: 1400));
      expect(processFakeStt!.listenCalls, 1);
      // The engine's late no-match outcome for the stopped
      // session, delivered through the adapter: the press
      // settles with its cached partial.
      await deliverError(tester, 'error_no_match', false);
      await pumpUntilSpeak(tester, h, '前方情况');
      expect(h.events,
          isNot(contains('tts.speak:没有听清，请按住按钮再说一次。')),
          reason: '${h.events}');
      expect(processFakeStt!.listenCalls, 1,
          reason: 'total listen count');

      await drainVoice(tester, h);
    });

    testWidgets(
        'xiaomi sequence: late final after stop is submitted',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await installFakeBackedInput(tester);
      h.events.clear();

      final TestGesture g = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g,
          expectRecorder: false, useFakeListen: true);
      expect(processFakeStt!.listenCalls, 1);
      await holdPastThreshold(tester);

      await g.up();
      await tester.pump(const Duration(milliseconds: 100));
      await deliverFakeStatus(tester, 'notListening');
      await tester.pump(const Duration(milliseconds: 200));
      expect(processFakeStt!.listenCalls, 1);

      // The final lands ~1.4 s after the release.
      await tester.pump(const Duration(milliseconds: 1200));
      await deliverFakeResult(tester, '帮助', true);
      await pumpUntilSpeak(tester, h, '你可以说：带我去图书馆');
      expect(processFakeStt!.listenCalls, 1);

      await drainVoice(tester, h);
    });

    testWidgets(
        'xiaomi sequence: a final arriving at 2.9 s is still '
        'inside the 3 s window and accepted',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await installFakeBackedInput(tester);
      h.events.clear();

      final TestGesture g = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g,
          expectRecorder: false, useFakeListen: true);
      await holdPastThreshold(tester);

      await g.up();
      await tester.pump(const Duration(milliseconds: 100));
      await deliverFakeStatus(tester, 'notListening');
      // 2.9 s after release the window (3 s, not 1.5 s) is
      // still open: the final is accepted and submitted.
      await tester.pump(const Duration(milliseconds: 2700));
      await deliverFakeResult(tester, '帮助', true);
      await pumpUntilSpeak(tester, h, '你可以说：带我去图书馆');
      expect(h.events,
          isNot(contains('tts.speak:没有听清，请按住按钮再说一次。')),
          reason: '${h.events}');
      expect(processFakeStt!.listenCalls, 1);

      await drainVoice(tester, h);
    });
  });

  group('permission error dedup (a)', () {
    testWidgets(
        'error_permission x3 speaks the dedicated text once, '
        'sets no permanent stop, and a later press retries',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await installFakeBackedInput(tester);
      h.events.clear();

      final TestGesture g = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g,
          expectRecorder: false, useFakeListen: true);
      expect(processFakeStt!.listenCalls, 1);

      // The Xiaomi engine's permission failure, three times
      // in a row (the real-device loop shape). A missing
      // engine permission is a PERMANENT error in the
      // plugin's model (recognition cannot continue until
      // it is resolved).
      await deliverError(tester, 'error_permission', true);
      await deliverError(tester, 'error_permission', true);
      await deliverError(tester, 'error_permission', true);
      await tester.pump(const Duration(milliseconds: 200));

      // The dedicated text is the press's spoken notice:
      // it is the scheduler's current prompt and it reaches
      // the TTS channel once the in-flight destination
      // announcement is completed (scheduler queueing).
      expect(mingtuHomeDebugHandle!.currentPrompt,
          contains(asrPermissionSpeechText));
      await pumpUntilSpeak(tester, h, asrPermissionSpeechText);
      expect(h.count('tts.speak:$asrPermissionSpeechText'), 1,
          reason: 'deduped per code: ${h.events}');
      // The error routed the fallback on.
      expect(mingtuHomeDebugHandle!.localAsrBroken, isTrue);

      // Release and press again: no permanent stop. The
      // error routed later presses to the recording
      // fallback; with a working recorder injected, the
      // next press RECORDS (proof it retries) and -- the
      // ASR proxy being unconfigured in this environment --
      // ends with the fixed not-configured text.
      final FakeRecorder recorder = FakeRecorder();
      mingtuHomeDebugHandle!.setRecorder(recorder);
      await holdPastThreshold(tester);
      await g.up();
      await tester.pump(const Duration(milliseconds: 200));
      await deliverFakeStatus(tester, 'notListening');
      await settleReleasedPress(tester, h);
      h.events.clear();

      final TestGesture g2 = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g2,
          expectRecorder: true, recorder: recorder);
      expect(h.count('asr.listen'), 0,
          reason: 'recording route, no system session: ${h.events}');
      await holdPastThreshold(tester);
      await g2.up();
      await tester.pump(const Duration(milliseconds: 300));
      await pumpUntilSpeak(tester, h, '云端识别未配置，无法识别。');
      await drainVoice(tester, h);
    });
  });

  group('recording + cloud ASR fallback (b, c, d)', () {
    Future<void> armFallback(WidgetTester tester,
        RecordingVoiceChannels h, FakeRecorder recorder,
        {String? asrText}) async {
      int senderCalls = 0;
      mingtuHomeDebugHandle!.setRecorder(recorder);
      mingtuHomeDebugHandle!.setCloudAsrClient(CloudAsrClient(
        proxyBaseUrl: 'https://fc.example',
        sender: (Uri url, String body, Map<String, String> headers) async {
          senderCalls++;
          return jsonEncode(<String, Object?>{'text': asrText});
        },
      ));
      addTearDown(() {});
      // Force the broken flag via a permission error on a
      // first (system-ASR) press. The error is delivered
      // through the fake-backed adapter (the channel's
      // plugin object cannot reach this app's adapter).
      await installFakeBackedInput(tester);
      final TestGesture g0 = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g0,
          expectRecorder: false, useFakeListen: true);
      await deliverError(tester, 'error_permission', true);
      expect(mingtuHomeDebugHandle!.localAsrBroken, isTrue);
      await holdPastThreshold(tester);
      await g0.up();
      await tester.pump(const Duration(milliseconds: 200));
      await deliverFakeStatus(tester, 'notListening');
      await settleReleasedPress(tester, h);
      h.events.clear();
      // Expose the counter through the recorder's clip size
      // channel: tests read it via the closure below.
      fallbackSenderCalls = () => senderCalls;
    }

    testWidgets(
        '(b) after local ASR breaks, a press records and the '
        'cloud transcript drives the destination flow',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      h.events.clear();

      final FakeRecorder recorder = FakeRecorder();
      await armFallback(tester, h, recorder, asrText: '校门口');

      // Put the app into its destination-asking state (the
      // same state the startup greeting leaves it in when
      // it asks where to go): the transcript is then
      // consumed as the destination answer.
      mingtuHomeDebugHandle!.askDestination();
      await tester.pump(const Duration(milliseconds: 100));
      await drainVoice(tester, h, rounds: 4);
      h.events.clear();

      final TestGesture g = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g,
          expectRecorder: true, recorder: recorder);
      // Recording route: the system ASR was never opened.
      expect(h.count('asr.listen'), 0, reason: '${h.events}');
      expect(recorder.started, isTrue);
      await holdPastThreshold(tester);
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));

      // The transcript entered the command pipeline as
      // the destination answer (a bare place name is not a
      // known command, so it answers the open question):
      // the destination confirmation was spoken.
      await pumpUntilSpeak(tester, h, '好的，去校门口。');
      expect(fallbackSenderCalls!(), 1);

      await drainVoice(tester, h);
    });

    testWidgets(
        '(c) a too-short recording is cancelled: 请按住说话 and '
        'no ASR call', (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      h.events.clear();

      final FakeRecorder recorder = FakeRecorder();
      await armFallback(tester, h, recorder, asrText: '去图书馆');

      final TestGesture g = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g,
          expectRecorder: true, recorder: recorder, tightTiming: true);
      // Release immediately (well under the 300 ms floor;
      // no real-time hold).
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
      await pumpUntilSpeak(tester, h, '请按住说话');
      expect(recorder.cancelled, isTrue);
      expect(fallbackSenderCalls!(), 0);

      await drainVoice(tester, h);
    });

    testWidgets(
        '(d) ASR proxy unconfigured: the fixed not-configured '
        'text is spoken', (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      h.events.clear();

      final FakeRecorder recorder = FakeRecorder();
      // Arm the fallback with the DEFAULT client (no proxy
      // URL in the test environment -> unconfigured).
      mingtuHomeDebugHandle!.setRecorder(recorder);
      await installFakeBackedInput(tester);
      final TestGesture g0 = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g0,
          expectRecorder: false, useFakeListen: true);
      await deliverError(tester, 'error_permission', true);
      expect(mingtuHomeDebugHandle!.localAsrBroken, isTrue);
      await holdPastThreshold(tester);
      await g0.up();
      await tester.pump(const Duration(milliseconds: 200));
      await deliverFakeStatus(tester, 'notListening');
      await settleReleasedPress(tester, h);
      h.events.clear();

      final TestGesture g = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g,
          expectRecorder: true, recorder: recorder);
      await holdPastThreshold(tester);
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
      await pumpUntilSpeak(tester, h, '云端识别未配置，无法识别。');

      await drainVoice(tester, h);
    });
  });

  group('MT-1111-PTT-2 recovery (f)', () {
    // One recoverable error, delivered with permanent=true
    // (the plugin's universal shape): press 1 listens and
    // errors; the press settles; press 2 must run the fixed
    // recovery -- cancel, then a REAL initialize (counted
    // on the fake), then listen -- in that order.
    Future<void> recoverableCase(
        WidgetTester tester, String code) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await installFakeBackedInput(tester);
      h.events.clear();

      final TestGesture g1 = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g1,
          expectRecorder: false, useFakeListen: true);
      expect(processFakeStt!.listenCalls, 1);
      final int initBefore = processFakeStt!.initializeCalls;
      await deliverError(tester, code, true);
      // The benign two never reach the error handler (they
      // settle the session through the no-match stream),
      // but their streak/recovery bookkeeping is maintained
      // on THAT stream with the same rules; the others are
      // counted by the error handler directly.
      expect(
          mingtuHomeDebugHandle!.recoverableErrorCounts[code], 1,
          reason: 'first $code occurrence counts once');
      expect(mingtuHomeDebugHandle!.recoveryPending, isTrue);
      expect(mingtuHomeDebugHandle!.localAsrBroken, isFalse,
          reason: 'a first recoverable error never routes '
              'to the cloud');
      await holdPastThreshold(tester);
      await g1.up();
      await tester.pump(const Duration(milliseconds: 200));
      await deliverFakeStatus(tester, 'notListening');
      await settleReleasedPress(tester, h);
      h.events.clear();
      processFakeStt!.ops.clear();

      final TestGesture g2 = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g2,
          expectRecorder: false, useFakeListen: true);
      // RED LINE: a real path started -- a NEW listen.
      expect(processFakeStt!.listenCalls, 2,
          reason: 'press 2 must listen again after $code');
      // Recovery order: cancel -> initialize -> listen.
      final List<String> ops = processFakeStt!.ops;
      final int cancelIdx = ops.indexOf('cancel');
      final int initIdx = ops.indexOf('initialize');
      final int listenIdx = ops.lastIndexOf('listen');
      expect(cancelIdx, greaterThanOrEqualTo(0),
          reason: 'recovery ops: $ops');
      expect(initIdx, greaterThan(cancelIdx),
          reason: 'recovery ops: $ops');
      expect(listenIdx, greaterThan(initIdx),
          reason: 'recovery ops: $ops');
      expect(processFakeStt!.initializeCalls, greaterThan(initBefore),
          reason: 'a REAL platform initialize happened');
      await holdPastThreshold(tester);
      await g2.up();
      await tester.pump(const Duration(milliseconds: 200));
      await deliverFakeStatus(tester, 'notListening');
      await settleReleasedPress(tester, h);
      await drainVoice(tester, h);
    }

    for (final String code in <String>[
      'error_busy',
      'error_client',
      'error_speech_timeout',
      'error_no_match',
    ]) {
      testWidgets(
          'PTT-2: $code (permanent=true) -- next press recovers '
          '(cancel -> initialize -> listen) and listens again',
          (WidgetTester tester) async {
        await recoverableCase(tester, code);
      });
    }

    testWidgets(
        'PTT-2: the same recoverable code twice in a row -- the '
        'next press RECORDS and speaks 改用云端识别 exactly once',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await installFakeBackedInput(tester);
      final FakeRecorder recorder = FakeRecorder();
      mingtuHomeDebugHandle!.setRecorder(recorder);
      h.events.clear();

      Future<void> errorPress() async {
        final TestGesture g = await startPttGesture(tester);
        await pressUntilCapture(tester, h, g,
            expectRecorder: false, useFakeListen: true);
        await deliverError(tester, 'error_busy', true);
        await holdPastThreshold(tester);
        await g.up();
        await tester.pump(const Duration(milliseconds: 200));
        await deliverFakeStatus(tester, 'notListening');
        await settleReleasedPress(tester, h);
        h.events.clear();
      }

      await errorPress(); // busy x1: count 1, recovery armed
      expect(
          mingtuHomeDebugHandle!.recoverableErrorCounts[
              'error_busy'],
          1);
      expect(mingtuHomeDebugHandle!.localAsrBroken, isFalse);
      await errorPress(); // busy x2 (via recovery): escalate
      expect(
          mingtuHomeDebugHandle!.recoverableErrorCounts[
              'error_busy'],
          2);
      expect(mingtuHomeDebugHandle!.localAsrBroken, isTrue);
      final int listensBefore = processFakeStt!.listenCalls;

      // The switching press: recorder, no listen, and the
      // switch notice exactly once.
      final TestGesture g3 = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g3,
          expectRecorder: true, recorder: recorder);
      expect(recorder.started, isTrue);
      expect(processFakeStt!.listenCalls, listensBefore,
          reason: 'no listen on the switching press');
      await pumpUntilSpeak(tester, h, asrCloudSwitchSpeechText);
      expect(h.count('tts.speak:$asrCloudSwitchSpeechText'), 1,
          reason: '${h.events}');
      await holdPastThreshold(tester);
      await g3.up();
      await tester.pump(const Duration(milliseconds: 300));
      await settleReleasedPress(tester, h);
      h.events.clear();

      // A later press is ALREADY on the fallback: it records
      // and does NOT repeat the switch notice.
      final TestGesture g4 = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g4,
          expectRecorder: true, recorder: recorder);
      expect(recorder.started, isTrue);
      await tester.pump(const Duration(milliseconds: 300));
      expect(h.count('tts.speak:$asrCloudSwitchSpeechText'), 0,
          reason: 'no repeat switch notice: ${h.events}');
      await holdPastThreshold(tester);
      await g4.up();
      await tester.pump(const Duration(milliseconds: 300));
      await drainVoice(tester, h);
    });

    testWidgets(
        'PTT-2: a failed re-initialize during recovery -- that '
        'press RECORDS and speaks 改用云端识别 once',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await installFakeBackedInput(tester);
      final FakeRecorder recorder = FakeRecorder();
      mingtuHomeDebugHandle!.setRecorder(recorder);
      h.events.clear();

      final TestGesture g1 = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g1,
          expectRecorder: false, useFakeListen: true);
      await deliverError(tester, 'error_client', true);
      expect(mingtuHomeDebugHandle!.recoveryPending, isTrue);
      await holdPastThreshold(tester);
      await g1.up();
      await tester.pump(const Duration(milliseconds: 200));
      await deliverFakeStatus(tester, 'notListening');
      await settleReleasedPress(tester, h);
      h.events.clear();

      // The recovery's re-initialize will fail.
      processFakeStt!.initializeResult = false;
      final int listensBefore = processFakeStt!.listenCalls;
      final TestGesture g2 = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g2,
          expectRecorder: true, recorder: recorder);
      expect(recorder.started, isTrue,
          reason: 'the press must still start a real path');
      expect(processFakeStt!.listenCalls, listensBefore,
          reason: 'no listen after a failed re-initialize');
      await pumpUntilSpeak(tester, h, asrCloudSwitchSpeechText);
      expect(h.count('tts.speak:$asrCloudSwitchSpeechText'), 1);
      await holdPastThreshold(tester);
      await g2.up();
      await tester.pump(const Duration(milliseconds: 300));
      await drainVoice(tester, h);
    });

    testWidgets(
        'PTT-2: recording cap -- holding past the cap auto-stops '
        'and transcribes once; an early release never double-sends',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      h.events.clear();

      final FakeRecorder recorder = FakeRecorder();
      await armFallbackRecorderOnly(tester, h, recorder,
          asrText: '去图书馆');
      mingtuHomeDebugHandle!.setRecordCapMs(300);

      final TestGesture g = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g,
          expectRecorder: true, recorder: recorder);
      expect(recorder.started, isTrue);
      // Hold WITHOUT releasing. The cap timer is a
      // wall-clock Timer the widget tester's fake clock
      // cannot fire, so the completion is driven through
      // the debug seam -- the SAME _onPttRecordCapReached
      // the production Timer calls. (That the Timer itself
      // is armed at asrMaxRecordMs on this path is covered
      // by the arming in _pttStartRecording; the seam
      // verifies the completion semantics.)
      mingtuHomeDebugHandle!.debugFireRecordCap();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(recorder.started, isFalse,
          reason: 'the cap auto-stopped the recorder');
      expect(fallbackSenderCalls!(), 1,
          reason: 'the capped clip was transcribed once');
      await pumpUntilSpeak(tester, h, asrRecordCapSpeechText);
      // Releasing after the cap must not send again.
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(fallbackSenderCalls!(), 1,
          reason: 'no double transcription after the cap');
      await drainVoice(tester, h);
    });
  });

  group('no automatic listen (e) + PTT-D checks', () {
    testWidgets(
        '(e) during and after a press there is exactly one '
        'listen; listenFor is 30 s; initialize does not grow '
        'across two normal presses',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      // Startup opened no session at all.
      expect(h.count('asr.listen'), 0, reason: '${h.events}');
      final int initAfterStartup = h.count('asr.initialize');
      h.events.clear();

      Future<void> onePress() async {
        final TestGesture g = await startPttGesture(tester);
        // NOTE: a no-content press settles by speaking the
        // no-content notice and leaves it PENDING; the next
        // press's cue is queued behind it, so pressUntilCapture
        // cannot see an uncompleted 请说 until prior speech is
        // completed -- drain first, here inside the press.
        h.completeAllSpeaks();
        await pressUntilCapture(tester, h, g, expectRecorder: false);
        await holdPastThreshold(tester);
        await g.up();
        await tester.pump(const Duration(milliseconds: 200));
        await h.deliverAllCloseStatuses();
        // A no-content press settles only when its 3 s
        // release window expires; the next press must not
        // start before that or it lands in the stopping
        // state and is swallowed.
        await settleReleasedPress(tester, h);
      }

      await onePress();
      expect(h.count('asr.listen'), 1, reason: '${h.events}');
      // PTT-D(3): the listen call carries listenFor = 30 s.
      expect(h.lastListenArgs, isNotNull);
      expect(h.lastListenArgs!['listenFor'], 30000,
          reason: 'listen args: ${h.lastListenArgs}');

      await onePress();
      expect(h.count('asr.listen'), 2, reason: '${h.events}');
      // PTT-D(4): normal presses never re-initialize.
      expect(h.count('asr.initialize'), initAfterStartup,
          reason: 'initialize grew: ${h.events}');
    });

    testWidgets(
        'PTT-D(2): a press stops playing TTS before opening '
        'the session (tts.stop precedes asr.listen)',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      // Start a straight-ahead prompt through the demo flow
      // so a non-P0 utterance is physically playing.
      mingtuHomeDebugHandle!.startVoiceDemo();
      mingtuHomeDebugHandle!.planRoute();
      mingtuHomeDebugHandle!.startNavigating();
      await tester.pump(const Duration(milliseconds: 300));
      h.completeAllSpeaks();
      await tester.pump(const Duration(milliseconds: 300));
      mingtuHomeDebugHandle!.manualStraight();
      await pumpUntilSpeak(tester, h, '直走');
      h.events.clear();

      final TestGesture g = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g, expectRecorder: false);
      final int stopIdx = h.events.indexOf('tts.stop');
      final int listenIdx = h.events.indexOf('asr.listen');
      expect(stopIdx, greaterThanOrEqualTo(0),
          reason: '${h.events}');
      expect(listenIdx, greaterThan(stopIdx),
          reason: 'stop before listen: ${h.events}');

      await holdPastThreshold(tester);
      await g.up();
      await tester.pump(const Duration(milliseconds: 200));
      await h.deliverAllCloseStatuses();
      await drainVoice(tester, h);
    });

    testWidgets(
        'PTT-D(4): backgrounding during listening cancels the '
        'session and never listens again',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      h.events.clear();

      final TestGesture g = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g, expectRecorder: false);
      expect(h.count('asr.listen'), 1, reason: '${h.events}');

      tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.paused);
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        h.count('asr.cancel') + h.count('asr.stop'),
        greaterThanOrEqualTo(1),
        reason: 'mic released on background: ${h.events}',
      );
      expect(h.count('asr.listen'), 1,
          reason: 'no listen after background: ${h.events}');

      await g.up();
      await h.deliverAllCloseStatuses();
      await drainVoice(tester, h);
    });

  });
}

/// Arm the recording fallback for a test that does not
/// live inside the (b, c, d) group: inject the recorder
/// and a counting fake ASR client, then force the broken
/// flag with a permission error on a system-ASR press
/// (the same arming the group's helper performs).
Future<void> armFallbackRecorderOnly(WidgetTester tester,
    RecordingVoiceChannels h, FakeRecorder recorder,
    {String? asrText}) async {
  int senderCalls = 0;
  mingtuHomeDebugHandle!.setRecorder(recorder);
  mingtuHomeDebugHandle!.setCloudAsrClient(CloudAsrClient(
    proxyBaseUrl: 'https://fc.example',
    sender: (Uri url, String body, Map<String, String> headers) async {
      senderCalls++;
      return jsonEncode(<String, Object?>{'text': asrText});
    },
  ));
  await installFakeBackedInput(tester);
  final TestGesture g0 = await startPttGesture(tester);
  await pressUntilCapture(tester, h, g0,
      expectRecorder: false, useFakeListen: true);
  await deliverError(tester, 'error_permission', true);
  expect(mingtuHomeDebugHandle!.localAsrBroken, isTrue);
  await holdPastThreshold(tester);
  await g0.up();
  await tester.pump(const Duration(milliseconds: 200));
  await deliverFakeStatus(tester, 'notListening');
  await settleReleasedPress(tester, h);
  h.events.clear();
  fallbackSenderCalls = () => senderCalls;
}

/// Set by the fallback-arming helper: reads the fake ASR
/// sender's call count for the current test.
int Function()? fallbackSenderCalls;
