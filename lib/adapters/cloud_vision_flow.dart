/// On-demand cloud-vision flow for Mingtu AI: the sequencing that
/// connects one explicit trigger (voice "看看前面" or the assist
/// button) to one camera frame and one rate-limited cloud call.
///
/// Order is deliberate:
/// 1. Not configured -> announce the not-configured degradation;
///    the camera is NOT opened for a call that cannot happen.
/// 2. Rate-limited -> announce the skip; again no frame captured.
/// 3. Announce "正在识别" FIRST, so the user hears progress (with
///    the disclaimer) before any await.
/// 4. Capture exactly ONE frame via [CameraFrameSource]. A
///    permission denial / unavailable camera / capture failure is
///    announced in Chinese and degraded to local detection.
/// 5. Describe the frame via [CloudVisionClient] (downsample +
///    payload cap + explicit timeout happen inside) and announce
///    the result -- success or failure -- with the disclaimer.
///
/// Nothing here runs on its own, uploads continuously, records
/// video, or feeds the risk engine. Every announcement the flow
/// makes is collected in the outcome so the caller can report
/// health honestly.
library;

import '../core/camera_frame.dart';
import '../core/cloud_vision.dart';
import 'cloud_vision_client.dart';

class CloudVisionFlowOutcome {
  /// The vision-side result. On a camera failure this is
  /// [CloudVisionFailure.noImage] with the camera detail attached;
  /// the precise spoken reason is the last announcement.
  final CloudVisionResult visionResult;

  /// Every announcement made, in order (also passed live to the
  /// `announce` callback as they happened).
  final List<String> announcements;

  const CloudVisionFlowOutcome(this.visionResult, this.announcements);
}

class OnDemandCloudVision {
  final CloudVisionClient client;
  final CameraFrameSource frameSource;

  const OnDemandCloudVision({
    required this.client,
    required this.frameSource,
  });

  Future<CloudVisionFlowOutcome> run({
    required void Function(String text) announce,
    DateTime? now,
  }) async {
    final List<String> announcements = <String>[];
    void say(String text) {
      announcements.add(text);
      announce(text);
    }

    if (!client.isConfigured) {
      final CloudVisionResult result =
          CloudVisionResult.failed(CloudVisionFailure.notConfigured);
      say(result.speechText);
      return CloudVisionFlowOutcome(result, announcements);
    }
    if (!client.canStartNow(now)) {
      final CloudVisionResult result =
          CloudVisionResult.failed(CloudVisionFailure.rateLimited);
      say(result.speechText);
      return CloudVisionFlowOutcome(result, announcements);
    }

    say(cloudVisionStartingSpeech);

    final CameraFrameCapture capture;
    try {
      capture = await frameSource.captureSingleFrame();
    } catch (e) {
      say(cameraFrameFailureSpeech(CameraFrameFailure.failure));
      return CloudVisionFlowOutcome(
        CloudVisionResult.failed(
          CloudVisionFailure.noImage,
          detail: '拍照异常：$e',
        ),
        announcements,
      );
    }
    if (!capture.ok) {
      final CameraFrameFailure failure =
          capture.failure ?? CameraFrameFailure.failure;
      say(cameraFrameFailureSpeech(failure));
      return CloudVisionFlowOutcome(
        CloudVisionResult.failed(
          CloudVisionFailure.noImage,
          detail: capture.detail,
        ),
        announcements,
      );
    }

    final CloudVisionResult result =
        await client.describe(imageBytes: capture.bytes!, now: now);
    say(result.speechText);
    return CloudVisionFlowOutcome(result, announcements);
  }
}
