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

import 'package:flutter/services.dart';
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
      _detail = 'NOT_CONFIGURED（系统语音合成不可用：平台调用异常）';
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
      _detail = 'NOT_CONFIGURED（系统语音合成失败：平台调用异常）';
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
/// Classify a recognition failure into the fixed ASR error
/// vocabulary WITHOUT retaining the raw exception text: only
/// a PlatformException's code is read (and it still passes
/// the exact-match whitelist in asr_errors.dart); every other
/// exception collapses to error_unknown. Raw platform strings
/// can embed tokens or URLs and must never reach the status,
/// the UI or the logs (Codex re-test of f951240).
String _asrFailureCode(Object e) {
  if (e is PlatformException) return asrErrorCode(e.code);
  return 'error_unknown';
}

class SystemVoiceInput implements VoiceInput {
  // Created lazily inside initialize(), for the same reason as
  // SystemVoiceOutput (see above).
  stt.SpeechToText? _speech;
  final StreamController<AsrResultEvent> _controller =
      StreamController<AsrResultEvent>.broadcast();
  final StreamController<AsrResultEvent> _partialController =
      StreamController<AsrResultEvent>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();
  final StreamController<AsrStatusEvent> _sessionEndController =
      StreamController<AsrStatusEvent>.broadcast();
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
  Stream<AsrStatusEvent> get sessionEnded => _sessionEndController.stream;

  /// The current listen generation: minted once per
  /// startListening() call. Consumers read the generation
  /// of the session they just started here and validate
  /// incoming events against it. The generation is adapter
  /// state (a plain counter), NOT something a result
  /// callback captures -- callbacks are validated against
  /// the live generation gate at event time (see _genOpen).
  int get currentSessionId => _generation;
  int get currentGeneration => _generation;

  int _generation = 0;

  /// The generation whose results are currently accepted,
  /// or 0 when no generation is open. Set when a listen
  /// actually starts; cleared the moment that session's
  /// stop/cancel is INITIATED -- from then on every
  /// callback of the old generation is ignored, however
  /// the plugin routes it (the plugin keeps ONE listener,
  /// so routing cannot distinguish generations; this gate
  /// can).
  int _genOpen = 0;

  /// Pass-through window, owned by the app layer: while
  /// true, results of the generation being stopped are
  /// still accepted. The push-to-talk stopping window
  /// needs exactly this: a final that belongs to the
  /// press and arrives while stop() is in flight (or in
  /// the grace right after) must be accepted and win over
  /// the cached partial -- an already-accepted Codex
  /// requirement. The app opens the window when a press
  /// release starts its stop and closes it when the press
  /// completes; a too-short press never opens it (its
  /// session is cancelled and void). Default false: every
  /// other stop/cancel closes the gate at initiation.
  bool acceptStoppingResults = false;

  bool _sessionOpen = false;
  bool _stopReturned = false;
  bool _closeStatusSeen = false;
  Completer<void>? _closeCompleter;

  /// True while a session is live or still closing; the
  /// app reads this to hold back a new press's prompt step
  /// until the previous session is fully closed.
  bool get sessionOpen => _sessionOpen;

  void _noteCloseProgress() {
    if (_sessionOpen && _stopReturned && _closeStatusSeen) {
      _sessionOpen = false;
      final Completer<void>? c = _closeCompleter;
      _closeCompleter = null;
      if (c != null && !c.isCompleted) c.complete();
    }
  }

  /// Wait until the previous session is fully closed,
  /// bounded at 800 ms (after the bound the caller may
  /// proceed; results arriving later still belong to the
  /// old closure and are validated by consumers).
  Future<void> awaitSessionClosed() async {
    if (!_sessionOpen) return;
    final Completer<void> c = _closeCompleter ??= Completer<void>();
    try {
      await c.future.timeout(const Duration(milliseconds: 800));
    } on TimeoutException {
      // Bounded wait elapsed: proceed; the platform may
      // still deliver the old session's tail, which the
      // old closure owns.
    }
  }

