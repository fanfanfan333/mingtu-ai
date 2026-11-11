/// Ego-motion judgement for NAVHAZ M1 (spec section 2.2).
///
/// V1 keeps this deliberately coarse: the user is either
/// standing still or walking, and the estimate carries the
/// user's own forward speed [vEgoMps] -- the value the
/// vehicle "approaching" test subtracts from the measured
/// relative closing speed (a vehicle counts as approaching
/// only when v_rel - v_ego > [NavHazConfig.approachingMarginMps]).
///
/// Speed-source priority (M1 fix round):
/// 1. GPS speed, when the fix that carried it is accurate
///    enough ([NavHazConfig.gpsSpeedMaxAccuracyM]) and
///    fresh (freshness is the CALLER's gate: a stale speed
///    is passed as null);
/// 2. the accelerometer step-frequency estimate
///    (step frequency x [NavHazConfig.strideLengthM]) --
///    a stationary user reads ~= 0 Hz here, i.e. still;
/// 3. accelerometer variance alone (walking at the
///    provisional [NavHazConfig.walkingSpeedMps], or still).
///
/// When NO source is usable the speed is UNKNOWN
/// ([speedKnown] == false). The TTC estimator then never
/// confirms a vehicle as "approaching" -- an unproven
/// approach must not promote a hazard on the approaching
/// rule. Instead the policy runs its dedicated ego-unknown
/// scale path (lead's ruling, 2026-11-11): levels from the
/// box-scale TTC alone, gated by an intersection test,
/// under a longer repeat cooldown -- see hazard_policy.
library;

import '../navhaz_config.dart';

enum EgoState { still, walking }

class EgoMotion {
  final EgoState state;

  /// The user's own forward speed estimate, m/s, or null
  /// when no source could judge it (see the library doc:
  /// unknown speed means "approach cannot be confirmed").
  final double? vEgoMps;

  const EgoMotion._(this.state, this.vEgoMps);

  /// Judge from sensor evidence, in the priority order
  /// documented at the top of this file. Parameters are
  /// null when the corresponding source has no usable
  /// reading right now.
  factory EgoMotion.judge({
    double? accelVariance,
    double? stepFrequencyHz,
    double? gpsSpeedMps,
    double? gpsAccuracyM,
  }) {
    // 1. GPS speed: trusted when the carrying fix is
    // accurate enough. (When no accuracy is supplied the
    // reading is taken at face value -- production callers
    // always supply the fix accuracy.)
    if (gpsSpeedMps != null &&
        gpsSpeedMps >= 0 &&
        (gpsAccuracyM == null ||
            gpsAccuracyM <= NavHazConfig.gpsSpeedMaxAccuracyM)) {
      return EgoMotion._(
        gpsSpeedMps >= NavHazConfig.walkingGpsSpeedMps
            ? EgoState.walking
            : EgoState.still,
        gpsSpeedMps,
      );
    }
    // 2. Step-frequency estimate: frequency x stride. A
    // stationary user produces ~= 0 Hz, hence still at 0.
    if (stepFrequencyHz != null) {
      final double v = stepFrequencyHz * NavHazConfig.strideLengthM;
      return EgoMotion._(
        v >= NavHazConfig.walkingGpsSpeedMps
            ? EgoState.walking
            : EgoState.still,
        v,
      );
    }
    // 3. Variance alone: walking at the provisional
    // constant, or known-still.
    if (accelVariance != null) {
      return accelVariance >= NavHazConfig.walkingAccelVariance
          ? const EgoMotion._(EgoState.walking, NavHazConfig.walkingSpeedMps)
          : const EgoMotion._(EgoState.still, 0);
    }
    // 4. No usable source: speed unknown (conservative).
    return unknown;
  }

  static const EgoMotion still = EgoMotion._(EgoState.still, 0);

  /// No evidence from any source: state reads still but
  /// the SPEED is unknown, which is what the approaching
  /// test keys on.
  static const EgoMotion unknown = EgoMotion._(EgoState.still, null);

  bool get isWalking => state == EgoState.walking;

  /// Whether [vEgoMps] is a real estimate (vs unknown).
  bool get speedKnown => vEgoMps != null;
}
