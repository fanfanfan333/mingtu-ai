/// Web / non-mobile YOLO factory: always unavailable, never fakes a
/// detection. The ultralytics_yolo plugin has no web implementation.
library;

import 'yolo_detector.dart';

YoloDetector createYoloDetector(String modelPath) =>
    UnavailableYoloDetector();

bool canOpenYoloLive(YoloDetector detector) => detector.isAvailable;
