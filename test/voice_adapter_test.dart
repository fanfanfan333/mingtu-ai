import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:mingtu_ai/adapters/system_voice_io.dart';
import 'package:mingtu_ai/adapters/voice_io.dart';
import 'package:mingtu_ai/core/asr_errors.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Adapter-layer mock tests for the Codex voice-P0 re-test fixes.
///
/// These fakes replace the PLATFORM side of flutter_tts /
/// speech_to_text, so they verify the adapter's contract: return
/// values are checked, errors propagate, stops are not swallowed.
/// They do NOT verify physical audio interruption on a device, and
/// they do NOT verify that a recogniser can hear "停下" while TTS
/// is speaking -- no such claim is made anywhere.

class FakeTts extends FlutterTts {
  List<String> languages = <String>['zh-CN', 'en-US'];
  dynamic setLanguageResult = 1;
  dynamic speakResult = 1;
  dynamic stopResult = 1;
  Object? speakError;
  Object? stopError;
  Completer<dynamic>? speakGate;
  Completer<dynamic>? stopGate;
  final List<String> callLog = <String>[];
  bool speakInFlight = false;
  int stopCalls = 0;
  bool stopCalledWhileSpeakInFlight = false;
  String? languageSetTo;

  /// NH-M1-10: the start handler the adapter registers
  /// via setStartHandler (the real engine invokes it when
  /// an utterance ACTUALLY starts sounding). The mock
  /// fires it at the speak() call point -- an APPROXIMATION:
  /// on a device the callback comes from the engine at
  /// true phonation, after queueing/engine latency the
  /// mock does not model; that magnitude difference is
  /// exactly what the pipeline-to-speak segment measures
  /// and stays on the real-device checklist for
  /// calibration.
  int startHandlerCalls = 0;

  @override
  void setStartHandler(void Function() handler) {
    // FlutterTts.startHandler is a plain field the plugin
    // invokes from its platform call handler; assigning
    // it IS the registration (the plugin's own
    // setStartHandler does exactly this).
    startHandler = handler;
  }

  @override
  Future<dynamic> awaitSpeakCompletion(bool awaitCompletion) async => 1;

  @override
  Future<dynamic> get getLanguages async => languages;

  @override
  Future<dynamic> isLanguageAvailable(String language) async =>
      languages.contains(language) ? 1 : 0;

  @override
  Future<dynamic> setLanguage(String language) async {
    languageSetTo = language;
    return setLanguageResult;
  }

  @override
  Future<dynamic> setSpeechRate(double rate) async => 1;

  @override
  Future<dynamic> setVolume(double volume) async => 1;

  @override
  Future<dynamic> setPitch(double pitch) async => 1;

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    callLog.add('speak:$text');
    speakInFlight = true;
    // NH-M1-10: fire the registered start handler at the
    // call point (see the field doc for the approximation
    // this is, and what remains for the real device).
    startHandlerCalls += 1;
    startHandler?.call();
    if (speakGate != null) await speakGate!.future;
    speakInFlight = false;
    if (speakError != null) throw speakError!;
    return speakResult;
  }

  @override
  Future<dynamic> stop() async {
    callLog.add('stop');
    stopCalls += 1;
    stopCalledWhileSpeakInFlight = speakInFlight;
    if (stopGate != null) await stopGate!.future;
    if (stopError != null) throw stopError!;
    return stopResult;
  }
}

/// SpeechToText has a factory (singleton) constructor and cannot
/// be extended, so the fake IMPLEMENTS the interface instead and
/// leans on noSuchMethod for the members the adapter tests never
/// touch (listen etc.).
class FakeStt implements stt.SpeechToText {
  stt.SpeechErrorListener? capturedOnError;
  stt.SpeechStatusListener? capturedOnStatus;
  int initializeCalls = 0;
  int cancelCalls = 0;

  /// The plugin's public listener fields: the adapter
  /// assigns its CURRENT registrations here after every
  /// initialize (the plugin's initialize latch otherwise
  /// keeps the first registration forever). Capturing the
  /// assignments mirrors the real plugin's single-listener
  /// replacement exactly.
  @override
  stt.SpeechErrorListener? errorListener;
  @override
  stt.SpeechStatusListener? statusListener;

  /// The onResult listener of EVERY listen() call, in call
  /// order. The adapter registers a fresh closure per
  /// session; keeping them all lets tests invoke an OLD
  /// session's closure after a newer session has started
  /// -- the exact late-callback shape the session-id
  /// stamping exists for.
  final List<stt.SpeechResultListener?> resultListeners =
      <stt.SpeechResultListener?>[];
  bool initResult = true;
  Object? stopError;
  Completer<void>? stopGate;
  Completer<void>? cancelGate;
  int stopCalls = 0;

