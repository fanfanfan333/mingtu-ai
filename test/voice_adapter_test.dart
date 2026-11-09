import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:mingtu_ai/adapters/system_voice_io.dart';
import 'package:mingtu_ai/adapters/voice_io.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
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
  int stopCalls = 0;

  @override
  Future<bool> initialize({
    stt.SpeechErrorListener? onError,
    stt.SpeechStatusListener? onStatus,
    dynamic debugLogging = false,
    Duration finalTimeout = const Duration(seconds: 2),
    List<stt.SpeechConfigOption>? options,
  }) async {
    capturedOnError = onError;
    capturedOnStatus = onStatus;
    return initResult;
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

    test('a permanent error marks the input unavailable', () async {
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
        'a listening session end is signalled on the sessionEnded '
        'stream (continuous-listen seam)', () async {
      final fake = FakeStt();
      final input = SystemVoiceInput(fake);
      expect(await input.initialize(), isTrue);
      final Future<void> ended = input.sessionEnded.first;
      expect(await input.startListening(), isTrue);
      expect(input.isListening, isTrue);
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
      await expectLater(input.stopListening(), throwsException);
      expect(input.isListening, isFalse);
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
      // The recorded order is the proof: speak ran strictly
      // AFTER the microphone stop completed.
      expect(order, <String>['stop-released', 'speak']);
      // And listening can resume afterwards.
      expect(await input.startListening(), isTrue);
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
    });
  });
  group('session id stamping (Codex re-test of 97e9c75)', () {
    test(
        'every result and status event carries its own '
        'session id, increasing across sessions', () async {
      final fake = FakeStt();
      final input = SystemVoiceInput(fake);
      addTearDown(input.dispose);
      expect(await input.initialize(), isTrue);

      final List<AsrResultEvent> finals = <AsrResultEvent>[];
      final List<AsrResultEvent> partials = <AsrResultEvent>[];
      final List<AsrStatusEvent> statuses = <AsrStatusEvent>[];
      final List<StreamSubscription<dynamic>> subs =
          <StreamSubscription<dynamic>>[
        input.transcripts.listen(finals.add),
        input.partials.listen(partials.add),
        input.sessionEnded.listen(statuses.add),
      ];
      addTearDown(() async {
        for (final StreamSubscription<dynamic> sub in subs) {
          await sub.cancel();
        }
      });

      SpeechRecognitionResult result(String words, bool isFinal) =>
          SpeechRecognitionResult(
            <SpeechRecognitionWords>[SpeechRecognitionWords(words, null, 0.9)],
            isFinal ? 2 : 0,
          );

      // Session 1.
      expect(await input.startListening(), isTrue);
      final int id1 = input.currentSessionId;
      expect(fake.resultListeners, hasLength(1));
      fake.resultListeners[0]!(result('第一句', false));
      fake.resultListeners[0]!(result('第一句完整', true));
      await Future<void>.delayed(Duration.zero);
      // The adapter emits sessionEnded from the platform
      // status callback only when it believes a session is
      // live; its stopListening() clears that flag locally
      // (the platform stop is fire-and-forget here), so the
      // end status must be delivered BEFORE the local stop
      // -- the same order a real engine produces (its done
      // status is what ends the session).
      fake.capturedOnStatus!('done');
      await Future<void>.delayed(Duration.zero);
      await input.stopListening();

      // Session 2.
      expect(await input.startListening(), isTrue);
      final int id2 = input.currentSessionId;
      expect(id2, greaterThan(id1));
      expect(fake.resultListeners, hasLength(2));
      fake.resultListeners[1]!(result('第二句', true));
      await Future<void>.delayed(Duration.zero);
      fake.capturedOnStatus!('done');
      await Future<void>.delayed(Duration.zero);
      await input.stopListening();

      // Every event of session 1 carries id1; every event
      // of session 2 carries id2 -- results (finals and
      // partials) and status alike.
      expect(partials.single.sessionId, id1);
      expect(partials.single.text, '第一句');
      expect(finals.map((AsrResultEvent e) => e.sessionId),
          <int>[id1, id2]);
      expect(finals.map((AsrResultEvent e) => e.text),
          <String>['第一句完整', '第二句']);
      expect(statuses.map((AsrStatusEvent e) => e.sessionId),
          <int>[id1, id2]);
      expect(statuses.map((AsrStatusEvent e) => e.status),
          <String>['done', 'done']);

      // A LATE result through session 1's still-reachable
      // closure (the recogniser delivering after stop, or
      // an in-flight platform callback) is stamped with
      // the OLD id: a consumer validating against the
      // current session id (id2, then id3 below) drops it
      // by construction. This is the direct evidence that
      // stale callbacks are identifiable -- and therefore
      // droppable -- rather than indistinguishable.
      fake.resultListeners[0]!(result('迟到的旧结果', true));
      await Future<void>.delayed(Duration.zero);
      expect(finals.last.sessionId, id1);
      expect(finals.last.text, '迟到的旧结果');
      expect(input.currentSessionId, id2);
      expect(
        finals.last.sessionId == input.currentSessionId,
        isFalse,
        reason: 'a stale event must fail the currency check',
      );

      // And the status stream follows the LIVE session:
      // after a third session starts, its end status
      // carries id3, so an old session's end can never be
      // mistaken for the current one's.
      expect(await input.startListening(), isTrue);
      final int id3 = input.currentSessionId;
      expect(id3, greaterThan(id2));
      fake.capturedOnStatus!('done');
      await Future<void>.delayed(Duration.zero);
      await input.stopListening();
      expect(statuses.last.sessionId, id3);
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
      expect(input.isAvailable, isFalse);
    });
  });
}
