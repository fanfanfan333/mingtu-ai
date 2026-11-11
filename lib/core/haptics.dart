/// Vibration seam for NAVHAZ M1 (spec section 2.5).
///
/// Patterns are (timings, amplitudes) waveform pairs from
/// [NavHazConfig]. The platform implementation talks to the
/// app's own `mingtu/device` MethodChannel (native Kotlin,
/// VibrationEffect.createWaveform); where no channel exists
/// the call degrades to a plain single buzz and then to
/// nothing -- a hazard alert must never depend on the
/// vibration succeeding.
library;

import 'navhaz_config.dart';

abstract class Haptics {
  /// Play an arbitrary waveform pattern. Timings alternate
  /// wait/vibrate starting with a wait; amplitudes are
  /// parallel (0 = off, 255 = full).
  Future<void> vibratePattern(List<int> timings, List<int> amplitudes);

  /// URGENT pattern: three strong pulses.
  Future<void> vibrateUrgent() => vibratePattern(
        NavHazConfig.urgentVibrationTimings,
        NavHazConfig.urgentVibrationAmplitudes,
      );

  /// WARNING pattern: two light taps.
  Future<void> vibrateWarning() => vibratePattern(
        NavHazConfig.warningVibrationTimings,
        NavHazConfig.warningVibrationAmplitudes,
      );
}

/// No-op haptics: tests that do not care about vibration,
/// and platforms without a device channel.
class NoOpHaptics implements Haptics {
  const NoOpHaptics();

  @override
  Future<void> vibratePattern(
      List<int> timings, List<int> amplitudes) async {}

  @override
  Future<void> vibrateUrgent() async {}

  @override
  Future<void> vibrateWarning() async {}
}

/// Recording fake for tests: every call is logged with its
/// kind ('urgent' / 'warning' / 'pattern') in call order.
class RecordingHaptics implements Haptics {
  final List<String> calls = <String>[];
  final List<List<int>> patterns = <List<int>>[];

  @override
  Future<void> vibratePattern(
      List<int> timings, List<int> amplitudes) async {
    calls.add('pattern');
    patterns.add(timings);
  }

  @override
  Future<void> vibrateUrgent() async {
    calls.add('urgent');
    patterns.add(NavHazConfig.urgentVibrationTimings);
  }

  @override
  Future<void> vibrateWarning() async {
    calls.add('warning');
    patterns.add(NavHazConfig.warningVibrationTimings);
  }
}
