/// Time-to-collision estimation for NAVHAZ M1
/// (spec section 2.2).
///
/// Two independent estimates per track, each smoothed by an
/// alpha-beta filter:
///
/// 1. Ground-plane ranging. With the camera pitched down by
///    theta (radians, from the IMU pitch monitor), a box
///    whose bottom edge sits at normalised image height
///    v_bottom is at range
///        Z = H_cam / tan(theta + atan((v_bottom - c_y)/f_y))
///    The estimate only applies when the bottom is below
///    the horizon line and not pinned to the image's lower
///    edge; otherwise Z is null. TTC_z follows from the
///    filtered closing speed of Z.
///
/// 2. Box-scale expansion. With s = sqrt(w*h), the scale
///    grows as the target approaches: TTC_s = s / (ds/dt),
///    using the alpha-beta filter's velocity. A non-positive
///    filtered ds/dt means "not approaching by scale" --
///    TTC_s is then infinite (reported as null here, and
///    kept distinct from "unknown" by [TrackEstimate]).
///
/// Fusion (spec 2.2): both valid and consistent with
/// each other (relative difference |a-b| / max(a,b) at or
/// below [NavHazConfig.ttcFusionTolerance]) -> the
/// smaller; only one valid -> that one; none -> null.
/// Both valid but INCONSISTENT (difference above the
/// tolerance) -> the fused TTC is null and the estimate
/// is marked [TrackEstimate.ttcDisagreement]: contradictory
/// ranging is not trustworthy, so the policy degrades to
/// the range-based rules and never promotes a hazard to
/// urgent on either leg's value alone (see the config
/// comment for the full rule).
///
/// CDX2-1 exception: fusion applies only when the ego
/// speed is KNOWN. With the ego speed unknown the
/// effective TTC is the box-scale leg alone (the policy's
/// ego-unknown path grades on it) and disagreement never
/// applies -- see [TtcEstimator.estimate].
///
/// NH-M1-11 exemption (lead's ruling, 2026-11-11): the
/// distrust rule above protects a track that has given no
/// other evidence. A track that has ALREADY fired its
/// pre-urgent vibration (its tau_now genuinely fell below
/// [NavHazConfig.preVibrationTtcS] on the raw reading
/// surface) and STILL extrapolates into the forward
/// channel ([TrackEstimate.willHit]) has committed that
/// evidence; a TRANSIENT disagreement of the agile legs
/// must not then erase the urgent tau and reset the
/// persistence guard, or a genuinely close target loses
/// its warning inside the physical window (the measured
/// failure: known ego, true TTC 0.9 s -- vibration at
/// frame 2, agile legs diverge at frames 4-6, raw tau
/// nulled, guard counter reset, voice never lands). For
/// such a track -- and ONLY such a track -- a disagreeing
/// frame fuses the agile prediction CONSERVATIVELY
/// (the smaller positive leg) and FREEZES the persistence
/// guard's run (neither advanced nor reset). Every other
/// track keeps the distrust rule verbatim; the normal
/// tier's fusion is never exempted; the unknown-ego path
/// has no fusion and so nothing to exempt.
library;

import 'dart:math' as math;

import '../navhaz_config.dart';
import '../tracking/tracker.dart';
import 'ego_motion.dart';

/// One-dimensional alpha-beta filter over time-stamped
/// values: tracks (value, velocity). Seeding (M1 fix
/// round): the FIRST observation seeds the value (velocity
/// 0); when the SECOND observation arrives, the velocity
/// is seeded from that first finite difference, divided by
/// the REAL interval between the two samples. The seeded
/// velocity is not used straight away: it is held pending
/// for one frame and promoted only after the third
/// observation has run it through one standard alpha-beta
/// update, so the first beta correction acts on the seed
/// before it can drive a TTC. That ordering matters --
/// both tracker backends smooth the box with their own
/// filter, whose early catch-up transient can make the raw
/// first difference overestimate the closing rate (an
/// earlier experiment with the raw difference as the seed
/// overestimated it by ~15% and fired warnings ~1 s
/// early). Measured on the acceptance fixture, the
/// promoted-after-one-update seed keeps every alert inside
/// its spec window (see the fix-round report).
class AlphaBetaFilter {
  final double alpha;
  final double beta;
  double _x = 0;
  double _v = 0;
  double? _pendingSeedV;
  int _samples = 0;
  DateTime? _lastAt;
  bool _seeded = false;

