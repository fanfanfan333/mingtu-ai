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

  test('confirmed side space with spatial evidence requires stopping', () {
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
    expect(a.stepDirection, StepDirection.none);
    expect(a.action, RiskAction.stop);
    expect(a.speechText, '前方有障碍，请停下，用盲杖确认。');
  });

  test('assess never instructs a left or right movement across evidence', () {
    const forbidden = [
      '向左移动一步',
      '向右移动一步',
      '向左迈',
      '向右迈',
      '向左迈步',
      '向右迈步',
    ];
    void check(RiskEvent event) {
      final assessment = engine.assess(event, now);
      for (final phrase in forbidden) {
        expect(assessment.speechText, isNot(contains(phrase)),
            reason: '${event.type}: ${assessment.reason}');
      }
      expect(assessment.stepDirection, isNot(StepDirection.left));
      expect(assessment.stepDirection, isNot(StepDirection.right));
    }

    // The API reports at most one confirmed side, so both-sides evidence
    // cannot be represented independently; exercise all representable sides.
    for (final type in [
      'obstacle',
      'traffic',
      'traffic_uncertain',
      'location_uncertain'
    ]) {
      for (final confirmed in [false, true]) {
        for (final side in StepDirection.values) {
          for (final spatial in [0.3, 0.9]) {
            for (final hasDistance in [false, true]) {
              for (final distance in [null, 1.0, 2.5, 4.0]) {
                for (final approaching in [false, true]) {
                  check(RiskEvent(
                    id: 'grid',
                    type: type,
                    createdAt: now,
                    expiresAt: now.add(const Duration(seconds: 10)),
                    evidence: PerceptionEvidence(
                      detectionConfidence: 0.9,
                      spatialConfidence: spatial,
                      hasDistanceEstimate: hasDistance,
                      distanceM: distance,
                      sideSpaceConfirmed: confirmed,
                      confirmedSafeSide: side,
                      movingTowardsUser: approaching,
                    ),
                  ));
                }
              }
            }
          }
        }
      }
    }
    for (final expired in [false, true]) {
      check(RiskEvent(
        id: 'missing',
        type: 'obstacle',
        createdAt: now,
        expiresAt: now.add(Duration(seconds: expired ? -1 : 10)),
      ));
    }
  });

  test('conflicting step directions resolve to stop, not both', () {
    const left = RiskAssessment(
      level: RiskLevel.r3,
      action: RiskAction.caution,
      speechText: '向左',
      reason: 'test',
      stepDirection: StepDirection.left,
    );
    const right = RiskAssessment(
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
