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
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../core/asr_errors.dart';
import '../core/voice_log.dart';
import '../core/voice_startup.dart';
import 'voice_io.dart';

/// Whether a flutter_tts platform call actually succeeded.
///
/// Evidence (flutter_tts 4.2.5, Android plugin source, read
/// directly): `setLanguage` answers `result.success(1)` only when
/// the locale was available AND set, `result.success(0)` otherwise;
/// `speak` with awaitSpeakCompletion completes via
/// `speakCompletion(1)` when the utterance finishes and
/// `speakCompletion(0)` on error; `stop` answers `success(1)`.
/// iOS answers booleans. So success is exactly `1` or `true`;
/// `0`, `false` or null mean the call did NOT do what it claims.
/// Treating an unexamined return value as success is how a device
/// without a Chinese voice -- or a rejected utterance -- got
/// reported as working speech.
bool ttsResultSucceeded(dynamic result) => result == 1 || result == true;

/// System TTS output. [initialize] must be called once before use;
/// it returns false (instead of throwing) when no TTS engine is
/// reachable, e.g. in a test harness or on web without a voice.
class SystemVoiceOutput implements VoiceOutput {
  // Created lazily inside initialize(): the FlutterTts constructor
  // touches the platform channel, which throws before the binding
  // exists (plain Dart test) and must be caught, not constructed here.
  FlutterTts? _tts;
  bool _available = false;
  bool _chineseVerified = false;
  String _detail = '未初始化';

  SystemVoiceOutput([FlutterTts? tts]) : _tts = tts;

  /// Whether a zh-CN voice was *verified* on this device during
  /// [initialize]. False until verification actually succeeded:
  /// unknown is never reported as verified.
  bool get chineseVoiceVerified => _chineseVerified;