  AlphaBetaFilter({double? alpha, double? beta})
      : alpha = alpha ?? NavHazConfig.alphaBetaAlphaNormal,
        beta = beta ?? kalataBeta(alpha ?? NavHazConfig.alphaBetaAlphaNormal);

  /// The Kalata relation (FIX3B): beta derived from
  /// alpha, never hand-filled --
  ///   beta = 2(2 - alpha) - 4 * sqrt(1 - alpha)
  /// alpha 0.3 -> 0.0534; alpha 0.7 -> 0.4091; the old
  /// hand-filled pair (0.5 / 0.1) sat far below its
  /// Kalata beta (0.172), which is exactly the velocity
  /// lag the CDX3 delay ledger measured.
  static double kalataBeta(double alpha) =>
      2 * (2 - alpha) - 4 * math.sqrt(1 - alpha);

  /// One-step-ahead predicted value (state extrapolated
  /// by the nominal frame interval): the agile tier's
  /// urgent TTC is derived from THIS state, so the
  /// prediction lead is part of the lag compensation.
  double get predictedNext =>
      _x + _v * (NavHazConfig.nominalFrameInterval.inMilliseconds / 1000.0);

  bool get seeded => _seeded;
  double get value => _x;
  double get velocity => _v;

  /// Frame interval between [at] and the previous update,
  /// with degenerate gaps (zero / absurd) replaced by the
  /// nominal interval: bursts of frames delivered inside a
  /// single event-loop turn (tests, replay) must not produce
  /// infinite velocities.
  double _dtSeconds(DateTime at) {
    final DateTime? last = _lastAt;
    if (last == null) {
      return NavHazConfig.nominalFrameInterval.inMilliseconds / 1000.0;
    }
    final double dt = at.difference(last).inMicroseconds / 1e6;
    if (dt <= 0.0005 || dt > 2.0) {
      return NavHazConfig.nominalFrameInterval.inMilliseconds / 1000.0;
    }
    return dt;
  }

  double update(double z, DateTime at) {
    final double dt = _dtSeconds(at);
    _lastAt = at;
    if (!_seeded) {
      _x = z;
      _v = 0;
      _seeded = true;
      _samples = 1;
      return _x;
    }
    if (_samples == 1) {
      // Second observation: seed the velocity from the
      // first finite difference over the real interval,
      // but hold it pending (see the class doc); the value
      // takes the new observation and the reported
      // velocity stays 0 for this frame.
      _pendingSeedV = (z - _x) / dt;
      _x = z;
      _samples = 2;
      return _x;
    }
    if (_pendingSeedV != null) {
      // Third observation: promote the seed, then let the
      // standard update below apply one alpha-beta
      // correction to it before any caller reads it.
      _v = _pendingSeedV!;
      _pendingSeedV = null;
    }
    _samples++;
    final double predicted = _x + _v * dt;
    final double residual = z - predicted;
    _x = predicted + alpha * residual;
    _v = _v + (beta / dt) * residual;
    return _x;
  }

  void reset() {
    _x = 0;
    _v = 0;
    _pendingSeedV = null;
    _samples = 0;
    _lastAt = null;
    _seeded = false;
  }
}

/// Everything the hazard policy needs to know about one
/// track in one frame.
class TrackEstimate {
  final Track track;

  /// Fused time-to-collision, seconds; null when neither
  /// estimate is usable.
  final double? ttcS;

  /// The scale-only and range-only estimates (diagnostics /
  /// tests); null when invalid (including "not approaching"
  /// for the scale estimate).
  final double? ttcScaleS;
  final double? ttcRangeS;

  /// True when both TTC legs were valid but contradicted
  /// each other beyond [NavHazConfig.ttcFusionTolerance]:
  /// the fused [ttcS] is then null BY DISTRUST, not by
  /// missing data. The policy treats it like any TTC null
  /// for level purposes (never urgent on a TTC branch) and
  /// may still use [rangeM] under the static / close-range
  /// rules; the marker exists for the policy's assertions
  /// and for logging.
  final bool ttcDisagreement;

  /// Filtered ground-plane range, metres; null when the
  /// ground-plane preconditions do not hold.
  final double? rangeM;

