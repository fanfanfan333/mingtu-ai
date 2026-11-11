/// Web / non-mobile frame source: there is no camera pipeline on
/// this platform, so every capture honestly reports unavailable.
/// Never fakes a frame.
library;

import '../core/camera_frame.dart';

CameraFrameSource createCameraFrameSource() => UnavailableCameraFrameSource();

class UnavailableCameraFrameSource implements CameraFrameSource {
  @override
  Future<CameraFrameCapture> captureSingleFrame() async =>
      CameraFrameCapture.failed(
        CameraFrameFailure.unavailable,
        detail: '本平台没有摄像头管线（仅手机端可拍照）。',
      );
}

/// Web / non-mobile YOLO frame source: no live view exists here.
CameraFrameSource createYoloFrameSource() => UnavailableCameraFrameSource();
