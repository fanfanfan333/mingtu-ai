/// Haptics seam: the device-channel implementation on
/// mobile, a no-op elsewhere (web / stub). The conditional
/// export mirrors the other platform seams in this project.
library;

export 'haptics_stub.dart'
    if (dart.library.io) 'haptics_mobile.dart';
