import '../core/orientation.dart';

/// No gyroscope source on this platform: fail closed.
OrientationMonitor createOrientationMonitor() =>
    const UnavailableOrientationMonitor();
