/// Cloud EVENT triggers (NAVHAZ M2 spec section 3.3):
/// the only two ways an AUTOMATIC cloud-vision call may
/// start, plus the budget every automatic call must pass.
///
/// This replaces the pre-3.3 automatic behaviour -- an
/// 8-second periodic walking scan and a per-alert
/// YOLO-triggered hazard frame. Automatic hazard scans
/// are gone entirely; what remains is event-shaped:
///
/// - crossingStop: the user has STOPPED at the start of
///   a crossing step (or a traffic light is in view) --
///   one frame goes out with task=crossing_info and the
///   answer is spoken as reference-only information;
/// - pathBlocked: a confirmed static obstacle has
///   blocked the forward channel for a while, the user
///   has stopped, and the local avoidance advisor's most
///   recent verdict was stop-only -- one frame goes out
///   with task=detour and the answer is recorded as
///   EVIDENCE ONLY (it never produces speech by itself;
///   whether a step direction may be spoken remains the
///   on-device three-condition rule's decision).
///
/// Both classes here are PURE LOGIC with caller-passed
/// time (an injectable clock by construction): the
/// policy reads a snapshot of facts the wiring layer
/// already owns, and the budget only answers "may this
/// call go out now". Neither touches the camera, the
/// network or the speech channel.
library;

import 'avoidance_advisor.dart' show StepAdvice;
import 'cloud_vision_hazard.dart' show VisionTrigger;
import 'navhaz_config.dart';

/// One evaluation's worth of scene facts, assembled by
/// the wiring layer from state it already maintains:
/// the navigation tracker's current step, the ego
/// judge's stillness, the hazard pipeline's estimates
/// and the avoidance advisor's latest verdict. Every
/// field is a plain value; durations are CONTINUOUS
/// holds measured by the wiring layer (a broken hold is
/// reported as zero, never accumulated).
class CloudTriggerSnapshot {
  /// Text of the navigation step the user is currently
  /// on (the tracker's current step), or null when no
  /// live navigation step exists.
  final String? currentStepText;

  /// Distance from the user's latest fix to the current
  /// step's START point, metres; null when unknown.
  final double? distanceToStepStartM;

  /// Whether the latest YOLO frame contained a traffic
  /// light detection (COCO label "traffic light").
  final bool trafficLightVisible;

  /// True while the ego judge's verdict is still (its
  /// unknown verdict also reads still: no source could
  /// confirm walking).
  final bool currentlyStill;

  /// How long the user has been CONTINUOUSLY still.
  /// Zero when not still.
  final Duration stillFor;

  /// How long a confirmed static obstacle has
  /// CONTINUOUSLY persisted inside the forward channel
  /// (same track, unbroken). Zero when none is present.
  final Duration corridorStaticObstacleFor;

  /// The avoidance advisor's most recent decision for a
  /// hazard, or null when it has never decided.
  final StepAdvice? lastAdvisorAdvice;

  /// Reserved seam, NOT a trigger in M2: a future
  /// on-device tactile-paving model may report a paving
  /// interruption here. The policy deliberately ignores
  /// this field today -- no cloud trigger exists for it
  /// until that model lands (spec 3.3).
  final bool tactilePavingInterrupted;

  /// The evaluation time (the frame's own stamp in
  /// production; a fake in tests).
  final DateTime now;

  const CloudTriggerSnapshot({
    required this.currentStepText,
    required this.distanceToStepStartM,
    required this.trafficLightVisible,
    required this.currentlyStill,
    required this.stillFor,
    required this.corridorStaticObstacleFor,
    required this.lastAdvisorAdvice,
    required this.now,
    this.tactilePavingInterrupted = false,
  });
}

/// The trigger policy: snapshot in, at most one trigger
/// kind out. Stateless -- every hold lives in the
/// snapshot's durations, measured by the wiring layer.
class CloudTriggerPolicy {
  const CloudTriggerPolicy();

  /// Evaluate [s]. When both triggers' conditions hold,
  /// crossingStop wins: the crossing is the moment the
  /// user is actively facing, and the budget would only
  /// let one call out anyway.
  VisionTrigger? evaluate(CloudTriggerSnapshot s) {
    if (_crossingHolds(s)) return VisionTrigger.crossingStop;
    if (_blockedHolds(s)) return VisionTrigger.pathBlocked;
    return null;
  }

