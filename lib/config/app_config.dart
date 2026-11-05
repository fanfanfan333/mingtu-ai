/// Runtime configuration for Mingtu AI v0.2.
///
/// All sensitive or environment-specific values come from
/// `--dart-define` only, never from hardcoded values and never from a
/// file committed to the repository. Run, for example:
///
///   flutter run --dart-define=MINGTU_AMAP_KEY=... \
///     --dart-define=MINGTU_YOLO_MODEL_PATH=... \
///     --dart-define=MINGTU_LLM_MODEL_ID=... \
///     --dart-define=MINGTU_DASHSCOPE_API_KEY=...
///
/// The DashScope key is only for the Bailian client
/// (lib/adapters/bailian_client.dart). It is never committed, never
/// logged and never sent to Muse: the user supplies it on their own
/// machine at run time, and it only authenticates to their own Bailian
/// account (a student voucher/credit is account-level there).
///
/// If a value is not supplied, the corresponding capability reports
/// NOT_CONFIGURED and the app must NOT fake a route, a detection or a
/// voice result. Values are never printed or logged: only the status
/// (configured / not configured) is shown.
class AppConfig {
  static const String amapApiKey =
      String.fromEnvironment('MINGTU_AMAP_KEY');
  static const String yoloModelPath =
      String.fromEnvironment('MINGTU_YOLO_MODEL_PATH');
  static const String llmModelId =
      String.fromEnvironment('MINGTU_LLM_MODEL_ID');
  static const String dashscopeApiKey =
      String.fromEnvironment('MINGTU_DASHSCOPE_API_KEY');

  static bool get hasAmapKey => amapApiKey.isNotEmpty;
  static bool get hasYoloModelPath => yoloModelPath.isNotEmpty;
  static bool get hasLlmModelId => llmModelId.isNotEmpty;
  static bool get hasDashscopeKey => dashscopeApiKey.isNotEmpty;

  static String get amapStatus => hasAmapKey
      ? '已配置密钥（值未显示，未验证真实高德接入）'
      : 'NOT_CONFIGURED（未提供高德密钥，地图为接口占位，不会伪造路线）';
  static String get yoloStatus => hasYoloModelPath
      ? '已配置模型路径（值未显示，未验证手机端推理）'
      : 'NOT_CONFIGURED（未提供 YOLO 模型路径，感知为接口演示，不会伪造检测）';
  static String get llmStatus => hasLlmModelId
      ? '已配置模型 ID（值未显示，云端仅按需调用，网关只返回决策）'
      : 'NOT_CONFIGURED（未提供 LLM 模型 ID，不会调用云端）';
  static String get bailianStatus => hasDashscopeKey
      ? '百炼 Key 已配置（值未显示，只在网关批准时由本机调用，未验证真实百炼接入）'
      : 'NOT_CONFIGURED（未提供百炼 Key，百炼客户端不会调用云端）';
}
