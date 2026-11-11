/// Hazard alert policy for NAVHAZ M1 (spec section 2.3):
/// decides, per frame, whether anything is spoken, at what
/// level, and about which single most dangerous target.
///
/// Level table (ALL conditions in a row must hold):
///   URGENT  -- track confirmed, will hit, and either
///              (vehicle closing-in with TTC <= 3.0 s) or
///              (any obstacle at range <= 1.5 m with
///              TTC <= 2.0 s).
///   WARNING -- track confirmed, will hit, and either
///              TTC in (3.0, 5.0] s, or a static obstacle in
///              the corridor at range <= 3 m.
///   silent  -- everything else.
///
/// TTC == null can NEVER produce urgent: with no usable
/// estimate only the inherited near-corridor rule applies
/// (box bottom low in the frame inside the corridor ->
/// warning), matching the pre-M1 behaviour for close
/// obstacles without geometry history.
///
/// Cooldown / dedup live here, per track: inside the
/// cooldown a re-alert needs a level upgrade (W -> U) or a
/// TTC that has fallen >= 40% since that track's last
/// spoken alert. Different tracks with the same category
/// and zone inside 500 ms merge into one announcement. A
/// frame yields at most ONE alert: urgent before warning,
/// then smaller TTC, then the hazard-kind order.
///
/// This policy never produces a step direction: wording is
/// [hazard_phrases] only, and a sideways step may be added
/// by the caller solely from the avoidance advisor's
/// three-condition decision.
library;

import '../../modules/visual_perception.dart';
import '../avoidance_advisor.dart';
import '../navhaz_config.dart';
import '../tracking/tracker.dart';
import '../speech_scheduler.dart';
import 'hazard_phrases.dart';
import 'ttc_estimator.dart';

enum HazardLevel { urgent, warning }

class HazardAlert {
  final HazardLevel level;
  final int trackId;
  final String label;
  final HazardKind kind;
  final String phrase;
  final double? ttcS;
  final double? rangeM;

  /// The representative detection (latest sample), for the
  /// caller's avoidance-advisor consultation.
  final Detection detection;

  /// Corridor-centred and near by the box-bottom rule: the
  /// trigger condition for a merged cloud hazard scan
  /// (unchanged from the pre-M1 wiring).
  final bool nearCenter;

  const HazardAlert({
    required this.level,
    required this.trackId,
    required this.label,
    required this.kind,
    required this.phrase,
    required this.ttcS,
    required this.rangeM,
    required this.detection,
    required this.nearCenter,
  });

  bool get urgent => level == HazardLevel.urgent;

  /// Speech kind per the arbitration rules: urgent hazards
  /// ride the danger level, warnings the avoidance level.
  SpeechKind get speechKind =>
      urgent ? SpeechKind.danger : SpeechKind.obstacleAvoidance;
}

class HazardPolicyResult {
  /// The single alert to speak this frame, if any.
  final HazardAlert? alert;

  /// Any track currently satisfies an urgent or warning
  /// condition (BEFORE cooldown): drives the app's risk
  /// state, which only clears after consecutive frames
  /// without it.
  final bool riskPresent;

  const HazardPolicyResult({required this.alert, required this.riskPresent});
}

class _LastAlert {
  final DateTime at;
  final HazardLevel level;
  final double? ttcS;
  const _LastAlert(this.at, this.level, this.ttcS);
}

class _Emitted {
  final DateTime at;
  final HazardKind kind;
  final String zone;
  final HazardLevel level;
  const _Emitted(this.at, this.kind, this.zone, this.level);
}

class HazardPolicy {
  final Map<int, _LastAlert> _lastByTrack = <int, _LastAlert>{};
  _Emitted? _lastEmitted;

  void reset() {
    _lastByTrack.clear();
    _lastEmitted = null;
  }

  /// The level one estimate qualifies for, or null. Pure
  /// per-target judgement (no cooldown) -- also used for
  /// the frame's risk presence.
  HazardLevel? levelFor(TrackEstimate e) {
    final Track track = e.track;
    if (!track.confirmed || track.lostFrames > 0) return null;
    if (!e.willHit) return null;
    final HazardKind kind =
        hazardKindForLabel(track.label) ?? HazardKind.clutter;
    final bool isVehicle = kind == HazardKind.motorVehicle ||
        kind == HazardKind.nonMotorVehicle;
    final double? ttc = e.ttcS;
    // Urgent.
    if (isVehicle && e.approaching && ttc != null && ttc <= NavHazConfig.urgentTtcS) {
      return HazardLevel.urgent;
    }
    if (e.rangeM != null &&
        e.rangeM! <= NavHazConfig.urgentCloseRangeM &&
        ttc != null &&
        ttc <= NavHazConfig.urgentCloseTtcS) {
      return HazardLevel.urgent;
    }
    // Without ranging (no pitch), a fast-expanding confirmed
    // vehicle in the corridor cannot be PROVEN closing in
    // m/s terms; the scale TTC alone then carries the urgent
    // call. (With ranging available the measured test above
    // is the only urgent vehicle path.)
    if (isVehicle &&
        e.closingSpeedMps == null &&
        ttc != null &&
        ttc <= NavHazConfig.urgentTtcS) {
      return HazardLevel.urgent;
    }
    // Warning: TTC band.
    if (ttc != null && ttc > NavHazConfig.urgentTtcS && ttc <= NavHazConfig.warningTtcS) {
      return HazardLevel.warning;
    }
    // Warning: static obstacle in the corridor, close range.
    final bool isStatic = !e.approaching;
    if (isStatic && e.rangeM != null && e.rangeM! <= NavHazConfig.warningStaticRangeM) {
      return HazardLevel.warning;
    }
    // Warning: no usable TTC -- the inherited near-corridor
    // rule (box bottom low in frame). Never urgent.
    final TrackSample? s = track.latest;
    if (ttc == null && s != null && s.bottom > NavHazConfig.nearBottom) {
      return HazardLevel.warning;
    }
    return null;
  }