  bool _crossingHolds(CloudTriggerSnapshot s) {
    // Context: a crossing step (by its text) OR a
    // traffic light in view. Either alone is enough
    // context; neither means this is not a crossing
    // moment at all.
    final String? text = s.currentStepText;
    final bool stepIsCrossing = text != null &&
        NavHazConfig.cloudCrossingStepKeywords
            .any((String k) => text.contains(k));
    if (!stepIsCrossing && !s.trafficLightVisible) return false;
    // Position: near the step's start. An unknown
    // distance never passes (unknown is not evidence).
    final double? distance = s.distanceToStepStartM;
    if (distance == null ||
        distance > NavHazConfig.cloudCrossingMaxStepDistanceM) {
      return false;
    }
    // Stillness: genuinely stopped, and stopped for the
    // configured hold -- a user merely passing slowly
    // through the kerb zone does not spend a call.
    if (!s.currentlyStill) return false;
    if (s.stillFor < NavHazConfig.cloudCrossingStillHold) return false;
    return true;
  }

  bool _blockedHolds(CloudTriggerSnapshot s) {
    // Persistence: the SAME confirmed static obstacle
    // has blocked the channel continuously for the
    // configured hold.
    if (s.corridorStaticObstacleFor <
        NavHazConfig.cloudBlockedObstacleHold) {
      return false;
    }
    // The user has stopped. NOTE the asymmetry with
    // crossingStop, which additionally requires a 2 s
    // stillness hold: the spec asks pathBlocked only
    // for a currently-still user (the obstacle's own
    // persistence is the temporal gate here), so no
    // extra stillness duration is imposed.
    if (!s.currentlyStill) return false;
    // The local advisor -- the only authority on step
    // directions -- most recently concluded stop-only:
    // there is no local way forward, which is exactly
    // when an evidence call is worth spending.
    if (s.lastAdvisorAdvice != StepAdvice.stopOnly) return false;
    return true;
  }
}

/// The automatic-call budget (spec 3.3), shared by
/// every cloud starter through ONE in-flight slot:
///
/// - AUTOMATIC calls (crossingStop / pathBlocked) are
///   at least [NavHazConfig.cloudAutoMinInterval]
///   apart AND at most [NavHazConfig.cloudAutoMaxPerWindow]
///   land in any sliding [NavHazConfig.cloudAutoWindow]
///   window. The window is the hard constraint; the
///   interval is its corollary and is enforced
///   explicitly too.
/// - At most ONE cloud request is in flight at a time,
///   whoever started it: a starter arriving while the
///   slot is taken is DROPPED, never queued.
/// - MANUAL calls never consume the automatic budget
///   (they are not recorded in the window and do not
///   move the interval clock), but they DO occupy the
///   shared in-flight slot while they run, and the
///   wiring layer applies the shared 429 backoff to
///   both kinds.
///
/// A successful [tryBegin] for an automatic kind
/// RECORDS the call at begin time (dispatch discipline,
/// the same rule the vision client's own limiter uses:
/// a taken slot stays taken even if the capture then
/// fails -- the budget counts authorised dispatches,
/// which is what the cost cap exists to bound).
class CloudAutoTriggerBudget {
  final List<DateTime> _autoDispatches = <DateTime>[];
  bool _inFlight = false;

  /// Whether any cloud request (automatic or manual)
  /// currently holds the shared slot.
  bool get inFlight => _inFlight;

  /// How many automatic dispatches fall inside the
  /// sliding window ending at [now] (diagnostics /
  /// tests; prunes nothing).
  int autoDispatchesInWindow(DateTime now) {
    final DateTime from = now.subtract(NavHazConfig.cloudAutoWindow);
    return _autoDispatches.where((DateTime t) => t.isAfter(from)).length;
  }

  /// Ask permission to start a request of [kind] at
  /// [now]. On true the caller OWNS the in-flight slot
  /// and MUST call [end] exactly once when the request
  /// finishes (success, failure or exception alike).
  /// On false nothing was recorded and nothing is owed.
  bool tryBegin(VisionTrigger kind, DateTime now) {
    if (_inFlight) return false;
    if (kind == VisionTrigger.manual) {
      // Manual: the slot is the only gate. The user's
      // own request is never rationed by the automatic
      // budget -- and never recorded into it either.
      _inFlight = true;
      return true;
    }
    // Prune dispatches that have slid out of the
    // window; the interval check below only ever reads
    // the newest one, which pruning cannot remove (it
    // is by construction the closest to [now]).
    final DateTime from = now.subtract(NavHazConfig.cloudAutoWindow);
    _autoDispatches.removeWhere((DateTime t) => !t.isAfter(from));
    final DateTime? last =
        _autoDispatches.isEmpty ? null : _autoDispatches.last;
    if (last != null &&
        now.difference(last) < NavHazConfig.cloudAutoMinInterval) {
      return false;
    }
    if (autoDispatchesInWindow(now) >= NavHazConfig.cloudAutoMaxPerWindow) {
      return false;
    }
    _autoDispatches.add(now);
    _inFlight = true;
    return true;
  }

  /// Release the in-flight slot. Called exactly once
  /// per successful [tryBegin].
  void end() {
    _inFlight = false;
  }
}
