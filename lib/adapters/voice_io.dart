/// Voice input / output contracts for Mingtu AI.
///
/// Blind-first rule: every prompt the app produces must be speakable,
/// and every control the app offers must be reachable by voice. These
/// interfaces are that contract.
///
/// v0.6: the real implementations now exist in
/// `system_voice_io.dart` ([SystemVoiceOutput] via flutter_tts,
/// [SystemVoiceInput] via speech_to_text), using the phone's own
/// system engines -- never a custom audio hack that bypasses the
/// user's accessibility settings. Recognised text is fed into
/// parseVoiceCommand, never into a state setter. The
/// [UnavailableVoiceOutput] / [UnavailableVoiceInput] implementations
/// below are still the fallback: when no engine is reachable (web
/// without a voice, VM, test harness, denied permission) the gap is
/// reported as NOT_CONFIGURED instead of being faked.
library;

/// v0.4 explicit scope decision: continuous wake-word detection
/// ("小途" always listening) is NOT_IMPLEMENTED in this competition
/// version -- it needs a native always-on recogniser, background
/// microphone permission, battery and vendor handling that cannot be
/// verified here. Replacement, implemented in v0.7: turn-taking
/// listening -- the app greets by voice at startup and then listens,
/// and after every spoken prompt finishes it listens again while a
/// task is running, so a blind user can say "停下" at any time without
/// tapping. The microphone only opens after speech ends, never while
/// TTS is speaking. Plus pause / resume / repeat / status / help /
/// emergency commands via parseVoiceCommand.
const String wakeWordStatus =
    'NOT_IMPLEMENTED（持续唤醒词未实现，替代：启动问候 + 播报后自动再听的轮流对话）';

abstract class VoiceOutput {
  bool get isAvailable;
  String get status;
  Future<void> speak(String text);
}

/// One recognition result, tagged with the id of the
/// listening session that produced it. The platform
/// recogniser has no session concept, so the adapter mints
/// an id per listen session and stamps every event from
/// that session's callback closure with it; consumers
/// validate the id against their own current session and
/// drop anything stale.
class AsrResultEvent {
  const AsrResultEvent(this.sessionId, this.text);
  final int sessionId;
  final String text;
}

/// One session-status event ('done' / 'notListening'),
/// tagged the same way, so a late status from an old
/// session cannot end (or be mistaken for) a newer one.
class AsrStatusEvent {
  const AsrStatusEvent(this.sessionId, this.status);
  final int sessionId;
  final String status;
}

abstract class VoiceInput {
  bool get isAvailable;
  String get status;
  Stream<AsrResultEvent> get transcripts;
}

class UnavailableVoiceOutput implements VoiceOutput {
  @override
  bool get isAvailable => false;

  @override
  String get status => 'NOT_CONFIGURED（未接入系统语音合成，当前演示只显示文字提示）';

  @override
  Future<void> speak(String text) async {
    // Deliberately does nothing: speaking must never be faked by
    // pretending a text display is a voice prompt.
  }
}

class UnavailableVoiceInput implements VoiceInput {
  @override
  bool get isAvailable => false;

  @override
  String get status => 'NOT_CONFIGURED（未接入系统语音识别，当前演示用指令输入代替）';

  @override
  Stream<AsrResultEvent> get transcripts => const Stream.empty();
}
