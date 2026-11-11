/// Speech-recognition error discipline (same rule as the
/// cloud-vision client): platform error strings are NOT
/// trusted content. Only whitelisted error codes survive;
/// anything else collapses to one unknown code, and every
/// surface -- detail, announcement, status, MingtuVoice log --
/// shows a fixed local Chinese text for the code. A raw
/// platform error message never reaches any of them.
library;

/// Error codes the speech_to_text platform layer is known to
/// produce. Anything outside this set is reported as
/// [asrErrorUnknown].
const Set<String> knownAsrErrorCodes = <String>{
  'error_permission',
  'error_insufficient_permissions',
  'error_network',
  'error_network_timeout',
  'error_no_match',
  'error_speech_timeout',
  'error_audio',
  'error_audio_error',
  'error_client',
  'error_server',
  'error_busy',
  'error_language_not_supported',
  'error_language_unavailable',
  'error_cancelled',
  'not_available',
};

const String asrErrorUnknown = 'error_unknown';

/// Normalise a raw platform error string to a whitelisted
/// code. The raw string is used ONLY for this lookup and is
/// then discarded.
String asrErrorCode(String raw) =>
    knownAsrErrorCodes.contains(raw) ? raw : asrErrorUnknown;

/// The dedicated spoken notice for a permission failure of
/// the SYSTEM speech engine (real-device fix round): on the
/// Xiaomi 15 the engine is Xiaomi's own speech service, and
/// it is THAT app which lacks the microphone permission --
/// the user must grant it there, in these exact steps. This
/// is the text _handleAsrError speaks for the permission
/// codes; [asrErrorText] keeps the short form for status and
/// log surfaces.
const String asrPermissionSpeechText =
    '系统语音识别没有麦克风权限。请打开设置，进入应用管理，找到小米语音，也就是小爱语音，在权限里把麦克风设为允许。';

/// Fixed Chinese text per whitelisted code.
String asrErrorText(String code) => switch (code) {
      'error_permission' || 'error_insufficient_permissions' => '语音识别权限被拒绝。',
      'error_network' || 'error_network_timeout' => '语音识别网络出错。',
      'error_no_match' => '没有听清任何话。',
      'error_speech_timeout' => '语音识别超时，没有听到声音。',
      'error_audio' || 'error_audio_error' => '麦克风音频出错。',
      'error_busy' => '语音识别正忙。',
      'error_language_not_supported' ||
      'error_language_unavailable' =>
        '设备不支持中文语音识别。',
      'error_cancelled' => '语音识别已取消。',
      'not_available' => '语音识别服务不可用。',
      _ => '语音识别出错。',
    };
