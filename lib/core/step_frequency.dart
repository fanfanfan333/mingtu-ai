/// Sliding-window accelerometer-magnitude statistics for
/// the ego-motion judge (NAVHAZ M1 fix round): variance
/// and step frequency over the trailing
/// [NavHazConfig.accelWindow].
///
/// Pure Dart and sensor-free: the platform pitch monitor
/// feeds magnitude samples in; unit tests feed synthetic
/// ones. The magnitude includes gravity (~9.81 m/s^2), so
/// the series is detrended by its own mean before peak
/// counting.
library;

import 'dart:math' as math;

import 'navhaz_config.dart';

class _MagSample {
  final DateTime t;
  final double mag;
  const _MagSample(this.t, this.mag);
}

class StepFrequencyEstimator {
  final List<_MagSample> _samples = <_MagSample>[];

  /// Below this magnitude variance ((m/s^2)^2) the signal
  /// carries no step rhythm at all: the frequency reads
  /// exactly 0 (a stationary user), not sensor noise.
  static const double _stillVariance = 0.02;

  /// Minimum spacing between counted step peaks: caps the
  /// readable cadence at ~3.5 Hz, above any walking pace.
  static const Duration _minPeakGap = Duration(milliseconds: 280);

  void add(double magnitude, DateTime t) {
    _samples.add(_MagSample(t, magnitude));
    final DateTime cutoff = t.subtract(NavHazConfig.accelWindow);
    _samples.removeWhere((_MagSample s) => s.t.isBefore(cutoff));
  }

  void clear() => _samples.clear();

  int get sampleCount => _samples.length;

  /// Enough signal to judge at all: a handful of samples
  /// spanning most of a second.
  bool get _usable =>
      _samples.length >= 8 &&
      _samples.last.t.difference(_samples.first.t) >=
          const Duration(milliseconds: 800);

  double? get variance {
    if (!_usable) return null;
    double mean = 0;
    for (final _MagSample s in _samples) {
      mean += s.mag;
    }
    mean /= _samples.length;
    double acc = 0;
    for (final _MagSample s in _samples) {
      final double d = s.mag - mean;
      acc += d * d;
    }
    return acc / _samples.length;
  }

  /// Step peaks per second over the window, or null when
  /// the window holds too little signal to judge.
  double? get stepFrequencyHz {
    final double? v = variance;
    if (v == null) return null;
    if (v < _stillVariance) return 0;
    double mean = 0;
    for (final _MagSample s in _samples) {
      mean += s.mag;
    }
    mean /= _samples.length;
    final double threshold = mean + 0.25 * math.sqrt(v);
    int peaks = 0;
    DateTime? lastPeakAt;
    for (int i = 1; i + 1 < _samples.length; i++) {
      final _MagSample s = _samples[i];
      if (s.mag <= threshold) continue;
      if (s.mag < _samples[i - 1].mag || s.mag <= _samples[i + 1].mag) {
        continue;
      }
      if (lastPeakAt != null && s.t.difference(lastPeakAt) < _minPeakGap) {
        continue;
      }
      peaks++;
      lastPeakAt = s.t;
    }
    final double seconds =
        _samples.last.t.difference(_samples.first.t).inMilliseconds / 1000.0;
    if (seconds <= 0) return null;
    return peaks / seconds;
  }
}
