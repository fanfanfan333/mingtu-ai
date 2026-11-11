/// Pothole second detector (NAVHAZ M3): the scan
/// coordinator that runs the pothole model as a SECOND,
/// independent detector alongside the main YOLO live view.
///
/// Design boundaries (M3 ruling):
/// - Behind the build-time switch
///   --dart-define=MINGTU_POTHOLE=1 (see
///   AppConfig.potholeEnabled), OFF by default. While off,
///   the wiring layer never constructs this object: no
///   model is loaded, no detector exists, no frame is
///   captured for it, and pipeline behaviour is exactly
///   the pre-M3 behaviour.
/// - Scans run ONLY while the user is walking (the caller
///   passes the pipeline's own ego verdict -- this file
///   never re-judges motion) and at most once per
///   [NavHazConfig.potholeScanMinInterval] (200 ms,
///   i.e. <= 5 FPS).
/// - A scan is ONE frame from the app's shared routed
///   frame source (the same source cloud vision uses:
///   while the live view holds the camera, its most
///   recent frame; otherwise a one-shot still under the
///   camera lease) plus ONE predict() on the second
///   model. There is never a second camera session.
/// - Results are handed to the caller through
///   [PotholeScanner.onDetections]; the wiring layer
///   merges them into live frames at the SHARED intake
///   (_onYoloDetections), so every downstream discipline
///   (thermal class restriction, tracking, grading,
///   arbitration) applies to pit detections exactly as
///   it does to main-detector detections.
/// - Failures are silent BY DESIGN at this layer: a
///   failed capture or inference produces no detections
///   and no speech. The pothole detector is an added
///   sense, never a precondition for the main pipeline,
///   and a scan failure must never masquerade as "no
///   pothole" -- it simply contributes nothing, exactly
///   like a frame the main detector missed.
library;

import 'dart:async';

import '../modules/visual_perception.dart';
import 'avoidance_advisor.dart';
import 'camera_frame.dart';
import 'navhaz_config.dart';

/// The pothole detector contract: single-image inference
/// on the pothole model, mirroring the main detector's
/// YoloDetector contract. The production implementation
/// lives behind a conditional import
/// (adapters/pothole_detector.dart); tests substitute
/// fakes. Implementations never throw to the caller and
/// never fabricate a detection: on load / inference
/// failure they return an empty list and report
/// unavailable through [isAvailable] / [status].
abstract class PotholeDetector {
  bool get isAvailable;
  String get status;

  /// Run inference on one image ([imageBytes] is a
  /// JPEG/PNG). Returns detections in the pipeline's
  /// shared [Detection] shape, with the pothole class
  /// already normalised to [potholeLabel].
  Future<List<Detection>> detectImage(List<int> imageBytes);
}

/// Last-resort / off-platform pothole detector: honestly
/// unavailable, detects nothing.
class UnavailablePotholeDetector implements PotholeDetector {
  const UnavailablePotholeDetector();

  @override
  bool get isAvailable => false;

  @override
  String get status =>
      'NOT_CONFIGURED（坑洞检测未接入：本平台不支持手机端推理，或模型未加载）';

  @override
  Future<List<Detection>> detectImage(List<int> imageBytes) async =>
      <Detection>[];
}

/// The scan coordinator. Constructed by the wiring layer
/// ONLY when the pothole switch is on; [enabled] is
/// injected (production passes AppConfig.potholeEnabled)
/// so tests can flip the switch without a build flag.
class PotholeScanner {
  final bool enabled;
  final PotholeDetector detector;
  final CameraFrameSource frameSource;

  /// Sink for completed scans: the pothole detections of
  /// the latest scan (possibly empty -- an empty result
  /// REPLACES the previous one at the caller, it does not
  /// accumulate) and the scan's frame time. Called at
  /// most once per scan, only when the scan actually ran
  /// (a gated-out or failed scan calls nothing: failure
  /// is not evidence of absence).
  final void Function(List<Detection> detections, DateTime at)?
      onDetections;

  DateTime? _lastScanStartedAt;
  bool _inFlight = false;
  int _scanCount = 0;

  PotholeScanner({
    required this.enabled,
    required this.detector,
    required this.frameSource,
    this.onDetections,
  });

  /// How many scans have actually run (capture attempted)
  /// -- the observable the cadence tests assert on.
  int get scanCount => _scanCount;

  bool get inFlight => _inFlight;

  /// Offer one pipeline frame's moment to the scanner.
  /// Runs a scan only when ALL gates pass: switch on,
  /// [walking] (the caller's ego verdict for this frame),
  /// no scan in flight, and the cadence interval since
  /// the last scan start has elapsed. [now] is the
  /// caller's frame clock (injectable in tests through
  /// the frames they feed). Never throws.
  Future<void> maybeScan({
    required bool walking,
    required DateTime now,
  }) async {
    if (!enabled || !walking || _inFlight) return;
    final DateTime? last = _lastScanStartedAt;
    if (last != null &&
        now.difference(last) < NavHazConfig.potholeScanMinInterval) {
      return;
    }
    _lastScanStartedAt = now;
    _inFlight = true;
    _scanCount += 1;
    try {
      final CameraFrameCapture capture =
          await frameSource.captureSingleFrame();
      if (!capture.ok || capture.bytes == null) return;
      final List<Detection> raw =
          await detector.detectImage(capture.bytes!);
      // The adapter already normalises the pothole class
      // to [potholeLabel]; the filter is defence in depth
      // so no other class of the second model (its
      // 'Sewage-Manhole' class is deliberately unmapped)
      // can ever enter the shared intake from this path.
      final List<Detection> pits = raw
          .where((Detection d) => d.label == potholeLabel)
          .toList(growable: false);
      onDetections?.call(pits, now);
    } catch (_) {
      // A scan failure contributes nothing (see the
      // library doc): no detections, no speech, no state
      // change beyond the cadence stamp above.
    } finally {
      _inFlight = false;
    }
  }
}
