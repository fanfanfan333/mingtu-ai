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
/// Pipeline per call, in order: configured? -> rate limiter ->
/// downsample -> payload cap -> POST -> parse. Any failure returns
/// a [CloudVisionResult] whose speechText announces the
/// degradation to local detection; this client never throws to
/// the UI and never retries on its own.
library;

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

  CloudVisionClient({
    required this.proxyBaseUrl,
    VisionSender? sender,
    ImageDownsampler? downsampler,
    VisionRateLimiter? limiter,
  })  : sender = sender ?? _defaultSender,
        downsampler = downsampler ?? codecDownsampler,
        limiter = limiter ?? VisionRateLimiter();

  bool get isConfigured => proxyBaseUrl.isNotEmpty;

  /// Describe one frame. [now] is injectable for tests.
  Future<CloudVisionResult> describe({
    required Uint8List imageBytes,
    String prompt = cloudVisionPrompt,
    DateTime? now,
  }) async {
    if (!isConfigured) {
      return CloudVisionResult.failed(CloudVisionFailure.notConfigured);
    }
    if (!limiter.tryAcquire(now ?? DateTime.now())) {
      return CloudVisionResult.failed(CloudVisionFailure.rateLimited);
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
      responseBody = await sender(url, body);
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
    final Object? choices = decoded['choices'];
    if (choices is List && choices.isNotEmpty) {
      final Object? first = choices.first;
      if (first is Map<String, Object?>) {
        final Object? message = first['message'];
        if (message is Map<String, Object?>) {
          final Object? content = message['content'];
          if (content is String && content.trim().isNotEmpty) {
            return CloudVisionResult.ok(content.trim());
          }
        }
      }
    }
    return CloudVisionResult.failed(CloudVisionFailure.badResponse);
  }
}
