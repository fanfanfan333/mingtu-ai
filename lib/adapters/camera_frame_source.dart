/// On-demand single-frame camera source factory.
///
/// Conditional export, same pattern as yolo_detector.dart: on a
/// phone (dart:io) the camera-plugin implementation is used; on
/// web the stub reports unavailable. The contract itself lives in
/// core/camera_frame.dart (one explicit trigger, one frame, no
/// streaming, no recording, failures typed for Chinese speech).
library;

export 'camera_frame_source_stub.dart'
    if (dart.library.io) 'camera_frame_source_mobile.dart';
