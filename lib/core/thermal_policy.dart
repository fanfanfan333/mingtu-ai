/// Thermal derating policy (NAVHAZ M2 spec section 3.2).
///
/// The policy is PURE LOGIC: it consumes thermal status
/// events with caller-supplied stamps (an injectable
/// clock -- the caller passes the event's own time) and
/// settles the cap the wiring layer applies on top of the
/// frame-rate policy's scene target:
///
///   final fps = min(scene target, cap.maxFps)
///
/// Status-to-tier mapping (thresholds in [NavHazConfig]):
/// - NONE or unknown    -> no cap at all;
///   LIGHT / MODERATE   -> FPS ceiling
///     [NavHazConfig.thermalCapModerateFps] + the camera
///     analysis resolution capped at 720p;
///   SEVERE             -> FPS ceiling
///     [NavHazConfig.thermalCapSevereFps] + detection
///     input restricted to vehicle and pedestrian classes;
///   CRITICAL and above (EMERGENCY / SHUTDOWN ride the
///     same tier) -> the SEVERE tier.
///
/// Two judgement calls, recorded here rather than buried:
/// - CRITICAL inherits SEVERE's class restriction. The
///   spec writes the restriction into the SEVERE line
///   ("lock 5 FPS, detect only vehicles and pedestrians")
///   and gives CRITICAL "lock 5 FPS + announce"; a hotter
///   device dropping the restriction its cooler tier
///   imposed would be incoherent, so the restriction is
///   read as part of the 5 FPS tier itself.
/// - The 720p ceiling, once imposed at LIGHT/MODERATE, is
///   not loosened at the hotter tiers either: caps only
///   ever tighten as heat rises.
///
/// Timing rules:
/// - Derating is IMMEDIATE: a worse status applies its
///   tier on the very evaluation that reports it.
/// - Recovery is HYSTERETIC and STEPWISE: the reported
///   status must hold continuously below the applied
///   tier for [NavHazConfig.thermalRecoveryHold] before
///   the cap rises ONE step (5 FPS tier -> 10 FPS/720p
///   tier -> unconstrained), and each further step needs
///   its own full hold. A worsening during recovery snaps
///   straight back to the corresponding strict tier. The
///   asymmetry mirrors section 3.1's frame-rate shifts:
///   protection never waits, relief always does.
/// Announcement model (episode latches; this SUPERSEDES
/// the section 3.2 rule "CRITICAL announces at most once
/// per five minutes", which re-announced for as long as
/// the device stayed critical -- the five-minute
/// re-announcement and its interval constant are gone):
/// a blind user cannot see an on-screen degradation
/// badge, so every material degradation is SPOKEN.
/// An EPISODE runs from the applied cap first leaving
/// unconstrained until it returns there. Inside one
/// episode two latches each fire at most once:
/// - the FPS latch: the first evaluation whose applied
///   cap limits the frame rate raises
///   [ThermalAnnouncement.fpsDrop];
/// - the scope latch: the first evaluation whose applied
///   cap restricts detection classes raises
///   [ThermalAnnouncement.scopeRestricted].
/// When one evaluation trips both (a direct NONE ->
/// SEVERE/CRITICAL jump), only the scope event is
/// raised and the FPS latch is consumed silently: the
/// narrower detection scope is the graver fact, and
/// both dictated texts end by asking the user to slow
/// down. Tier changes inside the episode (moderate <->
/// severe, severe -> critical -- the cap does not even
/// change there) raise nothing further.
/// When the applied cap returns to unconstrained AND at
/// least one latch fired during the episode,
/// [ThermalAnnouncement.recovered] is raised once and
/// both latches reset, so a later episode may announce
/// again. A PARTIAL recovery (back to the moderate tier,
/// say) raises nothing.
/// Correspondence with the old section 3.2 rule
/// "CRITICAL announces once": on a DIRECT jump to
/// critical the scope event fires at that very
/// evaluation, satisfying the once-only critical
/// announcement with the scope text; on the PROGRESSIVE
/// path (through severe) the scope fact was already
/// announced at severe, so critical itself adds no new
/// fact and stays silent.
/// UNKNOWN readings never end an episode and never
/// raise the recovered event. The ladder above treats
/// an unknown status as the unconstrained tier FOR THE
/// CAP (a device that cannot report its heat is never
/// punished), so the cap can settle back to no-cap
/// under unknown readings alone; the announcement layer
/// keeps the episode open in that case -- latches stay
/// consumed, nothing is spoken -- and the recovered
/// event fires only on an evaluation carrying a REAL
/// status of NONE with the cap unconstrained (in the
/// normal course that is exactly the evaluation where
/// the stepwise ladder, walked under real readings,
/// arrives back at no-cap).
library;