  bool _cooldownAllows(int trackId, HazardLevel level, double? ttc, DateTime now) {
    final _LastAlert? last = _lastByTrack[trackId];
    if (last == null) return true;
    const Duration cd = Duration(seconds: NavHazConfig.cooldownSeconds);
    if (now.difference(last.at) >= cd) return true;
    if (level == HazardLevel.urgent && last.level == HazardLevel.warning) {
      return true; // upgrade W -> U is never held back
    }
    if (ttc != null && last.ttcS != null &&
        ttc <= last.ttcS! * (1 - NavHazConfig.ttcDropReAlertRatio)) {
      return true; // closing much faster than last time
    }
    return false;
  }

  /// [commit] = false means "bookkeeping only": the frame
  /// still reports risk presence, but no alert is produced
  /// and no cooldown / merge state is consumed (the app is
  /// not in a state where hazard speech is allowed).
  HazardPolicyResult evaluate(List<TrackEstimate> estimates, DateTime now,
      {bool commit = true}) {
    HazardLevel? levelOf(TrackEstimate e) => levelFor(e);
    final List<TrackEstimate> risky =
        estimates.where((TrackEstimate e) => levelOf(e) != null).toList();
    final bool riskPresent = risky.isNotEmpty;
    if (!riskPresent) {
      return const HazardPolicyResult(alert: null, riskPresent: false);
    }

    final List<TrackEstimate> candidates = risky
        .where((TrackEstimate e) => _cooldownAllows(
            e.track.id, levelOf(e)!, e.ttcS, now))
        .toList();
    if (candidates.isEmpty) {
      return const HazardPolicyResult(alert: null, riskPresent: true);
    }
    candidates.sort((TrackEstimate a, TrackEstimate b) {
      final HazardLevel la = levelOf(a)!;
      final HazardLevel lb = levelOf(b)!;
      if (la != lb) return la == HazardLevel.urgent ? -1 : 1;
      final double ta = a.ttcS ?? double.infinity;
      final double tb = b.ttcS ?? double.infinity;
      if (ta != tb) return ta.compareTo(tb);
      final HazardKind ka =
          hazardKindForLabel(a.track.label) ?? HazardKind.clutter;
      final HazardKind kb =
          hazardKindForLabel(b.track.label) ?? HazardKind.clutter;
      return hazardKindPriority(ka).compareTo(hazardKindPriority(kb));
    });

    final TrackEstimate chosen = candidates.first;
    final HazardLevel level = levelOf(chosen)!;
    final Track track = chosen.track;
    final HazardKind kind =
        hazardKindForLabel(track.label) ?? HazardKind.clutter;
    final TrackSample s = track.latest!;
    final String zone = zoneName(s.cx);

    // Cross-track merge: a same-category, same-zone alert
    // was already spoken inside the merge window -- this one
    // is the same event for the user, unless it is strictly
    // more dangerous.
    final _Emitted? emitted = _lastEmitted;
    if (emitted != null &&
        now.difference(emitted.at) < NavHazConfig.mergeWindow &&
        emitted.kind == kind &&
        emitted.zone == zone &&
        !(level == HazardLevel.urgent &&
            emitted.level == HazardLevel.warning)) {
      return const HazardPolicyResult(alert: null, riskPresent: true);
    }

    final HazardAlert alert = HazardAlert(
      level: level,
      trackId: track.id,
      label: track.label,
      kind: kind,
      phrase: hazardPhrase(
        urgent: level == HazardLevel.urgent,
        name: hazardSpokenName(track.label, kind),
        isVehicle: kind == HazardKind.motorVehicle ||
            kind == HazardKind.nonMotorVehicle,
        cx: s.cx,
        rangeM: chosen.rangeM,
      ),
      ttcS: chosen.ttcS,
      rangeM: chosen.rangeM,
      detection: track.latestDetection!,
      nearCenter: s.cx >= NavHazConfig.corridorLeft &&
          s.cx <= NavHazConfig.corridorRight &&
          s.bottom > NavHazConfig.nearBottom,
    );
    if (!commit) {
      return const HazardPolicyResult(alert: null, riskPresent: true);
    }
    _lastByTrack[track.id] = _LastAlert(now, level, chosen.ttcS);
    _lastEmitted = _Emitted(now, kind, zone, level);
    return HazardPolicyResult(alert: alert, riskPresent: true);
  }
}
