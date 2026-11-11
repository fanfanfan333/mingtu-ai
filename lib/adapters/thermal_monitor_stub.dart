import '../core/thermal.dart';

/// No thermal source on this platform: the status stays
/// unknown and derating never engages.
ThermalMonitor createThermalMonitor() => const UnavailableThermalMonitor();