  Future<void> _doInitialize(FlutterTts tts) async {
    await tts.awaitSpeakCompletion(true);
    // P0 zh-CN verification: an engine that answers is not proof
    // it can speak Chinese -- a missing zh-CN voice data set would
    // otherwise be silently reported as "zh-CN 已接入". Ask the
    // engine for its language list and resolve zh-CN from evidence;
    // fall back to the engine's own availability probe only when
    // the list cannot be read.
    String? chosen;
    try {
      final dynamic langs = await tts.getLanguages;
      if (langs is List) {
        chosen = resolveChineseTtsLocale(
          langs.map((Object? e) => e.toString()).toList(),
        );
      }
    } catch (_) {
      chosen = null;
    }
    if (chosen == null) {
      try {
        final dynamic avail = await tts.isLanguageAvailable('zh-CN');
        if (avail == true || avail == 1) chosen = 'zh-CN';
      } catch (_) {
        chosen = null;
      }
    }
    if (chosen != null) {
      // Validate the setLanguage RESULT (Codex re-test finding):
      // the plugin answers 1 only when the locale was available
      // and actually set. A 0 here means Chinese is NOT in effect
      // even though the language list advertised it -- verification
      // must fail closed.
      final dynamic langResult = await tts.setLanguage(chosen);
      _chineseVerified = ttsResultSucceeded(langResult);
    } else {
      _chineseVerified = false;
      // Best effort only; the status stays honest (see initialize)
      // and the startup plan will not rely on voice.
      await tts.setLanguage('zh-CN');
    }
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
      _detail = _chineseVerified
          ? '系统语音合成已接入（zh-CN 中文语音已核实并设置成功，语速 0.85）'
          : '系统语音合成引擎可用，但 zh-CN 中文语音未核实成功'
              '（语言列表缺少中文，或设置语言未成功），中文播报不可用，语音不可依赖';
      mingtuVoiceLog('语音合成初始化：引擎可用，中文语音已核实=$_chineseVerified');
      return true;
    } on TimeoutException {
      _available = false;
      _detail = 'NOT_CONFIGURED（系统语音合成不可用：超时未响应）';
      mingtuVoiceLog('语音合成初始化失败：超时未响应（引擎不可用或未安装中文语音）');
      return false;
    } catch (e) {
      _available = false;
      _detail = 'NOT_CONFIGURED（系统语音合成不可用：$e）';
      mingtuVoiceLog('语音合成初始化失败：平台调用异常');
      return false;
    }
  }

  @override
  bool get isAvailable => _available;

  @override
  String get status => _detail;

  /// Speak [text] and return when the engine reports completion.
  /// The platform RESULT is validated (Codex re-test finding):
  /// with awaitSpeakCompletion the plugin completes the future
  /// with 1 when the utterance actually finished and 0 on error,
  /// so a 0/false/null result is a failure -- it throws (after
  /// marking unavailable) instead of letting the caller treat the
  /// prompt as spoken. Callers must handle the failure as a real
  /// voice failure, never as simulated success.
  @override
  Future<void> speak(String text) async {
    final FlutterTts? tts = _tts;
    if (!_available || tts == null) return;
    try {
      final dynamic result = await tts.speak(text);
      if (!ttsResultSucceeded(result)) {
        throw StateError('系统语音合成返回失败（speak result=$result）');
      }
    } catch (e) {
      _available = false;
      _chineseVerified = false;
      _detail = 'NOT_CONFIGURED（系统语音合成失败：$e）';
      rethrow;
    }
  }

  /// Stop playback. Completion and failure are NOT swallowed
  /// (Codex re-test finding): a platform error propagates, and a
  /// non-success result throws, so the caller learns that the stop
  /// did not take effect instead of believing the speaker is quiet.
  Future<void> stop() async {
    final FlutterTts? tts = _tts;
    if (tts == null) return;
    final dynamic result = await tts.stop();
    if (!ttsResultSucceeded(result)) {
      throw StateError('停止语音播报未成功（stop result=$result）');
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
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();
  final StreamController<void> _sessionEndController =
      StreamController<void>.broadcast();
  bool _available = false;
  String _detail = '未初始化';
  bool _listening = false;

  SystemVoiceInput([stt.SpeechToText? speech]) : _speech = speech;

  /// Recognition errors, as they happen (Codex re-test finding).
  /// Before this, the platform onError callback only rewrote a
  /// status string nobody was watching, so a recogniser dying
  /// mid-session was silent and the turn-taking loop kept retrying
  /// into the failure. Listeners get one event per platform error
  /// ('<code>|permanent=<bool>') and are responsible for
  /// announcing it once and stopping the retry loop.
  Stream<String> get errors => _errorController.stream;

  /// Fires when a listening session that was actually running
  /// ends (silence timeout, final result, platform stop). The
  /// app's continuous-listen loop restarts from here; without
  /// it, a session that ended in silence left the microphone
  /// closed forever and voice control appeared dead.
  Stream<void> get sessionEnded => _sessionEndController.stream;

  void _emitSessionEnded() {
    if (!_sessionEndController.isClosed) {
      _sessionEndController.add(null);
    }
  }

  Future<bool> _doInitialize(stt.SpeechToText speech) async {
    return speech.initialize(
      onError: (SpeechRecognitionError error) {
        // Whitelist discipline: the raw platform error string
        // is normalised to a known code here and discarded;
        // only the code and its fixed Chinese text travel on.
        final String code = asrErrorCode(error.errorMsg);
        _detail = 'NOT_CONFIGURED（${asrErrorText(code)}）';
        if (error.permanent) {
          // A permanent error blocks recognition until resolved;
          // claiming availability afterwards would be a lie.
          _available = false;
          _listening = false;
        }
        if (!_errorController.isClosed) {
          _errorController.add(
            '$code|permanent=${error.permanent}',
          );
        }
      },
      onStatus: (String status) {
        if (status == 'done' || status == 'notListening') {
          final bool wasListening = _listening;
          _listening = false;
          if (wasListening) {
            mingtuVoiceLog('语音识别会话结束（status=$status）');
            _emitSessionEnded();
          }
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
      mingtuVoiceLog('语音识别初始化：可用=$ok');
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

  /// Stop listening. Like the TTS stop, errors are NOT swallowed:
  /// they propagate so the caller knows the microphone may still
  /// be open. [_listening] is cleared either way (finally), because
  /// after a stop attempt the session state is no longer trusted.
  Future<void> stopListening() async {
    try {
      await _speech?.stop();
    } finally {
      _listening = false;
    }
  }

  void dispose() {
    _controller.close();
    _errorController.close();
  }
}

/// Speak only AFTER the microphone is fully closed
/// (Codex re-test of 037f25c): the caller awaits this, so
/// [speak] cannot start while a recognition session is still
/// shutting down -- the previous fire-and-forget stop let
/// speech begin over an open microphone. A failed stop is
/// swallowed HERE (and logged by the caller via the input's
/// state) because speech must still happen; the recogniser
/// being slow to close must not silence a danger alert.
Future<void> speakAfterClosingMic({
  required SystemVoiceInput? input,
  required Future<void> Function() speak,
}) async {
  if (input != null && input.isListening) {
    try {
      await input.stopListening();
    } catch (_) {
      // The session state is untrusted after a failed stop;
      // the adapter has already marked it not-listening.
    }
  }
  await speak();
}
