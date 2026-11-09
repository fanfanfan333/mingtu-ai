/// On-demand single-frame camera capture contract for Mingtu AI.
///
/// This is the ONLY camera path the cloud-vision assist uses:
/// - Capture is triggered explicitly (voice "看看前面" or the
///   on-screen assist button) -- never automatic, never periodic.
/// - Exactly ONE still frame is captured per trigger. There is no
///   image stream, no continuous upload and no video recording in
///   this path (the camera controller is opened for the shot and
///   disposed immediately; audio is disabled).
/// - Every outcome is spoken in Chinese by the caller: success,
///   permission denied, camera unavailable, capture failure. A
///   denied permission must never be silent for a blind user.
/// - A captured frame is handed to the cloud-vision client, which
///   downsamples it and applies the rate limiter before anything
///   leaves the device.
library;

import 'dart:typed_data';

import 'cloud_vision.dart';

/// Why a single-frame capture did not produce a frame.
enum CameraFrameFailure {
  /// The user (or the system) denied the camera permission.
  permissionDenied,

  /// No usable camera exists / the platform has no camera pipeline
  /// (web, desktop test runs, a device without a back camera).
  unavailable,

  /// Capture was attempted but failed for another reason.
  failure,
}

/// The result of one capture attempt: either the frame bytes, or
/// a typed failure. Implementations never throw to the caller.
class CameraFrameCapture {
  final Uint8List? bytes;
  final CameraFrameFailure? failure;
  final String? detail;

  const CameraFrameCapture._({this.bytes, this.failure, this.detail});

  factory CameraFrameCapture.ok(Uint8List bytes) =>
      CameraFrameCapture._(bytes: bytes);

  factory CameraFrameCapture.failed(
    CameraFrameFailure failure, {
    String? detail,
  }) =>
      CameraFrameCapture._(failure: failure, detail: detail);

  bool get ok => bytes != null && failure == null;
}

/// A source that can capture exactly one frame on demand. The
/// production implementation lives behind a conditional import
/// (adapters/camera_frame_source.dart); tests substitute fakes.
abstract class CameraFrameSource {
  Future<CameraFrameCapture> captureSingleFrame();
}

/// The Chinese announcement for a capture failure. Every variant
/// states the degradation back to local detection and carries the
/// cloud-vision disclaimer; none of them claims anything about
/// whether the scene is safe.
String cameraFrameFailureSpeech(CameraFrameFailure failure) {
  switch (failure) {
    case CameraFrameFailure.permissionDenied:
      return '摄像头权限被拒绝，无法拍照识别。'
          '请在系统设置里允许明途使用摄像头。'
          '已降级为本地检测。提醒：$cloudVisionDisclaimer';
    case CameraFrameFailure.unavailable:
      return '摄像头现在不可用，云端视觉未执行。'
          '已降级为本地检测。提醒：$cloudVisionDisclaimer';
    case CameraFrameFailure.failure:
      return '拍照失败，云端视觉未执行。'
          '已降级为本地检测。提醒：$cloudVisionDisclaimer';
  }
}

/// Cooperative cancellation for an in-flight recognition: the
/// app cancels it when it goes to background or is disposed, so
/// a late result is discarded instead of spoken, and the flow
/// stops before opening anything else.
class CloudVisionCancellation {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() {
    _cancelled = true;
  }
}

/// Routes frame capture so the camera is never double-opened:
/// while the YOLO live view is running (it owns the camera), the
/// frame comes from THAT view's capture (its most recent live
/// frame) via [yoloSource]; otherwise a dedicated one-shot still
/// is taken via [singleShotSource]. Exactly one source is used
/// per trigger -- the two never run together.
class RoutedCameraFrameSource implements CameraFrameSource {
  final bool Function() yoloLiveActive;
  final CameraFrameSource yoloSource;
  final CameraFrameSource singleShotSource;

  const RoutedCameraFrameSource({
    required this.yoloLiveActive,
    required this.yoloSource,
    required this.singleShotSource,
  });

  @override
  Future<CameraFrameCapture> captureSingleFrame() {
    if (yoloLiveActive()) {
      return yoloSource.captureSingleFrame();
    }
    return singleShotSource.captureSingleFrame();
  }
}
