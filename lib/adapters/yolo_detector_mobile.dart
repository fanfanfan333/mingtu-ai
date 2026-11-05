/// Phone YOLO detector (v0.6), via the official ultralytics_yolo
/// plugin: YOLO single-image inference, LiteRT (.tflite) on Android,
/// Core ML on iOS. [modelPath] is an official model id such as
/// 'yolo11n' (downloaded on the phone) or an asset / file path such
/// as 'assets/models/custom.tflite'.
///
/// The model is loaded lazily on the first [detectImage] call.
/// Failure to load or infer returns [] and marks the detector
/// unavailable -- a missing model must never become a spoken
/// "no obstacle" claim. Confidence below 0.3 never becomes a track:
/// that filter lives in VisualPerception.processFrame, not here.
library;

import 'dart:typed_data';

import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../modules/visual_perception.dart';
import 'yolo_detector.dart';

YoloDetector createYoloDetector(String modelPath) =>
    MobileYoloDetector(modelPath: modelPath);

class MobileYoloDetector implements YoloDetector {
  final String modelPath;
  final YOLO _yolo;
  bool _available = false;
  String _detail = '未初始化';

  MobileYoloDetector({required this.modelPath})
      : _yolo = YOLO(modelPath: modelPath, task: YOLOTask.detect);

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
          _detail = 'NOT_CONFIGURED（YOLO 模型加载失败：$modelPath）';
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
        ));
      }
      _available = true;
      _detail = 'YOLO 已接入（$modelPath），最近一帧 ${detections.length} 个检测。';
      return detections;
    } catch (e) {
      _available = false;
      _detail = 'NOT_CONFIGURED（YOLO 推理失败：$e）';
      return <Detection>[];
    }
  }
}
