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
  /// Codes of transient recogniser outcomes that are NOT
  /// failures: a stop whose session produced no final
  /// match, a silence timeout. Real recognisers deliver
  /// these routinely at the end of a stopped session.
  /// Error codes that are routine session OUTCOMES, not
  /// engine failures: a session that ends without a match,
  /// or in silence. A recogniser reports these for
  /// ordinary sessions constantly (every silence-ended
  /// auto-listen, every stopped session with no final).
  /// They never travel on the error stream: the app's
  /// error handler disables its listening loop on ANY
  /// error it receives, so forwarding them would kill
  /// voice control on the first quiet session.
  static const Set<String> _benignCloseErrorCodes = <String>{
    'error_no_match',
    'error_speech_timeout',
  };
  // Created lazily inside initialize(), for the same reason as
  // SystemVoiceOutput (see above).
  stt.SpeechToText? _speech;
  final StreamController<AsrResultEvent> _controller =
      StreamController<AsrResultEvent>.broadcast();
  final StreamController<AsrResultEvent> _partialController =
      StreamController<AsrResultEvent>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();
  final StreamController<String> _noMatchController =
      StreamController<String>.broadcast();
  final StreamController<AsrStatusEvent> _sessionEndController =
      StreamController<AsrStatusEvent>.broadcast();
  final StreamController<String> _engineController =
      StreamController<String>.broadcast();
  bool _available = false;
  String _detail = '未初始化';
  bool _listening = false;


  SystemVoiceInput([stt.SpeechToText? speech]) : _speech = speech;

  /// Test-only override of the close-watchdog ladder
  /// durations: [prod] is the time an unconfirmed close
  /// is left alone before the watchdog prods the engine
  /// with one cancel (production 3 s); [restart] is the
  /// cap on that prod cancel's future -- once it elapses
  /// (or the cancel settles sooner) the engine restart
  /// runs unconditionally (production 1 s). Tests set
  /// this to short real durations so the watchdog
  /// scenarios run quickly AND deterministically
  /// (polling assertions below, never a single fixed
  /// sleep that must land inside a window).
  ({Duration prod, Duration restart})? debugWatchdogLadder;

  /// Recognition errors, as they happen (Codex re-test finding).
  /// Before this, the platform onError callback only rewrote a
  /// status string nobody was watching, so a recogniser dying
  /// mid-session was silent and the turn-taking loop kept retrying
  /// into the failure. Listeners get one event per platform error
  /// ('<code>|permanent=<bool>') and are responsible for
  /// announcing it once and stopping the retry loop.
  ///
  /// CDX1: the payload's permanent field is the PLUGIN's raw
  /// flag, carried for diagnostics only -- speech_to_text
  /// 7.5.0's Android side reports permanent=true for every
  /// error. NO availability or retry decision (here or in
  /// the app) may use it; classification is by error code
  /// (see isFatalAsrError / isRecoverableAsrError).
  Stream<String> get errors => _errorController.stream;

  /// Session-outcome notices for the benign close codes
  /// (error_no_match / error_speech_timeout). These are NOT
  /// errors and never travel on [errors]; but the
  /// press-and-hold completion needs to KNOW a stopped
  /// session settled with no match -- on the Xiaomi engine
  /// that outcome arrives ~1.4 s AFTER the release stop --
  /// so the app can settle the press with its cached partial
  /// (or the no-content notice) at the right moment instead
  /// of waiting out the full window. Events carry the code
  /// only; no permanent flag, no retry semantics.
  Stream<String> get sessionNoMatch => _noMatchController.stream;

  /// Fires when a listening session that was actually running
  /// ends on its own (silence timeout, final result). Status
  /// events NEVER start a new session: recognition opens only
  /// from an explicit press (press-and-hold only since the
  /// real-device fix round removed every automatic listen).
  Stream<AsrStatusEvent> get sessionEnded => _sessionEndController.stream;

  /// Set by the owner when this input is being torn
  /// down: a disposed input must not restart its engine
  /// (its streams are closed; the restart would leak
  /// timers past the owner's lifetime). The adapter's own
  /// dispose() also sets it, but owners that merely drop
  /// the input (a widget State being disposed while the
  /// input object itself is never disposed) must set it
  /// too.
  bool engineDisposed = false;

  /// The engine object registrations were made against,
  /// or null when no engine object exists yet (the real
  /// plugin path constructs it lazily in [initialize]).
  /// Exposed so tests can tell an in-place re-initialize
  /// of an injected recogniser apart from a fresh engine.
  Object? get engineInstanceForTest => _engineSpeech;

  /// Test-only seam (app-level widget tests): replace the
  /// recogniser object this adapter drives, so a fake can
  /// deliver errors/results through the adapter's REAL
  /// onError/onStatus path into the app. Widget tests need
  /// this because the platform channel's plugin object
  /// belongs to the first app instance in the process --
  /// its captured listeners point at a stale adapter, so
  /// channel delivery cannot reach the live app's adapter.
  /// Production code never calls this.
  void debugAttachSpeechForTest(stt.SpeechToText speech) {
    _speech = speech;
    _engineSpeech = speech;
    _engineIsPluginInstance = false;
  }

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

  // --- Unconfirmed-close bookkeeping (this round) ---
  //
  // Platform results and statuses carry NO session
  // identity, so the adapter never GUESSES one from a
  // timeout. Instead it counts unconfirmed closes:
  // every stop()/cancel() the app initiates opens one
  // pending close; the session-closing platform status
  // (notListening/done) consumes exactly one. While the
  // count is above zero, NO new listen may start, a
  // closing status is consumed silently (it never ends
  // -- or is mistaken for -- any live session), and
  // results still arrive under the OLD session's own
  // closure and id. Only when the count reaches zero
  // again is a session allowed to open.
  int _pendingCloses = 0;

  /// How many initiated stops/cancels still await their
  /// closing platform status.
  int get pendingCloses => _pendingCloses;

  Completer<void>? _closeCompleter;

  /// True while any initiated stop/cancel still awaits
  /// its closing status; the app reads this to hold back
  /// a new press's prompt step until the previous
  /// session is confirmed closed. Kept from the previous
  /// round under its old meaning: "a session is still
  /// closing", now carried by the pending-close count.
  bool get sessionOpen => _pendingCloses > 0;

  /// Engine-generation events. 'restarted': the watchdog
  /// force-restarted the recognition engine because
  /// unconfirmed closes never resolved, and every
  /// pre-restart session is void. 'restart_failed': the
  /// restart's platform re-initialize FAILED -- the
  /// ledgers were still cleared (nothing stays wedged),
  /// but recognition is unavailable until a later start
  /// attempt succeeds again.
  Stream<String> get engineEvents => _engineController.stream;

  /// Outcome of the most recent watchdog restart's
  /// platform re-initialize (true also before any
  /// restart). The app reads this when it detects a
  /// restart only via the epoch bump -- the live event
  /// was missed -- so a FAILED restart replays the
  /// failure handling, never the success notice.
  bool get lastRestartSucceeded => _lastRestartSucceeded;
  bool _lastRestartSucceeded = true;

  /// The plugin's platform channel, invoked DIRECTLY by
  /// a watchdog restart: the plugin's Dart-side
  /// initialize() latches after its first success and
  /// never reaches the platform again, so a restart that
  /// must really re-initialize the platform issues the
  /// call itself (the platform-side initialize has no
  /// latch; the plugin's channel handler and its Dart
  /// callback registrations stay in place).
  static const MethodChannel _pluginChannel =
      MethodChannel('plugin.csdcorp.com/speech_to_text');

  /// An in-flight session-open attempt, abortable by an
  /// engine restart. See startListening for the
  /// generation-handoff race this exists for.
  Completer<void>? _startBarrier;

  // --- Stale-status defence (the close ledgers) ---
  //
  // The plugin keeps ONE result listener and ONE status
  // listener, so a platform event carries no session
  // identity. The adapter therefore never guesses WHICH
  // session an event belongs to from its text or its
  // timing (an earlier round's text-equality / 300 ms
  // first-result gate misjudged genuine fast finals and
  // repeated utterances, and is REMOVED): results are
  // accepted as the live session's own unless their
  // generation was voided (the _genOpen / epoch gates),
  // and cross-session safety comes from ORDER instead --
  // a session is settled only once its final has arrived
  // or its cancel has been CONFIRMED closed, and no new
  // listen opens while a close is unconfirmed
  // (_pendingCloses). What remains here is the status
  // side: _statusesOwed records, per stop/cancel, the
  // closing status still owed by that close; an arriving
  // done/notListening first repays one such debt and is
  // consumed as that OLD close -- it never ends the live
  // session. A session's natural end owes no debt: its
  // own stop was never called, so by then every earlier
  // debt has been repaid by an earlier status (each
  // close's status arrives before the next session can
  // open, because the pending-close barrier forbids
  // opening one earlier).

  /// Pending closes whose count was consumed by the
  /// closing session's terminal ERROR rather than by its
  /// closing status. The plugin forwards a stopped
  /// session's status AFTER its error, so those statuses
  /// still arrive -- and every one of them belongs to the
  /// error-closed session, not to any live successor.
  /// Rule B's stale-status consumption checks this
  /// alongside the stop/cancel debt.
  int _closeErrorConsumed = 0;

  /// Whether the LIVE session's listen() call is still
  /// being issued (its platform open has not settled).
  /// Statuses arriving inside this window belong to an
  /// EARLIER session's tail by construction -- a session
  /// cannot produce its own closing status before its
  /// open has even completed -- so rule B consumes one
  /// debt for them even when the count bookkeeping
  /// momentarily disagrees (see startListening).
  bool _sessionOpening = false;

  /// Statuses still owed to the adapter by sessions it
  /// stopped or cancelled (rule B, final form). The
  /// plugin's stop() forwards a stopped session's
  /// terminal result itself (its final-result timer
  /// re-delivers the last result as the session's final)
  /// and the 'done' status that would follow is delivered
  /// by the plugin as a FINAL result, never as a status --
  /// but that absorption only happens when a result is
  /// still FRESH at the moment of the stop (the plugin's
  /// listen/pause timers watch the last speech event; a
  /// result that arrived during active listening long
  /// before the stop no longer has a status conversion
  /// pending, and the session's own notListening still
  /// arrives as a status). So a stop counts one owed
  /// status UNLESS the session's last accepted result
  /// arrived during THIS stop's own call (the fresh-
  /// result case, e.g. speakAfterClosingMic stopping a
  /// session whose result just landed); a cancel always
  /// counts one (it never forwards a result). When this
  /// count is positive, an arriving done/notListening is
  /// consumed as an old close: it can only belong to one
  /// of those owed closes (the live session's own
  /// natural-end status cannot be owed to a stop that has
  /// not happened), so it never ends the live session.
  /// Decided from adapter-observable facts only, never
  /// from a clock.
  int _statusesOwed = 0;

  /// Set by the result path when a result is accepted;
  /// cleared at the START of every stop/cancel. A stop
  /// that begins after the flag was set (see
  /// [_statusesOwed]) treats the result as already
  /// delivered history, not as a just-landed terminal
  /// result.
  bool _resultArrivedSinceStopBegan = false;

  /// The engine generation (epoch): minted at 0 and
  /// bumped by every watchdog restart. Every engine
  /// callback registration captures the epoch it was
  /// registered under; a callback whose epoch is not the
  /// current one is dropped at entry -- belt and braces
  /// on top of the plugin's single-listener replacement.
  int get engineEpoch => _engineEpoch;
  int _engineEpoch = 0;

  /// The engine instance registrations were made against.
  /// After a watchdog restart this is a FRESH instance,
  /// so the forced re-initialize reaches the platform
  /// instead of short-circuiting inside the singleton.
  stt.SpeechToText? _engineSpeech;

  /// Whether the current engine object is one this
  /// adapter constructed itself (a real plugin instance)
  /// rather than an injected recogniser. Only a
  /// self-constructed engine is replaced by a fresh
  /// instance on restart; an injected recogniser is
  /// re-initialized in place.
  bool _engineIsPluginInstance = false;

  Timer? _engineWatchdog;
  Timer? _engineRetryTimer;
  bool _engineRestarting = false;

  /// Record close progress: one closing status consumes
  /// one pending close. Callers guarantee the count is
  /// above zero. When the last close lands, every waiter
  /// on [awaitSessionClosed] wakes.
  void _consumePendingClose() {
    if (_pendingCloses > 0) _pendingCloses--;
    if (_pendingCloses == 0) {
      // Every close is confirmed: the watchdog ladder is
      // stood down. Without this the 3 s timer would fire
      // on a LATER session's pending close and restart
      // the engine under a healthy flow.
      _engineWatchdog?.cancel();
      _engineWatchdog = null;
      _engineRetryTimer?.cancel();
      _engineRetryTimer = null;
      final Completer<void>? c = _closeCompleter;
      _closeCompleter = null;
      if (c != null && !c.isCompleted) c.complete();
    }
  }

  /// Wait until every initiated close is confirmed by a
  /// platform status -- with NO timeout release: an
  /// unconfirmed close never opens a new session. The
  /// only ways out are the closing status itself or the
  /// watchdog restart (which also completes the wait).
  Future<void> awaitSessionClosed() async {
    if (_pendingCloses == 0) return;
    final Completer<void> c = _closeCompleter ??= Completer<void>();
    await c.future;
  }

  /// Drive a pending close to its confirmation and wait
  /// for it. A stopped recogniser's terminal outcome is
  /// reported to the status listener the plugin registered
  /// at initialize() time; re-registering the CURRENT
  /// epoch's listeners through a fresh initialize cycle
  /// makes the plugin deliver the recogniser's actual
  /// current status to them (its status listener is
  /// invoked with the last known status on registration),
  /// which is the closing outcome this close is waiting
  /// for. This is NOT a timeout release: nothing proceeds
  /// until the closing outcome has actually been consumed
  /// and the count reaches zero (or the watchdog restart
  /// resolves the wait). Used by the app when IT initiated
  /// the close and now needs the microphone for a new
  /// session.
  Future<void> confirmSessionClose() async {
    if (_pendingCloses == 0) return;
    final stt.SpeechToText? speech = _speech;
    if (speech != null) {
      try {
        await _doInitialize(speech);
      } catch (_) {
        // A failed re-registration changes nothing: the
        // wait below still requires the real confirmation.
      }
    }
    await awaitSessionClosed();
  }

  /// The close watchdog (escalation ladder): while any
  /// close is unconfirmed, at 3 s the engine is prodded
  /// with ONE cancel whose future is capped at 1 s; the
  /// engine is then force-restarted UNCONDITIONALLY --
  /// a cancel future that never completes (a wedged
  /// platform) can no longer stall the ladder forever.
  /// Real-time timers: the deadline is wall-clock, not
  /// frame time.
  void _armCloseWatchdog() {
    _engineWatchdog?.cancel();
    _engineWatchdog =
        Timer(debugWatchdogLadder?.prod ?? const Duration(seconds: 3), () {
      if (_pendingCloses == 0 || _engineRestarting) return;
      if (engineDisposed) return;
      unawaited(_watchdogCancelStep());
    });
  }

  Future<void> _watchdogCancelStep() async {
    try {
      // A prod, NOT a new session close: it must not
      // raise the pending-close count, or the count could
      // never reach zero through it. The prod's future
      // is CAPPED: a platform whose cancel() never
      // completes must not stall the ladder -- on
      // timeout (or error) the restart below still runs.
      await _speech
          ?.cancel()
          .timeout(debugWatchdogLadder?.restart ??
              const Duration(seconds: 1));
    } catch (_) {
      // A failed or timed-out prod does not change the
      // ladder: the restart step below still runs.
    }
    if (_pendingCloses == 0 || _engineRestarting) return;
    if (engineDisposed) return;
    // No second waiting step: the restart follows the
    // (capped) prod immediately, so from the prod's
    // issue the restart is reached within the cap.
    unawaited(_restartEngine());
  }

  /// Force-restart the recognition engine: the current
  /// generation is voided, registrations are re-made
  /// under a bumped epoch with NEW onStatus/onError
  /// closures (the epoch guard drops any callback of the
  /// old registration), every close ledger is cleared,
  /// and the platform is REALLY re-initialized: for a
  /// plugin engine the initialize call is issued
  /// directly on the plugin channel, because the
  /// plugin's Dart-side initialize() latches after its
  /// first success and would never reach the platform
  /// again. The app is notified via [engineEvents]:
  /// 'restarted' when the re-initialize succeeded,
  /// 'restart_failed' when it failed -- the ledgers are
  /// cleared either way, so no wait can wedge and the
  /// next press retries through the normal start path.
  Future<void> _restartEngine() async {
    if (_engineRestarting) return;
    _engineRestarting = true;
    // A restart must never run under a disposed input:
    // after dispose the streams are closed and the
    // restart's own one-second retry timer would leak
    // past the owner's lifetime (in tests: a pending-
    // timer failure at tree teardown).
    if (_engineController.isClosed || engineDisposed) {
      _engineRestarting = false;
      return;
    }
    // Release any in-flight session-open attempt FIRST:
    // it belongs to the engine generation being replaced,
    // and the re-initialize below would otherwise consume
    // the plugin's one-shot initialize latch while the
    // attempt still waits for its listen() to be issued.
    final Completer<void>? early = _startBarrier;
    _startBarrier = null;
    if (early != null && !early.isCompleted) early.complete();
    _engineWatchdog?.cancel();
    _engineWatchdog = null;
    _engineRetryTimer?.cancel();
    _engineRetryTimer = null;
    final int epoch = ++_engineEpoch;
    // A fresh instance UNLESS the current engine object
    // was injected (tests inject a fake recogniser): an
    // injected engine is re-initialized in place, which
    // re-registers its listeners under the new epoch and
    // is exactly the observable restart contract.
    // Yield once first: the in-flight attempt released
    // above resolves its listen race on this turn and its
    // post-listen bookkeeping (which still belongs to the
    // OLD epoch) settles BEFORE this restart's state
    // writes below -- otherwise the attempt's tail could
    // clear this restart's _listening or re-stamp its
    // generation gate after the restart finished.
    await Future<void>.delayed(Duration.zero);
    final bool pluginEngine = _engineIsPluginInstance;
    final stt.SpeechToText fresh =
        identical(_speech, _engineSpeech) && _engineIsPluginInstance
            ? stt.SpeechToText()
            : _speech!;
    _speech = fresh;
    _engineSpeech = fresh;
    _engineIsPluginInstance = true;
    bool ok = false;
    try {
      ok = await _doInitialize(fresh, epoch, pluginEngine)
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      ok = false;
    }
    _lastRestartSucceeded = ok;
    _available = ok;
    _listening = false;
    _genOpen = 0;
    _pendingCloses = 0;
    _closeErrorConsumed = 0;
    _statusesOwed = 0;
    _resultArrivedSinceStopBegan = false;
    _sessionOpening = false;
    _engineRestarting = false;
    _detail = ok
        ? '系统语音识别已接入（引擎已重启，zh-CN，单次最长 10 秒，非持续监听）'
        : 'NOT_CONFIGURED（语音引擎重启后仍不可用）';
    mingtuVoiceLog('语音引擎已强制重启（epoch=$epoch）：旧会话全部作废');
    final Completer<void>? c = _closeCompleter;
    _closeCompleter = null;
    if (c != null && !c.isCompleted) c.complete();
    if (!_engineController.isClosed) {
      _engineController.add(ok ? 'restarted' : 'restart_failed');
    }
  }

  void _emitSessionEnded(int sessionId, String status) {
    if (!_sessionEndController.isClosed) {
      _sessionEndController.add(AsrStatusEvent(sessionId, status));
    }
  }

  Future<bool> _doInitialize(stt.SpeechToText speech,
      [int epoch = -1, bool forcePlatformInitialize = false]) async {
    final int regEpoch = epoch < 0 ? _engineEpoch : epoch;
    void onError(SpeechRecognitionError error) {
        // Stale registration: a registration made before
        // an engine restart must never act. (The plugin
        // replaces its single listener on re-initialize,
        // so this is the application-level guarantee.)
        if (regEpoch != _engineEpoch) return;
        // Whitelist discipline: the raw platform error string
        // is normalised to a known code here and discarded;
        // only the code and its fixed Chinese text travel on.
        final String code = asrErrorCode(error.errorMsg);
        _detail = 'NOT_CONFIGURED（${asrErrorText(code)}）';
        // Availability is decided BY ERROR CODE, never by
        // error.permanent (CDX1): speech_to_text 7.5.0's
        // Android sendError passes permanent=true for EVERY
        // error, so trusting the flag permanently disabled
        // recognition after a routine busy / client /
        // speech-timeout / no-match -- the Xiaomi failure.
        // Only FATAL codes (the engine itself cannot serve:
        // its own permission missing, no recogniser service,
        // no Chinese support) mark the input unavailable;
        // recoverable codes and unknown end this session
        // only, and the next press listens again.
        if (isFatalAsrError(code)) {
          _available = false;
          _listening = false;
        }
        if (_pendingCloses > 0) {
          // The error belongs to a session that is already
          // closing: it consumes that session's pending
          // close exactly like a closing status would, so
          // the unconfirmed-close count cannot wedge on an
          // errored session. What must never happen here
          // is a sessionEnded side effect for the closing
          // session. The consumption is matched by
          // _closeErrorConsumed: the SAME close's closing
          // status, arriving later, is then consumed as
          // stale (rule B) -- never as a natural end of
          // whatever session is live by then.
          _consumePendingClose();
          _closeErrorConsumed++;
          if (_benignCloseErrorCodes.contains(code)) {
            // Consumed as the close -- and reported as this
            // session's no-match OUTCOME on its own stream,
            // so a press settling in its stopping window
            // learns the session ended without a final
            // (the Xiaomi engine delivers exactly this,
            // late). It is still not an error.
            if (!_noMatchController.isClosed) {
              _noMatchController.add(code);
            }
            return;
          }
        }
        if (_benignCloseErrorCodes.contains(code)) {
          // A routine outcome, not a failure (see
          // _benignCloseErrorCodes): the session simply
          // ended without speech. Reported as an outcome on
          // [sessionNoMatch] (a held press settles with its
          // cached partial at release); never an error, and
          // no status event may start a new session.
          if (!_noMatchController.isClosed) {
            _noMatchController.add(code);
          }
          return;
        }
        if (!_errorController.isClosed) {
          _errorController.add(
            '$code|permanent=${error.permanent}',
          );
        }
    }

    void onStatus(String status) {
        if (regEpoch != _engineEpoch) return;
        if (status == 'done' || status == 'notListening') {
          if (_statusesOwed > 0 ||
              _closeErrorConsumed > 0 ||
              _sessionOpening) {
            // This status belongs to an OLD close, and
            // it repays ONE ledger only -- never two
            // (letting one status settle two accounts
            // would spend the LATE status's repayment
            // early and leave a genuinely late old status
            // with nothing to repay, free to fall into
            // the natural-end branch and end the live
            // session). Which account: the error marker
            // first (that close's own status, following
            // its error); else, while a close is still
            // unconfirmed, THIS close's confirmation (the
            // owed entry then survives for the same
            // session's genuinely late duplicate status);
            // else the owed debt itself (a late status
            // with no close outstanding). Consumed here,
            // a status NEVER ends the live session, never
            // clears _listening and never emits
            // sessionEnded for it.
            if (_closeErrorConsumed > 0) {
              _closeErrorConsumed--;
            } else if (_pendingCloses > 0) {
              _consumePendingClose();
            } else if (_statusesOwed > 0) {
              _statusesOwed--;
            }
            return;
          }
          if (_pendingCloses > 0) {
            // A close the app initiated is still
            // unconfirmed: this status CONFIRMS it. It is
            // consumed by the closing session ONLY -- it
            // never ends a live session, is never stamped
            // with a live session's id, and never reaches
            // the sessionEnded stream. (Previously this
            // status could be attributed to whatever
            // session happened to be live when it landed.)
            _consumePendingClose();
            return;
          }
          // No close is pending: a session ended on its
          // own (silence timeout, final result). Report
          // the end, stamped with the generation snapshot
          // taken NOW (no mutable session-id field is
          // read) and only if a session was actually
          // listening; the listening flag is cleared
          // LAST, never before the decision.
          final bool wasListening = _listening;
          if (wasListening) {
            mingtuVoiceLog('语音识别会话结束（status=$status）');
            _emitSessionEnded(_generation, status);
          }
          _listening = false;
        }
    }

    bool ok =
        await speech.initialize(onError: onError, onStatus: onStatus);
    // The plugin's initialize() is a one-shot latch: once
    // it has succeeded it returns the cached result and
    // does NOT re-register the listeners it was passed.
    // Left to the latch, a later registration -- a watchdog
    // restart's new epoch, or a fresh adapter instance --
    // would never receive a single status or error, and
    // every pending close would wedge until the watchdog
    // fired. The listener fields are public, so register
    // the SAME closures directly as well: whatever the
    // latch did, the plugin's single listener now points
    // at THIS registration, and any older registration is
    // replaced (its epoch guard would reject it anyway).
    // Best effort: a recogniser double that rejects the
    // assignment keeps the listeners it captured from
    // initialize() above, and initialization must not
    // fail over it.
    try {
      speech.errorListener = onError;
      speech.statusListener = onStatus;
    } catch (_) {
      // See the note above.
    }
    if (forcePlatformInitialize) {
      // Watchdog restart only: the initialize() above
      // latched and never reached the platform (the
      // plugin returns its cached success), so issue the
      // platform initialize DIRECTLY on the channel --
      // with the same arguments the plugin itself sends.
      // The platform-side initialize has no latch: it
      // re-runs and re-binds the channel callback
      // handler, while the Dart-side registrations made
      // just above (the plugin's platform callbacks and
      // the public listener fields) keep pointing at
      // THIS epoch's closures. The channel result is the
      // restart's real outcome: a platform that does not
      // answer true has NOT been re-initialized.
      try {
        final bool? platformOk =
            await _pluginChannel.invokeMethod<bool>(
          'initialize',
          <String, Object>{'debugLogging': false},
        );
        ok = platformOk ?? false;
      } catch (_) {
        ok = false;
      }
    }
    return ok;
  }

  Future<bool> initialize() async {
    try {
      final bool constructed = _speech == null;
      final stt.SpeechToText speech = _speech ??= stt.SpeechToText();
      _engineSpeech = speech;
      if (constructed) _engineIsPluginInstance = true;
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
    // Unconfirmed-close rule: a new session may open
    // ONLY once every initiated close has been confirmed
    // by its closing status. The wait has NO timeout
    // release: guessing from a clock is exactly how an
    // old session's tail got attributed to a new one. If
    // the closes never confirm, the watchdog restart
    // resolves the wait instead.
    await awaitSessionClosed();
    if (_listening || _engineRestarting) return false;
    if (!identical(speech, _engineSpeech)) return false;
    // A new generation opens. The result closure stamps
    // events with it, but the stamp is informational only:
    // acceptance is decided at event time by the _genOpen
    // gate, because the plugin's single listener can route
    // an old session's late result through this closure.
    final int sessionId = ++_generation;
    final int epoch = _engineEpoch;
    // Generation-handoff race: if a restart bumps the
    // epoch while this attempt's platform listen is in
    // flight, the resting plugin instance's _initWorked
    // latch is already consumed by the restart's
    // re-initialize, so THIS attempt's initialize() call
    // short-circuits and its listen() never runs. The
    // attempt must fail closed in that case, not hang.
    final Completer<void> barrier = Completer<void>();
    _startBarrier = barrier;
    _genOpen = sessionId;
    // Mark listening BEFORE the platform call: the
    // session counts as live from the moment its open is
    // issued, so a stop/cancel that lands while the start
    // is still in flight (the push-to-talk starting
    // window) is a REAL close of this session -- it opens
    // its pending close and calls the platform -- rather
    // than a no-op that would leave the engine listening
    // with nobody tracking it.
    _listening = true;
    _sessionOpening = true;
    // This session's listen options, shared by the
    // platform call below.
    final stt.SpeechListenOptions listenOptions =
        stt.SpeechListenOptions(
      // Hold-to-talk tuning (MT-1111-PTT-D): listenFor is
      // 30 s -- comfortably above the hold cap (the TalkBack
      // long-press auto-end is 10 s and a physical hold is
      // in that order), so the plugin never cuts a held
      // press off, yet never unbounded. pauseFor stays
      // 3 s: the plugin auto-stops after that much silence,
      // which in the hold flow is only a backstop -- the
      // user's release stop() is the primary end.
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 3),
      localeId: 'zh_CN',
      partialResults: true,
      cancelOnError: true,
    );
    try {
      await Future.any(<Future<void>>[
        speech.listen(
        onResult: (SpeechRecognitionResult result) {
          // A result from before an engine restart belongs
          // to a dead engine generation: dropped at entry.
          if (epoch != _engineEpoch) return;
          if (result.recognizedWords.isEmpty) return;
          // Generation gate: once this generation's stop or
          // cancel has been initiated (_genOpen moved on or
          // closed), its callbacks are ignored entirely.
          if (_genOpen != sessionId && !acceptStoppingResults) return;
          final String words = result.recognizedWords;
          // No content or timing guesses (the text-
          // equality / 300 ms first-result gate is
          // REMOVED): a result that reaches this closure
          // under a live generation IS this session's
          // result. Cross-session residue is prevented
          // by ORDER, not by judging results: the app
          // settles a session (its final received, or
          // its cancel confirmed closed) before any new
          // listen may open, and voided generations are
          // already rejected by the gate above.
          _resultArrivedSinceStopBegan = true;
          if (result.finalResult) {
            _controller.add(AsrResultEvent(sessionId, words));
          } else {
            _partialController.add(AsrResultEvent(sessionId, words));
          }
        },
        listenOptions: listenOptions,
        ),
        barrier.future,
      ]);
      if (identical(_startBarrier, barrier)) _startBarrier = null;
      if (epoch != _engineEpoch) {
        // The engine restarted under this attempt: the
        // session never really opened. Do NOT touch
        // adapter state here: the restart's own writes
        // own the new epoch now, and this attempt's tail
        // must not clear them (its _listening/_genOpen
        // writes would land after the restart's). The one
        // exception is this attempt's own opening flag:
        // the restart already reset it, and leaving the
        // local attempt believing otherwise changes
        // nothing outside this dead attempt.
        return false;
      }
      _listening = true;
      _sessionOpening = false;
      return true;
    } catch (e) {
      if (_genOpen == sessionId) _genOpen = 0;
      _listening = false;
      _sessionOpening = false;
      _detail = 'NOT_CONFIGURED（开始识别失败：${asrErrorText(_asrFailureCode(e))}）';
      return false;
    }
  }

  /// Stop listening. Like the TTS stop, errors are NOT swallowed:
  /// they propagate so the caller knows the microphone may still
  /// be open. [_listening] is cleared either way (finally), because
  /// after a stop attempt the session state is no longer trusted.
  ///
  /// A stop with NO live session is a no-op: it does NOT
  /// open a pending close. Speech paths call stop()
  /// defensively before speaking; if every such call
  /// opened a pending close, the count would be charged
  /// for sessions that never existed and the next listen
  /// would wait for closing statuses nobody will send.
  /// Exactly one pending close is opened per session that
  /// was actually live, at its first stop/cancel.
  Future<void> stopListening() async {
    // The freshness window for _statusesOwed starts NOW:
    // a result accepted from this moment on (while the
    // platform stop is in flight) is the just-landed
    // terminal-result case; anything accepted earlier is
    // history.
    _resultArrivedSinceStopBegan = false;
    if (!_listening) return;
    // Close this generation's gate FIRST: from this moment
    // its results are ignored, even while the platform
    // stop is still in flight -- UNLESS the app opened the
    // stopping pass-through window for exactly this stop
    // (a push-to-talk release whose final may still be in
    // flight; see acceptStoppingResults).
    if (!acceptStoppingResults) _genOpen = 0;
    // This stop opens one unconfirmed close: until the
    // platform's closing status lands, no new session may
    // open and the status belongs to THIS session only.
    // Its owed-status record (below, rule B) covers the
    // closing status this stop owes: should a FURTHER
    // status of this session land LATE -- after a
    // successor session has already opened -- it is
    // consumed as THIS session's close, never as the
    // successor's end.
    _pendingCloses++;
    // Record whether this close still owes a status
    // (see _statusesOwed): only a result that arrived
    // DURING this stop's own call absorbs the closing
    // status (the plugin converts it to a final result
    // instead); every other stopped session still owes
    // its notListening.
    if (!_resultArrivedSinceStopBegan) _statusesOwed++;
    _armCloseWatchdog();
    try {
      await _speech?.stop();
    } finally {
      _listening = false;
    }
  }

  /// Cancel listening: the session is VOIDED, not stopped
  /// gracefully -- the platform discards its pending
  /// result. Used for a too-short push-to-talk press, whose
  /// session must never produce an executable result. Like
  /// stop(), cancel counts toward the full-close barrier.
  Future<void> cancelListening() async {
    _resultArrivedSinceStopBegan = false;
    if (!_listening) return;
    _genOpen = 0;
    // A cancel closes the session too: one unconfirmed
    // close, same rule as stop() (rule B).
    _pendingCloses++;
    // A cancel discards the session outright: unlike
    // stop() it never forwards a final result, so its
    // closing status IS still owed (see _statusesOwed).
    _statusesOwed++;
    _armCloseWatchdog();
    try {
      await _speech?.cancel();
    } finally {
      _listening = false;
    }
  }

  /// Issue a platform cancel UNCONDITIONALLY
  /// (MT-1111-PTT-2 recovery step 1 of 3). Unlike
  /// [cancelListening] -- which is a no-op without a live
  /// session and books a pending close for one -- this
  /// cancel exists to drop whatever residue the PREVIOUS
  /// session left inside the platform recogniser before a
  /// recovery re-initialize, so it reaches the platform
  /// even when the adapter believes nothing is listening
  /// (the errored session was already stopped locally).
  /// It books NO pending close: the recovery's own
  /// re-initialize clears every ledger immediately after,
  /// and the session it cancels was already closed on the
  /// adapter's books. Errors propagate to the caller.
  Future<void> cancelForRecovery() async {
    _resultArrivedSinceStopBegan = false;
    if (_listening) _genOpen = 0;
    await _speech?.cancel();
    _listening = false;
  }

  /// Recover the engine for the NEXT press after a
  /// recoverable error (MT-1111-PTT-2 recovery step 2 of
  /// 3: cancel -> re-initialize -> listen; the app issues
  /// the cancel itself as step 1). The re-initialize is
  /// REAL: it runs the same forced re-initialize as the
  /// watchdog restart -- registrations are re-made under
  /// a bumped epoch with fresh onStatus/onError closures
  /// (the epoch guard voids the old registration) and, for
  /// a plugin engine, the platform initialize is issued
  /// directly on the plugin channel because the plugin's
  /// Dart-side initialize() latches after its first
  /// success. Unlike the watchdog restart this emits NO
  /// engine event (the app drives it synchronously inside
  /// a press and speaks its own outcome), and it restores
  /// availability from the re-initialize's own result even
  /// when a FATAL error had marked the input unavailable:
  /// availability after recovery is whatever the fresh
  /// initialize says. The ledgers are cleared either way,
  /// so a failed recovery can never wedge a later press.
  /// Returns whether the engine is ready to listen.
  Future<bool> restartForRecovery() async {
    if (_engineRestarting) return _lastRestartSucceeded;
    _engineRestarting = true;
    if (_engineController.isClosed || engineDisposed) {
      _engineRestarting = false;
      return false;
    }
    final Completer<void>? early = _startBarrier;
    _startBarrier = null;
    if (early != null && !early.isCompleted) early.complete();
    _engineWatchdog?.cancel();
    _engineWatchdog = null;
    _engineRetryTimer?.cancel();
    _engineRetryTimer = null;
    final int epoch = ++_engineEpoch;
    // Yield once: an in-flight start attempt released
    // above settles its bookkeeping (which belongs to the
    // OLD epoch) before this recovery's state writes.
    await Future<void>.delayed(Duration.zero);
    final bool pluginEngine = _engineIsPluginInstance;
    final stt.SpeechToText fresh =
        identical(_speech, _engineSpeech) && _engineIsPluginInstance
            ? stt.SpeechToText()
            : _speech!;
    _speech = fresh;
    _engineSpeech = fresh;
    _engineIsPluginInstance = true;
    bool ok = false;
    try {
      ok = await _doInitialize(fresh, epoch, pluginEngine)
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      ok = false;
    }
    _lastRestartSucceeded = ok;
    _available = ok;
    _listening = false;
    _genOpen = 0;
    _pendingCloses = 0;
    _closeErrorConsumed = 0;
    _statusesOwed = 0;
    _resultArrivedSinceStopBegan = false;
    _sessionOpening = false;
    _engineRestarting = false;
    _detail = ok
        ? '系统语音识别已接入（引擎已恢复，zh-CN）'
        : 'NOT_CONFIGURED（语音引擎恢复后仍不可用）';
    mingtuVoiceLog('语音引擎已为下一次按压恢复（epoch=$epoch）：旧会话全部作废');
    final Completer<void>? c = _closeCompleter;
    _closeCompleter = null;
    if (c != null && !c.isCompleted) c.complete();
    return ok;
  }

  void dispose() {
    engineDisposed = true;
    _engineWatchdog?.cancel();
    _engineWatchdog = null;
    _engineRetryTimer?.cancel();
    _engineRetryTimer = null;
    // A wait on an unconfirmed close must not hang past
    // disposal: release it (the owner is gone; nothing
    // will listen again on this input).
    final Completer<void>? c = _closeCompleter;
    _closeCompleter = null;
    if (c != null && !c.isCompleted) c.complete();
    _controller.close();
    _partialController.close();
    _errorController.close();
    _noMatchController.close();
    _engineController.close();
    _sessionEndController.close();
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
