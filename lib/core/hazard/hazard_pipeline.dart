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
  /// segment the app stamps (FIX4-FINAL S3). That segment
  /// measures only result-delivery -> detection callback,
  /// not camera capture or inference (NH-M1-10).
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
  /// NH-M1-13 residual: this set carries only firings
  /// that are actually DISPATCHED -- a one-shot re-arm
  /// re-firing inside the same approach (its step 1
  /// already spent) is gated out (see the pipeline's
  /// approach account), so a track appears here at most
  /// once per approach.
  final Set<int> preUrgentTrackIds;

  /// NH-M1-11: the subset of [preUrgentTrackIds] whose
  /// vibration fired under the disagreement exemption --
  /// this frame's raw tau exists ONLY because the
  /// exemption fused the disagreeing agile legs
  /// conservatively. The app dispatches these through the
  /// ordinary pre-urgent vibration path (vibration is
  /// cheap and revocable); the urgent SPEECH is never
  /// issued from the raw surface, exempted or not, so
  /// this subset changes nothing about speech. It exists
  /// so the exemption's effect on the vibration timeline
  /// is auditable (and so the policy's risk presence can
  /// tell a track whose raw tau was manufactured by the
  /// exemption from one whose guards published it --
  /// see hazard_policy.dart).
  final Set<int> preUrgentExemptedTrackIds;

  /// Per-track estimates of this frame (tests / replay
  /// diagnostics; unconfirmed and lost tracks included when
  /// they were estimated).
  final List<TrackEstimate> estimates;

  /// The vibration dispatches THIS frame should produce,
  /// already merged and counted by the NH-M1-13 ladder
  /// (see [HazardAlertSteps]): every pre-urgent one-shot
  /// firing of the frame, plus the alert's vibration when
  /// the policy's ladder allows it and the alert's track
  /// did not itself pre-vibrate this frame. The duplicate
  /// sources the ladder exists to kill are resolved
  /// across this list and the policy's step accounting:
  /// the same-frame pre-urgent + alert pair contributes
  /// ONE entry (the pre-urgent one), and an urgent landing
  /// on a LATER frame of an approach that already spent
  /// step 1 contributes NONE (the policy's registration
  /// suppresses it). `true` = urgent pattern, `false` =
  /// warning pattern. The app dispatches exactly this
  /// list; the counting tests assert on it directly.
  final List<({int trackId, bool urgent})> vibrations;

  /// NH-M1-13: whether THIS frame's alert may vibrate
  /// (the policy's ladder decision, forwarded for
  /// auditability; [vibrations] already embodies it).
  final bool alertVibrationAllowed;

  const HazardPipelineResult({
    required this.alert,
    required this.riskPresent,
    required this.estimates,
    required this.frameCapturedAt,
    this.preUrgentTrackIds = const <int>{},
    this.preUrgentExemptedTrackIds = const <int>{},
    this.vibrations = const <({int trackId, bool urgent})>[],
    this.alertVibrationAllowed = false,
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
  /// condition (the INSTANT eligibility one-shot: it
  /// re-arms when the instantaneous condition clears, and
  /// it is consumed when the urgent speech lands).
  final Set<int> _preVibrated = <int>{};

  /// NH-M1-13 residual (M2 first commit; Codex replay on
  /// 5280e00): the APPROACH-scoped step-1 account, with
  /// TWO jobs, both keyed to the approach and NOT to the
  /// eligibility one-shot above:
  ///   (a) DISPATCH GATE -- the one-shot re-arms when the
  ///       urgent speech consumes it (and when the
  ///       instantaneous condition drops for a frame); a
  ///       re-armed re-firing inside the same approach
  ///       must not dispatch again. In the 5280e00 replay
  ///       (unknown ego, T = 0.9 s) the frame-2 urgent
  ///       consumed the one-shot and frame 3's
  ///       still-eligible estimate re-fired it: that
  ///       re-firing WAS the second dispatch (frames
  ///       [2, 3]). The account records "step 1 already
  ///       DISPATCHED in this approach" and gates the
  ///       re-firing out of the dispatch surfaces.
  ///   (b) LADDER REGISTRATION SOURCE -- the policy's
  ///       registration ([HazardPolicy.notePreVibrated])
  ///       is re-asserted from this account, not from the
  ///       one-shot, and the policy no longer revokes it
  ///       when an alert episode ends: a mid-approach
  ///       urgent that opens a NEW alert episode must
  ///       still find step 1 spent.
  /// The account is written ONLY by an actual dispatch
  /// and cleared ONLY when the approach truly ends (the
  /// sustained-absence rule below). Eligibility jitter,
  /// one-shot re-arms and the urgent speech landing move
  /// it NOT AT ALL.
  final Set<int> _step1SpentInApproach = <int>{};

  /// NH-M1-13 residual: the approach-liveness clear
  /// threshold, counted in CONSECUTIVE frames on which a
  /// step-1-spent track produced NO estimate. The
  /// pipeline cannot observe tracker retirements
  /// directly (a lost track simply stops appearing in
  /// [processFrame]'s estimates, and lost-coast frames
  /// produce none either), so the approach end is read
  /// off the estimate stream: a single absent frame must
  /// NOT end the approach (that was the bug -- an absent
  /// frame is the lost-coast / unestimated case, not a
  /// retirement), while a SUSTAINED absence means the
  /// track is gone or its risk long cleared. The bound
  /// sits well inside the tracker's own retirement
  /// horizon ([NavHazConfig.lostRetentionFrames] lost
  /// frames at the nominal frame rate): an id recycled
  /// by the tracker after retirement is preceded by at
  /// least that many absent frames, so a recycled id
  /// never inherits a spent step 1.
  static const int _step1ApproachAbsentFrames = 5;

  /// Consecutive absent-frame counters backing
  /// [_step1ApproachAbsentFrames].
  final Map<int, int> _step1AbsentRun = <int, int>{};

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
    // The pre-urgent one-shot bookkeeping for THIS frame
    // runs BEFORE the policy evaluates (NH-M1-13 ordering,
    // see the block below): the ladder's step accounting
    // must see this frame's pre-urgent firing when it
    // decides the alert's step.
    final Set<int> eligiblePre = <int>{};
    final Set<int> eligibleExemptedPre = <int>{};
    for (final TrackEstimate e in estimates) {
      if (_preUrgentEligible(e)) {
        eligiblePre.add(e.track.id);
        if (e.urgentDisagreementExempted) {
          eligibleExemptedPre.add(e.track.id);
        }
      }
    }
    final Set<int> firedPre = eligiblePre.difference(_preVibrated);
    _preVibrated.retainWhere(eligiblePre.contains);
    _preVibrated.addAll(firedPre);
    for (final int id in firedPre) {
      policy.notePreVibrated(id);
    }

    // NH-M1-13 residual: maintain the APPROACH account's
    // lifecycle from the estimate stream BEFORE the
    // policy is touched: a step-1-spent track that is
    // estimated this frame has its absence counter reset
    // (the approach is alive); one that is absent
    // accumulates consecutive absent frames, and only a
    // SUSTAINED absence ([_step1ApproachAbsentFrames])
    // ends the approach. The ids whose approach ends on
    // THIS frame are collected for the policy-side close
    // below -- a one-frame absence (lost coast, a frame
    // the tracker kept but the estimator skipped) ends
    // NOTHING any more.
    final Set<int> presentIds = <int>{
      for (final TrackEstimate e in estimates) e.track.id,
    };
    final Set<int> approachEnded = <int>{};
    for (final int id in _step1SpentInApproach) {
      if (presentIds.contains(id)) {
        _step1AbsentRun.remove(id);
      } else {
        final int run = (_step1AbsentRun[id] ?? 0) + 1;
        if (run >= _step1ApproachAbsentFrames) {
          approachEnded.add(id);
        } else {
          _step1AbsentRun[id] = run;
        }
      }
    }
    _step1SpentInApproach.removeAll(approachEnded);
    for (final int id in approachEnded) {
      _step1AbsentRun.remove(id);
    }

    final HazardPolicyResult result =
        policy.evaluate(estimates, t, commit: commit);
    // NH-M1-13: close the policy's per-track ALERT
    // episodes for tracks absent from this frame's
    // estimates (their alert stream broke -- the next
    // alert under that id opens a new episode with a
    // fresh vibration budget). Deliberately separate from
    // the estimator's pre-urgent latch above: a track
    // briefly unestimated between two alert frames keeps
    // neither episode's continuity unless it was actually
    // estimated (and thus alertable) on the frames between.
    // NH-M1-13 residual: the STEP-1 REGISTRATION is no
    // longer closed by this call -- it belongs to the
    // approach account above, not to the alert episode;
    // [HazardPolicy.noteAbsentTracks] now leaves it alone
    // and the approach-ended ids close it explicitly.
    policy.noteAbsentTracks(presentIds);
    for (final int id in approachEnded) {
      policy.trackRetired(id);
    }
    // NH-M1-13 step 1 registration (the sustained form,
    // re-based on the APPROACH account by the residual
    // fix): every track whose step 1 fired during the
    // current approach and which is estimated this frame
    // has its registration re-asserted -- from
    // [_step1SpentInApproach], NOT from the eligibility
    // one-shot, so an ineligible frame (the urgent
    // already deliverable, a momentary out-of-band raw
    // tau) can no longer drop the registration mid-approach.
    for (final TrackEstimate e in estimates) {
      if (_step1SpentInApproach.contains(e.track.id)) {
        policy.notePreVibrated(e.track.id);
      }
    }

    // --- pre-emptive urgent vibration (FIX3B) ---
    // The eligibility / one-shot computation moved ABOVE
    // the policy evaluation (NH-M1-13 ordering); these are
    // the same sets (eligiblePre, and eligibleExemptedPre
    // for the audit set below).
    final Set<int> eligibleExempted = eligibleExemptedPre;
    final Set<int> fired = firedPre;
    // NH-M1-13 residual (the dispatch gate): [fired] is
    // the one-shot's raw firing set, and the one-shot
    // RE-ARMS -- by design -- when the urgent speech
    // consumes it or the instantaneous condition drops
    // for a frame. A re-armed one-shot must NOT dispatch
    // a second vibration inside the same approach: the
    // approach account ([_step1SpentInApproach]) gates
    // the DISPATCH. The account joins a track when its
    // step 1 is actually DISPATCHED (below), so the gate
    // reads the account as it stood BEFORE this frame:
    // a first-in-approach firing passes and joins; a
    // re-armed re-firing is already in the account and
    // is gated out of [HazardPipelineResult
    // .preUrgentTrackIds] and the merged vibration list.
    // The one-shot set itself, the estimator latch report
    // below and the exemption's qualification all keep
    // reading [fired] exactly as before -- the gate is on
    // the physical dispatch only. (The 5280e00 replay:
    // the frame-2 urgent consumed the one-shot, frame
    // 3's still-eligible estimate re-fired it, and the
    // re-firing WAS the second dispatch -- frames [2, 3]
    // in the replay's numbering.)
    final Set<int> firedDispatch =
        fired.difference(_step1SpentInApproach);
    _step1SpentInApproach.addAll(firedDispatch);
    bool urgentConsumed = false;
    if (result.alert != null && result.alert!.urgent) {
      // The urgent speech resets the one-shot, per the
      // ruling (and an urgent-confirmed track is by
      // construction no longer pre-urgent eligible, so
      // the retainWhere above would drop it next frame
      // anyway).
      urgentConsumed = _preVibrated.remove(result.alert!.trackId);
    }
    // NH-M1-11: report the pre-urgent EPISODE boundaries
    // to the estimator's exemption latch. An episode
    // begins when the vibration fires and ends when the
    // urgent speech is delivered (consuming it); the
    // retainWhere above only re-arms the ONE-SHOT, and
    // its mid-episode drops (a frame where the raw tau
    // happens to be published, or momentarily out of
    // band) are NOT episode ends and are deliberately not
    // reported -- see TtcEstimator.notePreUrgent. The
    // report runs AFTER this frame's estimates were
    // computed: a vibration fired on frame N qualifies
    // the track from frame N+1 on (the vibration is the
    // committed evidence; the exemption may only spend
    // evidence already given).
    for (final int id in fired) {
      _estimator.notePreUrgent(id, vibrated: true);
    }
    if (urgentConsumed) {
      _estimator.notePreUrgent(result.alert!.trackId, vibrated: false);
    }

    final void Function(String, int)? stamp = onLatency;
    if (stamp != null &&
        (result.alert != null || firedDispatch.isNotEmpty)) {
      // Synthetic stamps (tests / replay) fall outside
      // the plausibility window; only plausible
      // production figures stamp.
      final int? latencyMs = latencySegmentMs(t, DateTime.now());
      if (latencyMs != null) {
        stamp(result.alert != null ? 'alert' : 'pre-urgent', latencyMs);
      }
    }

    // --- vibration dispatch (NH-M1-13 ladder) ---
    // Merge this frame's two vibration sources into the
    // frame's ONE dispatch list (see the field doc on
    // [HazardPipelineResult.vibrations]): every pre-urgent
    // one-shot firing (the dispatch the pre-round app
    // performed off preUrgentTrackIds), plus the alert's
    // vibration when the policy's ladder allows it AND
    // the alert's track did not itself pre-vibrate this
    // frame (that pair is ONE physical event -- the
    // same-frame duplicate). The pre-urgent one-shot
    // bookkeeping above (_preVibrated, the estimator
    // latch) is untouched: the policy's step-1
    // registration is what suppresses the LATER urgent's
    // dispatch, not any change here to the firing itself.
    final List<({int trackId, bool urgent})> vibrations =
        <({int trackId, bool urgent})>[];
    for (final int id in firedDispatch) {
      vibrations.add((trackId: id, urgent: true));
    }
    if (result.alert != null &&
        result.vibrationAllowed &&
        !firedDispatch.contains(result.alert!.trackId)) {
      vibrations.add((
        trackId: result.alert!.trackId,
        urgent: result.alert!.urgent,
      ));
    }

    return HazardPipelineResult(
      alert: result.alert,
      riskPresent: result.riskPresent,
      estimates: estimates,
      frameCapturedAt: t,
      preUrgentTrackIds: firedDispatch,
      preUrgentExemptedTrackIds:
          firedDispatch.intersection(eligibleExempted),
      vibrations: vibrations,
      alertVibrationAllowed: result.vibrationAllowed,
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
  ///
  /// NH-M1-11 wrinkle: on an EXEMPTED frame the raw tau
  /// exists only because the exemption fused disagreeing
  /// legs. For a track that already vibrated that changes
  /// nothing (its one-shot is spent; the caller filters
  /// already-fired tracks out). For a track in a LATER
  /// episode -- its episode reset after the condition
  /// cleared -- the exemption may NOT be what re-arms its
  /// vibration: a vibration must be earned by an ordinary
  /// reading, never manufactured by the exemption it
  /// would then qualify for. Such a track is therefore
  /// not eligible on its exempted frames; it becomes
  /// eligible again on the first ordinary frame whose raw
  /// tau is back under the threshold.
  bool _preUrgentEligible(TrackEstimate e) {
    final double? tauNow = e.ttcUrgentRawS ?? e.ttcUrgentS;
    if (tauNow == null || tauNow >= NavHazConfig.preVibrationTtcS) {
      return false;
    }
    if (e.urgentDisagreementExempted) return false;
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

  /// TEST SEAM (NH-M1-11): the estimator-side view of one
  /// track's disagreement-exemption state -- the
  /// persistence guard's current run length and whether
  /// the track's current pre-urgent episode latch is set.
  /// The exemption tests assert the frozen run directly
  /// through this instead of inferring it from speech
  /// timing alone.
  ({int tauRun, bool vibratedEpisode}) debugExemptionState(int trackId) => (
        tauRun: _estimator.debugTauNowInBandRun(trackId),
        vibratedEpisode: _estimator.debugPreVibratedEpisode(trackId),
      );

  void reset() {
    tracker.reset();
    _estimator.reset();
    policy.reset();
    _preVibrated.clear();
    _step1SpentInApproach.clear();
    _step1AbsentRun.clear();
  }
}
