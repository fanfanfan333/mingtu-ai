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
///     same tier) -> the SEVERE tier, plus the heat
///     announcement (throttled, see below).
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
/// - The CRITICAL announcement is throttled inside the
///   policy: [ThermalCap.announcementDue] is true on at
///   most one evaluation per
///   [NavHazConfig.thermalCriticalAnnouncementInterval],
///   however many critical events arrive in between.
library;

import 'avoidance_advisor.dart';
import 'navhaz_config.dart';
import 'thermal.dart';

/// The settled thermal cap at one moment. [maxFps] null
/// means no FPS ceiling. [announcementDue] is a ONE-SHOT
/// event flag: it is true only on the single evaluation
/// that trips the (throttled) CRITICAL announcement, not
/// for as long as the device stays critical.
class ThermalCap {
  final int? maxFps;
  final bool analysisResolution720p;
  final bool restrictClasses;
  final bool announcementDue;

  const ThermalCap({
    required this.maxFps,
    required this.analysisResolution720p,
    required this.restrictClasses,
    this.announcementDue = false,
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
      other.announcementDue == announcementDue;

  @override
  int get hashCode => Object.hash(
      maxFps, analysisResolution720p, restrictClasses, announcementDue);

  @override
  String toString() => 'ThermalCap(maxFps: $maxFps, '
      '720p: $analysisResolution720p, '
      'restrictClasses: $restrictClasses, '
      'announcementDue: $announcementDue)';
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

  /// When the CRITICAL announcement last fired (the
  /// throttle's memory). Null until the first firing.
  DateTime? _lastAnnouncementAt;

  /// The cap currently in force (without any one-shot
  /// announcement flag).
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

  /// Whether [status] is CRITICAL or above -- the
  /// announcement tier (EMERGENCY / SHUTDOWN included).
  static bool isCriticalOrAbove(ThermalStatus status) =>
      status == ThermalStatus.critical ||
      status == ThermalStatus.emergency ||
      status == ThermalStatus.shutdown;

  /// Feed one status event stamped [now]; returns the
  /// settled cap, with [ThermalCap.announcementDue] set
  /// when this very event trips the throttled CRITICAL
  /// announcement.
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
    bool due = false;
    if (isCriticalOrAbove(status)) {
      final DateTime? last = _lastAnnouncementAt;
      if (last == null ||
          !now.isBefore(
              last.add(NavHazConfig.thermalCriticalAnnouncementInterval))) {
        due = true;
        _lastAnnouncementAt = now;
      }
    }
    final ThermalCap cap = _capFor(_applied);
    if (!due) return cap;
    return ThermalCap(
      maxFps: cap.maxFps,
      analysisResolution720p: cap.analysisResolution720p,
      restrictClasses: cap.restrictClasses,
      announcementDue: true,
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
