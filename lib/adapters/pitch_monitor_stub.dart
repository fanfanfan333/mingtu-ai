import '../core/pitch.dart';

/// No accelerometer source on this platform: pitch stays
/// unknown and ground-plane ranging stays off.
PitchMonitor createPitchMonitor() => const UnavailablePitchMonitor();
