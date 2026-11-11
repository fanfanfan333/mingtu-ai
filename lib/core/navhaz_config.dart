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

/// Lost-track buffer (CDX4 S1-a): how long a target may
/// vanish and STILL come back as the same track. The time
/// form is the ruling: about one second. The frame form
/// below is that second expressed at the nominal frame
/// interval (10 FPS): retention is counted in MISSED
/// FRAMES (the pipeline's frame clock), so at the nominal
/// rate the two agree; the frame count is what both
/// backends enforce.
static const double lostTrackBufferSeconds = 1.0;

/// A lost track keeps its ID for this many frames before
/// it is retired (a reappearing target within the window
/// is the same target, not a new one). = the
/// [lostTrackBufferSeconds] buffer at the nominal 10 FPS
/// frame interval (10 x 100 ms = 1.0 s).
static const int lostRetentionFrames = 10;

/// Detections below this confidence never enter tracking
/// (mirrors the long-standing VisualPerception default).
static const double minDetectionConfidence = 0.3;

/// Cap on the ByteTrack backend's retired-key set (keys of
/// tracks retired by this layer while the package may
/// still coast them internally). Beyond the cap the OLDEST
/// keys are evicted. Trade-off, accepted: eviction weakens
/// the "a retired package track is never reborn under its
/// old own ID" guarantee only for keys older than the most
/// recent [retiredKeyCap] retirements -- in exchange the
/// set cannot grow without bound on a long-running camera
/// session (each retirement is one target that left and
/// stayed gone past the ~1 s lost-track buffer; 1024 of
/// them is far beyond a realistic single-session count).
static const int retiredKeyCap = 1024;

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

/// Two-tier alpha-beta filtering (FIX3B). The NORMAL
/// tier (alpha 0.3) feeds the warning judgement and the
/// general estimate outputs; the AGILE tier (alpha 0.7)
/// exists only for the urgent judgement, whose one-step
/// prediction compensates the filter lag the CDX3 delay
/// ledger measured (the old single tier -- alpha 0.5 with
/// a hand-filled beta 0.1 -- read TTC_s about +0.87 s
/// high at the urgent crossing).
///
/// Beta is NOT hand-filled any more: it is derived from
/// alpha by the Kalata relation
///   beta = 2(2 - alpha) - 4 * sqrt(1 - alpha)
/// alpha 0.3 -> beta ~= 0.0534; alpha 0.7 -> beta ~=
/// 0.4091. The derivation lives in AlphaBetaFilter.
static const double alphaBetaAlphaNormal = 0.3;
static const double alphaBetaAlphaAgile = 0.7;

/// Pipeline latency subtracted from the agile tier's
/// one-step predicted TTC before the urgent judgement
/// (tau_now = tau_pred - pipelineLatencyS): detection ->
/// tracking -> policy -> speech/haptics dispatch.
/// PROVISIONAL value; to be calibrated on a real device
/// against the end-to-end latency stamps the pipeline
/// emits (see HazardPipeline.onLatency). Calibration
/// note (FIX3B): the lead's initial provisional 0.5 s
/// overshot the acceptance grid on the range-leg path --
/// that leg is essentially unbiased, so the full 0.5 s
/// came straight off the crossing point and the first
/// urgent landed at true TTC 3.5 s, past the grid's 3.3 s
/// upper bound. The grid measurements put the total
/// effective compensation (prediction step + latency) at
/// about 0.3 s; 0.2 s here plus the 0.1 s prediction
/// step lands all four backend x ego combinations
/// inside [2.4, 3.3]. The device stamps refine this.
static const double pipelineLatencyS = 0.2;

/// Pre-emptive urgent vibration (FIX3B): on any frame
/// whose urgent-predicted tau_now drops below this, the
/// pipeline fires the urgent vibration immediately --
/// before urgent confirmation -- while the urgent
/// SPEECH still waits for confirmation. One shot per
/// track until the condition clears or the urgent speech
/// is actually delivered.
static const double preVibrationTtcS = 1.5;

/// TTC fusion consistency rule (spec 2.2, tightened by
/// the M1 fix round): when BOTH TTC estimates are valid
/// (ground-plane TTC_z and box-scale TTC_s), their relative
/// difference |a-b| / max(a,b) decides. Consistent --
/// difference at or below this tolerance -- the fused TTC
/// is the SMALLER of the two. Inconsistent -- difference
/// above this tolerance -- the two measurements contradict
/// each other and, per the spec's degrade-or-do-not-confirm
/// rule, the fused TTC is null and the estimate carries a
/// disagreement marker: contradictory ranging is not
/// trustworthy, so the policy must never promote a hazard
/// to URGENT on either leg's value alone; it may still use
/// the (separately valid) range Z under the static /
/// close-range rules, exactly as for any TTC == null frame.
/// (Spec value.)
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

