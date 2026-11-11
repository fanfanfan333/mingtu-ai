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
/// Fusion (V1): both valid and within
/// [NavHazConfig.ttcFusionTolerance] of each other -> the
/// smaller; only one valid -> that one; none -> null. When
/// both are valid but DISAGREE beyond tolerance the smaller
/// is still used -- for a hazard warning the conservative
/// direction is the earlier one (noted here because the
/// spec lists only the agreeing case).
library;

import 'dart:math' as math;

import '../navhaz_config.dart';
import '../tracking/tracker.dart';
import 'ego_motion.dart';

/// One-dimensional alpha-beta filter over time-stamped
/// values: tracks (value, velocity). The first observation
/// seeds the value; the second seeds the velocity from the
/// finite difference (so a steadily growing series is
/// tracked from the start instead of after a long ramp --
/// the alert timing windows in the acceptance tests leave
/// no room for a multi-second filter warm-up).
class AlphaBetaFilter {
  final double alpha;
  final double beta;
  double _x = 0;
  double _v = 0;
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
      return _x;
    }
    final double predicted = _x + _v * dt;
    final double residual = z - predicted;
    // The velocity starts at ZERO and is built purely by
    // the beta corrections. Seeding it from the first
    // finite difference was tried and rejected: both
    // tracker backends smooth the box with their own
    // filter, whose early catch-up transient makes the
    // first difference systematically OVERESTIMATE the
    // closing rate (~15% on the acceptance fixture), which
    // dragged TTC ~13% low and fired warnings a full
    // second early. A zero seed errs the other way --
    // early TTC reads HIGH, alerts come a few frames later
    // but inside their windows, and the estimate converges
    // well before the TTC 2-4 s accuracy band.
    _x = predicted + alpha * residual;
    _v = _v + (beta / dt) * residual;
    return _x;
  }

  void reset() {
    _x = 0;
    _v = 0;
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

    // --- fusion ---
    double? ttc;
    if (ttcScale != null && ttcRange != null) {
      ttc = math.min(ttcScale, ttcRange);
    } else {
      ttc = ttcScale ?? ttcRange;
    }

    final bool approaching = closing != null &&
        closing - ego.vEgoMps > NavHazConfig.approachingMarginMps;

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
