import 'dart:async';

import '../adapters/voice_io.dart';
import 'haptics.dart';

/// Retries after delays measured from the end of each failed attempt.
enum DangerLevel { warning, urgent }

class TtsRecoveryController {
  TtsRecoveryController({
    required this.rebuild,
    required this.onRecovered,
    required this.haptics,
    DateTime Function()? now,
    Timer Function(Duration, void Function())? schedule,
  })  : now = now ?? DateTime.now,
        _schedule = schedule ?? Timer.new;

  static const announcement = '语音已恢复';
  static const dangerDurationCap = Duration(seconds: 30);
  static const dangerRollingWindow = Duration(seconds: 60);
  static const dangerRollingCap = Duration(seconds: 45);
  final List<(DateTime, DateTime)> _dangerIntervals = [];
  DateTime? _dangerStartedAt;

  final Future<VoiceOutput?> Function() rebuild;
  final void Function(VoiceOutput, String) onRecovered;
  final Haptics Function() haptics;
  final DateTime Function() now;
  final Timer Function(Duration, void Function()) _schedule;
  Timer? _retry;
  Timer? _vibration;
  Timer? _dangerCap;
  bool _dangerExhausted = false;
  int? _dangerTrackId;
  String? _dangerEventId;
  DangerLevel? _dangerLevel;
  bool _failed = false;
  bool _disposed = false;
  int _attempt = 0;
  DateTime? failedAt;

  bool get failed => _failed;
  bool get vibrating => _vibration != null;

  void fail() {
    if (_disposed || _failed) return;
    _failed = true;
    failedAt = now();
    _attempt = 0;
    _scheduleRetry();
  }

  void _scheduleRetry() {
    final seconds = _attempt == 0 ? 1 : (_attempt == 1 ? 3 : 10);
    _retry = _schedule(Duration(seconds: seconds), _tryRebuild);
  }

  Future<void> _tryRebuild() async {
    VoiceOutput? output;
    try {
      output = await rebuild();
    } catch (_) {
      // An unsuccessful rebuild leaves the unavailable output in place.
    }
    if (_disposed || !_failed) return;
    if (output == null || !output.isAvailable) {
      _attempt++;
      _scheduleRetry();
      return;
    }
    _failed = false;
    stopDanger();
    onRecovered(output, announcement);
  }

  /// Repeat while recovery is pending and until the caller clears danger.
  void danger(
      {int? trackId, String? eventId, DangerLevel level = DangerLevel.urgent}) {
    if (!_failed || _disposed) return;
    final different = (trackId != null &&
            _dangerTrackId != null &&
            trackId != _dangerTrackId) ||
        (eventId != null &&
            _dangerEventId != null &&
            eventId != _dangerEventId);
    final escalated = _dangerLevel != null && level.index > _dangerLevel!.index;
    if (different || escalated) {
      _endDangerInterval();
      _dangerCap?.cancel();
      _vibration?.cancel();
      _dangerCap = null;
      _vibration = null;
      _dangerExhausted = false;
      if (different) {
        _dangerTrackId = null;
        _dangerEventId = null;
        _dangerLevel = null;
      }
    }
    _dangerTrackId ??= trackId;
    _dangerEventId ??= eventId;
    if (_dangerLevel == null || level.index > _dangerLevel!.index) {
      _dangerLevel = level;
    }
    if (_vibration != null || _dangerExhausted) return;
    final start = now();
    _dangerIntervals.removeWhere((interval) =>
        !interval.$2.isAfter(start.subtract(dangerRollingWindow)));
    Duration episodeDuration = dangerDurationCap;
    if (!escalated) {
      // Usage during a continuously running episode is monotonic over this
      // window: old active time can leave no faster than new time enters.
      int usageAt(int micros) {
        final end = start.add(Duration(microseconds: micros));
        final cutoff = end.subtract(dangerRollingWindow);
        var used = micros;
        for (final interval in _dangerIntervals) {
          final from = interval.$1.isAfter(cutoff) ? interval.$1 : cutoff;
          if (interval.$2.isAfter(from)) {
            used += interval.$2.difference(from).inMicroseconds;
          }
        }
        return used;
      }

      final cap = dangerRollingCap.inMicroseconds;
      if (usageAt(0) >= cap) return;
      var low = 0;
      var high = dangerDurationCap.inMicroseconds;
      while (low < high) {
        final mid = (low + high + 1) ~/ 2;
        if (usageAt(mid) <= cap) {
          low = mid;
        } else {
          high = mid - 1;
        }
      }
      episodeDuration = Duration(microseconds: low);
    }
    _dangerStartedAt = start;
    _dangerCap = _schedule(episodeDuration, () {
      _endDangerInterval();
      _vibration?.cancel();
      _vibration = null;
      _dangerCap = null;
      _dangerExhausted = true;
    });
    void pulse() {
      if (!_failed || _disposed) return;
      unawaited(_dangerLevel == DangerLevel.warning
          ? haptics().vibrateWarning()
          : haptics().vibrateUrgent());
      _vibration = _schedule(
          _dangerLevel == DangerLevel.warning
              ? const Duration(milliseconds: 1500)
              : const Duration(milliseconds: 400),
          pulse);
    }

    pulse();
  }

  void _endDangerInterval() {
    final start = _dangerStartedAt;
    if (start != null) {
      _dangerIntervals.add((start, now()));
      _dangerStartedAt = null;
    }
  }

  void stopDanger() {
    _endDangerInterval();
    _dangerCap?.cancel();
    _dangerCap = null;
    _dangerExhausted = false;
    _dangerTrackId = null;
    _dangerEventId = null;
    _dangerLevel = null;
    _vibration?.cancel();
    _vibration = null;
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    stopDanger();
  }
}