/// Ego-speed source priority (M1 fix round): a GPS speed is
/// trusted only when the fix that carried it is at most
/// this accurate (metres) AND the speed is fresh (below).
/// Otherwise the accelerometer step-frequency estimate
/// carries the speed, and when neither source is usable
/// the ego speed is UNKNOWN -- the conservative branch in
/// which a vehicle can never be confirmed "approaching".
static const double gpsSpeedMaxAccuracyM = 20.0;
static const Duration gpsSpeedFreshness = Duration(seconds: 5);

/// Stride length for the step-frequency speed estimate
/// (speed = step frequency x stride), metres. PROVISIONAL:
/// a mid-range adult stride (published averages run about
/// 0.7-0.8 m); not yet calibrated on device.
static const double strideLengthM = 0.75;

/// Sliding window over which the accelerometer magnitude
/// variance and step frequency are estimated.
static const Duration accelWindow = Duration(milliseconds: 2500);

/// A vehicle counts as APPROACHING only when its relative
/// closing speed exceeds the user's own speed by more
/// than this margin, m/s. (Spec value.)
static const double approachingMarginMps = 1.0;

// ---- Forward channel (intersection test, ALL paths) ----------------
// Every will-hit / intersection judgement in the hazard
// pipeline -- the known-ego corridor test and the
// ego-unknown scale path alike (unified in the CDX3
// round) -- asks ONE question: does the box bottom-centre,
// extrapolated laterally to the TTC horizon, land inside
// the user's forward channel? The channel is metric when
// a range Z is available and a centre fraction of the
// frame when it is not. There is NO second way in: a box
// that merely OVERLAPS the channel in the current frame
// does not count (a crossing target's box sweeps through
// the channel while its extrapolated landing point is far
// outside it). Both values are PROVISIONAL (the lead's
// ruling fixes the defaults; field calibration may tune
// them).
//
// This channel is a HIT JUDGEMENT, a different thing from
// the wording / advisor corridor [corridorLeft,
// corridorRight] below (three-zone wording edges, shared
// with the avoidance advisor's three-condition rule):
// neither may be tuned by editing the other.

/// Half width of the forward channel, metres, for the
/// intersection test when the target's range can be
/// converted to metres. Default +/-1.0 m per the lead's
/// ruling. 【暂定】
static const double channelHalfWidthM = 1.0;

/// Width of the forward channel as a fraction of the
/// frame width, centred, for the intersection test when
/// no metric range is available: the channel is
/// [0.5 - f/2, 0.5 + f/2] = [0.30, 0.70] at the default.
/// 【暂定】
static const double channelCenterFraction = 0.40;

/// Legacy names for the two channel values above, kept
/// for the ego-unknown path's call sites and tests: the
/// channel is ONE definition (see the section header), so
/// these are aliases, not a second pair of values.
static const double egoUnknownChannelHalfWidthM = channelHalfWidthM;
static const double egoUnknownChannelCenterFraction =
    channelCenterFraction;

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

/// Navigation distance wording bands (FIX3B; the
/// rounding HABITS follow OsmAnd's Chinese announcements
/// -- rule reference only, independently implemented, no
/// OsmAnd code or text tables used; OsmAnd is GPL). Used
/// by navigationDistanceText for turn prompts and route
/// announcements -- NOT by entrance guidance, which
/// keeps its own Step D 10 m bands.
///   d < navWholeMetresBelow   -> whole metres (never
///                                  below
///                                  [navMinReportedMetres])
///   d < navRound50Below       -> nearest 10 m (half up;
///                                  max error 5 m)
///   d < navKilometreFrom      -> nearest 50 m (half up)
///   d < navAboutOneKmBelow    -> "about 1 km"
///   d < navFixedBeyondFrom    -> "about X km"
///   d >= navFixedBeyondFrom   -> fixed "beyond 10 km"
/// The 17-100 m band rounded DOWN (floor) until the
/// FIX4-FINAL ruling (S2): a floored readout could
/// understate by almost 10 m; nearest-with-half-up caps
/// the error at 5 m either way.
static const int navMinReportedMetres = 1;
static const double navWholeMetresBelow = 17;
static const double navRound50Below = 100;
static const double navKilometreFrom = 1000;
static const double navAboutOneKmBelow = 1500;
static const double navFixedBeyondFrom = 10000;

