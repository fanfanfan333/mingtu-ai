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
      : alpha = alpha ?? NavHazConfig.alphaBetaAlpha,
        beta = beta ?? NavHazConfig.alphaBetaBeta;

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

  /// True when the target's extrapolated path intersects
  /// the walking corridor within its TTC horizon.
  final bool willHit;

  /// Centre-x velocity, normalised units per second.
  final double cxVelocity;

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
    this.ttcDisagreement = false,
  });
}

class _FilterPair {
  final AlphaBetaFilter scale = AlphaBetaFilter();
  final AlphaBetaFilter range = AlphaBetaFilter();
}

/// Stateful estimator: one pair of filters per track id,
/// fed frame by frame by the hazard pipeline.
class TtcEstimator {
  final Map<int, _FilterPair> _filters = <int, _FilterPair>{};

  /// Focal length in normalised units, from the configured
  /// vertical FOV: f_y = 0.5 / tan(VFOV/2).
  static double get focalY =>
      0.5 / math.tan(NavHazConfig.verticalFovDeg * math.pi / 180 / 2);

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

  void forget(int trackId) => _filters.remove(trackId);

  void reset() => _filters.clear();

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

    // --- range series ---
    double? rangeF;
    double? ttcRange;
    double? closing;
    final double? zRaw =
        pitchDeg == null ? null : groundRangeM(bottom: s.bottom, pitchDeg: pitchDeg);
    if (zRaw != null) {
      rangeF = pair.range.update(zRaw, at);
      final double vz = pair.range.velocity; // dZ/dt (negative = closing)
      closing = -vz;
      if (closing > 1e-6) {
        ttcRange = rangeF / closing;
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
    final bool disagreement = ttcScale != null &&
        ttcRange != null &&
        TtcEstimator.legsDisagree(ttcScale, ttcRange);
    final double? ttc = TtcEstimator.fuseLegs(ttcScale, ttcRange);

    // Approaching: the measured closing must beat the
    // user's own speed by the margin. With the ego speed
    // UNKNOWN (no usable source) an approach can never be
    // confirmed -- the conservative branch of the ego
    // judge; the estimate then flows through the range /
    // TTC == null policy rules only.
    final double? vEgo = ego.vEgoMps;
    final bool approaching = closing != null &&
        vEgo != null &&
        closing - vEgo > NavHazConfig.approachingMarginMps;

    // --- corridor intersection ---
    final double cxVel = _cxVelocity(track);
    final double horizon = ttc ?? 1.0;
    final double cxAtHit = s.cx + cxVel * horizon;
    final bool extrapolatedIn = cxAtHit >= NavHazConfig.corridorLeft &&
        cxAtHit <= NavHazConfig.corridorRight;
    final bool boxOverlaps = (s.cx + s.w / 2) >= NavHazConfig.corridorLeft &&
        (s.cx - s.w / 2) <= NavHazConfig.corridorRight;
    final bool willHit = extrapolatedIn || boxOverlaps;

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
      ttcDisagreement: disagreement,
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
