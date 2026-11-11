/// Pothole detector factory (NAVHAZ M3), behind the same
/// conditional-export pattern as yolo_detector.dart: on a
/// phone (dart:io) the ultralytics_yolo implementation is
/// used; elsewhere the stub reports unavailable. The
/// contract itself lives in core/pothole_scan.dart
/// ([PotholeDetector]); this file only selects the
/// implementation and carries the pure class-name mapping
/// so it is testable without a phone.
///
/// The pothole model (tahaUgan/pothole-yolo11n) has two
/// classes per its model card: index 0 'Pothole', index 1
/// 'Sewage-Manhole'. The TFLite file itself carries NO
/// class-name metadata (verified 2026-11-11: its metadata
/// entries are only min_runtime_version /
/// keep_stablehlo_constant), so the plugin's className for
/// this model cannot be trusted to carry the card's
/// names: [potholeClassLabel] accepts the card names when
/// they do arrive, and otherwise falls back to the card's
/// index order. Only index 0 maps into the hazard system
/// (as [potholeLabel]); index 1 normalises to
/// [sewageManholeLabel] and is EXPLICITLY DISCARDED by
/// the scanner (M3 COMMIT23 ruling, see
/// core/pothole_scan.dart).
library;

import '../core/avoidance_advisor.dart';

export 'pothole_detector_stub.dart'
    if (dart.library.io) 'pothole_detector_mobile.dart';

/// Normalise one raw result of the pothole model to a
/// pipeline label: the model-card class names when the
/// runtime supplies them, the card's index order when it
/// does not (or supplies something unrecognised).
String potholeClassLabel({
  required int classIndex,
  required String className,
}) {
  final String name = className.trim().toLowerCase();
  if (name == 'pothole') return potholeLabel;
  if (name == sewageManholeLabel || name == 'sewage manhole') {
    return sewageManholeLabel;
  }
  // No usable name: the model card's index order is the
  // only authoritative mapping left.
  if (classIndex == 0) return potholeLabel;
  if (classIndex == 1) return sewageManholeLabel;
  return name;
}