import 'avoidance_advisor.dart';
import 'navhaz_config.dart';
import 'thermal.dart';

/// A one-shot spoken-announcement event raised by a
/// single [ThermalPolicy.evaluate] call (see the library
/// doc for the episode-latch model). At most one event
/// is raised per evaluation. The wiring layer maps each
/// event to its dictated text and speech level:
/// [fpsDrop] and [scopeRestricted] are spoken at alert
/// level, [recovered] at info level.
enum ThermalAnnouncement {
  /// Nothing to say on this evaluation.
  none,

  /// The episode's frame-rate cap first took hold:
  /// speak the derating text
  /// ([NavHazConfig.thermalCriticalAnnouncementText]).
  fpsDrop,

  /// The episode's class restriction first took hold:
  /// speak the scope text
  /// ([NavHazConfig.thermalScopeRestrictedAnnouncementText]).
  scopeRestricted,

  /// The episode ended at a genuinely cool reading:
  /// speak the restoration text
  /// ([NavHazConfig.thermalRecoveryAnnouncementText]).
  recovered,
}

/// The settled thermal cap at one moment. [maxFps] null
/// means no FPS ceiling. [announcement] is a ONE-SHOT
/// event: it is non-[ThermalAnnouncement.none] only on
/// the single evaluation that trips the episode latch,
/// not for as long as the condition persists.
class ThermalCap {
  final int? maxFps;
  final bool analysisResolution720p;
  final bool restrictClasses;
  final ThermalAnnouncement announcement;

  const ThermalCap({
    required this.maxFps,
    required this.analysisResolution720p,
    required this.restrictClasses,
    this.announcement = ThermalAnnouncement.none,
  });

  /// The no-cap value: no FPS ceiling, no resolution
  /// ceiling, no class restriction, nothing to announce.
  static const ThermalCap unconstrained = ThermalCap(
    maxFps: null,
    analysisResolution720p: false,
    restrictClasses: false,
  );

  @override
  bool operator ==(Object other) =>
      other is ThermalCap &&
      other.maxFps == maxFps &&
      other.analysisResolution720p == analysisResolution720p &&
      other.restrictClasses == restrictClasses &&
      other.announcement == announcement;

  @override
  int get hashCode => Object.hash(
      maxFps, analysisResolution720p, restrictClasses, announcement);

  @override
  String toString() => 'ThermalCap(maxFps: $maxFps, '
      '720p: $analysisResolution720p, '
      'restrictClasses: $restrictClasses, '
      'announcement: $announcement)';
}

/// Derating tiers as a ladder: recovery climbs it one
/// rung per hold; derating falls straight to the rung the
/// reported status demands.
enum _ThermalTier { unconstrained, moderate, severe }

class ThermalPolicy {
  _ThermalTier _applied = _ThermalTier.unconstrained;

  /// When the reported status was first observed
  /// CONTINUOUSLY below the applied tier (the recovery
  /// hold's start). Null while the reported tier is at or
  /// above the applied one.
  DateTime? _belowSince;

  /// Episode latch: the FPS-drop announcement has fired
  /// (or been silently consumed by a simultaneous scope
  /// event) during the current derating episode. Reset
  /// only when the recovered announcement fires.
  bool _fpsAnnounced = false;

  /// Episode latch: the scope-restriction announcement
  /// has fired during the current derating episode.
  /// Reset only when the recovered announcement fires.
  bool _scopeAnnounced = false;

  /// The cap currently in force (without any one-shot
  /// announcement event).
  ThermalCap get currentCap => _capFor(_applied);

  static _ThermalTier _tierFor(ThermalStatus status) => switch (status) {
        ThermalStatus.none ||
        ThermalStatus.unknown =>
          _ThermalTier.unconstrained,
        ThermalStatus.light ||
        ThermalStatus.moderate =>
          _ThermalTier.moderate,
        ThermalStatus.severe ||
        ThermalStatus.critical ||
        ThermalStatus.emergency ||
        ThermalStatus.shutdown =>
          _ThermalTier.severe,
      };

