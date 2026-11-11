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
