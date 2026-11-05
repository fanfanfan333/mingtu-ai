import 'package:test/test.dart';
import 'package:mingtu_ai/core/route_scoring.dart';

void main() {
  test('unknown accessibility is penalised, never treated as safe', () {
    const unknown = RouteCandidate(
      id: 'u',
      distanceM: 100,
      durationS: 120,
      accessibility: AccessibilityStatus.unknown,
      dataConfidence: 0.5,
    );
    const accessible = RouteCandidate(
      id: 'a',
      distanceM: 100,
      durationS: 120,
      accessibility: AccessibilityStatus.accessible,
      dataConfidence: 0.5,
    );
    expect(unknown.accessibilityMissingCost, 1.0);
    expect(accessible.accessibilityMissingCost, 0.0);
    final scored = RouteScoring.scoreRoutes([unknown, accessible]);
    // Same distance/time, but unknown must score worse than accessible.
    expect(scored.first.candidate.id, 'a');
    expect(
      scored.firstWhere((s) => s.candidate.id == 'u').reason.contains('UNKNOWN'),
      isTrue,
    );
  });

  test('weights are normalised and lower score wins', () {
    const shortRisky = RouteCandidate(
      id: 'short-risky',
      distanceM: 100,
      durationS: 120,
      accessibility: AccessibilityStatus.accessible,
      knownRiskSeverities: [0.9],
      dataConfidence: 0.5,
    );
    const longSafe = RouteCandidate(
      id: 'long-safe',
      distanceM: 200,
      durationS: 240,
      accessibility: AccessibilityStatus.accessible,
      knownRiskSeverities: [0.0],
      dataConfidence: 0.5,
    );
    final best = RouteScoring.selectBest(
      [shortRisky, longSafe],
      weights: const RouteWeights(
        distance: 0.1,
        time: 0.1,
        accessibilityMissing: 0.1,
        risk: 0.7,
      ),
    );
    expect(best?.candidate.id, 'long-safe');
  });
}