/// Hazard distance wording bands (FIX3B), used by
/// metresText for obstacle / danger announcements:
///   Z < hazardVeryCloseBelow    -> "very close", no
///                                  number
///   Z < hazardWholeMetresBelow  -> whole metres
///   Z < hazardNumberedBelow     -> "about 5 m" / "about
///                                  10 m", split at
///                                  hazardAboutSplit
///   Z >= hazardNumberedBelow    -> no number at all
///                                  (category + bearing
///                                  only)
static const double hazardVeryCloseBelow = 1.5;
static const double hazardWholeMetresBelow = 5;
static const double hazardNumberedBelow = 10;
static const double hazardAboutSplit = 7.5;

// ---- Cooldown / dedup ------------------------------------------------

/// Per-track alert cooldown, seconds (spec allows 3-5 s;
/// 4 s chosen). Inside the cooldown only two re-alerts are
/// allowed: a level upgrade (W -> U), or a TTC that has
/// fallen by at least [ttcDropReAlertRatio] since the last
/// spoken alert for that track (the drop path additionally
/// requires [realertDropMinInterval] since that alert,
/// NH-M2-07).
static const int cooldownSeconds = 4;

/// Per-track alert cooldown, seconds, when the frame's
/// ego speed is UNKNOWN (lead's ruling, 2026-11-11): the
/// scale-only path re-alerts less often (6 s instead of
/// [cooldownSeconds]). The window is chosen per alert
/// evaluation from THAT frame's ego state (not latched
/// per track). The two re-alert exceptions above (level
/// upgrade, TTC drop >= [ttcDropReAlertRatio]) apply
/// unchanged inside this longer window.
static const int cooldownSecondsEgoUnknown = 6;
static const double ttcDropReAlertRatio = 0.4;

/// NH-M2-07 (M3 first commit, lead's FINAL ruling
/// 2026-11-11): the TTC-drop re-alert exception above
/// additionally requires at least this much time since
/// that track's last SPOKEN alert (frame timestamps).
/// Rationale: at a 0.5 s gap the previous sentence has
/// not finished playing, so a repeat would only talk
/// over it (overlap) -- the drop alone no longer
/// suffices inside the window. The W -> U upgrade
/// exception is NOT subject to this interval (speech
/// arbitration interrupts for an upgrade, as before),
/// and a same-level re-alert after the cooldown window
/// has elapsed keeps the plain M1 behaviour above.
/// Calibration placeholder: NO real-device measurement
/// backs the 1.0 s value yet.
static const Duration realertDropMinInterval =
    Duration(seconds: 1);

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

// ---- Danger speech timing -------------------------------------------------

/// Cap on how long a danger / emergency prompt waits for
/// the physical stop of the current utterance before it
/// speaks anyway (FIX2 ruling, 2026-11-11): the stop is
/// still ISSUED first (physical preemption is preserved),
/// but its completion is no longer a precondition for the
/// danger voice -- after this cap the speak proceeds and
/// relies on the TTS engine's own speak-interrupts-current
/// behaviour. The cap is sized so vibration-start ->
/// danger-speech stays inside the spec's 300 ms bound
/// (150 ms stop cap + scheduling slack). Non-danger paths
/// keep their existing 800 ms stop bound; this constant
/// applies ONLY to the danger / emergency branch of the
/// sequenced speak path in main.dart.
static const Duration dangerStopWaitCap = Duration(milliseconds: 150);

/// NH-M1-17 (M2 first commit): per-character SPOKEN
/// duration used to estimate how long an announcement
/// takes to say -- a CONSERVATIVE UPPER bound per
/// Chinese character at the app's TTS rate. The voice
/// output runs at speech rate 0.85 (system_voice_io);
/// ordinary Mandarin TTS at that rate speaks roughly
/// 200-240 characters per minute, i.e. about 0.25-0.30 s
/// per character. 0.30 s/char is the pessimistic end of
/// that range, chosen so the estimate errs towards
/// "will not finish in time" (the safe direction for the
/// short-form decision below). NO real-device
/// measurement backs this figure yet: it is a
/// calibration placeholder, to be replaced by measured
/// per-character timings on a real device (see the
/// README known-issues note).
static const double ttsSecondsPerCharUpperBound = 0.30;

