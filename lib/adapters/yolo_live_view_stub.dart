/// Web / non-mobile YOLO live view: explains that live camera
/// inference is phone-only. Never fakes a camera feed.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../modules/visual_perception.dart';

Widget buildYoloLiveView({
  required String modelPath,
  required void Function(List<Detection> detections, DateTime frameCapturedAt)
      onDetections,
  void Function(double latencyMs)? onLatencyMs,
  void Function(Object error)? onError,
  // Accepted for signature parity with the mobile adapter
  // (M2 section 3.1): there is no camera or plugin on this
  // platform, so there is nothing to configure. The type is
  // Object? because the plugin's config class does not
  // exist off-device.
  Object? streamingConfig,
}) {
  return const Center(
    child: Text(
      'YOLO 实时摄像头仅支持手机（Android / iOS），网页演示不可用。'
      '请在真机上运行：模型在手机端推理，画面不上传云端。',
      textAlign: TextAlign.center,
    ),
  );
}

/// No live view exists on this platform, so there is nothing to
/// wait for: the "disposed" future is already complete.
Future<void> get yoloLiveViewDisposed => Future<void>.value();

/// No camera exists on this platform, so no rate was ever
/// applied (parity with the mobile adapter's record).
int? get appliedYoloFrameRateFps => null;

/// No-op on this platform: there is no plugin to retarget.
/// The signature mirrors the mobile adapter so the wiring
/// layer in main.dart stays platform-free (the section 3.2
/// 720p ceiling flag included -- equally a no-op here).
Future<void> applyYoloFrameRateTarget(int targetFps,
    {bool capAnalysisAt720p = false}) async {}
