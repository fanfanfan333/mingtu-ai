import 'package:test/test.dart';
import 'package:mingtu_ai/core/risk_engine.dart';

void main() {
  final now = DateTime(2026, 11, 5, 10, 0, 0);
  final engine = RiskEngine();

  test('uncertain side space never produces a left/right step', () {
    final event = RiskEvent(
      id: 'e1',
      type: 'obstacle',
      createdAt: now,
      expiresAt: now.add(const Duration(seconds: 10)),
      evidence: const PerceptionEvidence(
        detectionConfidence: 0.95,
        spatialConfidence: 0.9,
        hasDistanceEstimate: true,
        distanceM: 2.0,
        sideSpaceConfirmed: false,
      ),
    );
    final a = engine.assess(event, now);
    expect(a.stepDirection, isNot(StepDirection.left));
    expect(a.stepDirection, isNot(StepDirection.right));
    expect(a.action, RiskAction.stop);
    expect(a.speechText.contains('向左'), isFalse);
    expect(a.speechText.contains('向右'), isFalse);
  });

  test('missed detection is never treated as safe', () {
    final event = RiskEvent(
      id: 'e2',
      type: 'obstacle',
      createdAt: now,
      expiresAt: now.add(const Duration(seconds: 10)),
      evidence: null,
    );
    final a = engine.assess(event, now);
    expect(a.action, isNot(RiskAction.continue_));
    expect(a.speechText.contains('安全'), isFalse);
  });

  test('confirmed side space with spatial evidence may give a step', () {
    final event = RiskEvent(
      id: 'e3',
      type: 'obstacle',
      createdAt: now,
      expiresAt: now.add(const Duration(seconds: 10)),
      evidence: const PerceptionEvidence(
        detectionConfidence: 0.9,
        spatialConfidence: 0.8,
        hasDistanceEstimate: true,
        distanceM: 2.5,
        sideSpaceConfirmed: true,
        confirmedSafeSide: StepDirection.right,
      ),
    );
    final a = engine.assess(event, now);
    expect(a.stepDirection, StepDirection.right);
  });

  test('conflicting step directions resolve to stop, not both', () {
    final left = RiskAssessment(
      level: RiskLevel.r3,
      action: RiskAction.caution,
      speechText: '向左',
      reason: 'test',
      stepDirection: StepDirection.left,
    );
    final right = RiskAssessment(
      level: RiskLevel.r3,
      action: RiskAction.caution,
      speechText: '向右',
      reason: 'test',
      stepDirection: StepDirection.right,
    );
    final resolved = engine.resolveConflict([left, right]);
    expect(resolved.action, RiskAction.stop);
    expect(resolved.stepDirection, StepDirection.none);
  });

  test('expired event is invalid', () {
    final event = RiskEvent(
      id: 'e4',
      type: 'obstacle',
      createdAt: now.subtract(const Duration(seconds: 20)),
      expiresAt: now.subtract(const Duration(seconds: 1)),
      evidence: const PerceptionEvidence(
        detectionConfidence: 0.9,
        spatialConfidence: 0.9,
        hasDistanceEstimate: true,
        distanceM: 1.0,
        sideSpaceConfirmed: true,
        confirmedSafeSide: StepDirection.left,
      ),
    );
    expect(engine.assess(event, now).valid, isFalse);
  });
}
