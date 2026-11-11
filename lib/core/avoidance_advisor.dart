/// Avoidance advisor: turns one frame of local detections
/// into the spoken hazard announcement, applying the user's
/// three-condition rule (2026-11-09) for the ONLY case where
/// a left/right step may be spoken:
///
/// 1. the hazard is in the central corridor and NEAR --
///    estimated from the detection box (centre-x inside the
///    corridor, box bottom low in the frame);
/// 2. the OTHER side has had NO detection of ANY kind --
///    hazard or not (a chair occupies a side just as much
///    as a vehicle does) -- for at least
///    [sideClearFrames] consecutive frames;
/// 3. the phone orientation is stable (gyroscope / compass
///    seam; unknown or unstable never passes).
///
/// If any condition fails, the announcement names the hazard
/// and tells the user to stop. Steps, curbs and uncertain
/// cloud results NEVER produce a direction (they are handled
/// by the cloud-vision hazard path, caution wording only).
///
/// The corridor / zone thresholds follow the reference
/// approach discussed with the project lead (a virtual
/// corridor split at fixed centre-x edges, distance levels
/// from the box bottom edge; ShadowWalk's DecisionEngine
/// uses the same idea -- approach and thresholds only, no
/// code and no model carried over). The values are empirical
/// heuristics for a chest-worn phone tilted slightly down on
/// flat ground; they are configuration constants, not
/// measurements, and they are NOT field-verified.
library;

import '../modules/visual_perception.dart';

/// The hazard categories the user asked to be named in
/// announcements, in danger order (vehicles first).
enum HazardKind { motorVehicle, nonMotorVehicle, person, pole, pit, clutter }

String hazardKindName(HazardKind kind) => switch (kind) {
      HazardKind.motorVehicle => '机动车',
      HazardKind.nonMotorVehicle => '非机动车',
      HazardKind.person => '行人',
      HazardKind.pole => '杆子',
      HazardKind.pit => '坑洞',
      HazardKind.clutter => '杂物',
    };

int hazardKindPriority(HazardKind kind) => switch (kind) {
      HazardKind.motorVehicle => 0,
      HazardKind.nonMotorVehicle => 1,
      HazardKind.person => 2,
      HazardKind.pole => 3,
      HazardKind.pit => 4,
      HazardKind.clutter => 5,
    };

/// The pipeline label of a pothole detection. The pothole
/// model (M3) has two classes -- 'Pothole' (index 0) and
/// 'Sewage-Manhole' (index 1) per its model card; the
/// adapter normalises class 0 to this label, and class 1
/// stays UNMAPPED (a manhole cover is not the hazard this
/// round was ruled for, so it never enters the hazard
/// system).
const String potholeLabel = 'pothole';

/// Map a detector label to a hazard category. The bundled
/// COCO model has no pole class, so [HazardKind.pole] is
/// reachable only from future models or the cloud path --
/// it is part of the vocabulary regardless. Labels outside
/// the hazard vocabulary return null (not hazards).
HazardKind? hazardKindForLabel(String label) => switch (label) {
      'car' || 'truck' || 'bus' || 'motorcycle' => HazardKind.motorVehicle,
      'bicycle' => HazardKind.nonMotorVehicle,
      'person' => HazardKind.person,
      'pole' => HazardKind.pole,
      potholeLabel => HazardKind.pit,
      _ => null,
    };

enum StepAdvice { stopOnly, stepLeft, stepRight }

enum BoxDistanceLevel { near, mid, far, unknown }

enum AvoidanceNotice { actionConfirmed, actionUncertain }

class AvoidanceDecision {
  final HazardKind kind;
  final StepAdvice advice;

  /// True when the hazard sits in the central corridor at
  /// near distance (condition 1) -- the trigger for a merged
  /// cloud hazard scan.
  final bool nearCenterHazard;

  const AvoidanceDecision({
    required this.kind,
    required this.advice,
    required this.nearCenterHazard,
  });

  String get speech {
    final String name = hazardKindName(kind);
    return switch (advice) {
      StepAdvice.stepLeft => '前方有$name，向左迈一步。',
      StepAdvice.stepRight => '前方有$name，向右迈一步。',
      StepAdvice.stopOnly => kind == HazardKind.person
          ? '前方有人，请停下。'
          : '前方有$name，请停下。',
    };
  }
}

class AvoidanceAdvisor {
  /// Corridor edges on normalised centre-x (configurable).
  static const double corridorLeft = 0.33;
  static const double corridorRight = 0.67;

  /// Box-bottom thresholds for the distance levels
  /// (configurable, empirical): bottom above [nearBottom]
  /// is near, down to [midBottom] is mid, below is far.
  static const double nearBottom = 0.85;
  static const double midBottom = 0.65;

