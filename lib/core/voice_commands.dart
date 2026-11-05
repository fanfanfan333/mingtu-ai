/// Voice command parsing for Mingtu AI, blind-first.
///
/// This is the command layer that a real speech recogniser must feed.
/// It contains no ASR call itself: on a phone, the text comes from the
/// system recogniser (see adapters/voice_io.dart, NOT yet integrated);
/// in the demo UI it comes from the command input field, labelled as
/// a simulation. Parsing never changes task state by itself -- the
/// caller in main.dart checks the state machine before acting, so an
/// illegal voice command is answered, never silently applied.
///
/// Priority order matters: "我需要帮助" must win over a generic "帮助"
/// request, because emergency is the highest-priority speech kind.
library;

enum VoiceCommand {
  startLibrary,
  pause,
  resume,
  cancel,
  repeat,
  status,
  help,
  emergency,
  unknown,
}

VoiceCommand parseVoiceCommand(String raw) {
  final String text = raw.trim().replaceAll('小途', '').replaceAll('，', '').replaceAll(',', '').trim();
  if (text.isEmpty) return VoiceCommand.unknown;
  if (text.contains('需要帮助') || text.contains('救命') || text.contains('紧急')) {
    return VoiceCommand.emergency;
  }
  if (text.contains('暂停') || text.contains('停一下') || text.contains('先停下')) {
    return VoiceCommand.pause;
  }
  if (text.contains('继续') || text.contains('恢复')) {
    return VoiceCommand.resume;
  }
  if (text.contains('取消') || text.contains('不去了') || text.contains('结束任务')) {
    return VoiceCommand.cancel;
  }
  if (text.contains('再说一遍') || text.contains('重复') || text.contains('刚才说什么')) {
    return VoiceCommand.repeat;
  }
  if (text.contains('到哪') || text.contains('现在在哪') || text.contains('什么状态') || text.contains('走到哪')) {
    return VoiceCommand.status;
  }
  if (text.contains('去图书馆') || text.contains('图书馆')) {
    return VoiceCommand.startLibrary;
  }
  if (text.contains('帮助') || text.contains('能做什么') || text.contains('怎么用')) {
    return VoiceCommand.help;
  }
  return VoiceCommand.unknown;
}

String voiceCommandHelpText() =>
    '你可以说：带我去图书馆、暂停、继续、取消、再说一遍、'
    '现在到哪了、我需要帮助。';
