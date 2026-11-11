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
/// - THERMAL GATE (M3 COMMIT23 ruling, superseding the
///   step-2 "run, then filter at intake" behaviour): while
///   the APPLIED thermal cap restricts classes (SEVERE /
///   CRITICAL settled by the thermal ladder -- the same
///   state that raises the "vehicles and pedestrians
///   only" announcement), the scanner STOPS RUNNING: no
///   model load, no frame capture, no inference. A second
///   model is itself a heat source, and stopping matches
///   the scope the user was already told about. When the
///   ladder settles back to a non-restricting rung
///   (NONE / LIGHT / MODERATE) scanning resumes on its
///   own; the thermal recovery announcement the policy
///   already owns covers the news -- this layer adds NO
///   pothole-specific thermal speech. The wiring feeds
///   the gate through [PotholeScanner.setThermalRestricted];
///   the intake class restriction stays in place as a
///   backstop for detections already in flight.
/// - The model's Sewage-Manhole class is EXPLICITLY
///   DISCARDED in [PotholeScanner.maybeScan] (COMMIT23
///   ruling): most manholes are closed and can be stepped
///   on, the model cannot tell open from closed, and
///   announcing them would false-alarm constantly.
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

/// What the app should do about the pothole feature at
/// startup (M3 COMMIT23 zero-burden rule). The build must
/// succeed with or without the weight file, so presence
/// is a RUNTIME question (answered through the asset
/// system by the wiring layer), never a build-time one.
enum PotholeStartupState {
  /// Switch off: no existence check, no log, no speech --
  /// the feature is simply absent.
  disabled,

  /// Switch on but the weight asset is not bundled: the
  /// feature behaves as off (one fixed log line, and --
  /// because the user explicitly enabled it -- ONE spoken
  /// "pothole recognition unavailable" notice per process,
  /// latched by [PotholeUnavailableNoticeLatch]).
  unavailable,

  /// Switch on and the weight asset is bundled: normal
  /// operation.
  ready,
}

/// The startup decision, pure so the three states are
/// unit-testable without the asset system: [enabled] is
/// the switch (AppConfig.potholeEnabled) and
/// [modelBundled] the asset-system answer. The existence
/// check only ever RUNS when the switch is on; callers
/// pass `modelBundled: false` when it did not run, which
/// this function only consults under `enabled`.
PotholeStartupState potholeStartupState({
  required bool enabled,
  required bool modelBundled,
}) {
  if (!enabled) return PotholeStartupState.disabled;
  return modelBundled
      ? PotholeStartupState.ready
      : PotholeStartupState.unavailable;
}

/// Once-per-process latch for the spoken missing-model
/// notice: the user explicitly enabled the feature, so
/// its absence is announced -- but exactly once, however
/// often startup logic re-runs.
class PotholeUnavailableNoticeLatch {
  bool _claimed = false;

  bool get claimed => _claimed;

  /// True exactly once (the caller may announce); every
  /// later call returns false.
  bool claimOnce() {
    if (_claimed) return false;
    _claimed = true;
    return true;
  }
}

/// The scan coordinator. Constructed by the wiring layer
/// ONLY when the pothole switch is on AND the weight
/// asset is bundled (see [potholeStartupState]); [enabled]
/// is injected (production passes AppConfig.potholeEnabled)
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
  /// is not evidence of absence). The thermal gate also
  /// reports through this sink: when it closes, it calls
  /// once with an empty list to CLEAR the caller's stored
  /// result (see [setThermalRestricted]).
  final void Function(List<Detection> detections, DateTime at)?
      onDetections;

  DateTime? _lastScanStartedAt;
  bool _inFlight = false;
  int _scanCount = 0;

  /// The thermal gate (COMMIT23): true while the applied
  /// thermal cap restricts classes. Starts OPEN; the
  /// wiring feeds the current cap at construction and on
  /// every thermal evaluation, so a scanner created while
  /// the device is already hot is gated before its first
  /// scan (and its detector never loads: loading is lazy,
  /// inside the first scan this gate now prevents).
  bool _thermalRestricted = false;

  /// Bumped on every gate transition. A scan captures the
  /// epoch when it starts; if the epoch moved by the time
  /// its result is ready, the result is stale-by-ruling
  /// and is DROPPED (never delivered), whatever the gate's
  /// current state is by then.
  int _gateEpoch = 0;

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

  bool get thermalRestricted => _thermalRestricted;

  /// Feed the applied thermal state (the wiring passes
  /// `cap.restrictClasses` from the same ThermalPolicy
  /// evaluation that drives the class restriction and the
  /// scope announcement). Idempotent: only a TRANSITION
  /// acts. On closing (restricted becomes true): any scan
  /// in flight is invalidated (its result will be dropped
  /// on arrival) and the caller's stored result is cleared
  /// through [onDetections] with an empty list, so a pit
  /// found just before the heat spike is not merged for
  /// the rest of the stop. On opening: nothing is spoken
  /// or forced -- the next [maybeScan] simply runs again.
  void setThermalRestricted(bool restricted, {required DateTime now}) {
    if (restricted == _thermalRestricted) return;
    _thermalRestricted = restricted;
    _gateEpoch += 1;
    if (restricted) {
      onDetections?.call(const <Detection>[], now);
    }
  }

  /// Offer one pipeline frame's moment to the scanner.
  /// Runs a scan only when ALL gates pass: switch on,
  /// thermal gate open, [walking] (the caller's ego
  /// verdict for this frame), no scan in flight, and the
  /// cadence interval since the last scan start has
  /// elapsed. [now] is the caller's frame clock
  /// (injectable in tests through the frames they feed).
  /// Never throws.
  Future<void> maybeScan({
    required bool walking,
    required DateTime now,
  }) async {
    if (!enabled || _thermalRestricted || !walking || _inFlight) return;
    final DateTime? last = _lastScanStartedAt;
    if (last != null &&
        now.difference(last) < NavHazConfig.potholeScanMinInterval) {
      return;
    }
    _lastScanStartedAt = now;
    _inFlight = true;
    _scanCount += 1;
    final int epoch = _gateEpoch;
    try {
      final CameraFrameCapture capture =
          await frameSource.captureSingleFrame();
      if (!capture.ok || capture.bytes == null) return;
      final List<Detection> raw =
          await detector.detectImage(capture.bytes!);
      // The thermal gate closed (or flipped) while this
      // scan was in flight: the result is dropped, never
      // delivered -- the device was already too hot for
      // this model's evidence to be merged.
      if (epoch != _gateEpoch) return;
      // The adapter normalises the model's classes; only
      // the pothole class is kept. The Sewage-Manhole
      // class is discarded EXPLICITLY, by name
      // (COMMIT23 ruling): most manholes are closed and
      // can be stepped on, the model cannot tell open
      // from closed, and announcing them would
      // false-alarm constantly. Any other unexpected
      // label is dropped with it -- only [potholeLabel]
      // may enter the shared intake from this path.
      final List<Detection> pits = <Detection>[];
      for (final Detection d in raw) {
        if (d.label == sewageManholeLabel) {
          continue; // explicit discard (COMMIT23), see above
        }
        if (d.label == potholeLabel) pits.add(d);
      }
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
