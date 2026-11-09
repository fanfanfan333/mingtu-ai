/// Runtime configuration for Mingtu AI v0.2.
///
/// All sensitive or environment-specific values come from
/// `--dart-define` only, never from hardcoded values and never from a
/// file committed to the repository. Run, for example:
///
///   flutter run --dart-define=MINGTU_ROUTE_PROXY_URL=https://your-server \
///     --dart-define=MINGTU_YOLO_MODEL_PATH=yolo11n \
///     --dart-define=MINGTU_LLM_MODEL_ID=... \
///     --dart-define=MINGTU_DASHSCOPE_API_KEY=...
///
/// Amap key rule (navigation P0, changed): the Amap Web Service key
/// must NEVER be in the app -- not in source, not in the APK, not
/// via --dart-define (dart-define values are compiled into the app
/// binary and are extractable from a public APK). The key lives
/// only in the route proxy's server-side environment (see
/// server/amap_proxy.py); the app only knows the proxy base URL,
/// which is not a secret. The old MINGTU_AMAP_KEY /
/// MINGTU_AMAP_FROM / MINGTU_AMAP_TO dart-define channels are
/// removed: real-route origins now come from the on-device GPS
/// adapter (adapters/current_location.dart) and destinations only
/// from config/verified_locations.dart (human-verified, GCJ-02).
/// Without a proxy URL the app reports NOT_CONFIGURED and never
/// invents a route. YOLO model path defaults to the official
/// model id 'yolo11n' (the plugin downloads it on the phone); an
/// asset path such as 'assets/models/custom.tflite' also works.
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
  /// Base URL of the self-hosted Amap route proxy (server side
  /// holds the Amap key). A URL is not a credential. Empty = the
  /// proxy is not deployed/configured, and real routes are
  /// unavailable -- the app announces exactly that.
  static const String routeProxyUrl =
      String.fromEnvironment('MINGTU_ROUTE_PROXY_URL');
  static const String yoloModelPath =
      String.fromEnvironment('MINGTU_YOLO_MODEL_PATH', defaultValue: 'yolo11n');
  static const String llmModelId =
      String.fromEnvironment('MINGTU_LLM_MODEL_ID');
  static const String dashscopeApiKey =
      String.fromEnvironment('MINGTU_DASHSCOPE_API_KEY');

  static bool get hasRouteProxy => routeProxyUrl.isNotEmpty;
  static bool get hasYoloModelPath => yoloModelPath.isNotEmpty;
  static bool get hasLlmModelId => llmModelId.isNotEmpty;
  static bool get hasDashscopeKey => dashscopeApiKey.isNotEmpty;

  static String get routeProxyStatus => hasRouteProxy
      ? '已配置路线代理地址（仅地址，非密钥；未验证代理真实可用）'
      : 'NOT_CONFIGURED（路线代理未部署或未配置地址，真实路线不可用，不会伪造路线）';
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
