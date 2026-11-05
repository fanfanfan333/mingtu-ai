/// Phone YOLO live view (v0.6), via the official ultralytics_yolo
/// plugin's YOLOView: real-time camera inference, back camera, GPU
/// when available. Results are mapped to [Detection]s via
/// [yoloResultToDetection] using the normalised box centre; the
/// caller owns tracking, dedup and any spoken prompt.
library;

import 'package:flutter/widgets.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../modules/visual_perception.dart';
import 'yolo_detector.dart';

Widget buildYoloLiveView({
  required String modelPath,
  required void Function(List<Detection> detections) onDetections,
  void Function(double latencyMs)? onLatencyMs,
  void Function(Object error)? onError,
}) {
  return YOLOView(
    modelPath: modelPath,
    task: YOLOTask.detect,
    confidenceThreshold: 0.25,
    onResult: (List<YOLOResult> results) {
      onDetections(results
          .map((YOLOResult r) => yoloResultToDetection(
                label: r.className,
                confidence: r.confidence,
                centerX: r.normalizedBox.left + r.normalizedBox.width / 2,
                centerY: r.normalizedBox.top + r.normalizedBox.height / 2,
              ))
          .toList());
    },
    onPerformanceMetrics: (YOLOPerformanceMetrics metrics) {
      onLatencyMs?.call(metrics.processingTimeMs);
    },
    onModelError: (Object error, String path, YOLOTask? task) {
      onError?.call(error);
    },
  );
}
