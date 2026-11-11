/// The NAVHAZ M1 hazard pipeline (spec section 2.3):
/// detections in, at most one spoken alert out.
///
/// Wiring: Tracker (ids + history) -> TtcEstimator (range /
/// TTC / corridor intersection per track) -> HazardPolicy
/// (levels, cooldown, dedup). Pure Dart and fully driven by
/// synthetic frames: the replay tool and the acceptance
/// tests run exactly this object, and the app feeds it the
/// live YOLO frames.
library;

import '../../modules/visual_perception.dart';
import '../tracking/tracker.dart';
import 'ego_motion.dart';
import 'hazard_policy.dart';
import 'ttc_estimator.dart';

class HazardPipelineResult {
  final HazardAlert? alert;
  final bool riskPresent;

  /// Per-track estimates of this frame (tests / replay
  /// diagnostics; unconfirmed and lost tracks included when
  /// they were estimated).
  final List<TrackEstimate> estimates;

  const HazardPipelineResult({
    required this.alert,
    required this.riskPresent,
    required this.estimates,
  });
}

class HazardPipeline {
  final Tracker tracker;
  final TtcEstimator _estimator = TtcEstimator();
  final HazardPolicy policy = HazardPolicy();

  HazardPipeline({Tracker? tracker}) : tracker = tracker ?? createTracker();

  HazardPipelineResult processFrame(
    List<Detection> detections,
    DateTime t, {
    double? pitchDeg,
    EgoMotion ego = EgoMotion.still,
    bool commit = true,
  }) {
    final List<Track> tracks = tracker.update(detections, t);
    final List<TrackEstimate> estimates = <TrackEstimate>[];
    for (final Track track in tracks) {
      if (track.lostFrames > 0 || track.latest == null) continue;
      estimates.add(_estimator.estimate(
        track,
        at: t,
        pitchDeg: pitchDeg,
        ego: ego,
      ));
    }
    final HazardPolicyResult result =
        policy.evaluate(estimates, t, commit: commit);
    return HazardPipelineResult(
      alert: result.alert,
      riskPresent: result.riskPresent,
      estimates: estimates,
    );
  }

  void reset() {
    tracker.reset();
    _estimator.reset();
    policy.reset();
  }
}
