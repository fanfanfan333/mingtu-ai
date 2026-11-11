/// Web / non-mobile pothole detector factory: always
/// unavailable, never fakes a detection. The
/// ultralytics_yolo plugin has no web implementation.
library;

import '../core/pothole_scan.dart';

PotholeDetector createPotholeDetector(String modelPath) =>
    const UnavailablePotholeDetector();
