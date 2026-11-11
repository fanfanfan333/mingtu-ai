/// Cloud ASR client for Mingtu AI (press-and-hold fallback).
///
/// Sibling of [CloudVisionClient], same discipline: the app
/// POSTs to the project proxy (`{proxyBaseUrl}/asr`, see
/// server/fc/amap_proxy.py) with ONLY the disposable demo token
/// as a header -- the DashScope key lives server-side. The
/// proxy pins the model (qwen3-asr-flash) and answers either
/// {"text": ...} or a structured {"error": code}; this client
/// maps codes to fixed local failure texts and never copies a
/// response string or an exception into a detail.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/cloud_asr.dart';
import 'cloud_vision_client.dart'
    show VisionSender, defaultProxySender, visionTokenHeader;

/// Proxy error codes that mean "ASR is unavailable right now"
/// (same mapping discipline as the vision client's set, plus
/// the ASR route's own not-configured code).
const Set<String> asrUnavailableErrorCodes = <String>{
  'unauthorized',
  'vision_not_configured',
  'asr_not_configured',
  'body too large',
};

/// Outcome of one transcription attempt: exactly one of
/// [text] / [failure] is non-null.
class CloudAsrResult {
  final String? text;
  final AsrFailure? failure;

  const CloudAsrResult._({this.text, this.failure});

  factory CloudAsrResult.ok(String text) => CloudAsrResult._(text: text);

  factory CloudAsrResult.failed(AsrFailure failure) =>
      CloudAsrResult._(failure: failure);

  bool get ok => failure == null && text != null;

  /// The fixed local detail for a failure (never null when
  /// [failure] is set).
  String get detail => failure == null ? '' : asrFailureDetail(failure!);
}

class CloudAsrClient {
  /// Base URL of the ASR function (the same FC deployment as
  /// vision; see AppConfig.asrProxyUrl's fallback rule). MUST
  /// be https -- anything else is refused.
  final String proxyBaseUrl;

  /// Disposable demo token sent as [visionTokenHeader] (the
  /// /asr route shares the vision token check server-side).
  final String demoToken;
  final VisionSender sender;
  final Duration requestTimeout;

  CloudAsrClient({
    required this.proxyBaseUrl,
    this.demoToken = '',
    VisionSender? sender,
    this.requestTimeout = asrRequestTimeout,
  }) : sender = sender ?? defaultProxySender;

  bool get hasProxyUrl => proxyBaseUrl.isNotEmpty;

  /// True only for a non-empty HTTPS base URL.
  bool get isConfigured =>
      proxyBaseUrl.isNotEmpty && proxyBaseUrl.startsWith('https://');

  /// Transcribe one recorded WAV clip. Never throws: every
  /// failure is a [CloudAsrResult] with a fixed local detail.
  Future<CloudAsrResult> transcribe(Uint8List wavBytes) async {
    if (!hasProxyUrl || !isConfigured) {
      return CloudAsrResult.failed(AsrFailure.notConfigured);
    }
    if (wavBytes.length > asrMaxAudioBytes) {
      return CloudAsrResult.failed(AsrFailure.tooLarge);
    }
    final String base = proxyBaseUrl.endsWith('/')
        ? proxyBaseUrl.substring(0, proxyBaseUrl.length - 1)
        : proxyBaseUrl;
    final Uri url = Uri.parse('$base/asr');
    final String body =
        jsonEncode(buildAsrRequestBody(audioBase64: base64Encode(wavBytes)));
    if (body.length > asrMaxBodyBytes) {
      return CloudAsrResult.failed(AsrFailure.tooLarge);
    }
    final Map<String, String> headers = demoToken.isEmpty
        ? const <String, String>{}
        : <String, String>{visionTokenHeader: demoToken};
    final String responseBody;
    try {
      responseBody = await sender(url, body, headers).timeout(requestTimeout);
    } on TimeoutException {
      return CloudAsrResult.failed(AsrFailure.timeout);
    } catch (_) {
      // Fixed text only (see CloudVisionClient): a transport
      // exception can embed the request URL.
      return CloudAsrResult.failed(AsrFailure.network);
    }
    final Object? decodedRaw;
    try {
      decodedRaw = jsonDecode(responseBody);
    } catch (_) {
      return CloudAsrResult.failed(AsrFailure.badResponse);
    }
    if (decodedRaw is! Map<String, Object?>) {
      return CloudAsrResult.failed(AsrFailure.badResponse);
    }
    final Object? errorCode = decodedRaw['error'];
    if (errorCode != null) {
      if (errorCode == 'rate_limited') {
        return CloudAsrResult.failed(AsrFailure.rateLimited);
      }
      if (errorCode is String &&
          asrUnavailableErrorCodes.contains(errorCode)) {
        return CloudAsrResult.failed(AsrFailure.unavailable);
      }
      return CloudAsrResult.failed(AsrFailure.badResponse);
    }
    final String? text = parseAsrResponse(decodedRaw);
    if (text == null) {
      return CloudAsrResult.failed(AsrFailure.badResponse);
    }
    return CloudAsrResult.ok(text);
  }
}
