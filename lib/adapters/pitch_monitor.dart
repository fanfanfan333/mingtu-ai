/// Pitch monitor seam: the accelerometer-backed
/// implementation on mobile, the fail-closed unavailable
/// monitor elsewhere (web / stub). The conditional export
/// mirrors the other platform seams in this project.
library;

export 'pitch_monitor_stub.dart'
    if (dart.library.io) 'pitch_monitor_mobile.dart';