  void _emitSessionEnded(int sessionId, String status) {
    if (!_sessionEndController.isClosed) {
      _sessionEndController.add(AsrStatusEvent(sessionId, status));
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
          // Order matters (project-lead): FIRST record the
          // close progress for the serialization barrier;
          // THEN report the session end, stamped with the
          // generation snapshot taken NOW (no mutable
          // session-id field is read) and only if a session
          // was actually listening; the listening flag is
          // cleared LAST, never before the decision.
          _closeStatusSeen = true;
          _noteCloseProgress();
          final bool wasListening = _listening;
          if (wasListening) {
            mingtuVoiceLog('语音识别会话结束（status=$status）');
            _emitSessionEnded(_generation, status);
          }
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
      mingtuVoiceLog('语音识别初始化：可用=$ok');
      return ok;
    } on TimeoutException {
      _available = false;
      _detail = 'NOT_CONFIGURED（系统语音识别不可用：超时未响应）';
      return false;
    } catch (e) {
      _available = false;
      _detail = 'NOT_CONFIGURED（系统语音识别不可用：${asrErrorText(_asrFailureCode(e))}）';
      return false;
    }
  }

  @override
  bool get isAvailable => _available;

  @override
  String get status => _detail;

  @override
  Stream<AsrResultEvent> get transcripts => _controller.stream;

  bool get isListening => _listening;

  /// Partial (non-final) recognition results. The
  /// push-to-talk state machine caches the latest partial
  /// of a held press as its fallback text (used only when
  /// the session produced no final); automatic sessions
  /// ignore this stream entirely.
  Stream<AsrResultEvent> get partials => _partialController.stream;

  Future<bool> startListening() async {
    final stt.SpeechToText? speech = _speech;
    if (!_available || _listening || speech == null) return false;
    // Serialization: never overlap the previous session.
    await awaitSessionClosed();
    if (_listening) return false;
    // A new generation opens. The result closure stamps
    // events with it, but the stamp is informational only:
    // acceptance is decided at event time by the _genOpen
    // gate, because the plugin's single listener can route
    // an old session's late result through this closure.
    final int sessionId = ++_generation;
    _genOpen = sessionId;
    _sessionOpen = true;
    _stopReturned = false;
    _closeStatusSeen = false;
    _closeCompleter = null;
    try {
      await speech.listen(
        onResult: (SpeechRecognitionResult result) {
          if (result.recognizedWords.isEmpty) return;
          // Generation gate: once this generation's stop or
          // cancel has been initiated (_genOpen moved on or
          // closed), its callbacks are ignored entirely.
          if (_genOpen != sessionId && !acceptStoppingResults) return;
          if (result.finalResult) {
            _controller.add(AsrResultEvent(sessionId, result.recognizedWords));
          } else {
            _partialController.add(
                AsrResultEvent(sessionId, result.recognizedWords));
          }
        },
        listenOptions: stt.SpeechListenOptions(
          listenFor: const Duration(seconds: 10),
          pauseFor: const Duration(seconds: 3),
          localeId: 'zh_CN',
          partialResults: true,
          cancelOnError: true,
        ),
      );
      _listening = true;
      return true;
    } catch (e) {
      _sessionOpen = false;
      _detail = 'NOT_CONFIGURED（开始识别失败：${asrErrorText(_asrFailureCode(e))}）';
      return false;
    }
  }

  /// Stop listening. Like the TTS stop, errors are NOT swallowed:
  /// they propagate so the caller knows the microphone may still
  /// be open. [_listening] is cleared either way (finally), because
  /// after a stop attempt the session state is no longer trusted.
  Future<void> stopListening() async {
    // Close this generation's gate FIRST: from this moment
    // its results are ignored, even while the platform
    // stop is still in flight -- UNLESS the app opened the
    // stopping pass-through window for exactly this stop
    // (a push-to-talk release whose final may still be in
    // flight; see acceptStoppingResults).
    if (!acceptStoppingResults) _genOpen = 0;
    try {
      await _speech?.stop();
    } finally {
      _listening = false;
      _stopReturned = true;
      _noteCloseProgress();
    }
  }

  /// Cancel listening: the session is VOIDED, not stopped
  /// gracefully -- the platform discards its pending
  /// result. Used for a too-short push-to-talk press, whose
  /// session must never produce an executable result. Like
  /// stop(), cancel counts toward the full-close barrier.
  Future<void> cancelListening() async {
    _genOpen = 0;
    try {
      await _speech?.cancel();
    } finally {
      _listening = false;
      _stopReturned = true;
      _noteCloseProgress();
    }
  }

  void dispose() {
    _controller.close();
    _partialController.close();
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
