/// Voice input / output contracts for Mingtu AI.
///
/// Blind-first rule: every prompt the app produces must be speakable,
/// and every control the app offers must be reachable by voice. These
/// interfaces are that contract. They are NOT a real TTS/ASR
/// integration: no system TTS or recogniser plugin is wired in yet,
/// so on a real phone the app today still cannot actually speak or
/// listen. The [UnavailableVoiceOutput] / [UnavailableVoiceInput]
/// implementations exist precisely so that gap is reported as
/// NOT_CONFIGURED instead of being faked.
///
/// A future phone implementation must implement these two interfaces
/// with the platform system TTS/ASR (never a custom audio hack that
/// bypasses the user's accessibility settings), and must feed
/// recognised text into parseVoiceCommand, never into a state setter.
library;

abstract class VoiceOutput {
  bool get isAvailable;
  String get status;
  Future<void> speak(String text);
}

abstract class VoiceInput {
  bool get isAvailable;
  String get status;
  Stream<String> get transcripts;
}

class UnavailableVoiceOutput implements VoiceOutput {
  @override
  bool get isAvailable => false;

  @override
  String get status =>
      'NOT_CONFIGURED（未接入系统语音合成，当前演示只显示文字提示）';

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
  String get status =>
      'NOT_CONFIGURED（未接入系统语音识别，当前演示用指令输入代替）';

  @override
  Stream<String> get transcripts => const Stream.empty();
}
