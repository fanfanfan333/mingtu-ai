import 'package:test/test.dart';
import 'package:mingtu_ai/core/llm_gateway.dart';

void main() {
  test('local-first: cloud denied if local not attempted', () {
    final g = LlmGateway(budgetCapRmb: 100);
    final d = g.requestOnDemand(
      type: LlmCallType.vision,
      reason: 'test',
      localAttempted: false,
      localInsufficient: true,
      estimatedCostRmb: 0.01,
      input: const {},
    );
    expect(d.allowed, isFalse);
  });

  test('budget cap denies over-cap calls', () {
    final g = LlmGateway(budgetCapRmb: 1.0);
    g.recordCall(0.99);
    final d = g.requestOnDemand(
      type: LlmCallType.vision,
      reason: 'test',
      localAttempted: true,
      localInsufficient: true,
      estimatedCostRmb: 0.02,
      input: const {},
    );
    expect(d.allowed, isFalse);
    expect(g.remainingRmb, closeTo(0.01, 0.0001));
  });

  test('expensive foreign model ids are blocked', () {
    expect(() => LlmGateway(modelId: 'claude-opus-4'), throwsArgumentError);
    expect(() => LlmGateway(modelId: 'gpt-5'), throwsArgumentError);
    expect(() => LlmGateway(modelId: 'gemini-2.5-pro'), throwsArgumentError);
    expect(() => LlmGateway(modelId: 'qwen3-vl-flash'), returnsNormally);
  });
}
