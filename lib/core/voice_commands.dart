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
  // v0.5 blind-first additions: a blind user must be able to stop
  // immediately, confirm a step, ask what is ahead, and keep/delete
  // the recording -- all by voice, not by finding a button on screen.
  confirmStep,
  environment,
  // On-demand cloud vision: "看看前面" captures ONE frame and asks
  // the cloud to describe it (low frequency, spoken disclaimer).
  // It is an explicit trigger only -- never a background action.
  cloudVision,
  saveRecording,
  deleteRecording,
  unknown,
}

VoiceCommand parseVoiceCommand(String raw) {
  final String text = raw
      .trim()
      .replaceAll('小途', '')
      .replaceAll('，', '')
      .replaceAll(',', '')
      .trim();
  if (text.isEmpty) return VoiceCommand.unknown;
  if (text.contains('需要帮助') || text.contains('救命') || text.contains('紧急')) {
    return VoiceCommand.emergency;
  }
  if (text.contains('暂停') ||
      text.contains('停一下') ||
      text.contains('先停下') ||
      text.contains('停下') ||
      text.contains('别走') ||
      text.contains('别走了')) {
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
  if (text.contains('到哪') ||
      text.contains('现在在哪') ||
      text.contains('我在哪') ||
      text.contains('什么状态') ||
      text.contains('走到哪')) {
    return VoiceCommand.status;
  }
  if (text.contains('保存录像') || text.contains('保留录像') || text.contains('留着录像')) {
    return VoiceCommand.saveRecording;
  }
  if (text.contains('删除录像') || text.contains('删掉录像') || text.contains('不要录像')) {
    return VoiceCommand.deleteRecording;
  }
  if (text.contains('确认') ||
      text.contains('我到了') ||
      text.contains('完成了') ||
      text.contains('下一步')) {
    return VoiceCommand.confirmStep;
  }
  if (text.contains('看看前面') ||
      text.contains('看一下前面') ||
      text.contains('看看前方') ||
      text.contains('看一下前方') ||
      text.contains('看看周围') ||
      text.contains('看一下周围') ||
      text.contains('看一下前面有什么')) {
    return VoiceCommand.cloudVision;
  }
  if (text.contains('前面有什么') ||
      text.contains('周围有什么') ||
      text.contains('附近有什么') ||
      text.contains('前面是什么')) {
    return VoiceCommand.environment;
  }
  if (text.contains('去图书馆') || text.contains('图书馆')) {
    return VoiceCommand.startLibrary;
  }
  if (text.contains('帮助') || text.contains('能做什么') || text.contains('怎么用')) {
    return VoiceCommand.help;
  }
  return VoiceCommand.unknown;
}

String voiceCommandHelpText() => '你可以说：带我去图书馆、停下、暂停、继续、取消、再说一遍、'
    '现在到哪了、前面有什么、看看前面、确认、保存录像、删除录像、我需要帮助。';

/// UI-A11Y S1 (UI-01): semantics labels of the big button
/// in TalkBack TOGGLE mode (MediaQuery.accessibleNavigation
/// on). Idle invites a double-tap to start; while a press
/// session is live the label says how to end it. The
/// hold-mode label stays in main.dart, unchanged.
const String talkBackToggleIdleLabel = '按住说话，双击开始';
const String talkBackToggleListeningLabel = '正在听，双击结束';
