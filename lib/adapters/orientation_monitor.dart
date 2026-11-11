/// Orientation monitor: the gyroscope-backed implementation
/// on mobile, the fail-closed unavailable monitor elsewhere
/// (web / stub). The conditional export mirrors the other
/// platform seams in this project.
library;

export 'orientation_monitor_stub.dart'
    if (dart.library.io) 'orientation_monitor_mobile.dart';
