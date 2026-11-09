/// Phone-orientation stability: one of the three conditions
/// that must ALL hold before the avoidance advisor may speak
/// a left/right step (the user's rule, 2026-11-09). A sidestep
/// instruction is only meaningful if the phone -- worn on the
/// chest -- is being held steadily in a known orientation;
/// while the device is swinging or turning, "left" from the
/// camera's frame is not reliably the user's left.
///
/// [GyroStabilityJudge] is the pure decision logic (samples
/// in, verdict out). [OrientationMonitor] is the platform
/// seam; where no sensor source exists the monitor reports
/// unavailable and stability is false -- fail closed, so the
/// advisor falls back to "please stop" announcements.
library;

/// Judges orientation stability from gyroscope magnitudes.
///
/// Stable means: at least [minSamples] samples inside the
/// trailing [window], every sample's angular speed is at
/// or below [maxRadPerSec], AND the data is fresh: if no
/// new sample has arrived for more than [freshnessTimeout]
/// (500 ms, project-lead value), the verdict is NOT stable
/// -- an old "stable" conclusion is never carried forward
/// across a sensor gap. Walking produces a steady sway
/// well under the threshold; turning the body or swinging
/// the phone exceeds it.
class GyroStabilityJudge {
  static const int minSamples = 5;
  static const Duration window = Duration(seconds: 1);
  static const double maxRadPerSec = 0.35;

  /// Freshness bound: no new sample for longer than this
  /// and the orientation counts as unknown (unstable).
  static const Duration freshnessTimeout = Duration(milliseconds: 500);

  final List<({DateTime at, double mag})> _samples =
      <({DateTime at, double mag})>[];

  void addSample(double magnitudeRadPerSec, DateTime now) {
    _samples.add((at: now, mag: magnitudeRadPerSec));
    _samples.removeWhere((s) => now.difference(s.at) > window);
  }

  /// Stability verdict as of [now]. Stale data is never
  /// stable: with no samples at all, or when the newest
  /// sample is older than [freshnessTimeout], this returns
  /// false whatever the old samples said.
  bool isStableAt(DateTime now) {
    if (_samples.isEmpty) return false;
    final DateTime newest = _samples.last.at;
    if (now.difference(newest) > freshnessTimeout) return false;
    final List<({DateTime at, double mag})> recent = _samples
        .where((s) => now.difference(s.at) <= window && !s.at.isAfter(now))
        .toList();
    if (recent.length < minSamples) return false;
    return recent.every((s) => s.mag <= maxRadPerSec);
  }

  /// Verdict at the newest sample's own timestamp (the
  /// historical behaviour, kept for API compatibility).
  /// Callers that poll over time must use [isStableAt] with
  /// the current time, so a sensor stream that stops makes
  /// the verdict go stale instead of sticking at stable.
  bool get isStable =>
      _samples.isEmpty ? false : isStableAt(_samples.last.at);

  void reset() => _samples.clear();
}

/// Platform seam for orientation stability.
abstract class OrientationMonitor {
  /// Whether a real sensor source is feeding this monitor.
  bool get isAvailable;

  /// The latest stability verdict; false whenever the source
  /// is unavailable or has not produced enough samples yet.
  bool get isStable;

  /// Begin listening (idempotent).
  void start();

  /// Stop listening and release the sensor.
  void dispose();
}

/// Fail-closed monitor used where no sensor source exists
/// (web, tests, unsupported devices): orientation is never
/// "stable", so no sidestep direction is ever derived from
/// it. Honest by construction.
class UnavailableOrientationMonitor implements OrientationMonitor {
  const UnavailableOrientationMonitor();

  @override
  bool get isAvailable => false;

  @override
  bool get isStable => false;

  @override
  void start() {}

  @override
  void dispose() {}
}
