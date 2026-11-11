/// Camera pitch for ground-plane ranging (NAVHAZ M1, spec
/// section 2.2): the pure math + the monitor seam.
///
/// Convention: pitch is the camera's DOWNWARD tilt from
/// horizontal, in degrees (positive = looking down). For a
/// phone held roughly in portrait, the accelerometer's
/// gravity vector (device axes: x right, y up along the
/// screen, z out of the screen) gives it directly:
///
///   pitchDown = atan2(a_z, a_y)
///
/// Checks: upright portrait (a = (0, g, 0)) -> 0, camera
/// level; lying face-up (a = (0, 0, g), back camera facing
/// the ground) -> +90; face-down -> -90.
library;

import 'dart:math' as math;

/// Pitch down in degrees from one gravity sample.
double pitchDownDegFromGravity(double ax, double ay, double az) {
  return math.atan2(az, ay) * 180 / math.pi;
}

/// Platform seam: the current camera pitch, or null when
/// unknown / stale (ranging then stays disabled -- the
/// scale TTC still works; nothing guesses a pitch).
abstract class PitchMonitor {
  double? get currentPitchDeg;
  bool get isAvailable;
  void start();
  void dispose();
}

/// Fail-closed monitor: pitch always unknown.
class UnavailablePitchMonitor implements PitchMonitor {
  const UnavailablePitchMonitor();

  @override
  double? get currentPitchDeg => null;

  @override
  bool get isAvailable => false;

  @override
  void start() {}

  @override
  void dispose() {}
}
