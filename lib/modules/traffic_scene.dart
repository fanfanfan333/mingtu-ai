/// Traffic-scene information ONLY for Mingtu AI (v0.4 replacement).
///
/// This module REPLACES the deleted "traffic-light crossing decision".
/// A single camera image can never prove that a light belongs to the
/// user's crossing, that no vehicle is coming, or that crossing is safe.
/// Therefore this module NEVER outputs a crossing
/// permission of any wording, and NEVER outputs a step across a road.
///
/// What it does output, always as caution/stop:
/// - light seen but direction unconfirmed -> stop, ask for help / other confirmation
/// - no light / light unclear / location uncertain -> stop, do not guess
/// - any traffic event -> at most "路口信息" text, never a permission
library;

enum TrafficSceneOutcome { infoOnly, stopAndAskHelp }

class TrafficSceneAssessment {
  final TrafficSceneOutcome outcome;
  final String speechText;
  final String reason;
  final bool allowsCrossing; // always false by construction
  const TrafficSceneAssessment({
    required this.outcome,
    required this.speechText,
    required this.reason,
  }) : allowsCrossing = false;
}

class TrafficSceneService {
  TrafficSceneAssessment assess({
    required bool lightDetected,
    required bool lightDirectionConfirmed,
    required bool locationAccuracyOk,
    required bool crossingConfirmed,
  }) {
    // Crossing is never confirmed by this module: even a detected,
    // direction-confirmed light is only "information", because vehicle
    // speed, distance and other directions are not verified.
    if (!lightDetected || !lightDirectionConfirmed || !locationAccuracyOk) {
      return const TrafficSceneAssessment(
        outcome: TrafficSceneOutcome.stopAndAskHelp,
        speechText: '路口情况无法确认，请停下，不要凭信号灯判断过马路，必要时寻求帮助。',
        reason: 'traffic-unconfirmed',
      );
    }
    // Note: crossingConfirmed is accepted only to document that even a
    // caller claiming confirmation cannot turn this into permission.
    return const TrafficSceneAssessment(
      outcome: TrafficSceneOutcome.infoOnly,
      speechText: '前方疑似路口，信号灯信息仅供参考，不能作为过马路的许可，请停下并用你熟悉的方式确认后再决定。',
      reason: 'traffic-info-only-never-permission',
    );
  }
}
