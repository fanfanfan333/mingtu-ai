/// Phone YOLO live view (v0.6), via the official ultralytics_yolo
/// plugin's YOLOView: real-time camera inference, back camera, GPU
/// when available. Results are mapped to [Detection]s via
/// [yoloResultToDetection] using the normalised box centre; the
/// caller owns tracking, dedup and any spoken prompt.
///
/// The view is driven by ONE shared [YOLOViewController]
/// ([sharedYoloViewController]) so the cloud-vision assist can
/// capture a frame from THIS camera while the live view owns it,
/// instead of opening a second camera (see
/// camera_frame_source_mobile.dart's YoloLiveFrameSource).
/// [yoloLiveViewMounted] tracks whether the view is in the tree,
/// for the same routing decision and for lifecycle release.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../modules/visual_perception.dart';
import 'yolo_detector.dart';

/// The single controller for the live view, shared with the
/// on-demand frame source.
final YOLOViewController sharedYoloViewController = YOLOViewController();

/// Whether the YOLO live view is currently mounted (and thus
/// owns the device camera).
bool yoloLiveViewMounted = false;

Completer<void>? _yoloDisposeCompleter;

/// Completes when the live view has ACTUALLY unmounted (its
/// State.dispose ran) after having been mounted. The camera
/// owner's YOLO release waits on this: the logical lock is not
/// freed until the physical view teardown finished. A fresh
/// completer is created at every mount.
Future<void> get yoloLiveViewDisposed =>
    (_yoloDisposeCompleter ??= Completer<void>()).future;

Widget buildYoloLiveView({
  required String modelPath,
  required void Function(List<Detection> detections) onDetections,
  void Function(double latencyMs)? onLatencyMs,
  void Function(Object error)? onError,
}) {
  return _YoloLiveViewHost(
    modelPath: modelPath,
    onDetections: onDetections,
    onLatencyMs: onLatencyMs,
    onError: onError,
  );
}

class _YoloLiveViewHost extends StatefulWidget {
  final String modelPath;
  final void Function(List<Detection> detections) onDetections;
  final void Function(double latencyMs)? onLatencyMs;
  final void Function(Object error)? onError;

  const _YoloLiveViewHost({
    required this.modelPath,
    required this.onDetections,
    this.onLatencyMs,
    this.onError,
  });

  @override
  State<_YoloLiveViewHost> createState() => _YoloLiveViewHostState();
}

class _YoloLiveViewHostState extends State<_YoloLiveViewHost> {
  @override
  void initState() {
    super.initState();
    yoloLiveViewMounted = true;
    _yoloDisposeCompleter = Completer<void>();
  }

  @override
  void dispose() {
    yoloLiveViewMounted = false;
    final Completer<void>? completer = _yoloDisposeCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return YOLOView(
      modelPath: widget.modelPath,
      controller: sharedYoloViewController,
      task: YOLOTask.detect,
      confidenceThreshold: 0.25,
      onResult: (List<YOLOResult> results) {
        widget.onDetections(results
            .map((YOLOResult r) => yoloResultToDetection(
                  label: r.className,
                  confidence: r.confidence,
                  centerX: r.normalizedBox.left + r.normalizedBox.width / 2,
                  centerY: r.normalizedBox.top + r.normalizedBox.height / 2,
                ))
            .toList());
      },
      onPerformanceMetrics: (YOLOPerformanceMetrics metrics) {
        widget.onLatencyMs?.call(metrics.processingTimeMs);
      },
      onModelError: (Object error, String path, YOLOTask? task) {
        widget.onError?.call(error);
      },
    );
  }
}
