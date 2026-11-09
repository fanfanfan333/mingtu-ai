import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:mingtu_ai/adapters/system_voice_io.dart';
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
  bool initResult = true;
  Object? stopError;
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
    return initResult;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
    if (stopError != null) throw stopError!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FakeStt: ${invocation.memberName}');
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
    test('setLanguage returning 0 fails zh-CN verification closed',
        () async {
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

    test('speak returning 0 throws and marks the output unavailable',
        () async {
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

  group('SystemVoiceOutput stop semantics and the stop/speak race',
      () {
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

    test('stop issued while a speak is in flight reaches the engine '
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

    test('stop-then-confirm ordering: the confirmation speak is '
        'only submitted after stop COMPLETES (sequencer contract)',
        () async {
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

    test('an in-flight speak that then reports failure still fails '
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

    test('stopListening platform errors propagate, not swallowed',
        () async {
      final fake = FakeStt()..stopError = Exception('mic stuck');
      final input = SystemVoiceInput(fake);
      await input.initialize();
      await expectLater(input.stopListening(), throwsException);
      expect(input.isListening, isFalse);
    });
  });
}
