import 'navhaz_config.dart';

/// Schedules best-effort lens captures without overlapping them.
class LensSampleScheduler {
  LensSampleScheduler({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const Duration normalInterval = Duration(milliseconds: 500);
  static const Duration deratedInterval = Duration(seconds: 1);

  final DateTime Function() _now;
  DateTime? _lastStartedAt;
  Duration? _lastDuration;
  bool _inFlight = false;

  /// Starts [sample] if the current cadence and in-flight state allow it.
  Future<void> request(
    Future<void> Function() sample, {
    int? appliedFps,
    bool analysisCap720p = false,
  }) async {
    final DateTime now = _now();
    final bool heatLimited = analysisCap720p ||
        (appliedFps != null &&
            appliedFps <= NavHazConfig.thermalCapModerateFps);
    final Duration interval = heatLimited ||
            (_lastDuration != null && _lastDuration! >= normalInterval)
        ? deratedInterval
        : normalInterval;
    if (_inFlight ||
        (_lastStartedAt != null &&
            now.difference(_lastStartedAt!) < interval)) {
      return;
    }
    _inFlight = true;
    _lastStartedAt = now;
    try {
      await sample();
    } finally {
      _lastDuration = _now().difference(now);
      _inFlight = false;
    }
  }
}