  @override
  Future<bool> initialize({
    stt.SpeechErrorListener? onError,
    stt.SpeechStatusListener? onStatus,
    dynamic debugLogging = false,
    Duration finalTimeout = const Duration(seconds: 2),
    List<stt.SpeechConfigOption>? options,
  }) async {
    initializeCalls++;
    capturedOnError = onError;
    capturedOnStatus = onStatus;
    return initResult;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    if (cancelGate != null) await cancelGate!.future;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
    if (stopGate != null) await stopGate!.future;
    if (stopError != null) throw stopError!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #listen) {
      stt.SpeechResultListener? onResult;
      if (invocation.namedArguments.containsKey(#onResult)) {
        onResult =
            invocation.namedArguments[#onResult] as stt.SpeechResultListener?;
      } else if (invocation.positionalArguments.isNotEmpty) {
        onResult = invocation.positionalArguments.first
            as stt.SpeechResultListener?;
      }
      resultListeners.add(onResult);
      return Future<void>.value();
    }
    throw UnimplementedError('FakeStt: ${invocation.memberName}');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ttsResultSucceeded semantics (plugin-source based)', () {
    test('only 1 / true count as success', () {
      expect(ttsResultSucceeded(1), isTrue);
      expect(ttsResultSucceeded(true), isTrue);
      expect(ttsResultSucceeded(0), isFalse);
      expect(ttsResultSucceeded(false), isFalse);
      expect(ttsResultSucceeded(null), isFalse);
    });
  });

  group('SystemVoiceOutput return-value validation', () {
    test('setLanguage returning 0 fails zh-CN verification closed', () async {
      final fake = FakeTts()..setLanguageResult = 0;
      final out = SystemVoiceOutput(fake);
      expect(await out.initialize(), isTrue); // engine answered
      expect(out.chineseVoiceVerified, isFalse); // but Chinese NOT set
      expect(out.status, contains('未核实成功'));
    });

    test('setLanguage returning 1 verifies Chinese', () async {
      final out = SystemVoiceOutput(FakeTts());
      expect(await out.initialize(), isTrue);
      expect(out.chineseVoiceVerified, isTrue);
      expect(out.isAvailable, isTrue);
    });

    test('no zh-CN in the language list never verifies', () async {
      final fake = FakeTts()..languages = <String>['en-US', 'ja-JP'];
      final out = SystemVoiceOutput(fake);
      await out.initialize();
      expect(out.chineseVoiceVerified, isFalse);
    });

    test('speak returning 0 throws and marks the output unavailable', () async {
      final fake = FakeTts()..speakResult = 0;
      final out = SystemVoiceOutput(fake);
      await out.initialize();
      await expectLater(out.speak('你好'), throwsStateError);
      expect(out.isAvailable, isFalse);
      expect(out.chineseVoiceVerified, isFalse);
    });

    test('mock speak fires the registered start handler '
        '(NH-M1-10 segment-2 testability)', () async {
      final FakeTts fake = FakeTts();
      final out = SystemVoiceOutput(fake);
      await out.initialize();
      // The adapter registered its start handler on the
      // engine during initialize (setStartHandler), wired
      // to SystemVoiceOutput.onSpeakStart.
      expect(fake.startHandler, isNotNull,
          reason: 'the adapter registers a start handler '
              'on the TTS object at initialize');
      int starts = 0;
      out.onSpeakStart = () => starts++;
      await out.speak('前方有车');
      expect(starts, 1,
          reason: 'one speak -> one start event through '
              'the adapter seam, same signature as the '
              'real engine callback');
      expect(fake.startHandlerCalls, 1);
    });

    test('speak returning 1 completes normally', () async {
      final out = SystemVoiceOutput(FakeTts());
      await out.initialize();
      await out.speak('你好');
      expect(out.isAvailable, isTrue);
    });
  });

  group('SystemVoiceOutput stop semantics and the stop/speak race', () {
    test('stop failure (result 0) is NOT swallowed', () async {
      final fake = FakeTts()..stopResult = 0;
      final out = SystemVoiceOutput(fake);
      await out.initialize();
      await expectLater(out.stop(), throwsStateError);
    });

    test('stop platform exception propagates', () async {
      final fake = FakeTts()..stopError = Exception('platform gone');
      final out = SystemVoiceOutput(fake);
      await out.initialize();
      await expectLater(out.stop(), throwsException);
    });

    test(
        'stop issued while a speak is in flight reaches the engine '
        'before the speak completes (adapter ordering only)', () async {
      final fake = FakeTts();
      final gate = Completer<dynamic>();
      fake.speakGate = gate;
      final out = SystemVoiceOutput(fake);
      await out.initialize();
      final Future<void> speaking = out.speak('导航提示');
      // Let the fake's speak actually start.
      await Future<void>.delayed(Duration.zero);
      expect(fake.speakInFlight, isTrue);
      await out.stop();
      expect(fake.stopCalls, 1);
      expect(fake.stopCalledWhileSpeakInFlight, isTrue);
      gate.complete(1);
      await speaking; // completes without error after the stop
      expect(out.isAvailable, isTrue);
    });

    test(
        'stop-then-confirm ordering: the confirmation speak is '
        'only submitted after stop COMPLETES (sequencer contract)', () async {
      // Mirrors main's _stopSpeechThenConfirm at the adapter
      // level: cancel old speech, await stop, then speak the
      // confirmation. Before the fix the confirmation was
      // submitted while the stop was still in flight.
      final fake = FakeTts();
      final speakGate = Completer<dynamic>();
      final stopGate = Completer<dynamic>();
      fake.speakGate = speakGate;
      fake.stopGate = stopGate;
      final out = SystemVoiceOutput(fake);
      await out.initialize();

      final Future<void> oldSpeak = out.speak('导航提示');
      await Future<void>.delayed(Duration.zero);
      expect(fake.callLog, <String>['speak:导航提示']);

      bool confirmSubmitted = false;
      final Future<void> sequencer = () async {
        await out.stop();
        confirmSubmitted = true;
        await out.speak('已暂停导航');
      }();
      await Future<void>.delayed(Duration.zero);
      // Stop has been CALLED but has not completed: the
      // confirmation must not have been submitted yet.
      expect(fake.callLog, <String>['speak:导航提示', 'stop']);
      expect(confirmSubmitted, isFalse);

      stopGate.complete(1);
      speakGate.complete(1);
      await sequencer;
      await oldSpeak;
      expect(
        fake.callLog,
        <String>['speak:导航提示', 'stop', 'speak:已暂停导航'],
      );
    });

    test(
        'an in-flight speak that then reports failure still fails '
        'the caller after a stop (no fake success)', () async {
      final fake = FakeTts();
      final gate = Completer<dynamic>();
      fake.speakGate = gate;
      fake.speakResult = 0;
      final out = SystemVoiceOutput(fake);
      await out.initialize();
      final Future<void> speaking = out.speak('导航提示');
      await Future<void>.delayed(Duration.zero);
      await out.stop();
      gate.complete(0);
      await expectLater(speaking, throwsStateError);
      expect(out.isAvailable, isFalse);
    });
  });

