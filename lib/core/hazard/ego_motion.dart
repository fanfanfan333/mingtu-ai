/// Ego-motion judgement for NAVHAZ M1 (spec section 2.2).
///
/// V1 keeps this deliberately coarse: the user is either
/// standing still or walking, judged from the accelerometer
/// magnitude variance and the GPS speed. The walking speed
/// itself is the spec's provisional constant
/// ([NavHazConfig.walkingSpeedMps]) -- no IMU self-motion
/// subtraction is attempted in V1 (that is V2 work).
library;

import '../navhaz_config.dart';

enum EgoState { still, walking }

class EgoMotion {
  final EgoState state;

  /// The user's own forward speed estimate, m/s: the GPS
  /// speed when a trustworthy one exists, else the walking
  /// constant while walking, else 0.
  final double vEgoMps;

  const EgoMotion._(this.state, this.vEgoMps);

  /// Judge from sensor evidence:
  /// - [accelVariance]: variance of the accelerometer
  ///   magnitude over a recent window, (m/s^2)^2, or null
  ///   when no IMU evidence exists;
  /// - [gpsSpeedMps]: the GPS-reported speed, or null.
  ///
  /// Walking when EITHER source says so (a quiet IMU must
  /// not veto clear GPS motion, and vice versa). With no
  /// evidence at all the verdict is still / 0 -- the
  /// approaching test then uses the raw relative speed,
  /// which is the conservative direction for vehicles.
  factory EgoMotion.judge({double? accelVariance, double? gpsSpeedMps}) {
    final bool byAccel = accelVariance != null &&
        accelVariance >= NavHazConfig.walkingAccelVariance;
    final bool byGps =
        gpsSpeedMps != null && gpsSpeedMps >= NavHazConfig.walkingGpsSpeedMps;
    if (!byAccel && !byGps) {
      return const EgoMotion._(EgoState.still, 0);
    }
    final double v = (gpsSpeedMps != null && gpsSpeedMps > 0)
        ? gpsSpeedMps
        : NavHazConfig.walkingSpeedMps;
    return EgoMotion._(EgoState.walking, v);
  }

  static const EgoMotion still = EgoMotion._(EgoState.still, 0);

  bool get isWalking => state == EgoState.walking;
}