/// NH-M1-19 (narrowing NH-M1-17): the per-character
/// coefficient of the SHORT-FORM decision's condition 2
/// -- the issuance frame's remaining TTC must be
/// strictly below the normal phrase's character count
/// (runes, punctuation excluded) times THIS value for
/// the short form to be eligible at all. 0.25 s/char is
/// the FAST end of the same 200-240 chars/min Mandarin
/// range the 0.30 upper bound comes from: condition 2
/// asks "even at the fastest plausible reading speed,
/// could the full sentence still not finish?" -- if a
/// fast reading COULD finish it, the full sentence is
/// kept. The two constants divide the labour:
/// [ttsSecondsPerCharUpperBound] (0.30) remains the
/// conservative planning bound (spoken-duration
/// estimates), [shortPhraseSecondsPerChar] (0.25) is
/// the short-form gate only. Like the 0.30 figure this
/// is a calibration placeholder with NO real-device
/// measurement behind it yet.
static const double shortPhraseSecondsPerChar = 0.25;

/// NH-M1-19 voiced-character caps for the short forms
/// (M2-B item 4: the caps live HERE, once -- the tests
/// traverse the whole short-form table and read these
/// constants instead of restating the numbers, so a cap
/// change is one edit). Characters are counted by
/// hazard_phrases.voicedCharCount (runes, spoken
/// punctuation ，。！ excluded) -- the SAME counting the
/// gate's condition 2 uses; no second counter exists.
/// - [shortPhraseMaxCharsInVocabulary]: SIX voiced
///   characters for every short form whose item name
///   comes from the detector vocabulary (car / truck /
///   bus / motorcycle / bicycle / person / pole and the
///   clutter fallback for unlisted labels -- every such
///   form fits today, the longest being the clutter
///   centre form at exactly 6).
/// - [shortPhraseMaxCharsFallback]: EIGHT voiced
///   characters for the kind-name FALLBACK forms (labels
///   outside the detector vocabulary speak their kind
///   name -- 机动车 / 非机动车 -- whose honest item word
///   is 3 / 4 characters and cannot compress without
///   misreporting the category). The cap is genuinely
///   exercised, not headroom: the motor-vehicle centre
///   form measures 7 and the non-motor centre form
///   measures exactly 8.
static const int shortPhraseMaxCharsInVocabulary = 6;
static const int shortPhraseMaxCharsFallback = 8;

/// NH-M1-17, narrowed by NH-M1-19: NH-M1-17 introduced
/// the short form (an URGENT whose normal sentence
/// cannot finish before the physical moment speaks a
/// minimal stop form instead); Codex's re-test of the
/// M2 first commit measured that rule firing far too
/// early -- the spec 2.7 approaching car's first urgent
/// already spoke the short form at tau_now ~= 2.70-2.78
/// s, throwing away the item and bearing information a
/// normal urgent (true TTC ~= 2.6-3.0 s) must carry.
/// NH-M1-19 therefore gates the short form on BOTH
/// conditions at once; either failing keeps the FULL
/// sentence:
///   condition 1: the issuance frame's remaining TTC
///     (the published tau_now, falling back to the fused
///     TTC exactly as the cooldown's like-for-like
///     comparison does -- never the raw surface) is
///     strictly below [preVibrationTtcS] (1.5 s): the
///     alert is already inside the vibrate-first zone
///     where the short form is only a fallback;
///   condition 2: that same TTC is strictly below the
///     normal phrase's character count times
///     [shortPhraseSecondsPerChar].
/// The short form is a pure text variant of the SAME
/// alert (same request kind, same priority, chosen once
/// at issuance); warnings never take it. See
/// hazard_phrases.shortUrgentPhrase.

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

// ---- Adaptive frame rate (M2 section 3.1) ----------------------------

/// Master switch for the adaptive frame-rate policy
/// (frame_rate_policy.dart). When false the wiring layer
/// behaves EXACTLY as before this feature existed: no
/// streaming config is passed to the live view, no
/// controller call is made, and the plugin runs at its
/// own default rate. The policy object itself remains
/// pure logic either way; the flag is consulted only by
/// the wiring layer.
static const bool adaptiveFrameRateEnabled = true;

/// Target inference rate while the user is STILL and the
/// still gate (below) holds, FPS. (Spec 3.1 still tier.)
static const int frameRateStillFps = 2;

/// Target inference rate while WALKING, FPS. The spec
/// band is 8-10 FPS; the UPPER edge is taken so tracking
/// latency stays at the band's best while the power
/// saving against the plugin default is still large.
static const int frameRateWalkingFps = 10;

