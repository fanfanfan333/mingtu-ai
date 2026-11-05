/// Alibaba Cloud Bailian (DashScope) client for Mingtu AI.
///
/// Security rules, enforced by construction:
/// - The API key is NEVER hardcoded, NEVER read from a committed file and
///   NEVER logged, printed or returned in any result or error string.
///   It only arrives from `--dart-define=MINGTU_DASHSCOPE_API_KEY=...`
///   on the user's own machine/phone (see AppConfig). The key only
///   authenticates to the user's own Bailian account; a student voucher
///   or credit is account-level in the Bailian console and is not
///   transferred to, or through, this code or Muse.
/// - No network call happens unless the caller first obtains an
///   ALLOWING [LlmDecision] from [LlmGateway] (local-first, on-demand,
///   budget-capped). A denied decision, a missing key or an
///   unaffordable estimate all return without touching the network.
/// - The default transport uses dart:io HttpClient and is only used on
///   platforms that support it. Tests inject a fake [BailianSender] so
///   no test ever makes a real call or spends anything.
///
/// Endpoint: DashScope OpenAI-compatible mode.
///   https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions
/// The model id must match exactly what the Bailian console shows for
/// the user's account/region (for example qwen3-vl-flash). This file
/// does not hardcode any provider pricing; the caller supplies the
/// estimate through the gateway decision, as in llm_gateway.dart.
library;

import 'dart:convert';
import 'dart:io';

import '../core/llm_gateway.dart';

/// Sends one POST and returns the raw response body. The [headers]
/// argument will contain the Authorization header; a sender must never
/// log it. On a non-2xx status the sender should throw with the status
/// only, not with the request headers.
typedef BailianSender = Future<String> Function(
  Uri url,
  Map<String, String> headers,
  String body,
);

Future<String> _defaultSender(
  Uri url,
  Map<String, String> headers,
  String body,
) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(url);
    headers.forEach(request.headers.set);
    request.write(body);
    final HttpClientResponse response = await request.close();
    final String responseBody =
        await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Bailian HTTP ${response.statusCode}',
        uri: url,
      );
    }
    return responseBody;
  } finally {
    client.close();
  }
}

class BailianResult {
  /// 'ok' | 'NOT_CONFIGURED' | 'DENIED' | 'ERROR'
  final String status;
  final String? text;
  final String? error;
  const BailianResult({required this.status, this.text, this.error});

  bool get ok => status == 'ok';
}

class BailianClient {
  final String apiKey;
  final String modelId;
  final String baseUrl;
  final BailianSender sender;

  BailianClient({
    required this.apiKey,
    required this.modelId,
    this.baseUrl = 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    BailianSender? sender,
  }) : sender = sender ?? _defaultSender;

  bool get isConfigured => apiKey.isNotEmpty;

  String _redact(String value) =>
      apiKey.isEmpty ? value : value.replaceAll(apiKey, '[REDACTED]');

  /// One on-demand text call, gated by [decision] and [gateway].
  ///
  /// [prompt] is the user/task text only. No image bytes are sent by
  /// this method; a future vision method may add a single frame only
  /// under the same gating, never a continuous stream.
  Future<BailianResult> callText({
    required LlmGateway gateway,
    required LlmDecision decision,
    required String prompt,
  }) async {
    if (!isConfigured) {
      return const BailianResult(
        status: 'NOT_CONFIGURED',
        error: '未提供百炼 API Key（--dart-define），未调用云端。',
      );
    }
    if (!decision.allowed) {
      return BailianResult(
        status: 'DENIED',
        error: '网关未批准：${decision.reason}',
      );
    }
    final Object? estimated = decision.payload?['estimatedCostRmb'];
    final double estimatedCostRmb =
        estimated is num ? estimated.toDouble() : 0.001;
    if (!gateway.canAfford(estimatedCostRmb)) {
      return const BailianResult(
        status: 'DENIED',
        error: '预算上限不足，未调用云端。',
      );
    }
    final Uri url = Uri.parse('$baseUrl/chat/completions');
    final String body = jsonEncode(<String, Object>{
      'model': modelId,
      'messages': <Object>[
        <String, String>{'role': 'user', 'content': prompt},
      ],
    });
    try {
      final String responseBody = await sender(
        url,
        <String, String>{
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body,
      );
      final Object? decoded = jsonDecode(responseBody);
      if (decoded is! Map<String, Object?>) {
        return const BailianResult(
          status: 'ERROR',
          error: '百炼返回不是预期的 JSON 对象。',
        );
      }
      final Object? choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) {
        return const BailianResult(
          status: 'ERROR',
          error: '百炼返回没有 choices。',
        );
      }
      final Object? first = choices.first;
      if (first is! Map<String, Object?>) {
        return const BailianResult(
          status: 'ERROR',
          error: '百炼返回的 choice 格式不对。',
        );
      }
      final Object? message = first['message'];
      if (message is! Map<String, Object?> ||
          message['content'] is! String) {
        return const BailianResult(
          status: 'ERROR',
          error: '百炼返回没有文本内容。',
        );
      }
      gateway.recordCall(estimatedCostRmb);
      return BailianResult(
        status: 'ok',
        text: message['content'] as String,
      );
    } catch (e) {
      // Never let a transport error leak the key, even if a custom
      // sender accidentally included it in its message.
      return BailianResult(status: 'ERROR', error: _redact(e.toString()));
    }
  }
}
