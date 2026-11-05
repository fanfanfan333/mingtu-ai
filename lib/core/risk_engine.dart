/// Risk engine for Mingtu AI v0.1.
///
/// Two confidences are kept separate on purpose:
/// - [PerceptionEvidence.detectionConfidence]: how confident detection is
///   that *something* of this type is in the frame.
/// - [PerceptionEvidence.spatialConfidence]: how confident the *spatial*
///   estimate is (position, distance, side space). A high detection
///   confidence with a low spatial confidence must NEVER produce a precise
///   step instruction.
///
/// Non-negotiable rules implemented here:
/// 1. Uncertain side space -> NEVER a left/right step instruction.
///    Returns a cautious stop / ask-for-help prompt instead.
/// 2. A missed detection (no evidence) -> NEVER treated as safe.
///    Returns a cautious prompt, never "前方安全".
/// 3. Expired events are invalid and must not drive a prompt.
/// 4. Conflicting step directions (left vs right) resolve to a cautious
///    stop, never to playing both instructions in sequence.
enum RiskLevel { r0, r1, r2, r3, r4 }

enum RiskAction { continue_, caution, stop, askHelp, emergency }

enum StepDirection { left, right, none }

class PerceptionEvidence {
  final double detectionConfidence; // 0..1
  final double spatialConfidence; // 0..1
  final bool hasDistanceEstimate;
  final double? distanceM;
  final bool sideSpaceConfirmed;
  final StepDirection confirmedSafeSide; // only meaningful if sideSpaceConfirmed
  final bool movingTowardsUser;
  const PerceptionEvidence({
    required this.detectionConfidence,
    required this.spatialConfidence,
    required this.hasDistanceEstimate,
    this.distanceM,
    required this.sideSpaceConfirmed,
    this.confirmedSafeSide = StepDirection.none,
    this.movingTowardsUser = false,
  });
}

class RiskEvent {
  final String id;
  final String type; // e.g. 'obstacle', 'step', 'blockedBlindPath'
  final PerceptionEvidence? evidence; // null = missed / no evidence
  final DateTime createdAt;
  final DateTime expiresAt;
  const RiskEvent({
    required this.id,
    required this.type,
    required this.createdAt,
    required this.expiresAt,
    this.evidence,
  });

  bool isExpired(DateTime now) => now.isAfter(expiresAt);
}

class RiskAssessment {
  final RiskLevel level;
  final RiskAction action;
  final String speechText;
  final StepDirection? stepDirection;
  final bool valid; // false for expired / unusable events
  final String reason;
  const RiskAssessment({
    required this.level,
    required this.action,
    required this.speechText,
    required this.reason,
    this.stepDirection,
    this.valid = true,
  });
}

class RiskEngine {
  /// Minimum spatial confidence required before any precise step
  /// instruction may be produced.
  static const double minSpatialConfidenceForStep = 0.6;

  RiskAssessment assess(RiskEvent event, DateTime now) {
    if (event.isExpired(now)) {
      return const RiskAssessment(
        level: RiskLevel.r1,
        action: RiskAction.caution,
        speechText: '前方情况无法确认，请停下并谨慎判断。',
        reason: 'expired-event',
        valid: false,
      );
    }
    final ev = event.evidence;
    if (ev == null) {
      // Rule 2: missed detection is NEVER safe.
      return const RiskAssessment(
        level: RiskLevel.r1,
        action: RiskAction.caution,
        speechText: '前方情况无法确认，请停下并谨慎判断。',
        reason: 'missed-detection-never-safe',
      );
    }
    // Rule 1: uncertain side space -> never a step instruction.
    if (!ev.sideSpaceConfirmed) {
      return RiskAssessment(
        level: RiskLevel.r2,
        action: RiskAction.stop,
        speechText: '前方可能存在障碍，暂时无法确认安全绕行方向，请先停下。',
        reason: 'uncertain-side-space',
        stepDirection: StepDirection.none,
      );
    }
    // Side confirmed, but spatial confidence too low for a precise step.
    if (!ev.hasDistanceEstimate ||
        ev.spatialConfidence < minSpatialConfidenceForStep ||
        ev.confirmedSafeSide == StepDirection.none) {
      return const RiskAssessment(
        level: RiskLevel.r2,
        action: RiskAction.stop,
        speechText: '前方可能存在障碍，暂时无法确认安全绕行方向，请先停下。',
        reason: 'insufficient-spatial-evidence',
        stepDirection: StepDirection.none,
      );
    }
    // Emergency: close and moving towards the user.
    if (ev.movingTowardsUser &&
        ev.distanceM != null &&
        ev.distanceM! < 2.0) {
      return const RiskAssessment(
        level: RiskLevel.r4,
        action: RiskAction.emergency,
        speechText: '危险，请立即停下。',
        reason: 'close-moving-towards-user',
      );
    }
    // Confirmed safe side + sufficient spatial evidence -> step allowed.
    final sideText =
        ev.confirmedSafeSide == StepDirection.left ? '向左移动一步' : '向右移动一步';
    final level =
        (ev.distanceM != null && ev.distanceM! < 3.0) ? RiskLevel.r3 : RiskLevel.r2;
    return RiskAssessment(
      level: level,
      action: RiskAction.caution,
      speechText: '前方有障碍，已确认${ev.confirmedSafeSide == StepDirection.left ? '左侧' : '右侧'}有可通行空间。$sideText',
      reason: 'confirmed-side-space',
      stepDirection: ev.confirmedSafeSide,
    );
  }

  /// Resolve conflicts between assessments. Opposite step directions, or
  /// any emergency, never result in two step instructions being played.
  RiskAssessment resolveConflict(List<RiskAssessment> assessments) {
    if (assessments.isEmpty) {
      return const RiskAssessment(
        level: RiskLevel.r1,
        action: RiskAction.caution,
        speechText: '前方情况无法确认，请停下并谨慎判断。',
        reason: 'no-assessment',
      );
    }
    final valid = assessments.where((a) => a.valid).toList();
    if (valid.isEmpty) return assessments.first;
    valid.sort((a, b) => b.level.index.compareTo(a.level.index));
    final top = valid.first;
    final steps = valid
        .where((a) => a.stepDirection != null && a.stepDirection != StepDirection.none)
        .map((a) => a.stepDirection!)
        .toSet();
    if (steps.length > 1) {
      return const RiskAssessment(
        level: RiskLevel.r3,
        action: RiskAction.stop,
        speechText: '前方情况存在冲突指令，请先停下，不要按旧指令移动。',
        reason: 'conflicting-step-directions',
        stepDirection: StepDirection.none,
      );
    }
    return top;
  }
}