  /// Consecutive frames the far side must be empty.
  static const int sideClearFrames = 3;

  /// Frames a stepped-aside hazard may stay central before
  /// the action counts as unconfirmed.
  static const int actionConfirmWindowFrames = 6;

  int _leftClearStreak = 0;
  int _rightClearStreak = 0;

  StepAdvice? _pendingAction;
  int _pendingFrames = 0;
  int _pendingCenterClearFrames = 0;

  /// Distance level from the box bottom edge. Unknown
  /// geometry (no box) is unknown -- never near.
  BoxDistanceLevel distanceLevelOf(Detection d) {
    if (d.h <= 0) return BoxDistanceLevel.unknown;
    final double bottom = d.bottom;
    if (bottom > nearBottom) return BoxDistanceLevel.near;
    if (bottom >= midBottom) return BoxDistanceLevel.mid;
    return BoxDistanceLevel.far;
  }

  bool inCorridor(Detection d) => d.cx >= corridorLeft && d.cx <= corridorRight;

  /// Feed one frame. Updates the side-clear streaks and the
  /// pending-action tracker; returns a notice when a pending
  /// step action resolves (confirmed) or times out
  /// (uncertain). Speech completion NEVER resolves an action
  /// (spec 7.7-12): only frame evidence does.
  AvoidanceNotice? observeFrame(List<Detection> frame) {
    bool leftBusy = false;
    bool rightBusy = false;
    bool centerBusy = false;
    for (final Detection d in frame) {
      // Side occupancy counts EVERY detection, hazard or
      // not: a side is only "clear" when nothing at all was
      // seen there (a chair blocks a sideways step just as
      // surely as a vehicle does).
      if (d.cx < corridorLeft) leftBusy = true;
      if (d.cx > corridorRight) rightBusy = true;
      // The centre tracker keeps its hazard-only meaning:
      // it resolves whether the hazard the user stepped
      // away from is still standing in the corridor.
      if (hazardKindForLabel(d.label) == null) continue;
      if (inCorridor(d) && distanceLevelOf(d) == BoxDistanceLevel.near) {
        centerBusy = true;
      }
    }
    _leftClearStreak = leftBusy ? 0 : _leftClearStreak + 1;
    _rightClearStreak = rightBusy ? 0 : _rightClearStreak + 1;

    if (_pendingAction != null) {
      _pendingFrames += 1;
      if (!centerBusy) {
        _pendingCenterClearFrames += 1;
        if (_pendingCenterClearFrames >= 2) {
          _pendingAction = null;
          _pendingFrames = 0;
          _pendingCenterClearFrames = 0;
          return AvoidanceNotice.actionConfirmed;
        }
      } else {
        _pendingCenterClearFrames = 0;
      }
      if (_pendingFrames >= actionConfirmWindowFrames && centerBusy) {
        _pendingAction = null;
        _pendingFrames = 0;
        _pendingCenterClearFrames = 0;
        return AvoidanceNotice.actionUncertain;
      }
    }
    return null;
  }

  int get leftClearStreak => _leftClearStreak;
  int get rightClearStreak => _rightClearStreak;
  bool get hasPendingAction => _pendingAction != null;

  /// Decide the announcement for [hazard]. Side effects: a
  /// step decision registers a pending action for
  /// [observeFrame] to resolve from later frames.
  AvoidanceDecision decide({
    required Detection hazard,
    required bool orientationStable,
  }) {
    final HazardKind kind = hazardKindForLabel(hazard.label) ?? HazardKind.clutter;
    final bool nearCenter = inCorridor(hazard) &&
        distanceLevelOf(hazard) == BoxDistanceLevel.near;
    if (!nearCenter || !orientationStable) {
      return AvoidanceDecision(
          kind: kind, advice: StepAdvice.stopOnly, nearCenterHazard: nearCenter);
    }
    final bool leftClear = _leftClearStreak >= sideClearFrames;
    final bool rightClear = _rightClearStreak >= sideClearFrames;
    if (!leftClear && !rightClear) {
      return AvoidanceDecision(
          kind: kind, advice: StepAdvice.stopOnly, nearCenterHazard: true);
    }
    final StepAdvice advice;
    if (leftClear && !rightClear) {
      advice = StepAdvice.stepLeft;
    } else if (rightClear && !leftClear) {
      advice = StepAdvice.stepRight;
    } else {
      // Both sides clear: step away from the hazard's offset;
      // dead centre defaults to the right (keep-right walking
      // convention), still one step only.
      advice = hazard.cx <= 0.5 ? StepAdvice.stepRight : StepAdvice.stepLeft;
    }
    _pendingAction = advice;
    _pendingFrames = 0;
    _pendingCenterClearFrames = 0;
    return AvoidanceDecision(
        kind: kind, advice: advice, nearCenterHazard: true);
  }
}