  group('SystemVoiceInput error stream (no silent ASR death)', () {
    test('platform onError is forwarded to errors listeners', () async {
      final fake = FakeStt();
      final input = SystemVoiceInput(fake);
      expect(await input.initialize(), isTrue);
      final Future<String> firstError = input.errors.first;
      fake.capturedOnError!(
        SpeechRecognitionError('error_network', false),
      );
      expect(await firstError, 'error_network|permanent=false');
      // A transient error does not by itself kill availability.
      expect(input.isAvailable, isTrue);
    });

    test(
        'a FATAL code (permission) marks the input unavailable '
        '-- by code, not by the permanent flag', () async {
      final fake = FakeStt();
      final input = SystemVoiceInput(fake);
      await input.initialize();
      final Future<String> firstError = input.errors.first;
      fake.capturedOnError!(
        SpeechRecognitionError('error_permission', true),
      );
      expect(await firstError, contains('permanent=true'));
      expect(input.isAvailable, isFalse);
    });

    test(
        'MT-1111-PTT-2/CDX1: a RECOVERABLE code with '
        'permanent=true (the plugin sends permanent=true for '
        'EVERY error) does NOT mark the input unavailable',
        () async {
      for (final String code in <String>[
        'error_busy',
        'error_client',
        'error_network',
        'error_audio',
        // CDX2 / MT-1111-ALIGN: error_server and the two
        // language codes are RECOVERABLE too -- direct
        // cloud routing is only for no-engine / permission.
        'error_server',
        'error_language_not_supported',
        'error_language_unavailable',
      ]) {
        final fake = FakeStt();
        final input = SystemVoiceInput(fake);
        await input.initialize();
        final Future<String> firstError = input.errors.first;
        fake.capturedOnError!(SpeechRecognitionError(code, true));
        // The payload still carries the flag for
        // diagnostics; the DECISION must ignore it.
        expect(await firstError, '$code|permanent=true');
        expect(input.isAvailable, isTrue,
            reason: '$code is recoverable: availability must '
                'survive a permanent=true delivery');
      }
    });

    test(
        'MT-1111-PTT-2: error_unknown with permanent=true is '
        'recoverable too (retry, never permanent silence)',
        () async {
      final fake = FakeStt();
      final input = SystemVoiceInput(fake);
      await input.initialize();
      final Future<String> firstError = input.errors.first;
      fake.capturedOnError!(
        SpeechRecognitionError('error_unknown', true),
      );
      expect(await firstError, 'error_unknown|permanent=true');
      expect(input.isAvailable, isTrue);
    });

    test(
        'a listening session end is signalled on the sessionEnded '
        'stream (continuous-listen seam)', () async {
      final fake = FakeStt();
      final input = SystemVoiceInput(fake);
      expect(await input.initialize(), isTrue);
      final Future<void> ended = input.sessionEnded.first;
      expect(await input.startListening(), isTrue);
      expect(input.isListening, isTrue);
      // A session that ends on its own (silence) delivers
      // its status with NO stop pending: it is a natural
      // end and reaches the sessionEnded stream.
      fake.capturedOnStatus!('done');
      await ended.timeout(const Duration(seconds: 1));
      expect(input.isListening, isFalse);
    });

    test(
        'ASR errors are whitelisted: a known code passes, a '
        'raw platform string collapses to error_unknown and '
        'never reaches the detail', () async {
      final fake = FakeStt();
      final input = SystemVoiceInput(fake);
      await input.initialize();
      final Future<String> first = input.errors.first;
      fake.capturedOnError!(
        SpeechRecognitionError('error_permission', true),
      );
      expect(await first, 'error_permission|permanent=true');

      final FakeStt fake2 = FakeStt();
      final SystemVoiceInput input2 = SystemVoiceInput(fake2);
      await input2.initialize();
      final Future<String> second = input2.errors.first;
      fake2.capturedOnError!(
        SpeechRecognitionError('raw platform detail sentence', false),
      );
      expect(await second, 'error_unknown|permanent=false');
      expect(input2.status, isNot(contains('raw platform detail')));
      expect(input2.status, contains('语音识别出错'));
    });

    test('stopListening platform errors propagate, not swallowed', () async {
      final fake = FakeStt()..stopError = Exception('mic stuck');
      final input = SystemVoiceInput(fake);
      await input.initialize();
      // A live session first: a stop with no live session
      // is a no-op (it opens no pending close), so the
      // propagation contract applies to a real close.
      expect(await input.startListening(), isTrue);
      await expectLater(input.stopListening(), throwsException);
      expect(input.isListening, isFalse);
      expect(input.pendingCloses, 1);
    });
  });

