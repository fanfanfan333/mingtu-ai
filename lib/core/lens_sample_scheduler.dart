/// Schedules best-effort lens captures without overlapping them.
class LensSampleScheduler {
  LensSampleScheduler({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const Duration normalInterval = Duration(milliseconds: 500);
  static const Duration deratedInterval = Duration(seconds: 1);

  static const Duration inFlightTimeout = Duration(seconds: 3);

  final DateTime Function() _now;
  DateTime? _lastStartedAt;
  Duration? _lastDuration;
  bool _inFlight = false;
  int _generation = 0;

  /// Starts [sample] if the current cadence and in-flight state allow it.
  Future<void> request(
    Future<void> Function() sample, {
    bool analysisCap720p = false,
  }) async {
    final DateTime now = _now();
    final bool heatLimited = analysisCap720p;
    final Duration interval = heatLimited ||
            (_lastDuration != null && _lastDuration! >= normalInterval)
        ? deratedInterval
        : normalInterval;
    if (_inFlight && now.difference(_lastStartedAt!) >= inFlightTimeout) {
      _inFlight = false;
    }
    if (_inFlight ||
        (_lastStartedAt != null &&
            now.difference(_lastStartedAt!) < interval)) {
      return;
    }
    _inFlight = true;
    final int generation = ++_generation;
    _lastStartedAt = now;
    try {
      await sample();
    } finally {
      if (generation == _generation) {
        _lastDuration = _now().difference(now);
        _inFlight = false;
      }
    }
  }
}
