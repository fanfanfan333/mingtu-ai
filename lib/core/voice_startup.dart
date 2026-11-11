/// Startup voice plan and voice-notice texts for Mingtu AI
/// (follow-up on the Android submission PR).
///
/// Blind-first rules encoded here, as pure testable logic:
///
/// 1. The startup greeting must be spoken whenever Chinese TTS is
///    actually usable -- in particular even when speech recognition
///    (ASR) failed to initialise. Before this fix the greeting in
///    main.dart only ran `if (asrOk)`, so an ASR failure with a
///    working TTS left a blind user in total silence: no greeting,
///    no error, no next step.
/// 2. An ASR failure must be announced by voice (when voice works)
///    with a concrete, recoverable next step -- never silent.
/// 3. Chinese speech only counts as usable when a zh-CN voice is
///    *verified* on the device (see [resolveChineseTtsLocale]). An
///    engine that answers is not proof it can speak Chinese; an
///    unverified language is reported as unavailable, never assumed.
/// 4. When Chinese speech is not usable, the plan must NOT claim a
///    voice announcement of that fact (you cannot announce a TTS
///    failure through the failed TTS). The caller falls back to
///    vibration + on-screen status text (readable by a screen
///    reader) and reports honestly that voice cannot be relied on.
/// 5. Notice texts for unavailable / ended states never contain a
///    left/right step instruction and never promise that it is safe
///    to move forward: unknown is not safe.
library;

/// Pick the zh-CN locale to use from the locales a TTS engine
/// reports, or null when no mainland-Chinese voice exists.
///
/// Matching is normalisation-insensitive (`zh_CN` == `zh-CN`,
/// case-insensitive). Only zh-CN / zh-Hans-CN / bare zh count as
/// verified Chinese for this app; another Chinese variant (e.g.
/// zh-TW) is a different voice data set and is NOT silently treated
/// as zh-CN. Returns the engine's own locale string, so the caller
/// passes back exactly what the engine advertised.
String? resolveChineseTtsLocale(List<String> availableLocales) {
  String norm(String s) => s.trim().toLowerCase().replaceAll('_', '-');
  const List<String> wanted = <String>['zh-cn', 'zh-hans-cn', 'zh'];
  final Map<String, String> byNorm = <String, String>{
    for (final String loc in availableLocales) norm(loc): loc,
  };
  for (final String w in wanted) {
    final String? hit = byNorm[w];
    if (hit != null) return hit;
  }
  return null;
}

/// How the startup outcome may be delivered to the user.
enum StartupVoiceChannel {
  /// Chinese TTS verified usable: announcements are spoken.
  speech,

  /// No usable Chinese speech: use vibration + on-screen status
  /// (screen-reader readable). Nothing may be reported as "spoken".
  hapticAndStatus,
}

class StartupVoicePlan {
  final StartupVoiceChannel channel;

  /// The single startup announcement to speak, or null when the
  /// channel is not speech. Never non-null on the haptic channel:
  /// a plan that cannot be heard must not pretend otherwise.
  final String? spokenText;

  /// Whether the turn-taking auto-listen loop may start. Only true
  /// when the greeting really was spoken AND ASR is available, so
  /// the microphone never opens without the user hearing why.
  final bool startAutoListen;

  /// One-line honest summary of both engines, for status display
  /// and the health report. Distinguishes engine-down from
  /// engine-up-but-no-Chinese-voice.
  final String summary;

  const StartupVoicePlan({
    required this.channel,
    required this.spokenText,
    required this.startAutoListen,
    required this.summary,
  });

  bool get speechUsable => channel == StartupVoiceChannel.speech;
}

const String _greetingOk = '明途已启动，语音识别已开启。请说一句话，例如带我去图书馆。';
const String _greetingAsrDown = '明途已启动，但语音识别暂时不可用，你说话我可能听不见。'
    '危险提示仍会用语音播报。你可以请身边的人帮忙点屏幕上的开始按钮，'
    '或检查麦克风权限后重新打开应用。';

/// Decide the startup announcement from the *measured* engine
/// states. [ttsDetail] / [asrDetail] are the adapters' own status
/// strings; they are surfaced in the summary, never hidden.
StartupVoicePlan planStartupVoice({
  required bool ttsEngineOk,
  required bool chineseVoiceVerified,
  required bool asrOk,
}) {
  final bool speechUsable = ttsEngineOk && chineseVoiceVerified;
  final String ttsPart = !ttsEngineOk
      ? '语音播报不可用（引擎无响应或初始化失败）'
      : chineseVoiceVerified
          ? '语音播报可用（zh-CN 中文语音已核实）'
          : '语音播报不可用（设备缺少 zh-CN 中文语音数据）';
  final String asrPart = asrOk ? '语音识别可用' : '语音识别不可用';
  final String summary = '$ttsPart；$asrPart。';
  if (!speechUsable) {
    return StartupVoicePlan(
      channel: StartupVoiceChannel.hapticAndStatus,
      spokenText: null,
      startAutoListen: false,
      summary: '$summary 语音当前不可依赖，已改用振动和屏幕状态提示。',
    );
  }
  return StartupVoicePlan(
    channel: StartupVoiceChannel.speech,
    spokenText: asrOk ? _greetingOk : _greetingAsrDown,
    startAutoListen: asrOk,
    summary: summary,
  );
}

/// Kinds of state a blind user must be told about, in Chinese, as
/// soon as they occur.
enum VoiceNoticeKind {
  navigationUnavailable,
  detectionUnavailable,
  locationUnavailable,
  serviceError,
  navigationEnded,
  asrUnavailable,
  ttsUnavailable,
}

/// The exact announcement text for each notice kind.
///
/// Safety contract (pinned by tests): no text here contains a
/// left/right step instruction （向左/向右/左转/右转） and none
/// promises safe passage (no "you may proceed" / "it is fine to walk" claims). An unavailable
/// sensor or service is announced as unknown, never as safe.
String voiceNoticeText(VoiceNoticeKind kind) {
  switch (kind) {
    case VoiceNoticeKind.navigationUnavailable:
      return '导航暂时不可用，我无法确认路线。请先停留在原地，'
          '等恢复后再继续，或寻求身边的人帮助。';
    case VoiceNoticeKind.detectionUnavailable:
      return '障碍物检测暂时不可用，我无法确认前方情况。'
          '请放慢速度，谨慎移动，必要时寻求帮助。';
    case VoiceNoticeKind.locationUnavailable:
      return '定位暂时不可用，我不知道你现在的位置。'
          '请不要依赖位置提示，必要时寻求帮助。';
    case VoiceNoticeKind.serviceError:
      return '有一项服务出错，相关提示暂时不可用。'
          '请谨慎行动，必要时寻求帮助。';
    case VoiceNoticeKind.navigationEnded:
      return '导航已结束。结束不代表已经到达目的地，'
          '请通过语音或身边的人确认你所在的位置。';
    case VoiceNoticeKind.asrUnavailable:
      return '语音识别暂时不可用，你说话我可能听不见。'
          '可以请身边的人帮忙点屏幕按钮，或检查麦克风权限后重试。';
    case VoiceNoticeKind.ttsUnavailable:
      // This text is for status display / logs only. It must never
      // be reported as "announced by voice": if TTS is down, this
      // cannot have been heard. The wording says exactly that.
      return '语音播报不可用，本条只是文字提示，未被读出。'
          '语音当前不可依赖，请使用读屏软件或寻求帮助。';
  }
}
