/// Unified LLM gateway for Mingtu AI v0.1.
///
/// Design, all enforced here:
/// - Local-first: an on-demand cloud call is only allowed after a local
///   attempt (local detection / OCR / rules) has been tried and found
///   insufficient. The gateway does not make the network call itself in
///   v0.1; it returns an allow/deny decision and a request payload that a
///   future adapter may send. The live client is NOT_IMPLEMENTED.
/// - On-demand only: there is no continuous video streaming to the cloud
///   in this design. Cloud calls are per-trigger, per-frame at most.
/// - Domestic low-cost Flash/Lite models only by configuration. The
///   constructor rejects model ids that name expensive foreign models
///   (Claude / GPT / Gemini paid models). This is a guardrail, not a
///   claim about any provider's official pricing.
/// - Hard budget cap in RMB. Once spent + estimated cost would exceed the
///   cap, the call is denied and the caller must degrade locally.
/// - Prices are NOT hardcoded as official prices. Callers supply the
///   per-million-token prices they read from the provider console at
///   call time; the gateway only does the arithmetic and the cap check.
enum LlmCallType { vision, textPlanning, ocrAssist }

class LlmDecision {
  final bool allowed;
  final String reason;
  final Map<String, Object?>? payload;
  const LlmDecision({required this.allowed, required this.reason, this.payload});
}

class LlmGateway {
  final String modelId;
  final double budgetCapRmb;
  double spentRmb = 0.0;
  int calls = 0;

  static const List<String> _blockedSubstrings = [
    'claude',
    'gpt',
    'gemini',
    'opus',
  ];

  LlmGateway({
    // Default is a placeholder domestic low-cost style id. It is
    // configurable and must be replaced with the exact model id shown in
    // the provider console at integration time.
    this.modelId = 'qwen3-vl-flash',
    this.budgetCapRmb = 100.0,
  }) {
    final lower = modelId.toLowerCase();
    for (final blocked in _blockedSubstrings) {
      if (lower.contains(blocked)) {
        throw ArgumentError(
          'Model id "$modelId" is blocked in v0.1: expensive foreign '
          'models are out of scope for the very-low-RMB budget.',
        );
      }
    }
    if (budgetCapRmb <= 0) {
      throw ArgumentError('budgetCapRmb must be > 0');
    }
  }

  static double estimateCostRmb({
    required int inputTokens,
    required int outputTokens,
    required double inputPricePerMillionRmb,
    required double outputPricePerMillionRmb,
  }) {
    return inputTokens * inputPricePerMillionRmb / 1000000 +
        outputTokens * outputPricePerMillionRmb / 1000000;
  }

  bool canAfford(double estimatedCostRmb) =>
      spentRmb + estimatedCostRmb <= budgetCapRmb;

  LlmDecision requestOnDemand({
    required LlmCallType type,
    required String reason,
    required bool localAttempted,
    required bool localInsufficient,
    required double estimatedCostRmb,
    required Map<String, Object?> input,
  }) {
    if (!localAttempted) {
      return const LlmDecision(
        allowed: false,
        reason: 'local-first: try local perception / OCR / rules first',
      );
    }
    if (!localInsufficient) {
      return const LlmDecision(
        allowed: false,
        reason: 'local result was sufficient; no cloud call needed',
      );
    }
    if (!canAfford(estimatedCostRmb)) {
      return LlmDecision(
        allowed: false,
        reason:
            'budget cap exceeded: spent=$spentRmb, cap=$budgetCapRmb, estimated=$estimatedCostRmb',
      );
    }
    return LlmDecision(
      allowed: true,
      reason: 'on-demand call allowed within budget',
      payload: {
        'modelId': modelId,
        'type': type.name,
        'reason': reason,
        'input': input,
        'estimatedCostRmb': estimatedCostRmb,
      },
    );
  }

  void recordCall(double actualCostRmb) {
    spentRmb += actualCostRmb;
    calls += 1;
  }

  double get remainingRmb => budgetCapRmb - spentRmb;
}
