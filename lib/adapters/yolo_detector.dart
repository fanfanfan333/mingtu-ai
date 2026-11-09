/// YOLO detector contract for Mingtu AI (v0.6).
///
/// The mapping from a YOLO result to a [Detection] lives here in pure
/// Dart so it is testable without a phone: the centre of the
/// normalised box becomes (cx, cy); confidence is clamped to 0..1.
/// The box's left/right NEVER decides a step direction -- that is the
/// risk engine's job, and it still requires spatial confidence >= 0.6
/// plus a real distance before any step is spoken.
///
/// The real implementation is behind a conditional export: on a phone
/// (dart:io) [createYoloDetector] returns the ultralytics_yolo
/// implementation; on web it returns [UnavailableYoloDetector].
/// The plugin has no web implementation, so importing it directly
/// would break the web build.
library;

import '../modules/visual_perception.dart';

export 'yolo_detector_stub.dart'
    if (dart.library.io) 'yolo_detector_mobile.dart';

/// A YOLO result reduced to what Mingtu needs: label, confidence and
/// the centre of the normalised bounding box (0..1).
Detection yoloResultToDetection({
  required String label,
  required double confidence,
  required double centerX,
  required double centerY,
  double boxWidth = 0,
  double boxHeight = 0,
}) {
  return Detection(
    label: label,
    confidence: confidence.clamp(0.0, 1.0),
    cx: centerX.clamp(0.0, 1.0),
    cy: centerY.clamp(0.0, 1.0),
    w: boxWidth.clamp(0.0, 1.0),
    h: boxHeight.clamp(0.0, 1.0),
  );
}

abstract class YoloDetector {
  bool get isAvailable;
  String get status;

  /// Run inference on one image ([imageBytes] is a JPEG/PNG).
  /// Returns detections (possibly empty). Never returns a fake
  /// detection: on load / inference failure it returns [] and marks
  /// itself unavailable.
  Future<List<Detection>> detectImage(List<int> imageBytes);
}

class UnavailableYoloDetector implements YoloDetector {
  @override
  bool get isAvailable => false;

  @override
  String get status => 'NOT_CONFIGURED（YOLO 未接入：本平台不支持手机端推理，或模型未加载）';

  @override
  Future<List<Detection>> detectImage(List<int> imageBytes) async =>
      <Detection>[];
}
