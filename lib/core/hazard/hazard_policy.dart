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
/// obstacles without geometry history -- except that the
/// CDX3 round scoped that position-only rule to
/// NON-vehicle kinds in both degradations: a vehicle with
/// no TTC and no measured range behind it stays silent
/// (see [HazardPolicy.levelFor]). That holds for a
/// TTC null by DISAGREEMENT too (see
/// [TrackEstimate.ttcDisagreement]): when the two ranging
/// legs contradict each other, no TTC branch below may
/// promote on either leg's value -- every urgent branch
/// requires the fused TTC to be non-null -- while the
/// range-based static / close-range rules still apply to
/// the separately valid range.
///
/// EGO-UNKNOWN SCALE PATH (lead's ruling, 2026-11-11):
/// when the frame's ego speed is unknown
/// ([TrackEstimate.egoSpeedKnown] == false) NONE of the
/// table above applies. The estimate is judged by
/// [_levelForEgoUnknownScalePath] instead: no approaching
/// test (there is no v_ego to subtract), levels from the
/// box-scale TTC alone -- TTC_s <= 3.0 s urgent, in
/// (3.0, 5.0] warning, no downgrade -- gated by the
/// intersection test [TtcEstimator.scalePathIntersects]
/// (the extrapolated bottom-centre must land in the
/// forward channel; a crossing target stays silent). A
/// fused-TTC disagreement is NOT this path: the scale leg
/// is distrusted there too and the path stays silent.
/// Accepted consequence, per the ruling ("rather
/// over-report than miss"): with the ego speed unknown a
/// user walking toward a PARKED vehicle alerts exactly
/// like a vehicle approaching the user.
///
/// Cooldown / dedup live here, per track: inside the
/// cooldown a re-alert needs a level upgrade (W -> U) or a
/// TTC that has fallen >= 40% since that track's last
/// spoken alert. The cooldown window is chosen per
/// evaluation from that frame's ego state: 4 s when the
/// ego speed is known, 6 s when it is unknown (the
/// ego-unknown path talks less often); the two re-alert
/// exceptions apply unchanged in both windows. Different
/// tracks with the same category and zone inside 500 ms
/// merge into one announcement. A frame yields at most
/// ONE alert: urgent before warning, then smaller TTC,
/// then the hazard-kind order.
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
    if (track.lostFrames > 0) return null;
    // Tiered confirmation (FIX3B): WARNINGS and every
    // warning-level rule require the latched 3-frame
    // [Track.confirmed]; the URGENT branches may fire on
    // [Track.urgentConfirmed] (2-of-3 with the current
    // frame a hit) -- one frame earlier, and only for
    // urgent, whose TTC input is the compensated
    // [TrackEstimate.ttcUrgentS].
    final bool confirmedW = track.confirmed;
    final bool confirmedU = track.urgentConfirmed;
    if (!confirmedW && !confirmedU) return null;
    // Ego speed unknown: the dedicated scale path judges
    // the estimate on its own rules (no willHit corridor,
    // no approaching test) -- see the library doc. When
    // the scale leg yields no usable TTC the estimate
    // degrades to the two TTC == null rules below (static
    // range / near corridor), as CDX2-1 prescribes; the
    // approaching and TTC-band branches stay off because
    // the (scale-only) TTC is null in that case.
    if (!e.egoSpeedKnown) {
      final HazardLevel? scaleLevel = _levelForEgoUnknownScalePath(e,
          urgentOk: confirmedU, warningOk: confirmedW);
      if (scaleLevel != null || e.ttcScaleS != null) return scaleLevel;
      if (!confirmedW) return null;
      if (!e.willHit) return null;
      // A measured range still speaks for every kind: the
      // static-obstacle rule is a Z rule, not a position
      // guess (CDX3 item 2 leaves it untouched).
      if (e.rangeM != null &&
          e.rangeM! <= NavHazConfig.warningStaticRangeM) {
        return HazardLevel.warning;
      }
      // CDX3 item 2: with range AND scale TTC both invalid
      // the near-bottom courtesy rule below must NOT fire
      // for a VEHICLE. Every vehicle alert in M1 is
      // motion-evidence based (the approaching test, scale
      // growth, or a measured range); a vehicle with zero
      // closing evidence of any kind -- constant size, no
      // range, no TTC -- stays silent on frame position
      // alone (Codex counterexample: a near-bottom car at
      // constant size with no range must remain silent).
      // The rule itself survives for NON-vehicle near
      // obstacles: a pedestrian standing in the corridor
      // with no ranging is exactly the legacy near warning
      // the arbitration scenarios (d) / (a-literal)
      // encode.
      final HazardKind kind =
          hazardKindForLabel(track.label) ?? HazardKind.clutter;
      if (kind == HazardKind.motorVehicle ||
          kind == HazardKind.nonMotorVehicle) {
        return null;
      }
      final TrackSample? s = track.latest;
      if (s != null && s.bottom > NavHazConfig.nearBottom) {
        return HazardLevel.warning;
      }
      return null;
    }
    if (!e.willHit) return null;
    final HazardKind kind =
        hazardKindForLabel(track.label) ?? HazardKind.clutter;
    final bool isVehicle = kind == HazardKind.motorVehicle ||
        kind == HazardKind.nonMotorVehicle;
    final double? ttc = e.ttcS;
    // Urgent (FIX3B): judged on tau_now -- the agile
    // tier's predicted, latency-compensated TTC -- and
    // gated on URGENT confirmation. The branch structure
    // (which targets may go urgent) is unchanged; only
    // the TTC input and the confirmation tier changed, so
    // the prediction can never pull a WARNING early: the
    // warning bands below still read the normal [ttc].
    final double? tauNow = e.ttcUrgentS;
    if (confirmedU && tauNow != null) {
      if (isVehicle && e.approaching && tauNow <= NavHazConfig.urgentTtcS) {
        return HazardLevel.urgent;
      }
      if (e.rangeM != null &&
          e.rangeM! <= NavHazConfig.urgentCloseRangeM &&
          tauNow <= NavHazConfig.urgentCloseTtcS) {
        return HazardLevel.urgent;
      }
      // Without ranging (no pitch), a fast-expanding
      // vehicle in the corridor cannot be PROVEN closing
      // in m/s terms; the scale prediction alone then
      // carries the urgent call. (With ranging available
      // the measured test above is the only urgent
      // vehicle path.) This branch is the KNOWN-ego case;
      // the unknown-ego case never reaches here -- it is
      // judged by _levelForEgoUnknownScalePath.
      if (isVehicle &&
          e.closingSpeedMps == null &&
          tauNow <= NavHazConfig.urgentTtcS) {
        return HazardLevel.urgent;
      }
    }
    if (!confirmedW) return null;
    // Warning: TTC band (normal tier, unchanged).
    if (ttc != null && ttc > NavHazConfig.urgentTtcS && ttc <= NavHazConfig.warningTtcS) {
      return HazardLevel.warning;
    }
    // Warning: static obstacle in the corridor, close range.
    final bool isStatic = !e.approaching;
    if (isStatic && e.rangeM != null && e.rangeM! <= NavHazConfig.warningStaticRangeM) {
      return HazardLevel.warning;
    }
    // Warning: no usable TTC -- the inherited near-corridor
    // rule (box bottom low in frame). Never urgent. CDX3
    // item 2 scopes it to NON-vehicle kinds, exactly as in
    // the ego-unknown degradation above: frame position
    // alone, with no TTC and no range behind it, is not
    // evidence a vehicle is a hazard; the range-based
    // static rule above still covers near vehicles WITH a
    // measured range.
    final TrackSample? s = track.latest;
    if (ttc == null && !isVehicle && s != null && s.bottom > NavHazConfig.nearBottom) {
      return HazardLevel.warning;
    }
    return null;
  }

  /// The ego-unknown scale path (lead's ruling,
  /// 2026-11-11; conjunction pinned by the FIX2 round):
  /// the level for one estimate whose frame had NO usable
  /// ego speed. A warning or an urgent requires ALL FOUR
  /// conditions at once:
  ///   (i)   the track is confirmed (checked by the
  ///         caller, [levelFor]);
  ///   (ii)  the box scale is GROWING -- the estimator's
  ///         filtered scale rate is positive. (A usable
  ///         TTC_s exists only when the rate is positive,
  ///         so this is the same fact stated as an
  ///         independent, testable condition, per FIX2;
  ///         a constant-size target has TTC_s == null and
  ///         fails here, never on its position alone.)
  ///   (iii) the intersection gate passes: the box
  ///         bottom-centre, extrapolated laterally to
  ///         t + TTC_s, lands inside the forward channel
  ///         (metric +/- channel half width when a range
  ///         exists, the central frame fraction when it
  ///         does not -- [TtcEstimator.scalePathIntersects],
  ///         which deliberately has NO "current box
  ///         overlaps the channel" clause: only the
  ///         extrapolated landing point counts, so a
  ///         crossing target whose box currently overlaps
  ///         the channel stays silent);
  ///   (iv)  TTC_s falls in a band: urgent at <= 3.0 s,
  ///         warning in (3.0, 5.0], no downgrade for the
  ///         missing ego evidence (with the ego speed
  ///         unknown, a user walking toward a parked
  ///         vehicle alerts just like a vehicle
  ///         approaching the user -- accepted by the
  ///         ruling: rather over-report than miss).
  /// No condition may substitute for another: in
  /// particular TTC_s alone never promotes.
  ///
  /// When TTC_s itself is unusable (no measurable scale
  /// growth) this path grades nothing and the caller
  /// degrades to the TTC == null rules, exactly as
  /// CDX2-1 prescribes (the estimator has already nulled
  /// the fused TTC in that case). A fused-TTC
  /// disagreement cannot occur on this path: with the ego
  /// speed unknown the estimator performs no fusion (see
  /// TtcEstimator.estimate), so there is nothing to
  /// distrust and [TrackEstimate.ttcDisagreement] is
  /// always false here.
  HazardLevel? _levelForEgoUnknownScalePath(TrackEstimate e,
      {required bool urgentOk, required bool warningOk}) {
    final double? ttcS = e.ttcScaleS;
    final double? tauNow = e.ttcUrgentS;
    if (ttcS == null && tauNow == null) return null;
    // Condition (ii): measurable scale growth, asserted
    // independently of the TTC value (FIX2 conjunction).
    if (e.scaleRate <= 0) return null;
    final TrackSample? s = e.track.latest;
    if (s == null) return null;
    // URGENT (FIX3B tiering): tau_now -- the agile
    // prediction minus pipeline latency -- at or under
    // the urgent band, the intersection gate evaluated at
    // tau_now's own horizon, and URGENT confirmation
    // (2-of-3). The other conjunction conditions are the
    // FIX2 ones, unchanged.
    if (urgentOk &&
        tauNow != null &&
        tauNow <= NavHazConfig.urgentTtcS &&
        TtcEstimator.channelIntersects(
          cx: s.cx,
          cxVelocity: e.cxVelocity,
          horizonS: tauNow,
          rangeM: e.rangeM,
        )) {
      return HazardLevel.urgent;
    }
    // WARNING: full 3-frame confirmation and the NORMAL
    // scale TTC, exactly as before -- the prediction
    // never grades a warning.
    if (!warningOk || ttcS == null) return null;
    // Condition (iii): extrapolated intersection only.
    if (!TtcEstimator.scalePathIntersects(
      cx: s.cx,
      cxVelocity: e.cxVelocity,
      ttcScaleS: ttcS,
      rangeM: e.rangeM,
    )) {
      return null;
    }
    // Condition (iv): the plain scale-TTC bands. The
    // urgent band here is reachable only when the urgent
    // tier above did not fire (e.g. tau_now not yet
    // available on a hand-built estimate); it still
    // requires urgent confirmation -- an urgent-band TTC
    // on a merely warning-confirmed track grades nothing
    // rather than understating itself as a warning.
    if (ttcS <= NavHazConfig.urgentTtcS) {
      return urgentOk ? HazardLevel.urgent : null;
    }
    if (ttcS <= NavHazConfig.warningTtcS) return HazardLevel.warning;
    return null;
  }

  bool _cooldownAllows(TrackEstimate e, HazardLevel level, DateTime now) {
    final _LastAlert? last = _lastByTrack[e.track.id];
    if (last == null) return true;
    // The window follows THIS frame's ego state: unknown
    // ego speed -> the longer window (see the library
    // doc); the upgrade / TTC-drop exceptions below are
    // unchanged in both windows.
    final Duration cd = Duration(
        seconds: e.egoSpeedKnown
            ? NavHazConfig.cooldownSeconds
            : NavHazConfig.cooldownSecondsEgoUnknown);
    // Like-for-like comparison (FIX3B): an urgent
    // candidate's drop is measured on the urgent signal
    // (tau_now) against the tau_now stored when the last
    // urgent was spoken -- the earlier first-urgent now
    // fires at a NORMAL ttcS that is still high, and
    // comparing normal-to-normal would manufacture a
    // phantom 40% drop (and a duplicate urgent) as the
    // normal tier converged.
    final double? ttc =
        level == HazardLevel.urgent ? (e.ttcUrgentS ?? e.ttcS) : e.ttcS;
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
        .where((TrackEstimate e) => _cooldownAllows(e, levelOf(e)!, now))
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

    if (!commit) {
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
    _lastByTrack[track.id] = _LastAlert(now, level,
        level == HazardLevel.urgent
            ? (chosen.ttcUrgentS ?? chosen.ttcS)
            : chosen.ttcS);
    _lastEmitted = _Emitted(now, kind, zone, level);
    return HazardPolicyResult(alert: alert, riskPresent: true);
  }
}
