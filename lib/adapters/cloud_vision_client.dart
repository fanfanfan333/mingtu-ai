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

/// POSTs [body] to [url] and returns the raw response body. No
/// Authorization header exists on the client side -- there is no
/// key here to send.
typedef VisionSender = Future<String> Function(Uri url, String body);

Future<String> _defaultSender(Uri url, String body) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(url);
    request.headers.contentType = ContentType.json;
    request.write(body);
    final HttpClientResponse response = await request.close();
    final String responseBody = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Vision proxy HTTP ${response.statusCode}', uri: url);
    }
    return responseBody;
  } finally {
    client.close();
  }
}

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
  /// Base URL of the project proxy (same one as the route proxy).
  final String proxyBaseUrl;
  final VisionSender sender;
  final ImageDownsampler downsampler;
  final VisionRateLimiter limiter;

  /// Explicit timeout for the proxy request (the proxy adds its
  /// own 20 s upstream timeout server-side).
  final Duration requestTimeout;

  CloudVisionClient({
    required this.proxyBaseUrl,
    VisionSender? sender,
    ImageDownsampler? downsampler,
    VisionRateLimiter? limiter,
    this.requestTimeout = cloudVisionRequestTimeout,
  })  : sender = sender ?? _defaultSender,
        downsampler = downsampler ?? codecDownsampler,
        limiter = limiter ?? VisionRateLimiter();

  bool get isConfigured => proxyBaseUrl.isNotEmpty;

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
    if (!isConfigured) {
      return CloudVisionResult.failed(CloudVisionFailure.notConfigured);
    }
    final Uint8List small;
    try {
      small = await downsampler(imageBytes, cloudVisionMaxDimension);
    } catch (e) {
      return CloudVisionResult.failed(
        CloudVisionFailure.badResponse,
        detail: '图片降采样失败：$e',
      );
    }
    if (small.length > cloudVisionMaxImageBytes) {
      return CloudVisionResult.failed(CloudVisionFailure.imageTooLarge);
    }
    final String base = proxyBaseUrl.endsWith('/')
        ? proxyBaseUrl.substring(0, proxyBaseUrl.length - 1)
        : proxyBaseUrl;
    final Uri url = Uri.parse('$base/vision');
    final String body = jsonEncode(
      buildVisionRequestBody(imageBase64: base64Encode(small), prompt: prompt),
    );
    final String responseBody;
    try {
      responseBody = await sender(url, body).timeout(requestTimeout);
    } on TimeoutException {
      return CloudVisionResult.failed(
        CloudVisionFailure.timeout,
        detail: '请求超过 ${requestTimeout.inSeconds} 秒未返回。',
      );
    } catch (e) {
      return CloudVisionResult.failed(
        CloudVisionFailure.network,
        detail: '$e',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(responseBody);
    } catch (_) {
      return CloudVisionResult.failed(CloudVisionFailure.badResponse);
    }
    if (decoded is! Map<String, Object?>) {
      return CloudVisionResult.failed(CloudVisionFailure.badResponse);
    }
    if (decoded['error'] != null) {
      return CloudVisionResult.failed(
        CloudVisionFailure.upstream,
        detail: '${decoded['error']}',
      );
    }
    return _parseStructured(decoded);
  }

  /// Convenience for callers that do not manage the reservation
  /// themselves: reserve, then describe. A refused reservation
  /// is the rateLimited failure.
  Future<CloudVisionResult> describe({
    required Uint8List imageBytes,
    String prompt = cloudVisionPrompt,
    DateTime? now,
  }) async {
    if (!isConfigured) {
      return CloudVisionResult.failed(CloudVisionFailure.notConfigured);
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
