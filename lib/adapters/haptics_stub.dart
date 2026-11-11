import '../core/haptics.dart';

/// No device channel on this platform: vibration is a
/// no-op (hazard speech never depends on it).
Haptics createHaptics() => const NoOpHaptics();
