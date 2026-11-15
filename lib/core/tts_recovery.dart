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
    _dangerCap = _schedule(dangerDurationCap, () {
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
      _vibration = _schedule(const Duration(milliseconds: 400), pulse);
    }

    pulse();
  }

  void stopDanger() {
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
