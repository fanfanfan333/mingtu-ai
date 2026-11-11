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
import '../avoidance_advisor.dart';
import '../navhaz_config.dart';
import '../tracking/tracker.dart';
import 'ego_motion.dart';
import 'hazard_policy.dart';
import 'ttc_estimator.dart';

class HazardPipelineResult {
  final HazardAlert? alert;
  final bool riskPresent;

  /// Tracks that crossed the pre-emptive vibration
  /// threshold on THIS frame (FIX3B): tau_now below
  /// [NavHazConfig.preVibrationTtcS] with every urgent
  /// conjunction condition except confirmation satisfied.
  /// The app fires the urgent vibration for these
  /// immediately; the urgent SPEECH still waits for
  /// urgent confirmation through the normal alert path.
  /// One shot per track until the condition clears or
  /// the urgent speech is delivered (a vibration without
  /// a following confirmation is an accepted false-alarm
  /// cost -- vibration is cheap, a late warning is not).
  final Set<int> preUrgentTrackIds;

  /// Per-track estimates of this frame (tests / replay
  /// diagnostics; unconfirmed and lost tracks included when
  /// they were estimated).
  final List<TrackEstimate> estimates;

  const HazardPipelineResult({
    required this.alert,
    required this.riskPresent,
    required this.estimates,
    this.preUrgentTrackIds = const <int>{},
  });
}

class HazardPipeline {
  final Tracker tracker;
  final TtcEstimator _estimator = TtcEstimator();
  final HazardPolicy policy = HazardPolicy();

  /// End-to-end latency stamp sink (FIX3B): called with
  /// (stage, milliseconds) when an alert or a pre-urgent
  /// vibration is emitted -- the frame's own timestamp
  /// against the wall clock at emission. Millisecond count
  /// and stage name ONLY; never any key or personal data.
  /// Null in tests / replay (synthetic frame stamps would
  /// make the figure meaningless); the app wires it to
  /// its log in production frames, whose stamps are real.
  void Function(String stage, int latencyMs)? onLatency;

  /// Tracks that already spent their one pre-urgent
  /// vibration in the current unbroken run of the
  /// condition.
  final Set<int> _preVibrated = <int>{};

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

    // --- pre-emptive urgent vibration (FIX3B) ---
    final Set<int> eligible = <int>{};
    for (final TrackEstimate e in estimates) {
      if (_preUrgentEligible(e)) eligible.add(e.track.id);
    }
    final Set<int> fired = eligible.difference(_preVibrated);
    _preVibrated.retainWhere(eligible.contains);
    _preVibrated.addAll(fired);
    if (result.alert != null && result.alert!.urgent) {
      // The urgent speech resets the one-shot, per the
      // ruling (and an urgent-confirmed track is by
      // construction no longer pre-urgent eligible, so
      // the retainWhere above would drop it next frame
      // anyway).
      _preVibrated.remove(result.alert!.trackId);
    }

    final void Function(String, int)? stamp = onLatency;
    if (stamp != null && (result.alert != null || fired.isNotEmpty)) {
      final int latencyMs = DateTime.now().difference(t).inMilliseconds;
      // Synthetic stamps (tests / replay) yield absurd
      // values; only plausible production figures stamp.
      if (latencyMs >= 0 && latencyMs < 10000) {
        stamp(result.alert != null ? 'alert' : 'pre-urgent', latencyMs);
      }
    }

    return HazardPipelineResult(
      alert: result.alert,
      riskPresent: result.riskPresent,
      estimates: estimates,
      preUrgentTrackIds: fired,
    );
  }

  /// Every urgent conjunction condition EXCEPT
  /// confirmation, with tau_now already below the
  /// pre-vibration threshold (which is stricter than
  /// every urgent branch's TTC bound, so no branch check
  /// is repeated here).
  bool _preUrgentEligible(TrackEstimate e) {
    final double? tauNow = e.ttcUrgentS;
    if (tauNow == null || tauNow >= NavHazConfig.preVibrationTtcS) {
      return false;
    }
    if (e.track.urgentConfirmed) return false;
    if (!e.egoSpeedKnown) {
      // Scale path: growth + extrapolated intersection at
      // tau_now's horizon (the FIX2 conjunction minus
      // confirmation).
      if (e.scaleRate <= 0) return false;
      final TrackSample? s = e.track.latest;
      if (s == null) return false;
      return TtcEstimator.channelIntersects(
        cx: s.cx,
        cxVelocity: e.cxVelocity,
        horizonS: tauNow,
        rangeM: e.rangeM,
      );
    }
    // Known path: intersection + (vehicle approaching, or
    // the close-range condition, or the no-ranging scale
    // vehicle branch) -- the urgent branches' shape.
    if (!e.willHit) return false;
    final HazardKind kind =
        hazardKindForLabel(e.track.label) ?? HazardKind.clutter;
    final bool isVehicle = kind == HazardKind.motorVehicle ||
        kind == HazardKind.nonMotorVehicle;
    if (isVehicle && e.approaching) return true;
    if (e.rangeM != null && e.rangeM! <= NavHazConfig.urgentCloseRangeM) {
      return true;
    }
    if (isVehicle && e.closingSpeedMps == null) return true;
    return false;
  }

  void reset() {
    tracker.reset();
    _estimator.reset();
    policy.reset();
    _preVibrated.clear();
  }
}
