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

/// The disclaimer spoken with EVERY cloud-vision announcement
/// (starting, result, failure): the description is a low-frequency
/// reference only and never a basis for deciding it is safe to
/// walk. The exact wording is the product requirement.
const String cloudVisionDisclaimer = '仅供参考，请以盲杖和环境声音为准。';

/// Spoken when an on-demand capture starts, so the user is never
/// left in silence while the single frame is captured, shrunk and
/// sent: Chinese, states what is happening, carries the disclaimer.
const String cloudVisionStartingSpeech =
    '正在识别前方画面，请稍等。提醒：$cloudVisionDisclaimer';

/// The prompt sent with every frame (the proxy pins the same
/// text server-side, replacing whatever a client sent). The
/// model must answer with JSON ONLY, using the enum sets below:
/// the app never speaks model prose -- it generates its Chinese
/// announcement from the structured result with local templates,
/// so an upstream sentence (including any safety claim) has no
/// path to the user's ears.
const String cloudVisionPrompt = '只输出一个 JSON 对象，不要输出任何其他文字：'
    '{"scene": 场景, "obstacles": [{"type": 类型, '
    '"direction": 方位, "proximity": 远近, '
    '"confidence": 0到1的小数}]}。'
    '场景只能是：室内、室外、楼梯间、电梯内、路口、不确定。'
    '类型只能是：行人、自行车、电动车、汽车、公交车、柱子、'
    '台阶、楼梯、墙壁、门、桌子、椅子、树木、护栏、指示牌、其他。'
    '方位只能是：正前方、左前方、右前方、左侧、右侧、后方。'
    '远近只能是：很近、较近、较远。'
    '不要做任何通行判断，不要输出 JSON 以外的任何内容。';

/// Enum domains for the structured vision result. The proxy
/// coerces to the same sets server-side; the client coerces
/// AGAIN on receipt (a rogue or buggy proxy cannot smuggle an
/// unknown value into the spoken template either).
const Set<String> visionScenes = <String>{
  '室内',
  '室外',
  '楼梯间',
  '电梯内',
  '路口',
  '不确定',
};
const Set<String> visionObstacleTypes = <String>{
  '行人',
  '自行车',
  '电动车',
  '汽车',
  '公交车',
  '柱子',
  '台阶',
  '楼梯',
  '墙壁',
  '门',
  '桌子',
  '椅子',
  '树木',
  '护栏',
  '指示牌',
  '其他',
};
const Set<String> visionDirections = <String>{
  '正前方',
  '左前方',
  '右前方',
  '左侧',
  '右侧',
  '后方',
};
const Set<String> visionProximities = <String>{'很近', '较近', '较远'};

/// One recognised obstacle, enum fields only.
class VisionObstacle {
  final String type;
  final String direction;
  final String proximity;
  final double confidence;
  const VisionObstacle({
    required this.type,
    required this.direction,
    required this.proximity,
    required this.confidence,
  });
}

/// A structured scene: an enum scene label plus enum obstacles.
/// This is ALL the cloud is allowed to tell the app.
class VisionScene {
  final String scene;
  final List<VisionObstacle> obstacles;
  const VisionScene({required this.scene, required this.obstacles});
}

