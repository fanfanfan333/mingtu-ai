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

/// One latency segment, in milliseconds, between two
/// wall-clock stamps (FIX4-FINAL S3): the single helper
/// every latency stamp in the app is computed with, so a
/// test with fake stamps pins every segment at once.
/// Returns null outside the plausibility window (negative
/// -- a stamp pair out of order -- or >= 10 s, which can
/// only be a synthetic / replay timestamp): such pairs
/// are not stamped at all rather than logged as fiction.
int? latencySegmentMs(DateTime start, DateTime end) {
  final int ms = end.difference(start).inMilliseconds;
  if (ms < 0 || ms >= 10000) return null;
  return ms;
}

class HazardPipelineResult {
  final HazardAlert? alert;
  final bool riskPresent;

  /// The frame timestamp this result was computed from
  /// (the `t` handed to [HazardPipeline.processFrame]) --
  /// the start point of the frame-to-callback latency
  /// segment the app stamps (FIX4-FINAL S3).
  final DateTime frameCapturedAt;

  /// Tracks that crossed the pre-emptive vibration
  /// threshold on THIS frame (FIX3B; raw reading surface
  /// FIX4-FINAL): the current frame's tau_now below
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
    required this.frameCapturedAt,
    this.preUrgentTrackIds = const <int>{},
  });
}

class HazardPipeline {
  final Tracker tracker;
  final TtcEstimator _estimator = TtcEstimator();
  final HazardPolicy policy = HazardPolicy();

  /// Pipeline-segment latency stamp sink (FIX3B): called
  /// with (stage, milliseconds) when an alert or a
  /// pre-urgent vibration is emitted -- the frame's own
  /// timestamp against the wall clock at emission. The
  /// app adds the two FIX4-FINAL segments around it
  /// (frame-to-callback, pipeline-to-speak) in main.dart.
  /// Millisecond count and stage name ONLY; never any key
  /// or personal data.
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
      // Synthetic stamps (tests / replay) fall outside
      // the plausibility window; only plausible
      // production figures stamp.
      final int? latencyMs = latencySegmentMs(t, DateTime.now());
      if (latencyMs != null) {
        stamp(result.alert != null ? 'alert' : 'pre-urgent', latencyMs);
      }
    }

    return HazardPipelineResult(
      alert: result.alert,
      riskPresent: result.riskPresent,
      estimates: estimates,
      frameCapturedAt: t,
      preUrgentTrackIds: fired,
    );
  }

  /// Every urgent conjunction condition EXCEPT
  /// confirmation, with tau_now already below the
  /// pre-vibration threshold (which is stricter than
  /// every urgent branch's TTC bound, so no branch check
  /// is repeated here).
  ///
  /// DUAL READING SURFACES (FIX4-FINAL): this judgement
  /// reads the CURRENT FRAME's urgent estimate
  /// ([TrackEstimate.ttcUrgentRawS] -- tau_now before the
  /// persistence guard publishes it), because a fast
  /// target's first frames can carry a genuine sub-1.5 s
  /// tau that the guard has not published yet, and the
  /// vibration must not wait. The urgent SPEECH (the
  /// policy) keeps reading the guard-published
  /// [TrackEstimate.ttcUrgentS] plus urgent confirmation;
  /// the raw surface never promotes speech. The one
  /// confirmation-shaped exclusion kept here: a track
  /// whose urgent speech is already deliverable this
  /// frame (urgent-confirmed WITH a published tau) does
  /// not need a pre-vibration on top of its own speech.
  bool _preUrgentEligible(TrackEstimate e) {
    final double? tauNow = e.ttcUrgentRawS ?? e.ttcUrgentS;
    if (tauNow == null || tauNow >= NavHazConfig.preVibrationTtcS) {
      return false;
    }
    if (e.track.urgentConfirmed && e.ttcUrgentS != null) return false;
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