  group('speak/listen turn-taking (end-to-end sequence)', () {
    test(
        'listening pauses before speech, “停下” stop() lands '
        'while speech is in flight, listening resumes after', () async {
      final FakeTts tts = FakeTts();
      final FakeStt sttFake = FakeStt();
      final SystemVoiceOutput out = SystemVoiceOutput(tts);
      final SystemVoiceInput input = SystemVoiceInput(sttFake);
      expect(await out.initialize(), isTrue);
      expect(await input.initialize(), isTrue);

      // 1) The turn-taking loop is listening.
      expect(await input.startListening(), isTrue);
      expect(input.isListening, isTrue);

      // 2) Speech is about to start: the app closes the mic
      // FIRST (this is the exact call _speakActive makes via
      // _pauseListeningForSpeech).
      await input.stopListening();
      expect(input.isListening, isFalse);
      // The platform confirms the close with its closing
      // status; only then may a later session open
      // (unconfirmed-close rule). FakeStt delivers
      // nothing on its own, so the test delivers it
      // through the captured status listener, exactly as
      // the platform would. (The stop's owed-status entry
      // survives for a later duplicate status.)
      sttFake.capturedOnStatus!('notListening');
      expect(input.pendingCloses, 0);

      // 3) Speech runs; a “停下” during it delivers stop() to
      // the engine while the utterance is still in flight.
      tts.speakGate = Completer<dynamic>();
      final Future<void> speaking = out.speak('前方有车，请停下。');
      await Future<void>.delayed(Duration.zero);
      expect(tts.speakInFlight, isTrue);
      await out.stop();
      expect(tts.stopCalls, 1);
      expect(tts.stopCalledWhileSpeakInFlight, isTrue);
      tts.speakGate!.complete(1);
      await speaking;

      // 4) Speech finished: the loop reopens the microphone
      // (the call _finishSpeech drives via
      // _maybeStartListeningAfterSpeech).
      expect(await input.startListening(), isTrue);
      expect(input.isListening, isTrue);
    });
  });
  group('speakAfterClosingMic: speech waits for the mic stop', () {
    test('speak does not start until stopListening completes', () async {
      final sttFake = FakeStt();
      final input = SystemVoiceInput(sttFake);
      addTearDown(input.dispose);
      await input.initialize();
      expect(await input.startListening(), isTrue);
      expect(input.isListening, isTrue);

      sttFake.stopGate = Completer<void>();
      var speakStarted = false;
      final List<String> order = <String>[];
      final Future<void> sequence = speakAfterClosingMic(
        input: input,
        speak: () async {
          speakStarted = true;
          order.add('speak');
        },
      );
      // Flush microtasks: the stop is gated, so speech must
      // NOT have started yet -- this is the exact ordering
      // the production speak path now uses.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(sttFake.stopCalls, 1);
      expect(speakStarted, isFalse);
      // The mic is not closed yet -- exactly why speech waits.
      expect(input.isListening, isTrue);

      order.add('stop-released');
      sttFake.stopGate!.complete();
      await sequence;
      expect(input.isListening, isFalse);
      expect(speakStarted, isTrue);
      // Confirm the close with its closing status so
      // the resume below may open.
      sttFake.capturedOnStatus!('notListening');
      expect(input.pendingCloses, 0);
      // The recorded order is the proof: speak ran strictly
      // AFTER the microphone stop completed.
      expect(order, <String>['stop-released', 'speak']);
      // And listening can resume afterwards.
      expect(await input.startListening(), isTrue);
      // The previous session's closing status was already
      // consumed above; this listen's own stop now owes
      // one status debt, which the next test-file user of
      // this input does not see (the input is disposed).
    });

    test(
        'no open mic: speak runs immediately; a failed stop does not block speech',
        () async {
      final sttFake = FakeStt();
      final input = SystemVoiceInput(sttFake);
      addTearDown(input.dispose);
      await input.initialize();
      var ran = false;
      await speakAfterClosingMic(
          input: input,
          speak: () async {
            ran = true;
          });
      expect(ran, isTrue);
      expect(sttFake.stopCalls, 0);

      expect(await input.startListening(), isTrue);
      sttFake.stopError = StateError('stop failed');
      ran = false;
      await speakAfterClosingMic(
          input: input,
          speak: () async {
            ran = true;
          });
      expect(ran, isTrue);
      // The failed stop still opened a pending close; the
      // platform's terminal outcome confirms it (the
      // recogniser did close, only the acknowledgement
      // failed): the session's benign error settles the
      // pending close, its closing status repays the
      // owed-status ledger.
      (sttFake.errorListener ?? sttFake.capturedOnError)!(
          SpeechRecognitionError('error_no_match', false));
      (sttFake.statusListener ?? sttFake.capturedOnStatus)!(
          'notListening');
      expect(input.pendingCloses, 0);
    });
  });
  group('unconfirmed-close rule via the plugin channel', () {
    // PLUGIN-LAYER REWRITE (this round): platform events
    // carry NO session identity, so the adapter never
    // guesses one from a timeout. It counts unconfirmed
    // closes instead: a new listen may start ONLY once
    // every initiated stop/cancel has been confirmed by
    // its closing status -- there is no 800 ms release
    // anymore. This group uses the REAL plugin
    // (SystemVoiceInput's default SpeechToText) behind a
    // MethodChannel platform fake, and every result and
    // status is delivered exactly the way a platform
    // delivers it: textRecognition / notifyStatus
    // platform->Dart calls on
    // plugin.csdcorp.com/speech_to_text, routed by the
    // plugin's single listener.
    //
    // The plugin's initialize() short-circuits process-
    // wide after its first success, so this file gets
    // exactly ONE channel-driven adapter walk; the
    // watchdog-restart walk lives in its own group below
    // and reuses this walk's engine (see there).
    const String sttChannel = 'plugin.csdcorp.com/speech_to_text';

    Future<void> deliverPlatform(String method, Object? arg) async {
      final ByteData data = const StandardMethodCodec()
          .encodeMethodCall(MethodCall(method, arg));
      await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(sttChannel, data, (ByteData? _) {});
    }

    /// A closing session's confirmation: its closing
    /// status. (Its terminal ERROR is deliberately not
    /// delivered here: after a user stop the plugin
    /// itself suppresses notifyError -- _userEnded -- so
    /// on a real device the status is the confirmation
    /// channel; the adapter's error-consumed path is
    /// exercised by the FakeStt tests, whose recogniser
    /// has no such suppression.) The status confirms the
    /// pending close; the same stop's owed-status entry
    /// survives it for a genuinely late duplicate status.
    Future<void> deliverCloseOutcome() async {
      await deliverPlatform('notifyStatus', 'notListening');
    }

    String resultJson(String words, int resultType) =>
        jsonEncode(<String, dynamic>{
          'alternates': <Map<String, dynamic>>[
            <String, dynamic>{
              'recognizedWords': words,
              'confidence': 0.95,
            }
          ],
          'resultType': resultType,
        });

    test(
        'a closing status is consumed by the closing '
        'session only; the next listen waits -- past the '
        'old 800 ms bound -- until it lands', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final List<String> platformCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(sttChannel),
              (MethodCall call) async {
        platformCalls.add(call.method);
        switch (call.method) {
          case 'initialize':
            return true;
          case 'has_permission':
            return true;
          default:
            return null;
        }
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel(sttChannel), null);
      });

      final SystemVoiceInput input = SystemVoiceInput();
      addTearDown(input.dispose);
      // Stale-status debt bookkeeping for THIS walk
      // (rule B): generation 1's closing status is still
      // owed when generation 2's stop lands below, so the
      // FIRST status after that stop repays generation 1
      // -- and generation 2's own close then needs the
      // SECOND status. Tracked here so the walk delivers
      // exactly what the platform owes, no more.
      bool gen1CloseStatusConsumed = false;
      final List<AsrResultEvent> finals = <AsrResultEvent>[];
      final List<AsrResultEvent> partials = <AsrResultEvent>[];
      final List<AsrStatusEvent> ends = <AsrStatusEvent>[];
      final List<StreamSubscription<dynamic>> subs =
          <StreamSubscription<dynamic>>[
        input.transcripts.listen(finals.add),
        input.partials.listen(partials.add),
        input.sessionEnded.listen(ends.add),
      ];
      addTearDown(() async {
        for (final StreamSubscription<dynamic> sub in subs) {
          await sub.cancel();
        }
      });

      expect(await input.initialize(), isTrue);

      // --- Generation 1: live results flow, stamped 1.
      expect(await input.startListening(), isTrue);
      final int gen1 = input.currentSessionId;
      await deliverPlatform(
          'textRecognition', resultJson('第一句', 0)); // partial
      await deliverPlatform(
          'textRecognition', resultJson('第一句完整', 2)); // final
      await Future<void>.delayed(Duration.zero);
      expect(partials.single.sessionId, gen1);
      expect(partials.single.text, '第一句');
      expect(finals.single.sessionId, gen1);
      expect(finals.single.text, '第一句完整');
      // Repeat-utterance probe (new semantics): session
      // 2 below repeats this exact final text. With the
      // text-equality gate REMOVED, the repeat must be
      // accepted as session 2's own result.
      const String gen1FinalText = '第一句完整';

      // --- Stop generation 1. Its closing status has not
      // arrived: one close is UNCONFIRMED.
      await input.stopListening();
      expect(input.pendingCloses, 1);
      expect(input.sessionOpen, isTrue);
      expect(input.isListening, isFalse);

      // A late result of generation 1, delivered through
      // the channel NOW (between generations): the
      // adapter's generation gate is closed (no stopping
      // window is open), so it is dropped IN THE ADAPTER
      // -- transcripts never emit it.
      await deliverPlatform(
          'textRecognition', resultJson('迟到的旧结果', 2));
      await Future<void>.delayed(Duration.zero);
      expect(finals, hasLength(1));
      expect(partials, hasLength(1));

      // The closing status arrives: it CONFIRMS
      // generation 1's pending close -- the count drops
      // to zero and NO sessionEnded is emitted for it.
      await deliverCloseOutcome();
      await Future<void>.delayed(Duration.zero);
      expect(input.pendingCloses, 0);
      expect(input.sessionOpen, isFalse);
      expect(ends, isEmpty);
      gen1CloseStatusConsumed = true;

      // --- Generation 2 opens at once (nothing pending).
      final Stopwatch sw2 = Stopwatch()..start();
      expect(await input.startListening(), isTrue);
      expect(sw2.elapsedMilliseconds, lessThan(700),
          reason: 'a confirmed close must not wait');
      final int gen2 = input.currentSessionId;
      expect(gen2, greaterThan(gen1));
      // Session 2 repeats generation 1's final text
      // EXACTLY, as a bare final well within 300 ms of
      // its listen start: under the removed heuristics
      // this was dropped twice over (same text AND fast).
      // Now it is accepted as session 2's own result --
      // the adapter never judges a result by its text or
      // its timing.
      await deliverPlatform(
          'textRecognition', resultJson(gen1FinalText, 2));
      await Future<void>.delayed(Duration.zero);
      expect(finals.last.sessionId, gen2);
      expect(finals.last.text, gen1FinalText);

      // --- Generation 2 stops; its status is WITHHELD.
      // Generation 3's start must now wait -- and keep
      // waiting PAST the old 800 ms release: there is no
      // timeout guess anymore.
      await input.stopListening();
      expect(input.pendingCloses, 1);
      bool gen3Started = false;
      final Future<bool> gen3 = input.startListening().then((bool v) {
        gen3Started = true;
        return v;
      });
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(gen3Started, isFalse,
          reason: 'an unconfirmed close never releases a '
              'new listen, not even after 1.2 s');
      expect(input.isListening, isFalse);
      expect(platformCalls.where((String c) => c == 'listen'),
          hasLength(2),
          reason: 'no third listen reached the platform');

      // The withheld status finally lands at ~1.2 s: it
      // is consumed by generation 2's close. It does NOT
      // end generation 3 (which has not even opened yet)
      // and it emits NO sessionEnded.
      await deliverCloseOutcome();
      await Future<void>.delayed(Duration.zero);
      expect(input.pendingCloses, 0);
      expect(ends, isEmpty);

      // Only NOW does generation 3 open.
      expect(await gen3, isTrue);
      expect(gen3Started, isTrue);
      final int gen3Id = input.currentSessionId;
      expect(gen3Id, greaterThan(gen2));
      expect(input.isListening, isTrue);
      await deliverPlatform(
          'textRecognition', resultJson('第三句', 0)); // partial
      await deliverPlatform(
          'textRecognition', resultJson('第三句', 2)); // final
      await Future<void>.delayed(Duration.zero);
      expect(partials.last.sessionId, gen3Id);
      expect(partials.last.text, '第三句');
      expect(finals.last.sessionId, gen3Id);
      expect(finals.last.text, '第三句');
      // The late status never produced a session end.
      expect(ends, isEmpty);

      await input.stopListening();
      expect(platformCalls, contains('listen'));

      // Settle generation 3's own close so its ledgers
      // are repaid and no watchdog ladder is left armed
      // past this walk.
      await deliverCloseOutcome();
      await Future<void>.delayed(Duration.zero);
      expect(input.pendingCloses, 0);

      // ===== Codex synthetic scene (new semantics) =====
      // A session produces its result, its close is
      // CONFIRMED, a successor session opens -- and only
      // THEN do the old session's leftovers arrive: a
      // duplicate final (routed by the plugin's single
      // listener through the SUCCESSOR's result closure,
      // the '[newId:<old text>]' shape) and a duplicate
      // closing status. Under the new direction the
      // adapter does NOT judge the final (no text or
      // timing heuristics): the leftover is delivered to
      // session B's closure AFTER A's close was
      // confirmed, indistinguishable from B's own genuine
      // first result, so it is accepted and streamed as
      // B's -- the APP layer is what never executes it
      // out of turn (it can only be cached by a held
      // press and submitted by that press's own release,
      // or, for an automatic session, it IS that
      // session's input; see the app-level race test).
      // What the adapter still guarantees here: the old
      // STATUS is repaid from session A's owed-status
      // ledger and never ends session B.
      expect(gen1CloseStatusConsumed, isTrue);
      // --- Session A: results flow, then a confirmed close.
      expect(await input.startListening(), isTrue);
      final int genA = input.currentSessionId;
      await deliverPlatform(
          'textRecognition', resultJson('去图书馆', 0)); // partial
      await deliverPlatform(
          'textRecognition', resultJson('去图书馆', 2)); // final
      await Future<void>.delayed(Duration.zero);
      expect(partials.last.sessionId, genA);
      expect(partials.last.text, '去图书馆');
      expect(finals.last.sessionId, genA);
      expect(finals.last.text, '去图书馆');
      await input.stopListening();
      expect(input.pendingCloses, 1);
      await deliverCloseOutcome();
      await Future<void>.delayed(Duration.zero);
      expect(input.pendingCloses, 0,
          reason: 'session A close CONFIRMED before B opens');
      expect(ends, isEmpty);

      // --- Session B opens.
      expect(await input.startListening(), isTrue);
      final int genB = input.currentSessionId;
      expect(genB, greaterThan(genA));
      expect(input.isListening, isTrue);

      // Step 2: the OLD session's late final arrives now.
      // No guessing: it is accepted as session B's result
      // (streamed, stamped genB) -- see the scene header
      // for why that is the honest semantics now.
      final int finalsBeforeScene = finals.length;
      await deliverPlatform(
          'textRecognition', resultJson('去图书馆', 2));
      await Future<void>.delayed(Duration.zero);
      expect(finals, hasLength(finalsBeforeScene + 1),
          reason: 'the leftover final is streamed as '
              'session B\'s own result (no text/timing '
              'judgement)');
      expect(finals.last.sessionId, genB);
      expect(finals.last.text, '去图书馆');
      expect(input.isListening, isTrue);

      // Step 3: the OLD session's late status arrives.
      // Session A's stop recorded an owed status and its
      // confirming status repaid the pending close only;
      // THIS status repays the owed ledger -- session B
      // keeps listening and no sessionEnded is emitted.
      await deliverPlatform('notifyStatus', 'notListening');
      await Future<void>.delayed(Duration.zero);
      expect(input.isListening, isTrue,
          reason: 'the stale status must not end session B');
      expect(input.pendingCloses, 0,
          reason: 'no close is open for session B');
      expect(ends, isEmpty,
          reason: 'no sessionEnded for session B');

      // Session B closes normally: stop, then its
      // closing outcome settles its own ledgers.
      await input.stopListening();
      expect(input.pendingCloses, 1);
      await deliverCloseOutcome();
      await Future<void>.delayed(Duration.zero);
      expect(input.pendingCloses, 0);
      expect(ends, isEmpty);
    });
  });

  group('engine watchdog restart (injected recogniser)', () {
    test(
        'closes unconfirmed prod one cancel; the engine '
        'restarts right after the capped prod: count '
        'zeroed, epoch bumped, restarted emitted',
        () async {
      final FakeStt fake = FakeStt();
      final SystemVoiceInput input = SystemVoiceInput(fake);
      addTearDown(input.dispose);
      // Deterministic ladder (this round): the watchdog
      // steps run on a short injected ladder instead of
      // the production 3 s / 1 s, and every assertion below
      // POLLS for its condition instead of sleeping one
      // fixed duration that must land inside a window.
      input.debugWatchdogLadder = (
        prod: const Duration(milliseconds: 250),
        restart: const Duration(milliseconds: 150),
      );
      expect(await input.initialize(), isTrue);
      final int epoch0 = input.engineEpoch;
      // The injected recogniser IS the engine object the
      // adapter registered against -- the precondition
      // for its in-place re-initialize on restart.
      expect(identical(input.engineInstanceForTest, fake), isTrue);
      final Future<String> restarted = input.engineEvents.first;

      expect(await input.startListening(), isTrue);
      await input.stopListening();
      expect(input.pendingCloses, 1);
      // The closing status NEVER arrives (FakeStt
      // delivers none on its own and this test delivers
      // none either).
      // After the prod step the watchdog prods the engine
      // with ONE cancel -- which must NOT itself open a
      // pending close. Poll for the prod, do not sleep a
      // fixed window.
      for (int i = 0; i < 100 && fake.cancelCalls == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(fake.cancelCalls, 1,
          reason: 'exactly one watchdog cancel prod');
      // Ladder semantics (this round): there is no
      // second waiting step anymore -- the restart
      // follows the prod as soon as its future settles
      // or the cap elapses, so the intermediate state
      // (prod seen, restart not yet run) is not a stable
      // observation point; the end state is asserted
      // below instead.
      // After the restart step the engine is force-
      // restarted: the injected recogniser is re-
      // initialized in place (its initialize count
      // grows), the epoch bumps, the count is forgiven,
      // and 'restarted' is emitted.
      expect(await restarted.timeout(const Duration(seconds: 5)),
          'restarted');
      expect(input.pendingCloses, 0);
      expect(input.engineEpoch, epoch0 + 1);
      expect(fake.initializeCalls, 2,
          reason: 'initial initialize + the restart '
              're-initialize');
      expect(input.lastRestartSucceeded, isTrue);
      // The restart re-initialized the engine: with an
      // injected recogniser that is observable as the SAME
      // object still being the registered engine, under
      // the bumped epoch (its listener registrations were
      // re-made by the initialize call inside the
      // restart).
      expect(identical(input.engineInstanceForTest, fake), isTrue);
      expect(input.isAvailable, isTrue);
      expect(input.isListening, isFalse);

      // A status delivered NOW belongs to no session:
      // the count stays at zero (never negative) and no
      // sessionEnded is emitted for it.
      final List<AsrStatusEvent> ends = <AsrStatusEvent>[];
      final StreamSubscription<AsrStatusEvent> sub =
          input.sessionEnded.listen(ends.add);
      (fake.statusListener ?? fake.capturedOnStatus)!('notListening');
      await Future<void>.delayed(Duration.zero);
      expect(input.pendingCloses, 0);
      expect(ends, isEmpty);
      await sub.cancel();

      // And the restarted engine can listen again.
      expect(await input.startListening(), isTrue);
      expect(input.isListening, isTrue);
      // Settle this session's own close so no watchdog
      // ladder is left armed past the test.
      await input.stopListening();
      (fake.statusListener ?? fake.capturedOnStatus)!('notListening');
      expect(input.pendingCloses, 0);
    });

    test(
        'a prod cancel whose future NEVER completes '
        'cannot stall the ladder: the restart still runs '
        'and really re-initializes the engine', () async {
      final FakeStt fake = FakeStt();
      // The platform cancel hangs forever (this
      // completer is never completed) and no closing
      // status is ever delivered.
      fake.cancelGate = Completer<void>();
      final SystemVoiceInput input = SystemVoiceInput(fake);
      addTearDown(input.dispose);
      input.debugWatchdogLadder = (
        prod: const Duration(milliseconds: 250),
        restart: const Duration(milliseconds: 150),
      );
      expect(await input.initialize(), isTrue);
      expect(fake.initializeCalls, 1);
      final int epoch0 = input.engineEpoch;
      final Future<String> restarted = input.engineEvents.first;
      expect(await input.startListening(), isTrue);
      await input.stopListening();
      expect(input.pendingCloses, 1);
      // Prod at ~250 ms; its cancel never returns, so
      // only the 150 ms cap on the prod future lets the
      // ladder reach the restart at all.
      expect(await restarted.timeout(const Duration(seconds: 5)),
          'restarted');
      expect(fake.cancelCalls, 1,
          reason: 'exactly one watchdog cancel prod');
      expect(fake.initializeCalls, 2,
          reason: 'the restart really re-initialized');
      expect(input.pendingCloses, 0);
      expect(input.engineEpoch, epoch0 + 1);
      expect(input.lastRestartSucceeded, isTrue);
      expect(input.isAvailable, isTrue);
      // The restarted engine can listen again.
      expect(await input.startListening(), isTrue);
      expect(input.isListening, isTrue);
      await input.stopListening();
      (fake.statusListener ?? fake.capturedOnStatus)!('notListening');
      expect(input.pendingCloses, 0);
    });

    test(
        'a restart whose re-initialize FAILS emits '
        'restart_failed (never restarted), still clears '
        'every ledger and does not wedge', () async {
      final FakeStt fake = FakeStt();
      final SystemVoiceInput input = SystemVoiceInput(fake);
      addTearDown(input.dispose);
      input.debugWatchdogLadder = (
        prod: const Duration(milliseconds: 250),
        restart: const Duration(milliseconds: 150),
      );
      expect(await input.initialize(), isTrue);
      final List<String> engineLog = <String>[];
      final StreamSubscription<String> sub =
          input.engineEvents.listen(engineLog.add);
      addTearDown(sub.cancel);
      expect(await input.startListening(), isTrue);
      await input.stopListening();
      expect(input.pendingCloses, 1);
      // The restart's re-initialize will fail.
      fake.initResult = false;
      for (int i = 0; i < 200 && engineLog.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(engineLog, <String>['restart_failed']);
      expect(input.pendingCloses, 0,
          reason: 'ledgers are cleared even on failure');
      expect(input.lastRestartSucceeded, isFalse);
      expect(input.isAvailable, isFalse);
      // Not wedged: a later initialize (the app's retry
      // path) recovers the input and listening works.
      fake.initResult = true;
      expect(await input.initialize(), isTrue);
      expect(await input.startListening(), isTrue);
      expect(input.isListening, isTrue);
      await input.stopListening();
      (fake.statusListener ?? fake.capturedOnStatus)!('notListening');
      expect(input.pendingCloses, 0);
    });
  });

  group('ASR error non-leak: raw platform strings never surface', () {
    test(
        'an errorMsg carrying a synthetic token and URL collapses '
        'to the unknown code on every surface', () async {
      final fake = FakeStt();
      final input = SystemVoiceInput(fake);
      addTearDown(input.dispose);
      await input.initialize();
      final List<String> entries = <String>[];
      final StreamSubscription<String> sub = input.errors.listen(entries.add);
      addTearDown(sub.cancel);
      fake.capturedOnError!(
        SpeechRecognitionError(
          'error_network token=test-token-not-real '
          'https://example.invalid/hook?k=test-token-not-real',
          true,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(entries, hasLength(1));
      // Exact-match whitelist: the junk-laden string is not a
      // known code, so only the unknown code survives.
      expect(entries.single, startsWith('error_unknown|'));
      expect(entries.single, isNot(contains('test-token')));
      expect(entries.single, isNot(contains('http')));
      expect(entries.single, isNot(contains('example.invalid')));
      expect(asrErrorText('error_unknown'), isNot(contains('http')));
      // OLD assertion (pre-PTT-2): isAvailable was false,
      // because the adapter trusted the error's permanent
      // flag (this delivery carried permanent=true). NEW
      // classification: the code collapsed to error_unknown,
      // which is RECOVERABLE by code -- availability must
      // SURVIVE even a permanent=true delivery.
      expect(input.isAvailable, isTrue);
    });
  });
}