  /// Relative closing speed, m/s (positive = closing);
  /// null when neither ranging nor scale gives one.
  final double? closingSpeedMps;

  /// True when this target is closing faster than the
  /// user's own motion by the configured margin (vehicles
  /// only matter as "approaching"; a static obstacle the
  /// user walks toward is handled by the range rules).
  final bool approaching;

  /// True when the target's extrapolated bottom-centre
  /// LANDING POINT at its TTC horizon is inside the
  /// forward channel ([TtcEstimator.channelIntersects]:
  /// +/- the channel half width in metres with a range,
  /// the central frame fraction without one). Current-box
  /// overlap with the channel does NOT count (CDX3).
  final bool willHit;

  /// Centre-x velocity, normalised units per second.
  final double cxVelocity;

  /// Whether the ego speed behind this estimate was a real
  /// measurement ([EgoMotion.speedKnown]). When false, the
  /// policy runs its dedicated ego-unknown scale path (see
  /// hazard_policy.dart): no approaching judgement, levels
  /// from [ttcScaleS] alone, its own intersection gate and
  /// the longer unknown-ego cooldown. Defaults to true so
  /// hand-built estimates in older tests keep the known-ego
  /// behaviour.
  final bool egoSpeedKnown;

  /// Filtered box-scale growth rate ds/dt (normalised
  /// units per second): positive while the box grows. The
  /// ego-unknown path asserts growth through THIS field
  /// (FIX2 conjunction condition (ii)) rather than
  /// inferring it from the TTC's finiteness; a usable
  /// [ttcScaleS] exists only when this is positive, so the
  /// two are consistent by construction. Defaults to 0
  /// (no growth) for hand-built estimates.
  final double scaleRate;

  /// NH-M1-11: true when this frame's URGENT (agile-tier)
  /// prediction ran under the disagreement exemption --
  /// the two agile legs disagreed, but the track had
  /// already fired its pre-urgent vibration in the current
  /// episode and still extrapolates into the channel, so
  /// the raw urgent tau was fused conservatively (the
  /// smaller positive leg) instead of distrusted to null,
  /// and the persistence guard's run froze on this frame.
  /// Always false when the ego speed is unknown (no
  /// fusion happens there) and on every track that has
  /// not vibrated. The NORMAL tier is never exempted:
  /// [ttcS] and [ttcDisagreement] keep their verbatim
  /// meaning even on an exempt frame. Defaults to false
  /// for hand-built estimates.
  final bool urgentDisagreementExempted;

  /// Whether the underlying track is CONFIRMED
  /// ([Track.confirmed]: an unbroken run of matched
  /// frames reached the confirmation count). Read off the
  /// track so consumers of bare estimates -- the frame-
  /// rate policy's danger test (M2 section 3.1) in
  /// particular -- do not need the track object itself.
  bool get confirmed => track.confirmed;

  /// The URGENT judgement's TTC (FIX3B): the agile tier's
  /// one-step PREDICTED TTC (fused like [ttcS] when the
  /// ego speed is known, scale-only when it is not) minus
  /// [NavHazConfig.pipelineLatencyS], PUBLISHED through
  /// the persistence guard (three consecutive in-band
  /// estimates). Null when no predicted leg is usable.
  /// ONLY the urgent branches of the policy read this;
  /// warnings and every other consumer keep the
  /// normal-tier [ttcS] / [ttcScaleS], so the prediction
  /// can never pull a warning early.
  final double? ttcUrgentS;

  /// The same urgent TTC BEFORE the persistence guard:
  /// this frame's own tau_now, available from the first
  /// frame the agile tier produces one (FIX4-FINAL dual
  /// reading surfaces). ONLY the pre-urgent VIBRATION
  /// reads this: a fast-approaching target's first frames
  /// carry a genuinely low tau that the guard has not
  /// published yet, and the vibration -- cheap, revocable,
  /// never speech -- must not wait for publication. The
  /// urgent SPEECH never reads it: speech stays on the
  /// guard-published [ttcUrgentS] plus confirmation,
  /// unpromoted. Hand-built estimates leave it null and
  /// consumers fall back to [ttcUrgentS].
  final double? ttcUrgentRawS;

