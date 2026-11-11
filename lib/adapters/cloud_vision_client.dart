/// Cloud vision client for Mingtu AI (low-frequency assist).
///
/// The app NEVER calls DashScope directly and NEVER holds its key.
/// It POSTs one downsampled frame to the project proxy
/// (`{proxyBaseUrl}/vision`, see server/amap_proxy.py); the proxy
/// holds the DashScope key in its server environment and forwards
/// to the Beijing DashScope OpenAI-compatible endpoint -- the same
/// compatible-mode configuration as the Bailian text client
/// (https://dashscope.aliyuncs.com/compatible-mode/v1).
///
/// Pipeline: the caller first RESERVES the rate-limit slot
/// ([tryReserve]) BEFORE opening the camera, then hands the one
/// captured frame to [describeReserved], which runs: downsample
/// -> payload cap -> POST -> structured parse. The proxy answers
/// with enum-only JSON (scene / obstacles / parsed); this client
/// re-coerces every value against the same enum sets before
/// building a [VisionScene], so model prose never reaches the
/// app's speech templates. Any failure returns a
/// [CloudVisionResult] whose speechText announces the
/// degradation to local detection; this client never throws to
/// the UI and never retries on its own.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../core/cloud_vision.dart';
import '../core/cloud_vision_hazard.dart';

/// POSTs [body] to [url] with [headers] and returns the raw
/// response body for ANY HTTP status: the proxy answers guard
/// rejections (401/429/503) with structured JSON error bodies,
/// and the client maps those codes itself. There is NO Bailian
/// key on the client side -- the only credential-shaped header
/// is the disposable demo token.
typedef VisionSender = Future<String> Function(
  Uri url,
  String body,
  Map<String, String> headers,
);

/// The shared default transport (JSON POST via dart:io).
/// Public so sibling clients (cloud ASR) reuse the exact same
/// sender instead of duplicating transport code.
Future<String> defaultProxySender(
  Uri url,
  String body,
  Map<String, String> headers,
) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(url);
    request.headers.contentType = ContentType.json;
    headers.forEach(request.headers.set);
    request.write(body);
    final HttpClientResponse response = await request.close();
    final String responseBody = await response.transform(utf8.decoder).join();
    return responseBody;
  } finally {
    client.close();
  }
}

/// Header that carries the disposable demo token to the vision
/// function. The token is not a Bailian key; the server checks
/// it before spending anything and it is revoked after the demo.
const String visionTokenHeader = 'X-Mingtu-Vision-Token';

/// Structured proxy error codes that mean "vision is
/// unavailable right now" (token rejected, rate cap reached,
/// or the function itself is not configured server-side) --
/// announced to the user as 识图暂时不可用.
const Set<String> visionUnavailableErrorCodes = <String>{
  'unauthorized',
  'vision_not_configured',
  // The proxy answers an over-3MiB request body with HTTP 413
  // and this code; the sender surfaces only the body, so the
  // 413 maps here -- the user hears "识图暂时不可用"
  // (unavailable), not a generic service error.
  'body too large',
};

/// Downsamples encoded image [bytes] so the longest edge is at
/// most [maxDimension], re-encoding as PNG.
typedef ImageDownsampler = Future<Uint8List> Function(
  Uint8List bytes,
  int maxDimension,
);

/// Real downsampler on dart:ui's codec: decode once to learn the
/// size, and only re-decode at the target size when the image is
/// actually too large (small images pass through untouched).
Future<Uint8List> codecDownsampler(Uint8List bytes, int maxDimension) async {
  final ui.Codec probe = await ui.instantiateImageCodec(bytes);
  final ui.FrameInfo first = await probe.getNextFrame();
  final int w = first.image.width;
  final int h = first.image.height;
  first.image.dispose();
  probe.dispose();
  final ({int width, int height}) target =
      computeDownsampledSize(w, h, maxDimension: maxDimension);
  if (target.width == w && target.height == h) return bytes;
  final ui.Codec codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: target.width,
    targetHeight: target.height,
  );
  final ui.FrameInfo frame = await codec.getNextFrame();
  final ByteData? png =
      await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  codec.dispose();
  if (png == null) return bytes;
  return png.buffer.asUint8List();
}

