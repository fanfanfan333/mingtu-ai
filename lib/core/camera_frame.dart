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

import 'dart:async';

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

/// Last-resort frame source, installed when camera pipeline
/// CONSTRUCTION itself failed at startup (the failure is
/// recorded and announced by the startup guard). Every capture
/// honestly reports unavailable; nothing is faked.
class LastResortCameraFrameSource implements CameraFrameSource {
  const LastResortCameraFrameSource();

  @override
  Future<CameraFrameCapture> captureSingleFrame() async =>
      CameraFrameCapture.failed(
        CameraFrameFailure.unavailable,
        detail: '摄像头初始化失败',
      );
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

/// A unique ownership lease for the device camera. [CameraOwnership]
/// hands out exactly one live lease at a time; ONLY the holder of
/// the current lease can release it (see
/// [CameraOwnership.release]) -- a stale holder finishing late
/// (an old capture's finally block) cannot free a newer owner's
/// lock. [generation] makes leases distinguishable in logs/tests.
class CameraLease {
  final CameraUse use;
  final int generation;
  bool _releaseStarted = false;
  Future<void>? _physicalRelease;

  CameraLease._(this.use, this.generation);

  bool get releaseStarted => _releaseStarted;
}

/// The app's single camera arbiter: ONE lease for the whole app,
/// shared by the YOLO live view and the one-shot still capture,
/// so the two can never hold the camera at the same time.
///
/// Release is ASYNCHRONOUS and physical: [release] waits for the
/// underlying teardown (camera controller dispose, or the YOLO
/// view actually unmounting) before the lock is considered free,
/// and [tryAcquire] first waits for any pending release --
/// refusing (null) when that wait times out, so a caller can
/// announce "摄像头忙，请稍后再试" instead of double-opening.
/// After the app returns from background the same rule applies:
/// the next acquire still waits for the release that the
/// backgrounding started.
class CameraOwnership {
  CameraLease? _current;
  int _nextGeneration = 0;
  Completer<void>? _releaseCompleter;
  final Set<CloudVisionCancellation> _cancellations =
      <CloudVisionCancellation>{};

  CameraUse? get currentUse => _current?.use;
  CameraLease? get currentLease => _current;
  bool get isHeld => _current != null;
  bool get isReleasePending => _releaseCompleter != null;
  bool isHeldBy(CameraUse use) => _current?.use == use;
  int get activeCancellations => _cancellations.length;

  /// Try to take the camera for [use]. Waits for a pending
  /// physical release first (up to [timeout]); returns null when
  /// the wait times out or another use holds the camera. The
  /// YOLO live view is a persistent holder: re-acquiring it while
  /// it is held (and not releasing) returns the SAME lease. A
  /// one-shot capture is exclusive: while one is in flight, a
  /// second acquire is refused.
  Future<CameraLease?> tryAcquire(
    CameraUse use, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final Completer<void>? pending = _releaseCompleter;
    if (pending != null) {
      try {
        await pending.future.timeout(timeout);
      } on TimeoutException {
        return null;
      }
    }
    final CameraLease? current = _current;
    if (current != null) {
      if (current.use == use &&
          use == CameraUse.yoloLive &&
          !current._releaseStarted) {
        return current;
      }
      return null;
    }
    return _current = CameraLease._(use, ++_nextGeneration);
  }

  /// Record the future that completes when [lease]'s physical
  /// operation (e.g. an in-flight capture incl. its controller
  /// dispose) has fully finished, so a later [release] can wait
  /// for the hardware to actually be free.
  void trackPhysicalRelease(CameraLease lease, Future<void> physical) {
    if (identical(_current, lease) && !lease._releaseStarted) {
      lease._physicalRelease = physical;
    }
  }

  /// Release [lease], waiting for the physical teardown
  /// ([waitFor] when given, else the tracked physical release)
  /// BEFORE the lock frees. Only the current lease can release:
  /// a stale lease (an old operation finishing after a newer
  /// owner took over) releases nothing. Idempotent per lease.
  Future<void> release(CameraLease lease, {Future<void>? waitFor}) async {
    if (!identical(_current, lease) || lease._releaseStarted) return;
    lease._releaseStarted = true;
    final Completer<void> completer = Completer<void>();
    _releaseCompleter = completer;
    final Future<void>? physical = waitFor ?? lease._physicalRelease;
    if (physical != null) {
      try {
        await physical;
      } catch (_) {
        // A failed teardown still ends the release: the lock
        // must not jam shut forever.
      }
    }
    if (identical(_current, lease)) _current = null;
    if (identical(_releaseCompleter, completer)) _releaseCompleter = null;
    completer.complete();
  }

  void registerCancellation(CloudVisionCancellation token) {
    _cancellations.add(token);
  }

  void unregisterCancellation(CloudVisionCancellation token) {
    _cancellations.remove(token);
  }

  /// Cancel every registered in-flight request and START
  /// releasing the camera (the physical release completes
  /// asynchronously; the next [tryAcquire] waits for it).
  /// Called when the app goes to background or is disposed:
  /// nothing camera-related may survive that.
  void cancelAllAndRelease() {
    for (final CloudVisionCancellation token in _cancellations) {
      token.cancel();
    }
    _cancellations.clear();
    final CameraLease? current = _current;
    if (current != null) {
      release(current);
    }
  }
}

/// The spoken text for a refused camera acquisition.
const String cameraBusySpeech = '摄像头忙，请稍后再试。';

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
/// dedicated one-shot still is taken via [singleShotSource]
/// under a [CameraUse.singleShot] lease, released (physically)
/// afterwards. Exactly one source is used per trigger -- the two
/// never run together.
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
    final CameraLease? lease = await ownership.tryAcquire(CameraUse.singleShot);
    if (lease == null) {
      return CameraFrameCapture.failed(
        CameraFrameFailure.unavailable,
        detail: cameraBusySpeech,
      );
    }
    Future<CameraFrameCapture> operation;
    try {
      operation = singleShotSource.captureSingleFrame();
    } catch (e) {
      operation = Future<CameraFrameCapture>.value(
        CameraFrameCapture.failed(
          CameraFrameFailure.failure,
          detail: '拍照失败：$e',
        ),
      );
    }
    // The capture future completes only after the source's own
    // controller dispose (mobile impl), so tracking it makes a
    // later release wait for the hardware to be truly free.
    ownership.trackPhysicalRelease(
      lease,
      operation.then((_) {}, onError: (_) {}),
    );
    try {
      return await operation;
    } finally {
      await ownership.release(lease);
    }
  }
}
