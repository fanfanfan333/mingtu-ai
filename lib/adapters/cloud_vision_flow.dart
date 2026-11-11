/// On-demand cloud-vision flow for Mingtu AI: the sequencing that
/// connects one explicit trigger (voice "看看前面" or the assist
/// button) to one camera frame and one rate-limited cloud call.
///
/// Order is deliberate:
/// 1. Single-flight: if a recognition is already running, the
///    trigger is answered with "正在识别，请稍候" -- no second
///    camera open, no second reservation, no second upload.
/// 2. Not configured -> announce the degradation; nothing opens.
/// 3. RESERVE the rate-limit slot BEFORE the camera opens
///    (client.tryReserve). A refused reservation announces the
///    skip and no frame is ever captured; a taken slot stays
///    taken even if the capture then fails (retry protection).
/// 4. Announce "正在识别" (progress + disclaimer) before any
///    await, so the user is never left in silence.
/// 5. Capture exactly ONE frame through the routed frame source
///    (YOLO live frame while navigation owns the camera, else a
///    one-shot still -- never both, never a stream).
/// 6. Describe via the reserved call (downsample + cap + timeout
///    inside the client) and announce the template-generated
///    result -- or the failure -- in Chinese.
///
/// Cancellation: when the app goes to background or is disposed
/// the owner cancels the run's [CloudVisionCancellation]; the
/// flow then stops at the next stage boundary, discards any late
/// result (it is NOT spoken) and releases the single-flight lock.
/// Nothing here runs on its own or feeds the risk engine.
library;

import '../core/camera_frame.dart';
import '../core/cloud_vision.dart';
import 'cloud_vision_client.dart';

class CloudVisionFlowOutcome {
  /// The vision-side result. On a camera failure this is
  /// [CloudVisionFailure.noImage] with the camera detail attached;
  /// on a busy refusal it is [CloudVisionFailure.busy]; on
  /// cancellation it is noImage with detail '已取消'.
  final CloudVisionResult visionResult;

  /// Every announcement made, in order (also passed live to the
  /// `announce` callback as they happened).
  final List<String> announcements;

  /// True when the run was cancelled by lifecycle (the result
  /// was discarded, not announced).
  final bool cancelled;

  const CloudVisionFlowOutcome(
    this.visionResult,
    this.announcements, {
    this.cancelled = false,
  });
}

class OnDemandCloudVision {
  final CloudVisionClient client;
  final CameraFrameSource frameSource;
  bool _inFlight = false;

  OnDemandCloudVision({
    required this.client,
    required this.frameSource,
  });

  /// Whether a recognition is currently running (single-flight).
  bool get inFlight => _inFlight;

  Future<CloudVisionFlowOutcome> run({
    required void Function(String text) announce,
    DateTime? now,
    CloudVisionCancellation? cancellation,
  }) async {
    final List<String> announcements = <String>[];
    void say(String text) {
      announcements.add(text);
      announce(text);
    }

    if (_inFlight) {
      final CloudVisionResult busy =
          CloudVisionResult.failed(CloudVisionFailure.busy);
      say(busy.speechText);
      return CloudVisionFlowOutcome(busy, announcements);
    }
    if (!client.isConfigured) {
      final CloudVisionResult result =
          CloudVisionResult.failed(CloudVisionFailure.notConfigured);
      say(result.speechText);
      return CloudVisionFlowOutcome(result, announcements);
    }
    // Reserve BEFORE the camera: refusal here means zero capture.
    if (!client.tryReserve(now)) {
      final CloudVisionResult result =
          CloudVisionResult.failed(CloudVisionFailure.rateLimited);
      say(result.speechText);
      return CloudVisionFlowOutcome(result, announcements);
    }

    _inFlight = true;
    try {
      say(cloudVisionStartingSpeech);
      if (cancellation?.isCancelled ?? false) {
        return _cancelled(announcements);
      }

      final CameraFrameCapture capture;
      try {
        capture = await frameSource.captureSingleFrame();
      } catch (e) {
        // Cancellation is checked FIRST in every failure branch:
        // a run cancelled while the camera was working (app
        // backgrounded / disposed) must not announce anything
        // any more -- its user has moved on.
        if (cancellation?.isCancelled ?? false) {
          return _cancelled(announcements);
        }
        say(cameraFrameFailureSpeech(CameraFrameFailure.failure));
        return CloudVisionFlowOutcome(
          CloudVisionResult.failed(
            CloudVisionFailure.noImage,
            detail: '拍照异常：$e',
          ),
          announcements,
        );
      }
      if (cancellation?.isCancelled ?? false) {
        return _cancelled(announcements);
      }
      if (!capture.ok) {
        final CameraFrameFailure failure =
            capture.failure ?? CameraFrameFailure.failure;
        if (capture.detail == cameraBusySpeech) {
          // The camera arbiter refused (another use holds it or
          // a physical release is still pending): say exactly
          // that, so the user knows to retry in a moment.
          say(cameraBusySpeech);
          return CloudVisionFlowOutcome(
            CloudVisionResult.failed(
              CloudVisionFailure.noImage,
              detail: capture.detail,
            ),
            announcements,
          );
        }
        say(cameraFrameFailureSpeech(failure));
        return CloudVisionFlowOutcome(
          CloudVisionResult.failed(
            CloudVisionFailure.noImage,
            detail: capture.detail,
          ),
          announcements,
        );
      }

      final CloudVisionResult result = await client.describeReserved(
        imageBytes: capture.bytes!,
      );
      if (cancellation?.isCancelled ?? false) {
        // The answer arrived after the app went away: discard it.
        // Speaking a stale description to a user who has moved on
        // would be worse than silence.
        return _cancelled(announcements);
      }
      say(result.speechText);
      return CloudVisionFlowOutcome(result, announcements);
    } finally {
      _inFlight = false;
    }
  }

  CloudVisionFlowOutcome _cancelled(List<String> announcements) {
    return CloudVisionFlowOutcome(
      CloudVisionResult.failed(
        CloudVisionFailure.noImage,
        detail: '应用进入后台或销毁，识别已取消。',
      ),
      announcements,
      cancelled: true,
    );
  }
}
