/// Route scoring for Mingtu AI v0.1.
///
/// Score = wD * normalisedDistance + wT * normalisedTime
///       + wA * accessibilityMissingCost + wR * knownRiskCost
/// Lower is better. All costs are 0..1.
///
/// Accessibility rule (non-negotiable): UNKNOWN accessibility must be
/// marked UNKNOWN and penalised as a missing cost of 1.0. It must NEVER
/// be treated as SAFE (cost 0.0).
enum AccessibilityStatus { unknown, accessible, partiallyAccessible, inaccessible }

class RouteCandidate {
  final String id;
  final double distanceM;
  final double durationS;
  final AccessibilityStatus accessibility;
  final List<double> knownRiskSeverities; // each 0..1
  final double dataConfidence; // 0..1, data trust, NOT a safety probability
  const RouteCandidate({
    required this.id,
    required this.distanceM,
    required this.durationS,
    required this.accessibility,
    this.knownRiskSeverities = const [],
    required this.dataConfidence,
  });

  double get accessibilityMissingCost {
    switch (accessibility) {
      case AccessibilityStatus.accessible:
        return 0.0;
      case AccessibilityStatus.partiallyAccessible:
        return 0.5;
      case AccessibilityStatus.unknown:
        return 1.0;
      case AccessibilityStatus.inaccessible:
        return 1.0;
    }
  }

  double get knownRiskCost {
    if (knownRiskSeverities.isEmpty) return 0.0;
    return knownRiskSeverities.reduce((a, b) => a > b ? a : b);
  }
}

class RouteWeights {
  final double distance;
  final double time;
  final double accessibilityMissing;
  final double risk;
  const RouteWeights({
    this.distance = 0.25,
    this.time = 0.20,
    this.accessibilityMissing = 0.30,
    this.risk = 0.25,
  });

  double get _sum => distance + time + accessibilityMissing + risk;
  RouteWeights get normalised => RouteWeights(
        distance: distance / _sum,
        time: time / _sum,
        accessibilityMissing: accessibilityMissing / _sum,
        risk: risk / _sum,
      );
}

class ScoredRoute {
  final RouteCandidate candidate;
  final double score;
  final String reason;
  const ScoredRoute(this.candidate, this.score, this.reason);
}

class RouteScoring {
  static double _normalise(double value, double min, double max) {
    if (max <= min) return 0.0;
    return ((value - min) / (max - min)).clamp(0.0, 1.0);
  }

  static List<ScoredRoute> scoreRoutes(
    List<RouteCandidate> candidates, {
    RouteWeights weights = const RouteWeights(),
  }) {
    if (candidates.isEmpty) return const [];
    final w = weights.normalised;
    final minD = candidates.map((c) => c.distanceM).reduce((a, b) => a < b ? a : b);
    final maxD = candidates.map((c) => c.distanceM).reduce((a, b) => a > b ? a : b);
    final minT = candidates.map((c) => c.durationS).reduce((a, b) => a < b ? a : b);
    final maxT = candidates.map((c) => c.durationS).reduce((a, b) => a > b ? a : b);
    final scored = candidates.map((c) {
      final score = w.distance * _normalise(c.distanceM, minD, maxD) +
          w.time * _normalise(c.durationS, minT, maxT) +
          w.accessibilityMissing * c.accessibilityMissingCost +
          w.risk * c.knownRiskCost;
      final reason = c.accessibility == AccessibilityStatus.unknown
          ? '无障碍信息未知（UNKNOWN），未按安全处理；得分已按缺失成本计入。'
          : '无障碍状态：${c.accessibility.name}；已知风险成本：${c.knownRiskCost.toStringAsFixed(2)}。';
      return ScoredRoute(c, score, reason);
    }).toList();
    scored.sort((a, b) => a.score.compareTo(b.score));
    return scored;
  }

  static ScoredRoute? selectBest(
    List<RouteCandidate> candidates, {
    RouteWeights weights = const RouteWeights(),
  }) {
    final scored = scoreRoutes(candidates, weights: weights);
    return scored.isEmpty ? null : scored.first;
  }
}
