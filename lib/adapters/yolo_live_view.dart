/// YOLO live camera view for Mingtu AI (v0.6).
///
/// Conditional import, like yolo_detector.dart: on a phone the real
/// view (ultralytics_yolo YOLOView) runs; on web the stub explains
/// that live camera inference is phone-only. The plugin has no web
/// implementation, so importing it directly would break the web build.
///
/// Every frame's results are mapped to [Detection]s and handed to
/// [onDetections]. The caller feeds them into
/// VisualPerception.processFrame (tracking + dedup + the < 0.3
/// confidence filter). The view itself never speaks a step: a box's
/// left/right is not a walking direction.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../modules/visual_perception.dart';
import 'yolo_live_view_stub.dart'
    if (dart.library.io) 'yolo_live_view_mobile.dart' as impl;

/// A live YOLO camera view. [onDetections] fires per frame with the
/// mapped detections and the frame's app-side timestamp (stamped
/// by the adapter the moment the plugin delivers the frame's
/// results -- the plugin exposes no capture timestamp; the stamp
/// is the start point of the frame-to-callback latency segment,
/// FIX4-FINAL S3 -- that segment measures ONLY result-delivery
/// -> detection callback, NOT camera frame capture or model
/// inference time, NH-M1-10); [onLatencyMs] reports the frame
/// processing time in milliseconds when the plugin provides it.
class YoloLiveView extends StatelessWidget {
  final String modelPath;
  final void Function(List<Detection> detections, DateTime frameCapturedAt)
      onDetections;
  final void Function(double latencyMs)? onLatencyMs;
  final void Function(Object error)? onError;

  const YoloLiveView({
    super.key,
    required this.modelPath,
    required this.onDetections,
    this.onLatencyMs,
    this.onError,
  });

  @override
  Widget build(BuildContext context) => impl.buildYoloLiveView(
        modelPath: modelPath,
        onDetections: onDetections,
        onLatencyMs: onLatencyMs,
        onError: onError,
      );
}

/// Completes when the live view has actually unmounted (mobile)
/// or immediately (web stub). The camera owner's YOLO release
/// waits on this future.
Future<void> get yoloLiveViewDisposed => impl.yoloLiveViewDisposed;