  static ThermalCap _capFor(_ThermalTier tier) => switch (tier) {
        _ThermalTier.unconstrained => ThermalCap.unconstrained,
        _ThermalTier.moderate => const ThermalCap(
            maxFps: NavHazConfig.thermalCapModerateFps,
            analysisResolution720p: true,
            restrictClasses: false,
          ),
        _ThermalTier.severe => const ThermalCap(
            maxFps: NavHazConfig.thermalCapSevereFps,
            analysisResolution720p: true,
            restrictClasses: true,
          ),
      };

  /// Feed one status event stamped [now]; returns the
  /// settled cap, with [ThermalCap.announcement] set when
  /// this very event trips an episode latch (the FPS
  /// latch, the scope latch, or the recovery latch --
  /// see the library doc).
  ThermalCap evaluate({
    required ThermalStatus status,
    required DateTime now,
  }) {
    final _ThermalTier reported = _tierFor(status);
    if (reported.index >= _applied.index) {
      // Worse (or unchanged): apply immediately, and any
      // pending recovery hold is void.
      _applied = reported;
      _belowSince = null;
    } else {
      // Better than applied: start (or continue) the
      // recovery hold. One full continuous hold climbs
      // exactly ONE rung; the next rung's hold restarts
      // from this moment.
      final DateTime since = _belowSince ??= now;
      if (!now.isBefore(since.add(NavHazConfig.thermalRecoveryHold))) {
        _applied = _ThermalTier.values[_applied.index - 1];
        _belowSince = now;
      }
    }
    // Announcement layer (episode latches). The latches
    // read the SETTLED cap, so they track what the user
    // actually experiences, not the raw status.
    ThermalAnnouncement event = ThermalAnnouncement.none;
    final ThermalCap settled = _capFor(_applied);
    if (_applied != _ThermalTier.unconstrained) {
      if (settled.restrictClasses && !_scopeAnnounced) {
        // The scope event subsumes the FPS event when
        // both trip on the same evaluation (a direct
        // jump to the severe tier): the narrower scope
        // is the graver fact, so the FPS latch is
        // consumed silently alongside.
        _scopeAnnounced = true;
        _fpsAnnounced = true;
        event = ThermalAnnouncement.scopeRestricted;
      } else if (settled.maxFps != null && !_fpsAnnounced) {
        _fpsAnnounced = true;
        event = ThermalAnnouncement.fpsDrop;
      }
    } else if ((_fpsAnnounced || _scopeAnnounced) &&
        status == ThermalStatus.none) {
      // Genuine recovery: the cap is back to no-cap on a
      // REAL none reading, with an episode outstanding.
      // An UNKNOWN reading never satisfies this -- the
      // ladder may have relaxed the cap under unknown
      // readings, but the episode stays open (latches
      // unconsumed-by-recovery) until a real none
      // confirms the cool-down.
      _fpsAnnounced = false;
      _scopeAnnounced = false;
      event = ThermalAnnouncement.recovered;
    }
    if (event == ThermalAnnouncement.none) return settled;
    return ThermalCap(
      maxFps: settled.maxFps,
      analysisResolution720p: settled.analysisResolution720p,
      restrictClasses: settled.restrictClasses,
      announcement: event,
    );
  }

  /// The final frame rate the wiring applies (spec 3.2):
  /// the LOWER of the frame-rate policy's scene target
  /// and the thermal ceiling. An unconstrained cap passes
  /// the scene target through untouched.
  static int composeFps(int sceneFps, ThermalCap cap) {
    final int? ceiling = cap.maxFps;
    if (ceiling == null || sceneFps <= ceiling) return sceneFps;
    return ceiling;
  }

  /// Whether a detection label survives the SEVERE tier's
  /// class restriction: vehicles and pedestrians only,
  /// judged by the repository's existing label-to-kind
  /// mapping ([hazardKindForLabel]) -- motor vehicles,
  /// non-motor vehicles (bicycles) and persons pass;
  /// poles, clutter and every label outside the hazard
  /// vocabulary are held back. The restriction gates
  /// detection INPUT only; it says nothing about tracks
  /// already confirmed.
  static bool keepsLabelUnderRestriction(String label) {
    final HazardKind? kind = hazardKindForLabel(label);
    return kind == HazardKind.motorVehicle ||
        kind == HazardKind.nonMotorVehicle ||
        kind == HazardKind.person;
  }
}