/// Generate the spoken Chinese for a structured scene, from the
/// enum fields ONLY. Rules enforced by construction:
/// - no obstacles -> the exact "未识别到明显障碍" sentence with
///   the disclaimer; it never upgrades to "safe to walk";
/// - obstacles -> direction + proximity + type phrases, at most
///   three spoken, then the disclaimer and the unverified note;
/// - safe-passage wording (the Chinese equivalents of "safe", "you can pass", "you can walk", "no danger") never appears:
///   this template has no way to produce a safety judgement.
String visionSceneSpeechText(VisionScene scene) {
  if (scene.obstacles.isEmpty) {
    return '云端视觉辅助：未识别到明显障碍，$cloudVisionDisclaimer';
  }
  final List<String> parts = <String>[
    for (final VisionObstacle o in scene.obstacles.take(3))
      '${o.direction}${o.proximity}处有${o.type}',
  ];
  final String more =
      scene.obstacles.length > 3 ? '等${scene.obstacles.length}处' : '';
  final String scenePart = scene.scene == '不确定' ? '' : '识别场景为${scene.scene}。';
  return '云端视觉辅助：$scenePart${parts.join('；')}$more。'
      '提醒：$cloudVisionDisclaimer'
      '这只是低频辅助描述，未经验证，不能当作是否能通行的判断。';
}

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

  /// Peek without taking the slot: would a call at [now] be
  /// allowed? The on-demand flow uses this BEFORE opening the
  /// camera, so a rate-limited request never captures a frame it
  /// would only throw away.
  bool isAvailable(DateTime now) {
    final DateTime? last = _lastCallAt;
    return last == null || now.difference(last) >= minInterval;
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

  /// The model output could not be parsed into the structured
  /// enum result (prose, unknown values, wrong shapes).
  uncertain,

  /// A recognition is already in flight (single-flight guard).
  busy,

  /// The vision service refused or is unavailable: wrong or
  /// missing demo token, rate cap reached, or the function is
  /// not configured server-side. Announced as 识图暂时不可用.
  unavailable,
}

class CloudVisionResult {
  final VisionScene? scene;
  final CloudVisionFailure? failure;
  final String? detail;

  const CloudVisionResult._({this.scene, this.failure, this.detail});

  factory CloudVisionResult.ok(VisionScene scene) =>
      CloudVisionResult._(scene: scene);

  factory CloudVisionResult.failed(
    CloudVisionFailure failure, {
    String? detail,
  }) =>
      CloudVisionResult._(failure: failure, detail: detail);

  bool get ok => failure == null && scene != null;

  /// What the user hears. A success is generated locally from
  /// enum fields (see visionSceneSpeechText) -- never model
  /// prose. Every failure announces the degradation back to
  /// local detection; nothing fails silently. [busy] is a
  /// concurrency notice, not a failure.
  String get speechText {
    if (ok) return visionSceneSpeechText(scene!);
    switch (failure) {
      case CloudVisionFailure.notConfigured:
        return '识图未配置：云端识图代理地址还没有配置，'
            '已降级为本地检测。提醒：$cloudVisionDisclaimer';
      case CloudVisionFailure.rateLimited:
        return '云端视觉调用太频繁，这次已跳过，继续用本地检测。提醒：$cloudVisionDisclaimer';
      case CloudVisionFailure.imageTooLarge:
        return '图片太大，云端视觉已跳过，继续用本地检测。提醒：$cloudVisionDisclaimer';
      case CloudVisionFailure.noImage:
        return '当前没有可用的摄像头画面，云端视觉未执行，继续用本地检测。提醒：$cloudVisionDisclaimer';
      case CloudVisionFailure.network:
        return '云端视觉网络失败，已降级为本地检测。提醒：$cloudVisionDisclaimer';
      case CloudVisionFailure.timeout:
        return '云端视觉请求超时，已降级为本地检测。提醒：$cloudVisionDisclaimer';
      case CloudVisionFailure.upstream:
        return '云端视觉服务出错，已降级为本地检测。提醒：$cloudVisionDisclaimer';
      case CloudVisionFailure.badResponse:
        return '云端视觉返回无法理解，已降级为本地检测。提醒：$cloudVisionDisclaimer';
      case CloudVisionFailure.uncertain:
        return '云端视觉识别不确定，已降级为本地检测。提醒：$cloudVisionDisclaimer';
      case CloudVisionFailure.busy:
        return '正在识别，请稍候。';
      case CloudVisionFailure.unavailable:
        return '识图暂时不可用，已降级为本地检测。提醒：$cloudVisionDisclaimer';
      case null:
        return '云端视觉不可用，已降级为本地检测。提醒：$cloudVisionDisclaimer';
    }
  }
}
