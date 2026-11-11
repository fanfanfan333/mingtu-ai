/// NAVHAZ M1 configuration: every threshold for the
/// tracking + time-to-collision (TTC) + hazard-alert
/// pipeline in ONE place.
///
/// Per the project lead's decision (2026-11-11), after
/// on-device testing only the VALUES in this file may be
/// tuned -- the logic that consumes them must not change.
/// Values marked are engineering estimates whose
/// sources were not verified; they are starting points for
/// field calibration, not measurements.
library;

/// Which tracking backend the hazard pipeline uses.
enum TrackerBackend { byteTrack, sort}

class NavHazConfig {
NavHazConfig._();

// ---- Tracking -------------------------------------------------

/// Compile-time override: --dart-define=MINGTU_TRACKER=sort
/// selects the hand-written SORT fallback (e.g. when the
/// default backend's IDs prove unstable on a real device).
static const String _trackerDefine =
String.fromEnvironment('MINGTU_TRACKER');

/// Active backend: the define wins when it names a known
/// backend; anything else falls back to byteTrack.
static TrackerBackend get trackerBackend =>
_trackerDefine == 'sort'? TrackerBackend.sort: TrackerBackend.byteTrack;

/// A track is CONFIRMED after this many CONSECUTIVE matched
/// frames; unconfirmed tracks never alert. (Spec value.)
static const int confirmFrames = 3;

/// Per-track ring-buffer capacity: the most recent samples
/// kept for velocity / TTC estimation. (Spec value.)
static const int sampleBufferFrames = 30;

/// A lost track keeps its ID for this many frames before it
/// is retired (a reappearing target within the window is
/// the same target, not a new one). (Spec value.)
static const int lostRetentionFrames = 5;

/// Detections below this confidence never enter tracking
/// (mirrors the long-standing VisualPerception default).
static const double minDetectionConfidence = 0.3;

/// SORT fallback association threshold (IoU).
static const double sortIouThreshold = 0.3;

// ---- Camera / ranging ------------------------------------------

/// Camera height above the ground when chest-worn, metres.
/// (spec value; calibrate on device).
static const double cameraHeightM = 1.3;

/// Assumed vertical field of view, degrees, used to derive
/// the ground-plane ranging constants below until a real
/// calibration replaces them.
static const double verticalFovDeg = 60.0;

/// Assumed horizontal field of view, degrees, used for the
/// clock-direction wording of far hazards.
static const double horizontalFovDeg = 70.0;

/// Normalised principal-point y (image centre until
/// calibrated).
static const double principalY = 0.5;

/// Focal length in normalised image units, derived from
/// [verticalFovDeg]: f_y = 0.5 / tan(VFOV / 2). Computed by
/// the TTC estimator from the FOV constant so the pair can
/// never drift apart.

/// Ground-plane ranging only applies when the box bottom
/// is above this normalised y (a bottom pinned to the
/// image edge carries no horizon geometry). (Spec value.)
static const double groundPlaneMaxBottom = 0.98;

// ---- TTC estimation ----------------------------------------------

/// Alpha-beta filter gains for the scale / range series.
/// (spec values).
static const double alphaBetaAlpha = 0.5;
static const double alphaBetaBeta = 0.1;

/// Two TTC estimates that agree within this relative
/// tolerance are fused by taking the smaller. (Spec value.)
static const double ttcFusionTolerance = 0.5;

/// Nominal frame interval used when frame timestamps are
/// degenerate (zero / absurd gaps, e.g. bursts delivered
/// inside one event-loop turn in tests). 10 FPS matches
/// the M1 replay fixtures.
static const Duration nominalFrameInterval = Duration(milliseconds: 100);

// ---- Ego motion -----------------------------------------------------

/// Walking speed assumed while the ego-motion judge says
/// "walking", m/s. (spec value).
static const double walkingSpeedMps = 1.2;

/// GPS speed at or above this (m/s) counts as walking even
/// when the accelerometer is quiet.
static const double walkingGpsSpeedMps = 0.5;

/// Accelerometer-magnitude variance at or above this
/// ((m/s^2)^2) counts as walking motion.
static const double walkingAccelVariance = 0.8;

/// A vehicle counts as APPROACHING only when its relative
/// closing speed exceeds the user's own speed by more
/// than this margin, m/s. (Spec value.)
static const double approachingMarginMps = 1.0;

// ---- Corridor ----------------------------------------------------

/// The virtual walking corridor on normalised centre-x
/// (same edges as the avoidance advisor's three-condition
/// rule; a hazard only matters when its extrapolated path
/// intersects this band). (Spec values.)
static const double corridorLeft = 0.33;
static const double corridorRight = 0.67;

/// Near-corridor rule inherited from the pre-M1 behaviour:
/// with no usable TTC, a hazard whose box bottom is below
/// this normalised y inside the corridor is treated as
/// near. (Existing project value.)
static const double nearBottom = 0.85;

// ---- Alert levels ---------------------------------------------------

/// URGENT: an approaching vehicle (or any obstacle at very
/// close range) with TTC at or below this, seconds.
/// (Spec value.)
static const double urgentTtcS = 3.0;

/// URGENT close-range branch: any obstacle this close
/// (metres) with TTC at or below [urgentCloseTtcS].
/// (spec values).
static const double urgentCloseRangeM = 1.5;
static const double urgentCloseTtcS = 2.0;

/// WARNING: a confirmed will-hit hazard with TTC at or
/// below this, seconds (the band above [urgentTtcS]).
/// (Spec value: device test plan asks for >= 3 s of
/// advance warning for approaching vehicles.)
static const double warningTtcS = 5.0;

/// WARNING: a static obstacle inside the corridor at or
/// within this range, metres. (Spec value.)
static const double warningStaticRangeM = 3.0;

/// Wording switches from three-zone to clock+distance
/// beyond this range, metres. (Spec value.)
static const double nearWordingRangeM = 5.0;

// ---- Cooldown / dedup ------------------------------------------------

/// Per-track alert cooldown, seconds (spec allows 3-5 s;
/// 4 s chosen). Inside the cooldown only two re-alerts are
/// allowed: a level upgrade (W -> U), or a TTC that has
/// fallen by at least [ttcDropReAlertRatio] since the last
/// spoken alert for that track.
static const int cooldownSeconds = 4;
static const double ttcDropReAlertRatio = 0.4;

/// Two DIFFERENT tracks of the same category and direction
/// zone alerting within this window are merged into one
/// announcement. (Spec value.)
static const Duration mergeWindow = Duration(milliseconds: 500);

// ---- Speech arbitration ------------------------------------------------

/// An interrupted navigation prompt that could not be
/// replayed within this window is dropped for good.
/// (Spec value.)
static const Duration replayExpiry = Duration(seconds: 15);

/// A turn replay is dropped when the user is already
/// closer than this to the intersection, metres.
/// (Spec value.)
static const double replayMinDistanceM = 3.0;

// ---- Vibration patterns ---------------------------------------------------
// VibrationEffect waveform semantics: timings alternate
// wait/vibrate starting with a wait; amplitudes are
// parallel (0 = off). Consumed by the device haptics
// channel and asserted by the arbitration tests.

/// URGENT: three strong pulses (100 ms on, 50 ms off,
/// ~350 ms total). (Spec pattern.)
static const List<int> urgentVibrationTimings = <int>[0, 100, 50, 100, 50, 100];
static const List<int> urgentVibrationAmplitudes = <int>[0, 255, 0, 255, 0, 255];

/// WARNING: two light taps (40 ms on, 60 ms off).
/// (Spec pattern; amplitude 128 = half strength.)
static const List<int> warningVibrationTimings = <int>[0, 40, 60, 40];
static const List<int> warningVibrationAmplitudes = <int>[0, 128, 0, 128];
}
