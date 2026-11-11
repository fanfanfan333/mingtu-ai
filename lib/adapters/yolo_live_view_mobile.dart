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
///
/// Adaptive frame rate (NAVHAZ M2 section 3.1): the plugin
/// (locked 0.7.2) supports BOTH construction-time and RUNTIME
/// streaming configuration -- [YOLOView.streamingConfig] for
/// the initial value and [YOLOViewController.setStreamingConfig]
/// for live changes over the same method channel -- so the
/// frame-rate policy's target is applied at runtime through
/// [applyYoloFrameRateTarget], never by rebuilding the view
/// (a rebuild would drop the camera session and the shared
/// controller's frame-capture routing with it).
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../core/navhaz_config.dart';
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

/// The streaming configuration for one target inference
/// rate (M2 section 3.1): [fps] drives BOTH the plugin's
/// inference frequency (how often the model actually runs)
/// and its result-stream cap, so the saving is real CPU/GPU
/// work, not just fewer callbacks. Everything else mirrors
/// the plugin's own minimal defaults (detections +
/// classifications + timing/fps metrics on; masks, poses,
/// OBB and original images off), so enabling the adaptive
/// rate changes NOTHING about what a frame carries.
///
/// [analysisResolution] is null here on purpose: raising it
/// is the THERMAL policy's lever (M2 section 3.2 caps it at
/// 720p under heat), and that policy will pass its own value
/// through this same builder when it lands.
YOLOStreamingConfig yoloStreamingConfigForFps(int fps,
    {Size? analysisResolution}) {
  return YOLOStreamingConfig(
    maxFPS: fps,
    inferenceFrequency: fps,
    analysisResolution: analysisResolution,
  );
}

/// The frame-rate target most recently handed to the plugin
/// (null before the first application and whenever the
/// adaptive policy is disabled). Exposed for wiring tests
/// and diagnostics; the plugin remains the authority on
/// what it actually runs.
int? appliedYoloFrameRateFps;

/// Apply a new target inference rate at RUNTIME through the
/// shared controller (M2 section 3.1): no view rebuild, no
/// camera restart. Repeated calls with the already-applied
/// target are no-ops, so the wiring layer may call this on
/// every evaluated frame.
///
/// SECTION 3.2 HOOK: the thermal cap composes HERE -- the
/// caller will pass min(scene target, thermal cap) as
/// [targetFps] once the thermal monitor exists; this
/// function stays a dumb applier of the final number.
Future<void> applyYoloFrameRateTarget(int targetFps) async {
  if (appliedYoloFrameRateFps == targetFps) return;
  appliedYoloFrameRateFps = targetFps;
  await sharedYoloViewController
      .setStreamingConfig(yoloStreamingConfigForFps(targetFps));
}

Widget buildYoloLiveView({
  required String modelPath,
  required void Function(List<Detection> detections, DateTime frameCapturedAt)
      onDetections,
  void Function(double latencyMs)? onLatencyMs,
  void Function(Object error)? onError,
  YOLOStreamingConfig? streamingConfig,
}) {
  return _YoloLiveViewHost(
    modelPath: modelPath,
    onDetections: onDetections,
    onLatencyMs: onLatencyMs,
    onError: onError,
    streamingConfig: streamingConfig,
  );
}

class _YoloLiveViewHost extends StatefulWidget {
  final String modelPath;
  final void Function(List<Detection> detections, DateTime frameCapturedAt)
      onDetections;
  final void Function(double latencyMs)? onLatencyMs;
  final void Function(Object error)? onError;

  /// Initial streaming configuration (M2 section 3.1), or
  /// null for the plugin's own defaults -- which is exactly
  /// what every caller gets while
  /// [NavHazConfig.adaptiveFrameRateEnabled] is off.
  final YOLOStreamingConfig? streamingConfig;

  const _YoloLiveViewHost({
    required this.modelPath,
    required this.onDetections,
    this.onLatencyMs,
    this.onError,
    this.streamingConfig,
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
    // The applied-rate record describes THIS view's plugin
    // session; a fresh mount starts unrecorded so the first
    // policy evaluation re-applies its target.
    appliedYoloFrameRateFps = null;
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
      streamingConfig: widget.streamingConfig,
      onResult: (List<YOLOResult> results) {
        // Frame timestamp (FIX4-FINAL S3): stamped HERE,
        // the moment the plugin delivers this frame's
        // results -- the plugin exposes no camera capture
        // timestamp, so this delivery stamp is the frame's
        // app-side timestamp and the start point of the
        // frame-to-callback latency segment. Scope of that
        // segment (NH-M1-10): it measures ONLY result-
        // delivery -> detection callback; it does NOT
        // include camera frame capture or model inference
        // time (both happen before this stamp exists).
        final DateTime frameCapturedAt = DateTime.now();
        widget.onDetections(
            results.map((YOLOResult r) => yoloResultToDetection(
                  label: r.className,
                  confidence: r.confidence,
                  centerX: r.normalizedBox.left + r.normalizedBox.width / 2,
                  centerY: r.normalizedBox.top + r.normalizedBox.height / 2,
                  boxWidth: r.normalizedBox.width,
                  boxHeight: r.normalizedBox.height,
                )).toList(),
            frameCapturedAt);
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
