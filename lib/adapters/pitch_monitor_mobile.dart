import 'dart:async';
import 'dart:math' as math;

import 'package:sensors_plus/sensors_plus.dart';

import '../core/pitch.dart';
import '../core/step_frequency.dart';

/// Accelerometer-backed pitch monitor (sensors_plus). The
/// gravity vector is lightly low-passed (walking shake
/// would otherwise swing the ranging input frame to frame),
/// and the reading goes stale after the same 500 ms
/// freshness bound the heading tracker uses: no fresh
/// sample -> pitch unknown -> ranging off, never a replayed
/// old angle.
///
/// The SAME subscription feeds a [StepFrequencyEstimator]
/// with the acceleration magnitude: that is the ego-motion
/// evidence (variance + step frequency) the hazard pipeline
/// consumes -- no second sensor subscription is opened.
class AccelerometerPitchMonitor implements PitchMonitor {
  static const Duration freshness = Duration(milliseconds: 500);

  StreamSubscription<AccelerometerEvent>? _sub;
  double? _smoothedDeg;
  DateTime? _lastAt;
  bool _available = false;
  final StepFrequencyEstimator _steps = StepFrequencyEstimator();

  @override
  double? get currentPitchDeg {
    final DateTime? last = _lastAt;
    if (last == null || DateTime.now().difference(last) > freshness) {
      return null;
    }
    return _smoothedDeg;
  }

  @override
  bool get isAvailable => _available;

  @override
  double? get currentAccelVariance =>
      isAvailable ? _steps.variance : null;

  @override
  double? get currentStepFrequencyHz =>
      isAvailable ? _steps.stepFrequencyHz : null;

  @override
  void start() {
    if (_sub != null) return;
    try {
      _sub = accelerometerEventStream().listen(
        (AccelerometerEvent e) {
          _available = true;
          final double deg = pitchDownDegFromGravity(e.x, e.y, e.z);
          _smoothedDeg =
              _smoothedDeg == null ? deg : _smoothedDeg! * 0.8 + deg * 0.2;
          final DateTime now = DateTime.now();
          _lastAt = now;
          _steps.add(math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z), now);
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
    _steps.clear();
  }
}

PitchMonitor createPitchMonitor() => AccelerometerPitchMonitor();
