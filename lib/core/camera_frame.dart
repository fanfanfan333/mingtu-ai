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

/// What the device camera is being used for right now.
enum CameraUse { yoloLive, singleShot }

/// The app's single camera arbiter: ONE owner for the whole app,
/// shared by the YOLO live view and the one-shot still capture,
/// so the two can never hold the camera at the same time.
///
/// Ownership rules:
/// - [tryAcquire] succeeds only when the camera is free or
///   already held for the SAME use; a different use is refused.
/// - [release] only frees the camera for its current use.
/// - Every in-flight cancellable camera request registers its
///   token here; [cancelAllAndRelease] (app backgrounded /
///   disposed) cancels ALL of them and frees the camera -- not
///   just whichever token happens to be newest.
class CameraOwnership {
  CameraUse? _current;
  final Set<CloudVisionCancellation> _cancellations =
      <CloudVisionCancellation>{};

  CameraUse? get current => _current;
  bool get isHeld => _current != null;
  bool isHeldBy(CameraUse use) => _current == use;
  int get activeCancellations => _cancellations.length;

  bool tryAcquire(CameraUse use) {
    if (_current == use) {
      // The live view is a persistent holder: acquiring it again
      // (navigation start + manual toggle) is idempotent. A
      // one-shot capture is an exclusive operation: a second
      // acquire while one is in flight is REFUSED, so two
      // captures can never overlap.
      return use == CameraUse.yoloLive;
    }
    if (_current != null) return false;
    _current = use;
    return true;
  }

  void release(CameraUse use) {
    if (_current == use) _current = null;
  }

  void registerCancellation(CloudVisionCancellation token) {
    _cancellations.add(token);
  }

  void unregisterCancellation(CloudVisionCancellation token) {
    _cancellations.remove(token);
  }

  /// Cancel every registered in-flight request and free the
  /// camera. Called when the app goes to background or is
  /// disposed: nothing camera-related may survive that.
  void cancelAllAndRelease() {
    for (final CloudVisionCancellation token in _cancellations) {
      token.cancel();
    }
    _cancellations.clear();
    _current = null;
  }
}

/// Owns the cancellation token of the ONE cloud-vision run that
/// may be active at a time. [begin] returns null when a run is
/// already active: the caller must refuse the duplicate trigger
/// WITHOUT creating a token -- the previous design overwrote a
/// shared field with a fresh token on every call, orphaning the
/// running run's token so background/dispose cancelled only the
/// newest (idle) token and the real run could no longer be
/// cancelled.
class VisionRunManager {
  CloudVisionCancellation? _active;

  bool get isRunning => _active != null;
  CloudVisionCancellation? get activeToken => _active;

  CloudVisionCancellation? begin() {
    if (_active != null) return null;
    return _active = CloudVisionCancellation();
  }

  void end(CloudVisionCancellation token) {
    if (identical(_active, token)) _active = null;
  }

  void cancelActive() {
    _active?.cancel();
  }
}

/// Routes frame capture so the camera is never double-opened:
/// while the YOLO live view is running (it holds the camera via
/// [CameraOwnership]), the frame comes from THAT view's capture
/// (its most recent live frame) via [yoloSource]; otherwise a
/// dedicated one-shot still is taken via [singleShotSource],
/// which must first acquire [CameraUse.singleShot] ownership
/// and releases it afterwards. Exactly one source is used per
/// trigger -- the two never run together.
class RoutedCameraFrameSource implements CameraFrameSource {
  final bool Function() yoloLiveActive;
  final CameraFrameSource yoloSource;
  final CameraFrameSource singleShotSource;
  final CameraOwnership ownership;

  const RoutedCameraFrameSource({
    required this.yoloLiveActive,
    required this.yoloSource,
    required this.singleShotSource,
    required this.ownership,
  });

  @override
  Future<CameraFrameCapture> captureSingleFrame() async {
    if (yoloLiveActive()) {
      return yoloSource.captureSingleFrame();
    }
    if (!ownership.tryAcquire(CameraUse.singleShot)) {
      return CameraFrameCapture.failed(
        CameraFrameFailure.unavailable,
        detail: '摄像头正被其他功能占用。',
      );
    }
    try {
      return await singleShotSource.captureSingleFrame();
    } finally {
      ownership.release(CameraUse.singleShot);
    }
  }
}
