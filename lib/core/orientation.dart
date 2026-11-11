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

import 'dart:math' as math;

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

  /// The phone's current compass heading in degrees, or
  /// null when no fresh heading sample exists (older than
  /// 500 ms) or the source has no magnetometer. Entrance
  /// guidance treats null as "distance only".
  double? get currentHeadingDeg;

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
  double? get currentHeadingDeg => null;

  @override
  void start() {}

  @override
  void dispose() {}
}

/// Tracks the phone's compass heading from magnetometer
/// samples, for the entrance guidance's relative directions
/// (step D adjustment). Pure sample store plus the same
/// 500 ms freshness rule as the gyroscope judge: a heading
/// older than [HeadingTracker.freshnessTimeout] is not a
/// heading at all -- callers must treat it as unknown and
/// announce distance only, never a direction derived from
/// stale data.
class HeadingTracker {
  static const Duration freshnessTimeout = Duration(milliseconds: 500);

  double? _headingDeg;
  DateTime? _at;

  /// Record one heading sample (degrees clockwise from
  /// north; any range is accepted and normalised on read).
  void addSample(double headingDeg, DateTime now) {
    _headingDeg = headingDeg;
    _at = now;
  }

  /// Record a raw magnetometer vector (microteslas). The
  /// heading assumes the phone is roughly level with its
  /// top edge pointing the way the user faces -- the
  /// chest-worn premise of this app; a strongly tilted
  /// device makes the value approximate, which is why the
  /// spoken directions stay coarse (six wide sectors).
  void addField(double x, double y, DateTime now) {
    if (x == 0 && y == 0) return;
    addSample(math.atan2(x, -y) * 180.0 / math.pi, now);
  }

  /// The heading as of [now], or null when there is no
  /// sample or the newest sample is older than the
  /// freshness timeout.
  double? headingAt(DateTime now) {
    final DateTime? at = _at;
    final double? h = _headingDeg;
    if (at == null || h == null) return null;
    if (now.difference(at) > freshnessTimeout) return null;
    return ((h % 360.0) + 360.0) % 360.0;
  }

  void reset() {
    _headingDeg = null;
    _at = null;
  }
}