  const TrackEstimate({
    required this.track,
    required this.ttcS,
    required this.ttcScaleS,
    required this.ttcRangeS,
    required this.rangeM,
    required this.closingSpeedMps,
    required this.approaching,
    required this.willHit,
    required this.cxVelocity,
    this.ttcUrgentS,
    this.ttcUrgentRawS,
    this.ttcDisagreement = false,
    this.egoSpeedKnown = true,
    this.scaleRate = 0,
    this.urgentDisagreementExempted = false,
    this.debugAgileScaleTtcS,
    this.debugAgileRangeTtcS,
  });

  /// TEST SEAM (NH-M1-11 literal-regression): this frame's
  /// AGILE predicted legs BEFORE any fusion -- the two
  /// readings whose transient disagreement the exemption
  /// forgives. Carried on the estimate (production
  /// consumers ignore them) so the literal per-frame
  /// regression test can assert the exact leg values and
  /// disagreement frame positions Codex reported, instead
  /// of inferring the disagreement from downstream
  /// effects. Null when the corresponding leg is unusable
  /// this frame.
  final double? debugAgileScaleTtcS;
  final double? debugAgileRangeTtcS;
}

class _FilterPair {
  /// Normal tier: feeds warnings and the general outputs.
  final AlphaBetaFilter scale = AlphaBetaFilter();
  final AlphaBetaFilter range = AlphaBetaFilter();

  /// Agile tier (FIX3B): the same two series filtered at
  /// the higher alpha, existing only so the urgent
  /// judgement can read a one-step prediction with far
  /// less velocity lag. The differential-seed form (seed
  /// held one frame, promoted through one update before
  /// use) applies to this tier exactly as to the normal
  /// one -- the tiers differ only in their gains.
  final AlphaBetaFilter scaleAgile =
      AlphaBetaFilter(alpha: NavHazConfig.alphaBetaAlphaAgile);
  final AlphaBetaFilter rangeAgile =
      AlphaBetaFilter(alpha: NavHazConfig.alphaBetaAlphaAgile);
}

/// Stateful estimator: one pair of filters per track id,
/// fed frame by frame by the hazard pipeline.
class TtcEstimator {
  final Map<int, _FilterPair> _filters = <int, _FilterPair>{};

  /// Per-track run length of consecutive estimates whose
  /// RAW tau_now (before the persistence guard below) sat
  /// at or under the urgent band -- the jitter guard's
  /// counter. NH-M1-11: a frame that runs under the
  /// disagreement exemption FREEZES its track's entry here
  /// (the run is neither advanced nor reset); every other
  /// frame updates it exactly as before.
  final Map<int, int> _tauNowInBandRun = <int, int>{};

  /// NH-M1-11 exemption qualification latch: the track ids
  /// whose CURRENT pre-urgent episode has already fired
  /// the vibration. Qualification is the EPISODE's
  /// property, not the one-shot's bookkeeping state: an
  /// episode runs from the vibration until the episode
  /// ENDS -- the urgent speech is delivered (the episode
  /// is spent), the track is lost / retired, or the
  /// estimator resets. Whether the track is pre-urgent
  /// ELIGIBLE on any given frame in between is irrelevant
  /// here: the FIX4-FINAL dual-surface reading makes the
  /// raw tau of an already-confirmed track ineligible on
  /// exactly the frames where the exemption matters (the
  /// published tau exists), so keying qualification to
  /// eligibility would switch the exemption off on the
  /// first frame after the vibration. The pipeline --
  /// which owns the pre-urgent one-shot and its resets --
  /// reports the episode boundaries through
  /// [notePreUrgent]; the estimator only READS the latch,
  /// it never sets it, so the exemption's episode
  /// semantics are the pre-urgent semantics by
  /// construction (no second lifecycle). A retired track
  /// id leaves the latch through [forget]; a NEW track
  /// under a recycled id never inherits an old episode.
  final Set<int> _preVibratedEpisode = <int>{};

  /// Focal length in normalised units, from the configured
  /// vertical FOV: f_y = 0.5 / tan(VFOV/2).
  static double get focalY =>
      0.5 / math.tan(NavHazConfig.verticalFovDeg * math.pi / 180 / 2);

  /// Focal length in normalised units, from the configured
  /// horizontal FOV: f_x = 0.5 / tan(HFOV/2).
  static double get focalX =>
      0.5 / math.tan(NavHazConfig.horizontalFovDeg * math.pi / 180 / 2);

