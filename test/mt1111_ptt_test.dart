import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/system_voice_io.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart'
    as stt_result;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:mingtu_ai/core/asr_errors.dart';
import 'package:mingtu_ai/core/voice_startup.dart';
import 'package:mingtu_ai/main.dart';

/// MT-1111-PTT real-device fix round, FIRST commit (core
/// press-and-hold only): app-level behaviour tests for the
/// Xiaomi sequence (E), the permission-error dedup (a),
/// the no-automatic-listen counts (e), and the PTT-D core
/// checks (listenFor=30 s, initialize discipline,
/// background release, TTS-stop order). The recording +
/// cloud ASR fallback tests (b, c, d) and the startup-
/// unavailability direct-fallback test (PTT-D(5)) live in
/// the second commit's version of this file.
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
    {bool useFakeListen = false}) async {
  const Duration step = Duration(milliseconds: 50);
  for (int i = 0;
      i < 40 &&
          !h.speakQueue.any(
              (MapEntry<String, Completer<dynamic>> e) => e.key == '请说');
      i++) {
    h.completeAllSpeaks();
    await h.deliverAllCloseStatuses();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
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
    if (useFakeListen) {
      return processFakeStt != null && processFakeStt!.listenCalls > 0;
    }
    return h.count('asr.listen') > 0;
  }

  for (int i = 0; i < 40 && !started(); i++) {
    await h.deliverAllCloseStatuses();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(step);
  }
  if (!started()) fail('capture never started: ${h.events}');
  // The listen CALL lands before the app's state machine
  // finishes entering `listening` (the start future and
  // the prompt step's tail settle a few microtasks later):
  // give it rounds so deliveries made by the caller land
  // in the listening state, as on device. Zero-duration
  // pumps flush microtasks without advancing fake time.
  for (int i = 0; i < 6; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
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

  @override
  Future<bool> initialize({
    stt.SpeechErrorListener? onError,
    stt.SpeechStatusListener? onStatus,
    dynamic debugLogging = false,
    Duration finalTimeout = const Duration(seconds: 2),
    List<stt.SpeechConfigOption>? options,
  }) async {
    errorListener = onError;
    statusListener = onStatus;
    return true;
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> stop() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #listen) {
      resultListener = invocation.namedArguments[#onResult]
          as stt.SpeechResultListener?;
      listenCalls++;
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

void main() {
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
          useFakeListen: true);
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
          useFakeListen: true);
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
          useFakeListen: true);
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
          useFakeListen: true);
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

      // Release and press again: no permanent stop. In
      // this commit there is no recording fallback yet
      // (that routing is the second commit's wiring), so
      // the retry takes the only form core has: the next
      // press opens a NEW system session and listens
      // again -- the error never disabled pressing.
      await holdPastThreshold(tester);
      await g.up();
      await tester.pump(const Duration(milliseconds: 200));
      await deliverFakeStatus(tester, 'notListening');
      await settleReleasedPress(tester, h);
      h.events.clear();

      // No permanent stop at the APP level: a later press
      // runs the whole press flow again -- vibrate, cue,
      // start attempt. The adapter, by its own pre-existing
      // discipline, reports the recogniser unavailable
      // after a PERMANENT error (claiming availability
      // would be a lie), so in this commit -- which has no
      // recording fallback yet; that routing is the second
      // commit's wiring -- the attempt ends with the fixed
      // ASR-unavailable notice instead of a new session.
      // What the error must never do is silence or skip
      // the press itself.
      final TestGesture g2 = await startPttGesture(tester);
      await pumpUntilSpeak(tester, h, '请说');
      h.completeSpeak('请说');
      await pumpUntilSpeak(
          tester, h, voiceNoticeText(VoiceNoticeKind.asrUnavailable));
      expect(h.count('vibrate'), 2,
          reason: 'press vibrate + failure vibrate: ${h.events}');
      expect(processFakeStt!.listenCalls, 1,
          reason: 'the adapter refuses before the platform '
              'after a permanent error: ${h.events}');
      await g2.up();
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
        await pressUntilCapture(tester, h, g);
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
      await pressUntilCapture(tester, h, g);
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
      await pressUntilCapture(tester, h, g);
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