class CloudVisionClient {
  /// Base URL of the vision function (Alibaba Cloud Function
  /// Compute). MUST be https -- anything else is refused.
  final String proxyBaseUrl;

  /// Disposable demo token sent as [visionTokenHeader]. Empty
  /// means no token is sent and the server will refuse.
  final String demoToken;
  final VisionSender sender;
  final ImageDownsampler downsampler;
  final VisionRateLimiter limiter;

  /// Explicit timeout for the proxy request (the proxy adds its
  /// own 20 s upstream timeout server-side).
  final Duration requestTimeout;

  CloudVisionClient({
    required this.proxyBaseUrl,
    this.demoToken = '',
    VisionSender? sender,
    ImageDownsampler? downsampler,
    VisionRateLimiter? limiter,
    this.requestTimeout = cloudVisionRequestTimeout,
  })  : sender = sender ?? defaultProxySender,
        downsampler = downsampler ?? codecDownsampler,
        limiter = limiter ?? VisionRateLimiter();

  /// True only for a non-empty HTTPS base URL. An http:// (or
  /// otherwise non-https) address is refused outright.
  bool get isConfigured =>
      proxyBaseUrl.isNotEmpty && proxyBaseUrl.startsWith('https://');

  bool get hasProxyUrl => proxyBaseUrl.isNotEmpty;

  /// Reserve the rate-limit slot for a call at [now], BEFORE
  /// any camera is opened: a refused reservation means no frame
  /// is captured at all. Returns false when not configured or
  /// when the previous call is too recent. The slot stays taken
  /// even if the subsequent capture fails (retry protection).
  bool tryReserve(DateTime? now) =>
      isConfigured && limiter.tryAcquire(now ?? DateTime.now());

  /// Describe one frame whose slot was already reserved via
  /// [tryReserve]. [now] is injectable for tests.
  Future<CloudVisionResult> describeReserved({
    required Uint8List imageBytes,
    String prompt = cloudVisionPrompt,
  }) async {
    if (!hasProxyUrl) {
      return CloudVisionResult.failed(CloudVisionFailure.notConfigured);
    }
    if (!isConfigured) {
      return CloudVisionResult.failed(
        CloudVisionFailure.notConfigured,
        detail: '识图代理地址不是 https，已拒绝使用。',
      );
    }
    final ({Map<String, Object?>? decoded, CloudVisionResult? failure}) reply =
        await _decodedResponse(
            imageBytes: imageBytes, prompt: prompt, task: null);
    if (reply.failure != null) return reply.failure!;
    return _parseStructured(reply.decoded!);
  }

  /// Hazard-mode counterpart of [describeReserved] (the slot
  /// must already be reserved): sends the strict-JSON hazard
  /// task and parses the answer with the hazard validator.
  /// Same transport, same fixed-text failure discipline.
  Future<HazardScanOutcome> describeHazardReserved({
    required Uint8List imageBytes,
  }) async {
    if (!hasProxyUrl || !isConfigured) {
      return const HazardScanOutcome.failed(CloudVisionFailure.notConfigured);
    }
    final ({Map<String, Object?>? decoded, CloudVisionResult? failure}) reply =
        await _decodedResponse(
            imageBytes: imageBytes,
            prompt: cloudHazardPrompt,
            task: 'hazard_scan');
    if (reply.failure != null) {
      return HazardScanOutcome.failed(reply.failure!.failure!);
    }
    // Compatibility rule (new client against an older FC):
    // a response that is not a conforming hazard payload --
    // the old FC's scene shape (which HAS a "parsed" flag
    // but none of the hazard keys), or any unrecognised
    // shape -- is treated as UNKNOWN, never as an error and
    // never as data: parseHazardAssessment collapses every
    // such body to HazardAssessment.unknown (parsed ==
    // false), and the caller announces the fixed downgrade
    // sentence for it. Structured proxy errors never reach
    // this line; they were mapped to failures inside
    // _decodedResponse, and that mapping is unchanged.
    return HazardScanOutcome.ok(parseHazardAssessment(reply.decoded));
  }

