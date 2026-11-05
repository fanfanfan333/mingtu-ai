import 'dart:convert';

import 'package:mingtu_ai/adapters/bailian_client.dart';
import 'package:mingtu_ai/core/llm_gateway.dart';
import 'package:test/test.dart';

LlmDecision _allowedDecision(LlmGateway gateway) {
  return gateway.requestOnDemand(
    type: LlmCallType.textPlanning,
    reason: 'test',
    localAttempted: true,
    localInsufficient: true,
    estimatedCostRmb: 0.001,
    input: const {},
  );
}

void main() {
  test('missing key returns NOT_CONFIGURED and sends nothing', () async {
    var called = false;
    final client = BailianClient(
      apiKey: '',
      modelId: 'qwen3-vl-flash',
      sender: (url, headers, body) async {
        called = true;
        return '{}';
      },
    );
    final gateway = LlmGateway(budgetCapRmb: 100);
    final result = await client.callText(
      gateway: gateway,
      decision: _allowedDecision(gateway),
      prompt: 'hi',
    );
    expect(result.status, 'NOT_CONFIGURED');
    expect(called, isFalse);
    expect(gateway.calls, 0);
  });

  test('denied gateway decision sends nothing', () async {
    var called = false;
    final client = BailianClient(
      apiKey: 'fake-test-key',
      modelId: 'qwen3-vl-flash',
      sender: (url, headers, body) async {
        called = true;
        return '{}';
      },
    );
    final gateway = LlmGateway(budgetCapRmb: 100);
    final denied = gateway.requestOnDemand(
      type: LlmCallType.textPlanning,
      reason: 'test',
      localAttempted: false,
      localInsufficient: true,
      estimatedCostRmb: 0.001,
      input: const {},
    );
    final result = await client.callText(
      gateway: gateway,
      decision: denied,
      prompt: 'hi',
    );
    expect(result.status, 'DENIED');
    expect(called, isFalse);
  });

  test('allowed call posts to DashScope compatible endpoint and parses text',
      () async {
    Uri? seenUrl;
    Map<String, String>? seenHeaders;
    String? seenBody;
    final client = BailianClient(
      apiKey: 'fake-test-key',
      modelId: 'qwen3-vl-flash',
      sender: (url, headers, body) async {
        seenUrl = url;
        seenHeaders = headers;
        seenBody = body;
        return jsonEncode({
          'choices': [
            {
              'message': {'content': '服务台标识通常包含名称和方向。'}
            }
          ],
        });
      },
    );
    final gateway = LlmGateway(budgetCapRmb: 100);
    final result = await client.callText(
      gateway: gateway,
      decision: _allowedDecision(gateway),
      prompt: 'test prompt',
    );
    expect(result.ok, isTrue);
    expect(result.text, contains('服务台标识'));
    expect(seenUrl.toString(),
        'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions');
    expect(seenHeaders!['Authorization'], 'Bearer fake-test-key');
    expect(jsonDecode(seenBody!)['model'], 'qwen3-vl-flash');
    expect(gateway.calls, 1);
    expect(gateway.spentRmb, closeTo(0.001, 0.000001));
  });

  test('transport error never leaks the key', () async {
    final client = BailianClient(
      apiKey: 'fake-test-key',
      modelId: 'qwen3-vl-flash',
      sender: (url, headers, body) async {
        throw Exception('boom with fake-test-key inside');
      },
    );
    final gateway = LlmGateway(budgetCapRmb: 100);
    final result = await client.callText(
      gateway: gateway,
      decision: _allowedDecision(gateway),
      prompt: 'hi',
    );
    expect(result.status, 'ERROR');
    expect(result.error, isNot(contains('fake-test-key')));
    expect(result.error, contains('[REDACTED]'));
  });
}