  /// Lateral offset, in metres, of a point at normalised
  /// centre-x [cx] whose ground range is [rangeM]: the
  /// ray's angle off the optical axis satisfies
  /// tan(angle) = (cx - 0.5) / f_x, and the offset is
  /// rangeM * tan(angle). Sign follows the image x axis
  /// (positive = right of centre).
  static double lateralOffsetM(double cx, double rangeM) =>
      (cx - 0.5) / focalX * rangeM;

  /// THE intersection test for every hazard path (the
  /// CDX3 round unified the known-ego corridor test and
  /// the ego-unknown scale-path gate into this one):
  /// extrapolate the box bottom-centre's lateral position
  /// (its centre-x [cx], moving at [cxVelocity]) to
  /// t + [horizonS] and ask whether the LANDING POINT is
  /// inside the user's forward channel. With a metric
  /// range the channel is +/-[NavHazConfig.channelHalfWidthM]
  /// metres (via [lateralOffsetM] at [rangeM]); without
  /// one it is the central [NavHazConfig.channelCenterFraction]
  /// of the frame. A crossing target extrapolates OUT of
  /// the channel and never intersects, however small its
  /// TTC -- and however much its CURRENT box overlaps the
  /// channel: there is deliberately no "current box
  /// overlaps" clause (the pre-CDX3 willHit had one, and
  /// it let crossing targets in on frames where the box
  /// swept through the corridor).
  static bool channelIntersects({
    required double cx,
    required double cxVelocity,
    required double horizonS,
    required double? rangeM,
  }) {
    final double cxAtHit = cx + cxVelocity * horizonS;
    if (rangeM != null) {
      return lateralOffsetM(cxAtHit, rangeM).abs() <=
          NavHazConfig.channelHalfWidthM;
    }
    const double half = NavHazConfig.channelCenterFraction / 2;
    return cxAtHit >= 0.5 - half && cxAtHit <= 0.5 + half;
  }

  /// Intersection gate for the ego-unknown scale path
  /// (lead's ruling, 2026-11-11): [channelIntersects] with
  /// the scale TTC as the horizon. Kept as a named entry
  /// because the policy's scale path (and its tests) speak
  /// in scale-TTC terms; the channel definition itself is
  /// the shared one.
  static bool scalePathIntersects({
    required double cx,
    required double cxVelocity,
    required double ttcScaleS,
    required double? rangeM,
  }) {
    return channelIntersects(
      cx: cx,
      cxVelocity: cxVelocity,
      horizonS: ttcScaleS,
      rangeM: rangeM,
    );
  }

  /// Raw (unfiltered) ground-plane range for one detection,
  /// or null when the geometry does not apply: no pitch, box
  /// bottom pinned to the image edge, or the bottom at /
  /// above the horizon line (the tangent then says the
  /// point is at or beyond infinity).
  static double? groundRangeM({
    required double bottom,
    required double pitchDeg,
  }) {
    if (bottom >= NavHazConfig.groundPlaneMaxBottom) return null;
    final double theta = pitchDeg * math.pi / 180;
    final double below =
        math.atan((bottom - NavHazConfig.principalY) / focalY);
    final double denom = math.tan(theta + below);
    if (denom <= 0.02) return null;
    return NavHazConfig.cameraHeightM / denom;
  }

  void forget(int trackId) {
    _filters.remove(trackId);
    _tauNowInBandRun.remove(trackId);
    _preVibratedEpisode.remove(trackId);
  }

  void reset() {
    _filters.clear();
    _tauNowInBandRun.clear();
    _preVibratedEpisode.clear();
  }

  /// Report a pre-urgent EPISODE boundary (NH-M1-11): the
  /// pipeline calls this with [vibrated] = true when a
  /// track's pre-urgent vibration fires (its episode
  /// begins; the latch is set) and with [vibrated] = false
  /// when the episode ENDS (the urgent speech was
  /// delivered, consuming it -- the latch is cleared).
  /// Mid-episode eligibility changes are NOT reported:
  /// they do not move the latch (see
  /// [_preVibratedEpisode]). The exemption reads the latch
  /// in [estimate].
  void notePreUrgent(int trackId, {required bool vibrated}) {
    if (vibrated) {
      _preVibratedEpisode.add(trackId);
    } else {
      _preVibratedEpisode.remove(trackId);
    }
  }

