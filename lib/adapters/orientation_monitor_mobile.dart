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
  StreamSubscription<GyroscopeEvent>? _sub;
  bool _available = false;

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
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}

OrientationMonitor createOrientationMonitor() => GyroscopeOrientationMonitor();
