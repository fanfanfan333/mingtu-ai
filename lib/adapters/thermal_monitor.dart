/// Thermal monitor seam: the PowerManager-backed
/// implementation on mobile, the fail-closed unavailable
/// monitor elsewhere (web / stub). The conditional export
/// mirrors the other platform seams in this project.
library;

export 'thermal_monitor_stub.dart'
    if (dart.library.io) 'thermal_monitor_mobile.dart';
