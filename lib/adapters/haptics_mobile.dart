import 'package:flutter/services.dart';

import '../core/haptics.dart';
import '../core/navhaz_config.dart';

/// Device haptics through the app's own `mingtu/device`
/// MethodChannel (MainActivity.kt, VibrationEffect
/// waveform). The native side answers a bool: true when
/// the pattern was handed to the vibrator, false when it
/// was NOT executed (invalid arguments, missing VIBRATE
/// permission, platform exception). A false is recorded
/// in [HapticsFailureLog] -- never silently swallowed --
/// and a plain framework buzz is attempted as a degraded
/// fallback. A missing channel degrades the same way, and
/// then to silence: the alert flow never awaits success
/// here, but it can always OBSERVE failure.
///
/// The urgent / warning entry points are overridden
/// explicitly: the [NoOpHaptics] base implements them as
/// no-ops, so inheriting them would silently drop every
/// hazard pattern (a latent defect this fix round removes
/// -- the patterns now reach the channel).
class DeviceHaptics extends NoOpHaptics {
  static const MethodChannel _channel = MethodChannel('mingtu/device');

  @override
  Future<void> vibrateUrgent() => vibratePattern(
        NavHazConfig.urgentVibrationTimings,
        NavHazConfig.urgentVibrationAmplitudes,
      );

  @override
  Future<void> vibrateWarning() => vibratePattern(
        NavHazConfig.warningVibrationTimings,
        NavHazConfig.warningVibrationAmplitudes,
      );

  @override
  Future<void> vibratePattern(
      List<int> timings, List<int> amplitudes) async {
    try {
      final bool? executed = await _channel.invokeMethod<bool>(
          'vibratePattern', <String, Object>{
        'timings': timings,
        'amplitudes': amplitudes,
      });
      if (executed == true) return;
      // Native explicitly reports the pattern did not
      // run: make the failure observable, then fall back.
      HapticsFailureLog.record();
    } catch (_) {
      // No channel / platform error: degrade below.
    }
    try {
      await HapticFeedback.vibrate();
    } catch (_) {
      // No vibration hardware path at all: stay silent.
    }
  }
}

Haptics createHaptics() => DeviceHaptics();
