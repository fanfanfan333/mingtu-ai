import 'dart:async';

import '../adapters/voice_io.dart';
import 'haptics.dart';

/// Retries after delays measured from the end of each failed attempt.
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
  final Future<VoiceOutput?> Function() rebuild;
  final void Function(VoiceOutput, String) onRecovered;
  final Haptics Function() haptics;
  final DateTime Function() now;
  final Timer Function(Duration, void Function()) _schedule;
  Timer? _retry;
  Timer? _vibration;
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

  /// Repeat the urgent waveform for as long as recovery is pending.
  void danger() {
    if (!_failed || _disposed || _vibration != null) return;
    void pulse() {
      if (!_failed || _disposed) return;
      unawaited(haptics().vibrateUrgent());
      _vibration = _schedule(const Duration(milliseconds: 400), pulse);
    }

    pulse();
  }

  void stopDanger() {
    _vibration?.cancel();
    _vibration = null;
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    stopDanger();
  }
}
