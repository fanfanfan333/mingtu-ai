/// Adaptive frame-rate policy for the live detection
/// view (NAVHAZ M2 spec section 3.1).
///
/// The policy is PURE LOGIC: it never touches the camera
/// plugin. Each evaluation takes the scene facts the
/// wiring layer already has -- the ego-motion verdict
/// (reusing [EgoMotion], the same judgement the hazard
/// pipeline runs on), whether a near danger is present
/// (derived from the hazard pipeline's per-frame
/// estimates), and detection activity -- and returns the
/// target inference rate. The wiring layer maps that
/// target onto the plugin's streaming config and applies
/// the section 3.2 thermal cap on top (see the marked
/// hook in yolo_live_view_mobile.dart).
///
/// Tiers (values in [NavHazConfig]):
/// - danger: a confirmed track with TTC below
///   [NavHazConfig.frameRateDangerTtcS], or an
///   approaching vehicle whose extrapolated path lands
///   in the forward channel;
/// - walking: the ego judge says the user is walking;
/// - still: the ego judge says still AND the substitute
///   gate holds (no live track, no new detection inside
///   [NavHazConfig.frameRateStillQuietWindow]).
///
/// Upshifts apply IMMEDIATELY (danger never waits out a
/// timer). Downshifts are hysteretic: the lower tier's
/// conditions must hold continuously for
/// [NavHazConfig.frameRateDownshiftHold] before the
/// target drops, so one quiet frame or a brief sensor
/// wobble cannot flap the camera rate.
///
/// Substitute gating, honestly scoped: the plugin
/// delivers DETECTIONS, not raw frames, so a true
/// frame-difference / optical-flow gate cannot be built
/// at this layer. The spec's substitute (IMU still + no
/// tracks + no new detection for the quiet window) is
/// what the still tier uses; real motion gating is
/// deferred to the permissive-licence pipeline move
/// (spec section 6 Q1).
library;

import 'hazard/ego_motion.dart';
import 'hazard/ttc_estimator.dart';
import 'navhaz_config.dart';

/// The scene tier the policy has settled on. The FPS
/// each tier maps to lives in [NavHazConfig]; the tier
/// is exposed (not just the number) so tests and logs
/// can say WHY the rate is what it is.
enum FrameRateTier { still, walking, danger }

class FrameRatePolicy {
  FrameRateTier _tier = FrameRateTier.walking;

  /// When the currently-wanted lower tier was first
  /// observed (and has held since). Null while the
  /// wanted tier is at or above the settled tier.
  DateTime? _lowerSince;

  /// The tier the policy has settled on after the last
  /// evaluation (post-hysteresis).
  FrameRateTier get tier => _tier;

  /// The settled target inference rate, FPS.
  int get targetFps => fpsForTier(_tier);

  static int fpsForTier(FrameRateTier tier) => switch (tier) {
        FrameRateTier.still => NavHazConfig.frameRateStillFps,
        FrameRateTier.walking => NavHazConfig.frameRateWalkingFps,
        FrameRateTier.danger => NavHazConfig.frameRateDangerFps,
      };

  /// Whether ANY of this frame's estimates is a near
  /// danger (spec 3.1): a CONFIRMED track whose TTC --
  /// the published urgent value when there is one, else
  /// the fused value, the same like-for-like choice the
  /// alert cooldown makes -- is below
  /// [NavHazConfig.frameRateDangerTtcS]; or an
  /// approaching vehicle (approaching is a vehicle-only
  /// judgement in the estimator) whose extrapolated
  /// landing point is inside the forward channel.
  /// Unconfirmed tracks never count: an unproven target
  /// must not pin the camera at its most expensive rate.
  static bool dangerPresentIn(List<TrackEstimate> estimates) {
    for (final TrackEstimate e in estimates) {
      if (!e.track.confirmed) continue;
      final double? ttc = e.ttcUrgentS ?? e.ttcS;
      if (ttc != null && ttc < NavHazConfig.frameRateDangerTtcS) {
        return true;
      }
      if (e.approaching && e.willHit) return true;
    }
    return false;
  }

  /// Evaluate one frame and return the settled target
  /// FPS after hysteresis.
  ///
  /// [now] is the evaluation time (injectable clock: the
  /// caller passes the frame's own stamp). [motion] is
  /// the ego judge's verdict for this frame -- the
  /// wiring layer reuses the app's existing per-frame
  /// judgement rather than re-reading any sensor here.
  /// [dangerPresent] is [dangerPresentIn] over the
  /// hazard pipeline's estimates for this frame.
  /// [hasLiveTrack] means at least one track was
  /// ESTIMATED on the latest frame (the pipeline skips
  /// lost-coast tracks, so an estimated track is a
  /// currently-seen one); [lastDetectionAt] is the last
  /// frame stamp that carried any detection at all. The
  /// two feed the still gate's substitute conditions.
  int evaluate({
    required DateTime now,
    required EgoMotion motion,
    required bool dangerPresent,
    required bool hasLiveTrack,
    required DateTime? lastDetectionAt,
  }) {
    final FrameRateTier wanted = _wantedTier(
      now: now,
      motion: motion,
      dangerPresent: dangerPresent,
      hasLiveTrack: hasLiveTrack,
      lastDetectionAt: lastDetectionAt,
    );
    if (wanted.index >= _tier.index) {
      // Upshift (or no change): immediate.
      _tier = wanted;
      _lowerSince = null;
    } else {
      // Downshift: only after the lower conditions have
      // held continuously for the configured hold. A
      // single evaluation back at/above the settled tier
      // (handled above) resets the clock.
      final DateTime since = _lowerSince ??= now;
      if (!now.isBefore(since.add(NavHazConfig.frameRateDownshiftHold))) {
        _tier = wanted;
        _lowerSince = null;
      }
    }
    return targetFps;
  }

  FrameRateTier _wantedTier({
    required DateTime now,
    required EgoMotion motion,
    required bool dangerPresent,
    required bool hasLiveTrack,
    required DateTime? lastDetectionAt,
  }) {
    if (dangerPresent) return FrameRateTier.danger;
    if (motion.isWalking) return FrameRateTier.walking;
    // Still candidate: the substitute gate must ALSO
    // hold -- no live track and no new detection inside
    // the quiet window. Until it does, a stationary user
    // with something in view keeps the walking rate:
    // standing still in front of a hazard is not a
    // reason to look at it less often.
    if (hasLiveTrack) return FrameRateTier.walking;
    if (lastDetectionAt != null &&
        now.difference(lastDetectionAt) <
            NavHazConfig.frameRateStillQuietWindow) {
      return FrameRateTier.walking;
    }
    return FrameRateTier.still;
  }
}