  /// TEST SEAM (NH-M1-11): the persistence guard's current
  /// run length for [trackId] -- the frozen-run assertion
  /// of the exemption tests reads the counter directly
  /// instead of inferring it from publication timing.
  int debugTauNowInBandRun(int trackId) => _tauNowInBandRun[trackId] ?? 0;

  /// TEST SEAM (NH-M1-11): whether [trackId]'s current
  /// pre-urgent episode latch is set (exemption
  /// qualification condition 1).
  bool debugPreVibratedEpisode(int trackId) =>
      _preVibratedEpisode.contains(trackId);

  /// Whether two valid TTC legs contradict each other:
  /// relative difference |a-b| / max(a,b) strictly above
  /// [NavHazConfig.ttcFusionTolerance].
  static bool legsDisagree(double a, double b) =>
      (a - b).abs() / math.max(a, b) > NavHazConfig.ttcFusionTolerance;

  /// Fuse the two TTC legs (spec 2.2): both valid and
  /// consistent -> the smaller; exactly one valid -> that
  /// one; both valid but inconsistent -> null (the pair is
  /// distrusted, never averaged and never min-ed into an
  /// urgent the measurements do not jointly support).
  static double? fuseLegs(double? scale, double? range) {
    if (scale != null && range != null) {
      return legsDisagree(scale, range) ? null : math.min(scale, range);
    }
    return scale ?? range;
  }

  /// Conservative fusion for the NH-M1-11 exemption ONLY:
  /// both legs valid and POSITIVE but disagreeing -> the
  /// SMALLER leg (the more dangerous reading -- the
  /// earlier warning), never an average. Exactly one
  /// valid -> that one, exactly as [fuseLegs]. A
  /// non-positive leg is not a usable reading and never
  /// wins the min (the caller only reaches this helper
  /// when the ordinary fusion distrusted the pair, i.e.
  /// both legs exist; the positivity guard keeps a
  /// degenerate leg from manufacturing a zero tau).
  static double? fuseLegsConservative(double? scale, double? range) {
    if (scale != null && range != null) {
      if (scale <= 0 || range <= 0) return null;
      return math.min(scale, range);
    }
    return scale ?? range;
  }

