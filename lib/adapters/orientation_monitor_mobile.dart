import 'dart:async';
import 'dart:math' as math;

import 'package:sensors_plus/sensors_plus.dart';

import '../core/orientation.dart';

/// Gyroscope-backed orientation monitor (sensors_plus).
/// Feeds angular-speed magnitudes into the pure
/// [GyroStabilityJudge]; the verdict logic lives there and
/// is unit-tested without hardware.
class GyroscopeOrientationMonitor implements OrientationMonitor {
  final GyroStabilityJudge _judge = GyroStabilityJudge();
  final HeadingTracker _heading = HeadingTracker();
  StreamSubscription<GyroscopeEvent>? _sub;
  StreamSubscription<MagnetometerEvent>? _magSub;
  bool _available = false;

  /// The phone's compass heading right now, or null when
  /// the magnetometer has not produced a sample within
  /// the 500 ms freshness bound (entrance guidance then
  /// announces distance only).
  @override
  double? get currentHeadingDeg => _heading.headingAt(DateTime.now());

  @override
  bool get isAvailable => _available;

  @override
  // Evaluated at query time (isStableAt), so a sensor
  // stream that stops delivering turns the verdict
  // unstable within the freshness bound instead of
  // replaying the last good one.
  bool get isStable => _available && _judge.isStableAt(DateTime.now());

  @override
  void start() {
    if (_sub != null) return;
    try {
      _sub = gyroscopeEventStream().listen(
        (GyroscopeEvent e) {
          _available = true;
          final double mag = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
          _judge.addSample(mag, DateTime.now());
        },
        onError: (Object _) {
          _available = false;
        },
      );
    } catch (_) {
      _available = false;
    }
    // Heading source for entrance guidance (step D): the
    // magnetometer feeds the pure HeadingTracker. Failure
    // here only means "no heading" (distance-only guidance)
    // -- it never affects the stability verdict above.
    try {
      _magSub = magnetometerEventStream().listen(
        (MagnetometerEvent e) {
          _heading.addField(e.x, e.y, DateTime.now());
        },
        onError: (Object _) {},
      );
    } catch (_) {
      // No magnetometer: heading stays unknown.
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    _magSub?.cancel();
    _magSub = null;
  }
}

OrientationMonitor createOrientationMonitor() => GyroscopeOrientationMonitor();