  /// Crossing-mode counterpart of [describeHazardReserved]
  /// (M2 section 3.3; the slot must already be reserved):
  /// sends task=crossing_info and parses the answer with
  /// the strict crossing validator. A nonconforming body
  /// collapses to [CrossingInfo.unknown] inside the
  /// outcome -- unknown data, never an error and never
  /// prose; structured proxy errors were already mapped
  /// to failures by the shared transport.
  Future<CrossingScanOutcome> describeCrossingReserved({
    required Uint8List imageBytes,
  }) async {
    if (!hasProxyUrl || !isConfigured) {
      return const CrossingScanOutcome.failed(
          CloudVisionFailure.notConfigured);
    }
    final ({Map<String, Object?>? decoded, CloudVisionResult? failure}) reply =
        await _decodedResponse(
            imageBytes: imageBytes,
            prompt: cloudCrossingPrompt,
            task: 'crossing_info');
    if (reply.failure != null) {
      return CrossingScanOutcome.failed(reply.failure!.failure!);
    }
    return CrossingScanOutcome.ok(parseCrossingInfo(reply.decoded));
  }

  /// Detour-mode counterpart (M2 section 3.3): sends
  /// task=detour and parses with the strict detour
  /// validator. The answer is evidence only; see
  /// [DetourInfo].
  Future<DetourScanOutcome> describeDetourReserved({
    required Uint8List imageBytes,
  }) async {
    if (!hasProxyUrl || !isConfigured) {
      return const DetourScanOutcome.failed(CloudVisionFailure.notConfigured);
    }
    final ({Map<String, Object?>? decoded, CloudVisionResult? failure}) reply =
        await _decodedResponse(
            imageBytes: imageBytes,
            prompt: cloudDetourPrompt,
            task: 'detour');
    if (reply.failure != null) {
      return DetourScanOutcome.failed(reply.failure!.failure!);
    }
    return DetourScanOutcome.ok(parseDetourInfo(reply.decoded));
  }

  /// Shared transport for the vision modes: downscale,
  /// POST, decode, and map a structured proxy error to a
  /// fixed-text failure. Returns exactly one of the two
  /// record fields.
  Future<({Map<String, Object?>? decoded, CloudVisionResult? failure})>
      _decodedResponse({
    required Uint8List imageBytes,
    required String prompt,
    required String? task,
  }) async {
    final Uint8List small;
    try {
      small = await downsampler(imageBytes, cloudVisionMaxDimension);
    } catch (e) {
      return (
        decoded: null,
        failure: CloudVisionResult.failed(
          CloudVisionFailure.badResponse,
          detail: '图片处理失败。',
        )
      );
    }
    if (small.length > cloudVisionMaxImageBytes) {
      return (
        decoded: null,
        failure: CloudVisionResult.failed(CloudVisionFailure.imageTooLarge)
      );
    }
    final String base = proxyBaseUrl.endsWith('/')
        ? proxyBaseUrl.substring(0, proxyBaseUrl.length - 1)
        : proxyBaseUrl;
    final Uri url = Uri.parse('$base/vision');
    final String body = jsonEncode(
      buildVisionRequestBody(
          imageBase64: base64Encode(small), prompt: prompt, task: task),
    );
    final Map<String, String> headers = demoToken.isEmpty
        ? const <String, String>{}
        : <String, String>{visionTokenHeader: demoToken};
    final String responseBody;
    try {
      responseBody = await sender(url, body, headers).timeout(requestTimeout);
    } on TimeoutException {
      return (
        decoded: null,
        failure: CloudVisionResult.failed(
          CloudVisionFailure.timeout,
          detail: '请求超过 ${requestTimeout.inSeconds} 秒未返回。',
        )
      );
    } catch (_) {
      // Fixed text ONLY: a transport exception can embed the
      // request URL or other request details; nothing from the
      // exception may reach the result detail, the speech or
      // the logs.
      return (
        decoded: null,
        failure: CloudVisionResult.failed(
          CloudVisionFailure.network,
          detail: '网络请求失败，未收到识图服务响应。',
        )
      );
    }
    final Object? decodedRaw;
    try {
      decodedRaw = jsonDecode(responseBody);
    } catch (_) {
      return (
        decoded: null,
        failure: CloudVisionResult.failed(CloudVisionFailure.badResponse)
      );
    }
    if (decodedRaw is! Map<String, Object?>) {
      return (
        decoded: null,
        failure: CloudVisionResult.failed(CloudVisionFailure.badResponse)
      );
    }
    final Map<String, Object?> decoded = decodedRaw;
    final Object? errorCode = decoded['error'];
    if (errorCode != null) {
      // ONLY the whitelisted codes map to a failure kind, and
      // the detail is ALWAYS a fixed local text: an arbitrary
      // server error string is attacker-controlled content (a
      // compromised or hostile upstream could echo credentials
      // or URLs into it) and must never reach the detail, the
      // speech or the logs. rate_limited maps to its own
      // failure so callers can apply the announce-once +
      // exponential-backoff policy for 429s.
      if (errorCode == 'rate_limited') {
        return (
          decoded: null,
          failure: CloudVisionResult.failed(
            CloudVisionFailure.rateLimited,
            detail: '云端识图请求过于频繁。',
          )
        );
      }
      if (errorCode is String &&
          visionUnavailableErrorCodes.contains(errorCode)) {
        return (
          decoded: null,
          failure: CloudVisionResult.failed(
            CloudVisionFailure.unavailable,
            detail: '识图暂时不可用（服务端拒绝或未配置）。',
          )
        );
      }
      return (
        decoded: null,
        failure: CloudVisionResult.failed(
          CloudVisionFailure.upstream,
          detail: '云端识图服务返回了未识别的错误。',
        )
      );
    }
    return (decoded: decoded, failure: null);
  }

