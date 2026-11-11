/// Runtime configuration for Mingtu AI v0.2.
///
/// All sensitive or environment-specific values come from
/// `--dart-define` only, never from hardcoded values and never from a
/// file committed to the repository. Run, for example:
///
///   flutter run --dart-define=MINGTU_ROUTE_PROXY_URL=https://your-server \
///     --dart-define=MINGTU_YOLO_MODEL_PATH=yolo11n \
///     --dart-define=MINGTU_LLM_MODEL_ID=... \
///     --dart-define=MINGTU_VISION_PROXY_URL=https://your-fc-endpoint \
///     --dart-define=MINGTU_VISION_TOKEN=<demo token, build time only>
///
/// Amap key rule: the PRODUCTION Amap Web Service key must never
/// be in the app -- it lives only in the route proxy's server-side
/// environment (see server/amap_proxy.py); the app then only
/// knows the proxy base URL, which is not a secret.
///
/// DEMO EXCEPTION (explicit user decision, 2026-11-09): the demo
/// build may inject a DISPOSABLE demo key via
/// --dart-define=MINGTU_AMAP_KEY for a direct-connection demo
/// mode (see adapters/amap_client.dart). dart-define values are
/// compiled into the app binary and ARE extractable from the
/// APK, so this is only acceptable because the key is a
/// throwaway: the user MUST regenerate/revoke it after the demo.
/// The value itself is never committed to this repository, never
/// printed and never logged (the client never surfaces request
/// URLs, which carry it). The old MINGTU_AMAP_FROM /
/// MINGTU_AMAP_TO dart-define channels stay removed: real-route
/// origins come from the on-device GPS adapter
/// (adapters/current_location.dart) and destinations only from
/// config/verified_locations.dart (human-verified, GCJ-02).
/// Without a demo key or a proxy URL the app reports
/// NOT_CONFIGURED and never invents a route. YOLO model path
/// defaults to the official model id 'yolo11n' (the plugin
/// downloads it on the phone); an asset path such as
/// 'assets/models/custom.tflite' also works.
///
/// Bailian (DashScope) has NO client-side key channel at all
/// (user decision, 2026-11-09): the former client dart-define
/// key channel and the direct client were REMOVED. The Bailian
/// key exists only in the server function's environment on
/// Alibaba Cloud Function Compute (see server/DEPLOY_FC.md);
/// the app sends frames to that function's HTTPS URL with a
/// disposable demo token (also build-time injected, revocable
/// after the demo) -- never with a Bailian key.
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

  /// Disposable DEMO key for the direct-connection demo mode
  /// (see the demo exception above). Injected ONLY at build time
  /// via --dart-define=MINGTU_AMAP_KEY; the value is never in
  /// this repository and must be regenerated/revoked after the
  /// demo. Empty = no demo mode (proxy or unconfigured).
  static const String amapDemoKey = String.fromEnvironment('MINGTU_AMAP_KEY');

  /// Bundled model asset (assets/... paths are copied to a
  /// real file by the ultralytics_yolo resolver). The previous
  /// default 'yolo11n' was a bare model ID: the plugin tried
  /// to download it on-device and failed ("Could not open
  /// 'yolo11n'"), leaving YOLO dead on real hardware.
  static const String yoloModelPath = String.fromEnvironment(
    'MINGTU_YOLO_MODEL_PATH',
    defaultValue: 'assets/models/yolo11n.tflite',
  );
  static const String llmModelId =
      String.fromEnvironment('MINGTU_LLM_MODEL_ID');

  /// HTTPS base URL of the cloud-vision function (Alibaba
  /// Cloud Function Compute; the Bailian key lives only in that
  /// function's server environment). MUST be https: the client
  /// refuses anything else. Empty = vision not configured.
  static const String visionProxyUrl =
      String.fromEnvironment('MINGTU_VISION_PROXY_URL');

  /// Disposable demo token for the vision function, injected
  /// ONLY at build time via --dart-define=MINGTU_VISION_TOKEN.
  /// It is NOT a Bailian key; the server checks it before
  /// spending anything, and the user revokes/rotates it after
  /// the demo. Never committed, never printed, never logged.
  static const String visionDemoToken =
      String.fromEnvironment('MINGTU_VISION_TOKEN');

  /// HTTPS base URL of the cloud-ASR function (the press-and-
  /// hold recording fallback's /asr route). Optional: when the
  /// dedicated define is empty the ASR client falls back to
  /// [visionProxyUrl], because /asr and /vision are routes of
  /// the SAME FC deployment and share the demo token.
  static const String _asrProxyUrlDefine =
      String.fromEnvironment('MINGTU_ASR_PROXY_URL');

  /// Effective ASR proxy base URL (dedicated define first,
  /// vision proxy as the fallback).
  static String get asrProxyUrl =>
      _asrProxyUrlDefine.isNotEmpty ? _asrProxyUrlDefine : visionProxyUrl;

  static bool get hasRouteProxy => routeProxyUrl.isNotEmpty;
  static bool get hasAmapDemoKey => amapDemoKey.isNotEmpty;
  static bool get hasYoloModelPath => yoloModelPath.isNotEmpty;
  static bool get hasLlmModelId => llmModelId.isNotEmpty;
  static bool get hasVisionProxy => visionProxyUrl.isNotEmpty;
  static bool get visionProxyIsHttps => visionProxyUrl.startsWith('https://');
  static bool get hasVisionDemoToken => visionDemoToken.isNotEmpty;

  static String get amapDemoKeyStatus => hasAmapDemoKey
      ? '演示直连 Key 已注入（构建时参数，值未显示；演示后必须作废/重新生成）'
      : '未注入演示 Key（直连演示模式不可用，走代理或未配置）';
  static String get routeProxyStatus => hasRouteProxy
      ? '已配置路线代理地址（仅地址，非密钥；未验证代理真实可用）'
      : 'NOT_CONFIGURED（路线代理未部署或未配置地址，真实路线不可用，不会伪造路线）';
  static String get yoloStatus => hasYoloModelPath
      ? '已配置模型路径（值未显示，未验证手机端推理）'
      : 'NOT_CONFIGURED（未提供 YOLO 模型路径，感知为接口演示，不会伪造检测）';
  static String get llmStatus => hasLlmModelId
      ? '已配置模型 ID（值未显示，云端仅按需调用，网关只返回决策）'
      : 'NOT_CONFIGURED（未提供 LLM 模型 ID，不会调用云端）';
  static String get visionProxyStatus => !hasVisionProxy
      ? 'NOT_CONFIGURED（未提供识图代理地址，云端识图不可用，客户端无百炼密钥）'
      : (!visionProxyIsHttps
          ? '配置无效（识图代理地址不是 https，已拒绝使用）'
          : '已配置识图代理（HTTPS，地址非密钥；百炼密钥只在服务器函数环境中）'
              '${hasVisionDemoToken ? '；演示令牌已注入（值未显示，演示后作废）' : '；未注入演示令牌，代理将拒绝调用'}');
}
