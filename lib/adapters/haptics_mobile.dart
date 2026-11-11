import 'package:flutter/services.dart';

import '../core/haptics.dart';

/// Device haptics through the app's own `mingtu/device`
/// MethodChannel (MainActivity.kt, VibrationEffect
/// waveform). A missing channel or a platform error
/// degrades to the framework's plain vibrate, and then to
/// silence -- the alert flow never awaits success here.
class DeviceHaptics extends NoOpHaptics {
  static const MethodChannel _channel = MethodChannel('mingtu/device');

  @override
  Future<void> vibratePattern(
      List<int> timings, List<int> amplitudes) async {
    try {
      await _channel.invokeMethod<void>('vibratePattern', <String, Object>{
        'timings': timings,
        'amplitudes': amplitudes,
      });
    } catch (_) {
      try {
        await HapticFeedback.vibrate();
      } catch (_) {
        // No vibration hardware path at all: stay silent.
      }
    }
  }
}

Haptics createHaptics() => DeviceHaptics();
