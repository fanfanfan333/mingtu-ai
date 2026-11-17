/// Phone YOLO detector using the packaged asset only. Failures are terminal
/// for this detector instance and never produce a fabricated detection.
library;

import 'dart:typed_data';

import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../modules/visual_perception.dart';
import '../config/app_config.dart';
import 'yolo_detector.dart';

YoloDetector createYoloDetector(String modelPath) =>
    MobileYoloDetector(modelPath: modelPath);

bool canOpenYoloLive(YoloDetector detector) =>
    detector is MobileYoloDetector ? !detector._failed : detector.isAvailable;

class MobileYoloDetector implements YoloDetector {
  final String modelPath;
  YOLO? _yolo;
  final YOLO Function(String) _createModel;
  bool _failed = false;
  bool _available = false;
  String _detail = '未初始化';

  MobileYoloDetector(
      {required String modelPath, YOLO Function(String)? createModel})
      : modelPath = resolvePackagedYoloModelPath(modelPath),
        _createModel = createModel ?? _defaultCreateModel;

  static YOLO _defaultCreateModel(String path) =>
      YOLO(modelPath: path, task: YOLOTask.detect);

  @override
  bool get isAvailable => _available;

  @override
  String get status => _detail;

  @override
  Future<List<Detection>> detectImage(List<int> imageBytes) async {
    if (_failed) return <Detection>[];
    try {
      final YOLO yolo = _yolo ??= _createModel(modelPath);
      if (!yolo.isInitialized) {
        final bool ok = await yolo.loadModel();
        if (!ok) {
          _failed = true;
          _available = false;
          _detail = 'NOT_CONFIGURED（YOLO 模型加载失败）';
          return <Detection>[];
        }
      }
      final Map<String, dynamic> result = await yolo.predict(
        Uint8List.fromList(imageBytes),
        confidenceThreshold: 0.25,
      );
      final Object? raw = result['detections'];
      if (raw is! List) {
        _available = true;
        _detail = 'YOLO 已接入（$modelPath），本帧无检测。';
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
          label: parsed.className,
          confidence: parsed.confidence,
          centerX: cx,
          centerY: cy,
          boxWidth: parsed.normalizedBox.width,
          boxHeight: parsed.normalizedBox.height,
        ));
      }
      _available = true;
      _detail = 'YOLO 已接入（$modelPath），最近一帧 ${detections.length} 个检测。';
      return detections;
    } catch (_) {
      _failed = true;
      _available = false;
      _detail = 'NOT_CONFIGURED（YOLO 模型或推理不可用）';
      return <Detection>[];
    }
  }
}
