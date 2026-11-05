/// System voice I/O for Mingtu AI (v0.6).
///
/// Real implementations of the [VoiceOutput] / [VoiceInput] contracts
/// in voice_io.dart, using the phone's own speech engines:
/// - output: `flutter_tts` (system TTS, zh-CN). The scheduler's text
///   is spoken here; the Flutter layer reports completion back to the
///   scheduler via [SpeechScheduler.completeActive] -- speech finishing
///   still never means the user's physical action finished.
/// - input: `speech_to_text` (system recogniser, zh-CN), short
///   commands only. Recognised text is fed to `parseVoiceCommand`,
///   never to a state setter. This is NOT continuous wake-word
///   listening: one listen session lasts at most 10 s and stops on
///   silence; the user taps (or a sighted helper taps) to listen again.
///
/// Availability is honest: every platform call is wrapped, and a
/// missing plugin / missing engine / denied permission leaves
/// [isAvailable] false and the status NOT_CONFIGURED instead of
/// crashing or faking speech. In the VM / flutter_test there is no
/// platform engine, so these classes report unavailable there and the
/// demo falls back to its simulated text prompts.
library;

import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'voice_io.dart';

/// System TTS output. [initialize] must be called once before use;
/// it returns false (instead of throwing) when no TTS engine is
/// reachable, e.g. in a test harness or on web without a voice.
class SystemVoiceOutput implements VoiceOutput {
  // Created lazily inside initialize(): the FlutterTts constructor
  // touches the platform channel, which throws before the binding
  // exists (plain Dart test) and must be caught, not constructed here.
  FlutterTts? _tts;
  bool _available = false;
  String _detail = '未初始化';

  SystemVoiceOutput([FlutterTts? tts]) : _tts = tts;

  Future<void> _doInitialize(FlutterTts tts) async {
    await tts.awaitSpeakCompletion(true);
    await tts.setLanguage('zh-CN');
    await tts.setSpeechRate(0.85);
    await tts.setVolume(1.0);
    await tts.setPitch(1.0);
  }

  Future<bool> initialize() async {
    try {
      final FlutterTts tts = _tts ??= FlutterTts();
      // A dead engine must not hang startup: a platform call that
      // never answers (test harness, missing engine) times out here
      // and is reported, instead of leaving the caller waiting.
      await _doInitialize(tts).timeout(const Duration(seconds: 3));
      _available = true;
      _detail = '系统语音合成已接入（zh-CN，语速 0.85）';
      return true;
    } on TimeoutException {
      _available = false;
      _detail = 'NOT_CONFIGURED（系统语音合成不可用：超时未响应）';
      return false;
    } catch (e) {
      _available = false;
      _detail = 'NOT_CONFIGURED（系统语音合成不可用：$e）';
      return false;
    }
  }

  @override
  bool get isAvailable => _available;

  @override
  String get status => _detail;

  /// Speak [text] and return when the engine reports completion.
  /// Throws (after marking unavailable) only if the engine fails;
  /// callers fall back to the simulated prompt in that case.
  @override
  Future<void> speak(String text) async {
    final FlutterTts? tts = _tts;
    if (!_available || tts == null) return;
    try {
      await tts.speak(text);
    } catch (e) {
      _available = false;
      _detail = 'NOT_CONFIGURED（系统语音合成失败：$e）';
      rethrow;
    }
  }

  Future<void> stop() async {
    try {
      await _tts?.stop();
    } catch (_) {
      // Stopping a dead engine is not an error worth surfacing.
    }
  }
}

/// System speech recognition input. [initialize] must be called once
/// before use. [startListening] opens one short session (max 10 s,
/// stops on ~3 s silence); final results are added to [transcripts].
/// Partial results are ignored so one utterance is parsed once.
class SystemVoiceInput implements VoiceInput {
  // Created lazily inside initialize(), for the same reason as
  // SystemVoiceOutput (see above).
  stt.SpeechToText? _speech;
  final StreamController<String> _controller =
      StreamController<String>.broadcast();
  bool _available = false;
  String _detail = '未初始化';
  bool _listening = false;

  SystemVoiceInput([stt.SpeechToText? speech]) : _speech = speech;

  Future<bool> _doInitialize(stt.SpeechToText speech) async {
    return speech.initialize(
      onError: (Object e) {
        _detail = 'NOT_CONFIGURED（系统语音识别出错：$e）';
      },
      onStatus: (String status) {
        if (status == 'done' || status == 'notListening') {
          _listening = false;
        }
      },
    );
  }

  Future<bool> initialize() async {
    try {
      final stt.SpeechToText speech = _speech ??= stt.SpeechToText();
      final bool ok =
          await _doInitialize(speech).timeout(const Duration(seconds: 3));
      _available = ok;
      _detail = ok
          ? '系统语音识别已接入（zh-CN，单次最长 10 秒，非持续监听）'
          : 'NOT_CONFIGURED（系统语音识别未授权或不可用）';
      return ok;
    } on TimeoutException {
      _available = false;
      _detail = 'NOT_CONFIGURED（系统语音识别不可用：超时未响应）';
      return false;
    } catch (e) {
      _available = false;
      _detail = 'NOT_CONFIGURED（系统语音识别不可用：$e）';
      return false;
    }
  }

  @override
  bool get isAvailable => _available;

  @override
  String get status => _detail;

  @override
  Stream<String> get transcripts => _controller.stream;

  bool get isListening => _listening;

  Future<bool> startListening() async {
    final stt.SpeechToText? speech = _speech;
    if (!_available || _listening || speech == null) return false;
    try {
      await speech.listen(
        onResult: (SpeechRecognitionResult result) {
          if (result.finalResult && result.recognizedWords.isNotEmpty) {
            _controller.add(result.recognizedWords);
          }
        },
        listenOptions: stt.SpeechListenOptions(
          listenFor: const Duration(seconds: 10),
          pauseFor: const Duration(seconds: 3),
          localeId: 'zh_CN',
          partialResults: false,
          cancelOnError: true,
        ),
      );
      _listening = true;
      return true;
    } catch (e) {
      _detail = 'NOT_CONFIGURED（开始识别失败：$e）';
      return false;
    }
  }

  Future<void> stopListening() async {
    try {
      await _speech?.stop();
    } catch (_) {
      // See SystemVoiceOutput.stop.
    }
    _listening = false;
  }

  void dispose() {
    _controller.close();
  }
}