/// Target inference rate while a confirmed hazard is
/// NEAR (see [frameRateDangerTtcS]), FPS. The spec band
/// is 15-20 FPS; the UPPER edge is taken because this
/// tier exists precisely for the frames where TTC
/// estimates must refresh fastest.
static const int frameRateDangerFps = 20;

/// A confirmed track counts as NEAR DANGER for the frame
/// rate when its TTC is below this, seconds. (Spec 3.1:
/// "confirmed track with TTC < 5 s, or an approaching
/// vehicle inside the corridor" -- the corridor branch
/// needs no threshold and lives in the policy's danger
/// input definition.)
static const double frameRateDangerTtcS = 5.0;

/// Downshift hysteresis (spec 3.1): a LOWER tier's
/// conditions must hold CONTINUOUSLY for this long
/// before the target actually drops. Upshifts are
/// immediate -- a danger must never wait out a timer --
/// but a momentary lull (one quiet frame, a brief GPS
/// wobble) must not flap the camera rate down and back.
static const Duration frameRateDownshiftHold = Duration(seconds: 3);

/// Still-gate quiet window (spec 3.1 substitute gating):
/// the still tier requires, on top of the ego judge
/// saying still, NO live track AND no new detection for
/// at least this long. The plugin delivers detections,
/// not raw frames, so true frame-difference / optical-
/// flow gating is NOT available at this layer; it is
/// deferred until the detection pipeline moves off the
/// plugin (spec section 6 Q1). This detection-quiet
/// proxy is the spec's own substitute, not an equivalent.
static const Duration frameRateStillQuietWindow = Duration(seconds: 2);

// ---- Thermal derating (M2 section 3.2) -------------------------------

/// Master switch for thermal derating (thermal_policy.dart
/// + the thermal_monitor adapter). When false the wiring
/// layer never subscribes to the platform thermal stream
/// and imposes no cap: the pre-3.2 behaviour, exactly. The
/// policy object itself remains pure logic either way; the
/// flag is consulted only by the wiring layer.
static const bool thermalDeratingEnabled = true;

/// FPS ceiling while the device reports LIGHT or MODERATE
/// thermal status (spec 3.2). The same tier also caps the
/// camera analysis resolution at 720p (the adapter maps
/// that to the plugin's Size(1280, 720) convention).
static const int thermalCapModerateFps = 10;

/// FPS ceiling while the device reports SEVERE thermal
/// status or worse (spec 3.2). This tier additionally
/// restricts detection input to vehicle and pedestrian
/// classes only.
static const int thermalCapSevereFps = 5;

/// Stepwise recovery hold (spec 3.2): after the reported
/// status improves, it must HOLD below the applied tier
/// continuously for this long before the cap rises ONE
/// step (severe tier -> moderate tier -> unconstrained).
/// Derating is always immediate; recovery is always
/// hysteretic -- the same asymmetry as the frame-rate
/// policy's up/down shifts (section 3.1), because a
/// device oscillating around a thermal threshold must
/// not flap the camera rate with it.
static const Duration thermalRecoveryHold = Duration(seconds: 30);

/// The heat derating warning, verbatim (spec 3.2,
/// announcement model superseded by the episode-latch
/// ruling): spoken once per derating episode, at the
/// moment the applied cap first limits the frame rate
/// (the FPS latch in thermal_policy.dart), at alert
/// level. It asks the user to slow down and watch their
/// footing; it makes no claim about the way ahead and
/// passes the banned-word check (asserted in the thermal
/// tests). The constant keeps its section 3.2 name --
/// it was the CRITICAL-tier text under the original
/// rule -- but the episode latch, not the critical
/// status, now decides when it is spoken.
static const String thermalCriticalAnnouncementText =
    '手机较热，识别已降频，请放慢脚步注意脚下';

/// The scope-restriction warning, verbatim (dictated
/// wording): spoken once per derating episode, at the
/// moment the applied cap first restricts detection to
/// vehicles and pedestrians (the scope latch in
/// thermal_policy.dart), at alert level. A blind user
/// cannot see the narrower detection scope on a screen,
/// so the narrowing is always spoken; the text passes
/// the banned-word check (asserted in the thermal
/// tests).
static const String thermalScopeRestrictedAnnouncementText =
    '手机过热，暂时只提醒车辆和行人，请放慢脚步';