  /// Estimate one track for the current frame.
  ///
  /// [pitchDeg] is the camera pitch DOWN from horizontal in
  /// degrees (null = unknown; ranging then stays null and
  /// only the scale estimate can fire). [ego] supplies the
  /// user's own speed for the approaching test.
  TrackEstimate estimate(
    Track track, {
    required DateTime at,
    required double? pitchDeg,
    required EgoMotion ego,
  }) {
    final TrackSample s = track.latest!;
    final _FilterPair pair = _filters.putIfAbsent(track.id, _FilterPair.new);

    // --- scale series ---
    final double scaleRaw = math.sqrt(math.max(0, s.w) * math.max(0, s.h));
    final double scaleF = pair.scale.update(scaleRaw, at);
    final double scaleV = pair.scale.velocity;
    double? ttcScale;
    if (scaleV > 1e-6 && scaleF > 0) {
      ttcScale = scaleF / scaleV;
    }
    // Agile tier, same raw series (FIX3B): its one-step
    // predicted TTC (predicted scale over the agile
    // velocity) is the scale leg of the urgent judgement.
    pair.scaleAgile.update(scaleRaw, at);
    double? ttcScalePred;
    if (pair.scaleAgile.velocity > 1e-6 &&
        pair.scaleAgile.predictedNext > 0) {
      ttcScalePred =
          pair.scaleAgile.predictedNext / pair.scaleAgile.velocity;
    }

    // --- range series ---
    double? rangeF;
    double? ttcRange;
    double? closing;
    double? ttcRangePred;
    final double? zRaw =
        pitchDeg == null ? null : groundRangeM(bottom: s.bottom, pitchDeg: pitchDeg);
    if (zRaw != null) {
      rangeF = pair.range.update(zRaw, at);
      final double vz = pair.range.velocity; // dZ/dt (negative = closing)
      closing = -vz;
      if (closing > 1e-6) {
        ttcRange = rangeF / closing;
      }
      // Agile range leg: predicted range over the agile
      // closing speed.
      pair.rangeAgile.update(zRaw, at);
      final double closingAgile = -pair.rangeAgile.velocity;
      if (closingAgile > 1e-6 && pair.rangeAgile.predictedNext > 0) {
        ttcRangePred =
            pair.rangeAgile.predictedNext / closingAgile;
      }
    } else {
      // No ranging this frame: the range estimate is
      // unusable (never carried across a geometry gap).
      rangeF = null;
    }

    // Closing speed fallback: from the scale expansion rate
    // times the range (relative expansion of a rigid target
    // equals the fractional closing rate).
    if (closing == null && rangeF != null && scaleV > 1e-6 && scaleF > 0) {
      closing = rangeF * (scaleV / scaleF);
      // A scale-derived TTC range-equivalent: consistent
      // with ttcScale by construction, so it does not add a
      // separate fused input -- it only feeds `approaching`.
    }

    // --- fusion (spec 2.2; the full consistency rule is
    // written out at NavHazConfig.ttcFusionTolerance) ---
    // CDX2-1: with the ego speed UNKNOWN there is NO
    // fusion at all -- the effective TTC is the scale leg
    // itself, so the range leg can never promote (or
    // demote) an unknown-path judgement, and disagreement
    // is not applicable (no fusion, no divergence). The
    // range leg's own outputs (rangeM, ttcRangeS) keep
    // their diagnostic meaning; only the effective TTC
    // changes. With the ego speed known the two legs fuse
    // exactly as before.
    final bool disagreement = ego.speedKnown &&
        ttcScale != null &&
        ttcRange != null &&
        TtcEstimator.legsDisagree(ttcScale, ttcRange);
    final double? ttc = ego.speedKnown
        ? TtcEstimator.fuseLegs(ttcScale, ttcRange)
        : ttcScale;

    // Approaching: the measured closing must beat the
    // user's own speed by the margin. With the ego speed
    // UNKNOWN (no usable source) an approach can never be
    // confirmed -- the conservative branch of the ego
    // judge. The estimate then carries egoSpeedKnown ==
    // false and the policy runs its dedicated ego-unknown
    // scale path (scale TTC + intersection gate, no
    // approaching judgement at all).
    final double? vEgo = ego.vEgoMps;
    final bool approaching = closing != null &&
        vEgo != null &&
        closing - vEgo > NavHazConfig.approachingMarginMps;

    // --- intersection (CDX3: ONE rule for every path) ---
    // The extrapolated bottom-centre landing point at the
    // TTC horizon must land inside the forward channel
    // (metric +/- channel half width with a range, the
    // central frame fraction without one). The pre-CDX3
    // "extrapolated in OR current box overlaps the
    // [0.33, 0.67] corridor" rule is gone: overlap alone
    // let crossing targets count as will-hit on the frames
    // where their box swept through the corridor.
    final double cxVel = _cxVelocity(track);
    final double horizon = ttc ?? 1.0;
    final bool willHit = channelIntersects(
      cx: s.cx,
      cxVelocity: cxVel,
      horizonS: horizon,
      rangeM: rangeF,
    );

    // --- urgent TTC (FIX3B) ---
    // tau_now = tau_pred - pipelineLatencyS, where
    // tau_pred fuses the two agile predicted legs exactly
    // like the normal TTC (consistency rule included)
    // when the ego speed is known, and is the predicted
    // SCALE leg alone when it is not (the unknown path
    // never fuses). Read ONLY by the policy's urgent
    // branches.
    double? ttcPred = ego.speedKnown
        ? TtcEstimator.fuseLegs(ttcScalePred, ttcRangePred)
        : ttcScalePred;
    // NH-M1-11 exemption: the ordinary fusion just
    // distrusted the agile pair (both legs valid, relative
    // difference beyond the tolerance). The track is
    // exempt from that distrust FOR THIS FRAME when BOTH
    // qualification conditions hold:
    //   (1) its current pre-urgent episode has already
    //       fired the vibration (the [_preVibratedEpisode]
    //       latch -- the pipeline's one-shot semantics,
    //       reported through [notePreUrgent]);
    //   (2) the CURRENT frame still extrapolates into the
    //       forward channel ([willHit], computed above on
    //       the normal tier -- its definition is untouched
    //       by this exemption).
    // Either missing -> the distrust stands verbatim.
    // Exempt: fuse conservatively (the smaller positive
    // agile leg) and mark the frame; the persistence guard
    // below then FREEZES this track's run instead of
    // resetting it. The normal tier above is never
    // exempted: [ttcS] stays null and [disagreement] stays
    // true on an exempt frame.
    bool urgentExempted = false;
    if (ego.speedKnown &&
        ttcPred == null &&
        ttcScalePred != null &&
        ttcRangePred != null &&
        TtcEstimator.legsDisagree(ttcScalePred, ttcRangePred) &&
        _preVibratedEpisode.contains(track.id) &&
        willHit) {
      final double? conservative =
          TtcEstimator.fuseLegsConservative(ttcScalePred, ttcRangePred);
      if (conservative != null) {
        ttcPred = conservative;
        urgentExempted = true;
      }
    }
    final double? tauNowRaw = ttcPred == null
        ? null
        : math.max(0, ttcPred - NavHazConfig.pipelineLatencyS);
    // Jitter guard (spec 2.7.4): the agile tier's gain
    // turns a box-size glitch into a SHORT tau plunge --
    // measured on jitter_car: one frame at true TTC 4.9 s
    // through the SORT backend (tau_now 2.2, neighbours
    // 4.5 / 4.2), two frames through ByteTrack (its own
    // smoothing stretches the whip). tau_now is therefore
    // ISSUED only from the THIRD consecutive in-band
    // estimate: the raw tau_now must sit at or under the
    // urgent band for three estimates in a row, the same
    // sustain-the-evidence philosophy as the 3-frame
    // track confirmation. A genuine crossing pays two
    // frames (0.2 s), which the latency calibration
    // absorbs; a glitch whip never reaches the policy.
    // NH-M1-11: an exemption frame FREEZES the run -- it
    // neither advances it (the frame's evidence is
    // contested) nor resets it (the track's committed
    // evidence stands) -- and tau_now is not issued from a
    // frozen frame; the run resumes accumulating from the
    // frozen value on the next ordinary in-band frame.
    final int inBandRun;
    if (urgentExempted) {
      inBandRun = _tauNowInBandRun[track.id] ?? 0;
    } else if (tauNowRaw != null && tauNowRaw <= NavHazConfig.urgentTtcS) {
      inBandRun = (_tauNowInBandRun[track.id] ?? 0) + 1;
    } else {
      inBandRun = 0;
    }
    _tauNowInBandRun[track.id] = inBandRun;
    final double? ttcUrgent =
        (!urgentExempted && inBandRun >= 3) ? tauNowRaw : null;

    return TrackEstimate(
      track: track,
      ttcS: ttc,
      ttcScaleS: ttcScale,
      ttcRangeS: ttcRange,
      rangeM: rangeF,
      closingSpeedMps: closing,
      approaching: approaching,
      willHit: willHit,
      cxVelocity: cxVel,
      ttcUrgentS: ttcUrgent,
      ttcUrgentRawS: tauNowRaw,
      ttcDisagreement: disagreement,
      egoSpeedKnown: ego.speedKnown,
      scaleRate: scaleV,
      urgentDisagreementExempted: urgentExempted,
      debugAgileScaleTtcS: ttcScalePred,
      debugAgileRangeTtcS: ttcRangePred,
    );
  }

  /// Centre-x velocity from the sample history: the oldest
  /// sample at least two frames back against the latest, so
  /// a single noisy frame cannot invent a crossing.
  double _cxVelocity(Track track) {
    final List<TrackSample> samples = track.samples;
    if (samples.length < 2) return 0;
    final TrackSample last = samples.last;
    TrackSample first = samples.first;
    for (int i = samples.length - 2; i >= 0; i--) {
      first = samples[i];
      if (last.t.difference(first.t).inMilliseconds >= 150) break;
    }
    final double dt = last.t.difference(first.t).inMicroseconds / 1e6;
    if (dt <= 0.01) {
      // Degenerate timestamps (test bursts): fall back to
      // the nominal frame interval times the frame distance.
      final int frames = samples.length - 1;
      final double nominal =
          NavHazConfig.nominalFrameInterval.inMilliseconds / 1000.0;
      return (last.cx - samples.first.cx) / (frames * nominal);
    }
    return (last.cx - first.cx) / dt;
  }
}
