/// Phone pothole detector (NAVHAZ M3), via the official
/// ultralytics_yolo plugin's programmatic YOLO class:
/// a SECOND model instance loaded outside the live view,
/// inferred on single frames the shared routed frame
/// source hands the scanner.
///
/// The instance is created with useMultiInstance: true --
/// the plugin gives a multi-instance YOLO its own method
/// channel, so this detector can coexist with the main
/// model's live view (whose channel is the view's) and
/// with the single-image main detector (whose channel is
/// the default instance's). Model loading is lazy (first
/// [detectImage] call), exactly like the main detector.
///
/// THREADING REALITY (honest boundary): a scan runs one
/// capture + one predict on the app's async flow; the
/// plugin's own inference runs on its native side. What
/// this costs on a real phone (single-frame latency,
/// contention with the live view) is a real-device
/// measurement, NOT verified here.
///
/// Failure to load or infer returns [] and marks the
/// detector unavailable -- a missing model must never
/// become a spoken "no pothole" claim (and never does:
/// the scanner treats failure as "no contribution").
library;

import 'dart:typed_data';

import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../core/pothole_scan.dart';
import '../modules/visual_perception.dart';
import 'pothole_detector.dart';
import 'yolo_detector.dart' show yoloResultToDetection;

PotholeDetector createPotholeDetector(String modelPath) =>
    MobilePotholeDetector(modelPath: modelPath);

class MobilePotholeDetector implements PotholeDetector {
  final String modelPath;
  final YOLO _yolo;
  bool _available = false;
  String _detail = '未初始化';

  MobilePotholeDetector({required this.modelPath})
      : _yolo = YOLO(
          modelPath: modelPath,
          task: YOLOTask.detect,
          useMultiInstance: true,
        );

  @override
  bool get isAvailable => _available;

  @override
  String get status => _detail;

  @override
  Future<List<Detection>> detectImage(List<int> imageBytes) async {
    try {
      if (!_yolo.isInitialized) {
        final bool ok = await _yolo.loadModel();
        if (!ok) {
          _available = false;
          _detail = 'NOT_CONFIGURED（坑洞模型加载失败：$modelPath）';
          return <Detection>[];
        }
      }
      final Map<String, dynamic> result = await _yolo.predict(
        Uint8List.fromList(imageBytes),
        confidenceThreshold: 0.25,
      );
      final Object? raw = result['detections'];
      if (raw is! List) {
        _available = true;
        _detail = '坑洞模型已接入（$modelPath），本帧无检测。';
        return <Detection>[];
      }
      final List<Detection> detections = [];
      for (final Object? item in raw) {
        if (item is! Map) continue;
        final YOLOResult parsed = YOLOResult.fromMap(item);
        final double cx =
            parsed.normalizedBox.left + parsed.normalizedBox.width / 2;
        final double cy =
            parsed.normalizedBox.top + parsed.normalizedBox.height / 2;
        detections.add(yoloResultToDetection(
          label: potholeClassLabel(
            classIndex: parsed.classIndex,
            className: parsed.className,
          ),
          confidence: parsed.confidence,
          centerX: cx,
          centerY: cy,
          boxWidth: parsed.normalizedBox.width,
          boxHeight: parsed.normalizedBox.height,
        ));
      }
      _available = true;
      _detail = '坑洞模型已接入（$modelPath），最近一帧 ${detections.length} 个检测。';
      return detections;
    } catch (e) {
      _available = false;
      _detail = 'NOT_CONFIGURED（坑洞推理失败：$e）';
      return <Detection>[];
    }
  }
}