/// The recovery notice, verbatim (dictated wording):
/// spoken once when a derating episode fully ends --
/// the applied cap back to unconstrained on a genuine
/// NONE reading -- at info level. Partial recoveries
/// and unknown readings never produce it (see
/// thermal_policy.dart). Passes the banned-word check
/// (asserted in the thermal tests).
static const String thermalRecoveryAnnouncementText = '障碍提醒已恢复';

// ---- Cloud event triggers (M2 section 3.3) ---------------------------

/// Master switch for the AUTOMATIC cloud triggers
/// (cloud_trigger_policy.dart). When false the wiring
/// layer never evaluates the trigger policy and no
/// automatic cloud call is ever made; MANUAL cloud
/// vision (the user's own "看看前面") is not governed by
/// this flag at all. The policy and budget objects stay
/// pure logic either way.
static const bool cloudAutoTriggerEnabled = true;

/// Step-text keywords that mark a navigation step as a
/// crossing step for the crossingStop trigger (spec
/// 3.3): a step whose text contains ANY of these is a
/// step at which the user may have to cross or turn at
/// an intersection.
static const List<String> cloudCrossingStepKeywords = <String>[
  '人行横道',
  '过马路',
  '路口',
];

/// crossingStop distance gate (spec 3.3): the user must
/// be within this many metres of the crossing step's
/// START point.
static const double cloudCrossingMaxStepDistanceM = 15.0;

/// crossingStop stillness gate (spec 3.3): the user
/// must have been still CONTINUOUSLY for at least this
/// long before a crossing frame is worth sending.
static const Duration cloudCrossingStillHold = Duration(seconds: 2);

/// pathBlocked persistence gate (spec 3.3): a confirmed
/// static obstacle inside the forward channel must have
/// persisted CONTINUOUSLY for at least this long.
static const Duration cloudBlockedObstacleHold = Duration(seconds: 4);

/// Static-obstacle closing slack for the pathBlocked
/// evidence (wiring layer): an obstacle counts as
/// STATIC when it closes no faster than the user's own
/// measured motion explains, plus this slack -- i.e.
/// the obstacle itself is not approaching; the closing
/// is the user walking toward it. While the user stands
/// still this reduces to "closes at most this fast".
static const double cloudBlockedStaticClosingSlackMps = 0.3;

/// Automatic-call budget (spec 3.3): two automatic
/// cloud calls are at least this far apart...
static const Duration cloudAutoMinInterval = Duration(seconds: 60);

/// ...and at most [cloudAutoMaxPerWindow] automatic
/// calls land in any sliding window of this length.
/// The window is the HARD constraint (it caps the
/// average at 0.5 calls/minute over any 10 minutes);
/// the interval above is its corollary and is enforced
/// explicitly as well.
static const Duration cloudAutoWindow = Duration(minutes: 10);

/// See [cloudAutoWindow].
static const int cloudAutoMaxPerWindow = 5;

// ---- Pothole second detector (M3) -----------------------------------
//
// The pothole detector is a SECOND, independent detector
// (its own model, tahaUgan/pothole-yolo11n, CC BY 4.0 --
// see tool/fetch_pothole_model.sh and the README model
// section) behind the build-time switch
// --dart-define=MINGTU_POTHOLE=1 (AppConfig.potholeEnabled,
// default OFF). The constants below govern only its scan
// cadence and its grading threshold; the grading itself is
// the dedicated pit branch in hazard_policy.dart.

/// Pit URGENT range (M3 ruling): a pothole whose measured
/// ground range Z is at or below this many metres grades
/// URGENT. A pit is a static ground feature, so the grade
/// is a pure range rule -- the TTC machinery (approach
/// tests, scale/range closing legs) never applies to it.
/// (Provisional value from the ruling; real-device
/// calibration pending, like every value in this file.)
static const double pitUrgentRangeM = 1.5;

/// Scan cadence cap for the pothole scanner: at most one
/// scan per this interval (200 ms = 5 FPS), and scans run
/// ONLY while the user is walking (the pipeline's own ego
/// judgement). A pothole scan is a single frame through
/// the shared routed frame source plus one predict() on
/// the second model -- never a second camera session.
static const Duration potholeScanMinInterval =
    Duration(milliseconds: 200);

/// How long a completed scan's detections stay mergeable
/// into live frames at the shared intake. Scans refresh
/// at the cadence above while walking, so this age only
/// bounds the tail after walking stops or a scan stalls:
/// past it, the stored detections are dropped and the pit
/// track coasts out through the tracker's normal lost
/// window instead of being re-fed forever.
static const Duration potholeResultMaxAge = Duration(seconds: 1);
}