  /// Convenience for callers that do not manage the reservation
  /// themselves: reserve, then describe. A refused reservation
  /// is the rateLimited failure.
  Future<CloudVisionResult> describe({
    required Uint8List imageBytes,
    String prompt = cloudVisionPrompt,
    DateTime? now,
  }) async {
    if (!hasProxyUrl) {
      return CloudVisionResult.failed(CloudVisionFailure.notConfigured);
    }
    if (!isConfigured) {
      return CloudVisionResult.failed(
        CloudVisionFailure.notConfigured,
        detail: '识图代理地址不是 https，已拒绝使用。',
      );
    }
    if (!tryReserve(now)) {
      return CloudVisionResult.failed(CloudVisionFailure.rateLimited);
    }
    return describeReserved(imageBytes: imageBytes, prompt: prompt);
  }

  /// Build a [CloudVisionResult] from the proxy's structured
  /// body, re-coercing every value client-side: unknown enums
  /// are dropped here too, `parsed: false` (or a missing flag)
  /// is the uncertain failure, and no string from the response
  /// is ever copied into a result.
  CloudVisionResult _parseStructured(Map<String, Object?> decoded) {
    if (decoded['parsed'] != true) {
      return CloudVisionResult.failed(CloudVisionFailure.uncertain);
    }
    final Object? sceneRaw = decoded['scene'];
    final String scene = sceneRaw is String && visionScenes.contains(sceneRaw)
        ? sceneRaw
        : '不确定';
    final List<VisionObstacle> obstacles = <VisionObstacle>[];
    final Object? rawList = decoded['obstacles'];
    if (rawList is List) {
      for (final Object? item in rawList) {
        if (item is! Map<String, Object?>) continue;
        final Object? type = item['type'];
        final Object? direction = item['direction'];
        final Object? proximity = item['proximity'];
        final Object? confidence = item['confidence'];
        if (type is! String || !visionObstacleTypes.contains(type)) {
          continue;
        }
        if (direction is! String || !visionDirections.contains(direction)) {
          continue;
        }
        if (proximity is! String || !visionProximities.contains(proximity)) {
          continue;
        }
        obstacles.add(VisionObstacle(
          type: type,
          direction: direction,
          proximity: proximity,
          confidence:
              confidence is num ? confidence.toDouble().clamp(0.0, 1.0) : 0.0,
        ));
        if (obstacles.length >= 5) break;
      }
    }
    return CloudVisionResult.ok(
      VisionScene(scene: scene, obstacles: obstacles),
    );
  }
}
