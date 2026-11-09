/// Low-frequency cloud vision ASSIST for Mingtu AI.
///
/// Positioning, stated once and enforced by the texts below:
/// - Local YOLO detection and the local safety degradation logic
///   remain PRIMARY. This is an occasional, user-triggered assist
///   that describes a single frame in words; it never feeds the
///   risk engine and never produces walking instructions.
/// - It is NOT verified road-danger detection. Every spoken result
///   carries that caveat; no text here claims a scene is safe.
/// - The model is called ONLY through the project proxy
///   (server/amap_proxy.py, POST /vision): the DashScope key lives
///   in the proxy's server environment. The app holds no key --
///   not in source, not in the APK, not via --dart-define.
/// - Cost/privacy controls are part of the feature, not options:
///   images are downsampled before upload, calls are rate-limited
///   ([cloudVisionMinInterval]), and the output token budget is
///   capped ([cloudVisionMaxOutputTokens]) with thinking disabled.
library;

/// The vision model id. Case matters: this is the exact lowercase
/// id from the DashScope console; an uppercase variant 404s.
const String cloudVisionModelId = 'qwen3.7-flash';

/// Output budget per call (the proxy also clamps to this).
const int cloudVisionMaxOutputTokens = 256;

/// Longest image edge after downsampling, in pixels.
const int cloudVisionMaxDimension = 768;

/// Hard cap on the encoded image payload sent to the proxy.
const int cloudVisionMaxImageBytes = 1536 * 1024;

/// Minimum interval between two cloud vision calls. A failed call
/// still consumes the slot: low frequency is also retry protection.
const Duration cloudVisionMinInterval = Duration(seconds: 20);

/// Explicit client-side timeout for one vision request. The proxy
/// applies its own upstream timeout (20 s) as well; a call that
/// exceeds this is abandoned and announced as a degradation --
/// never left hanging in silence.
const Duration cloudVisionRequestTimeout = Duration(seconds: 15);

/// The prompt sent with every frame. It asks for a plain scene
/// description and explicitly forbids walking-safety judgements.
const String cloudVisionPrompt = '请用简短中文描述这张图片里的场景和主要物体，'
    '不超过三句话。不要给出任何行走方向，不要判断道路是否安全，'
    '不要说可以安全通过。';

/// Simple interval rate limiter with an injectable clock (callers
/// pass `now`), so the policy is unit-testable without sleeping.
class VisionRateLimiter {
  final Duration minInterval;
  DateTime? _lastCallAt;

  VisionRateLimiter({this.minInterval = cloudVisionMinInterval});

  /// Take the slot for a call at [now]. Returns false (and takes
  /// nothing) when the previous call is too recent.
  bool tryAcquire(DateTime now) {
    final DateTime? last = _lastCallAt;
    if (last != null && now.difference(last) < minInterval) return false;
    _lastCallAt = now;
    return true;
  }

  void reset() {
    _lastCallAt = null;
  }
}

/// Target pixel size when the longest edge is capped at
/// [maxDimension]. Images already small enough keep their size;
/// dimensions never drop below 1.
({int width, int height}) computeDownsampledSize(
  int width,
  int height, {
  int maxDimension = cloudVisionMaxDimension,
}) {
  if (width <= 0 || height <= 0) return (width: 0, height: 0);
  final int longest = width > height ? width : height;
  if (longest <= maxDimension) return (width: width, height: height);
  final double scale = maxDimension / longest;
  return (
    width: (width * scale).round().clamp(1, maxDimension),
    height: (height * scale).round().clamp(1, maxDimension),
  );
}

/// The OpenAI-compatible chat body for one vision call, exactly as
/// the proxy forwards it to the Beijing DashScope compatible
/// endpoint (same compatible-mode configuration the Bailian text
/// client uses). Thinking is disabled when the model supports the
/// flag -- it is always sent as false here.
Map<String, Object> buildVisionRequestBody({
  required String imageBase64,
  String prompt = cloudVisionPrompt,
}) {
  return <String, Object>{
    'model': cloudVisionModelId,
    'messages': <Object>[
      <String, Object>{
        'role': 'user',
        'content': <Object>[
          <String, Object>{
            'type': 'image_url',
            'image_url': <String, String>{
              'url': 'data:image/png;base64,$imageBase64',
            },
          },
          <String, String>{'type': 'text', 'text': prompt},
        ],
      },
    ],
    'max_tokens': cloudVisionMaxOutputTokens,
    'enable_thinking': false,
  };
}

enum CloudVisionFailure {
  /// Proxy base URL not configured (proxy not deployed).
  notConfigured,

  /// Too soon after the previous call.
  rateLimited,

  /// Even after downsampling the payload exceeds the cap.
  imageTooLarge,

  /// No frame was available to send.
  noImage,

  /// Transport failed.
  network,

  /// The request exceeded the explicit client timeout.
  timeout,

  /// The proxy/upstream answered with an error.
  upstream,

  /// The response was not the expected shape.
  badResponse,
}

class CloudVisionResult {
  final String? description;
  final CloudVisionFailure? failure;
  final String? detail;

  const CloudVisionResult._({this.description, this.failure, this.detail});

  factory CloudVisionResult.ok(String description) =>
      CloudVisionResult._(description: description);

  factory CloudVisionResult.failed(
    CloudVisionFailure failure, {
    String? detail,
  }) =>
      CloudVisionResult._(failure: failure, detail: detail);

  bool get ok => failure == null && description != null;

  /// What the user hears. A success is framed as unverified
  /// assistive description -- never as a safety judgement. Every
  /// failure announces the degradation back to local detection;
  /// nothing fails silently.
  String get speechText {
    if (ok) {
      return '云端视觉辅助描述：$description '
          '提醒：这只是低频辅助描述，未经验证，不能当作道路安全判断，'
          '请继续以本地检测和盲杖为准。';
    }
    switch (failure) {
      case CloudVisionFailure.notConfigured:
        return '云端视觉未配置：路线代理还没有部署，云端视觉不可用，'
            '已降级为本地检测。';
      case CloudVisionFailure.rateLimited:
        return '云端视觉调用太频繁，这次已跳过，继续用本地检测。';
      case CloudVisionFailure.imageTooLarge:
        return '图片太大，云端视觉已跳过，继续用本地检测。';
      case CloudVisionFailure.noImage:
        return '当前没有可用的摄像头画面，云端视觉未执行，继续用本地检测。';
      case CloudVisionFailure.network:
        return '云端视觉网络失败，已降级为本地检测。';
      case CloudVisionFailure.timeout:
        return '云端视觉请求超时，已降级为本地检测。';
      case CloudVisionFailure.upstream:
        return '云端视觉服务出错，已降级为本地检测。';
      case CloudVisionFailure.badResponse:
        return '云端视觉返回无法理解，已降级为本地检测。';
      case null:
        return '云端视觉不可用，已降级为本地检测。';
    }
  }
}
