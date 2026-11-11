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
/// exceptions apply in both windows, with one NH-M2-07
/// refinement (lead's final ruling, 2026-11-11): the
/// TTC-drop exception additionally requires at least
/// [NavHazConfig.realertDropMinInterval] (1.0 s) since
/// that track's last spoken alert -- a drop re-alert at
/// a 0.5 s gap would talk over the previous sentence,
/// which has not finished playing. The upgrade
/// exception is exempt from the interval, and a
/// re-alert after the window has elapsed is unchanged.
/// Different
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

  /// Whether THIS alert may fire its level's vibration
  /// (NH-M1-13, vibration counted per APPROACH -- the
  /// ladder documented at [HazardAlertSteps]): the
  /// episode's first WARNING vibrates (step 2); a WARNING
  /// re-alert inside the same episode does not; an URGENT
  /// that upgrades a previously WARNED episode vibrates
  /// once more (step 3); an URGENT that opens the episode
  /// vibrates ONLY if this approach has not already spent
  /// its vibration on the pre-urgent step (step 1, which
  /// the pipeline registers via [HazardPolicy.notePreVibrated]
  /// before evaluating) -- a pure pre-urgent -> U approach
  /// therefore vibrates exactly once in total. False
  /// whenever [alert] is null. The SPEECH is never gated
  /// by this flag -- only the vibration is counted.
  final bool vibrationAllowed;

  const HazardPolicyResult({
    required this.alert,
    required this.riskPresent,
    this.vibrationAllowed = false,
  });
}

/// The per-approach vibration ladder (NH-M1-13), the
/// single statement of how many vibrations one approach
/// of one track may produce. The steps are LEVEL STEPS,
/// and each step fires at most once per approach:
///
///   step 1  pre-urgent vibration -- at most ONE per
///           pre-urgent episode (the pipeline's one-shot;
///           TTC < 1.5 s before confirmation);
///   step 2  the approach's first WARNING alert -- ONE
///           warning vibration;
///   step 3  the WARNING -> URGENT upgrade inside the
///           same approach -- ONE more (urgent) vibration:
///           the level changed, a new step.
///
/// The per-path totals follow from which steps the path
/// actually walks:
///   pre-urgent -> URGENT (never warned): ONE (step 1
///     spends the approach's vibration; the urgent frame
///     adds nothing -- whether the pre-urgent fired on an
///     earlier frame or the same frame);
///   WARNING -> URGENT (never pre-vibrated): TWO (steps
///     2 + 3);
///   pre-urgent + WARNING + URGENT (all three steps
///     walked): THREE -- each step fired once.
/// Inside one approach nothing else vibrates: no re-alert
/// repeats its step, no second upgrade exists.
///
/// Two clocks, deliberately separate: an "alert episode"
/// (the policy's -- from the track's first alert until
/// its alert stream ends: the track leaves the estimates,
/// or [HazardPolicy.trackRetired] reports its retirement)
/// scopes steps 2/3; the pre-urgent episode (the
/// pipeline's latch -- NH-M1-11's exemption reads it)
/// scopes step 1's FIRING. The ladder JOINS them only
/// through the registration [HazardPolicy.notePreVibrated]:
/// when an urgent OPENS an alert episode, step 1's having
/// fired earlier in the approach (registration present)
/// is what suppresses the urgent's own dispatch. The
/// registration itself is APPROACH-scoped (NH-M1-13
/// residual): it is set when step 1 fires and cleared
/// ONLY when the pipeline reports the approach over
/// ([HazardPolicy.trackRetired] from the pipeline's
/// sustained-absence rule) -- neither the alert episode's
/// end nor a frame's instantaneous pre-urgent eligibility
/// may revoke it, or a mid-approach urgent re-vibrates
/// (the 5280e00 replay: unknown ego, T = 0.9 s, a second
/// dispatch three frames after the first). NH-M1-11
/// exemption frames fire NO vibration and are untouched
/// by this ladder.
class HazardAlertSteps {
  HazardAlertSteps._();
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

  /// NH-M1-13 vibration-episode bookkeeping (steps 2/3 of
  /// the ladder at [HazardAlertSteps]): the level of the
  /// last alert per track IN THE CURRENT alert episode.
  /// An entry exists exactly while the track's alert
  /// episode is open: it is created by the episode's
  /// first alert, consulted to decide whether the next
  /// alert is the first warning / the W -> U upgrade /
  /// neither, and cleared when the episode ends -- the
  /// caller reports the end explicitly (the track absent
  /// from a frame's estimates, or its retirement, via
  /// [trackRetired] / [noteAbsentTracks]); the speech
  /// cooldown map above is a different clock and is NOT
  /// reused for this.
  final Map<int, HazardLevel> _episodeAlertLevel = <int, HazardLevel>{};

  void reset() {
    _lastByTrack.clear();
    _lastEmitted = null;
    _episodeAlertLevel.clear();
    _preVibratedInApproach.clear();
  }

  /// NH-M1-13: report that [trackId]'s alert episode has
  /// ended (the track retired, or it was absent from a
  /// frame's estimates so its alert stream broke). The
  /// next alert of a (possibly new) track with this id
  /// opens a fresh episode with a fresh vibration budget.
  void trackRetired(int trackId) {
    _episodeAlertLevel.remove(trackId);
    _preVibratedInApproach.remove(trackId);
  }

  /// NH-M1-13: close the alert episodes of every track
  /// NOT in [presentIds] (a frame's estimated tracks).
  /// The step-1 registration deliberately does NOT clear
  /// here (NH-M1-13 residual, M2 first commit): it is
  /// scoped to the APPROACH, whose end the pipeline
  /// judges on its own sustained-absence rule and reports
  /// through [trackRetired] -- an alert episode can end
  /// and reopen inside one approach (a track unestimated
  /// for a frame, then alerting again) without the
  /// approach's spent step 1 being forgotten; the old
  /// same-boundary clearing was exactly what revoked the
  /// registration mid-approach and let a later urgent
  /// vibrate a second time.
  void noteAbsentTracks(Set<int> presentIds) {
    _episodeAlertLevel.removeWhere((int id, HazardLevel _) =>
        !presentIds.contains(id));
  }

  /// NH-M1-13 step 1 registration: the pipeline reports
  /// that [trackId]'s pre-urgent vibration has fired in
  /// the current approach (called BEFORE [evaluate] on
  /// the firing frame, and re-asserted while the
  /// pipeline's one-shot holds the track). Consulted for
  /// exactly one decision: an episode-opening URGENT adds
  /// no vibration when the approach already spent step 1.
  final Set<int> _preVibratedInApproach = <int>{};

  void notePreVibrated(int trackId) {
    _preVibratedInApproach.add(trackId);
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
    // NH-M2-07 (lead's final ruling, 2026-11-11): the
    // TTC-drop exception additionally requires
    // [NavHazConfig.realertDropMinInterval] since the
    // last SPOKEN alert -- at a shorter gap the previous
    // sentence has not finished playing and the repeat
    // would only talk over it. The upgrade branch above
    // is deliberately NOT gated by the interval, and
    // the window-elapsed return above is unchanged.
    // A blocked attempt records nothing (_lastByTrack
    // is written at issuance only), so both the
    // interval and the drop baseline keep measuring
    // from the last spoken alert and a later frame
    // whose drop still holds can still re-alert.
    if (ttc != null && last.ttcS != null &&
        ttc <= last.ttcS! * (1 - NavHazConfig.ttcDropReAlertRatio) &&
        now.difference(last.at) >= NavHazConfig.realertDropMinInterval) {
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
    final String spokenName = hazardSpokenName(track.label, kind);
    final String normalPhrase = hazardPhrase(
      urgent: level == HazardLevel.urgent,
      name: spokenName,
      isVehicle: kind == HazardKind.motorVehicle ||
          kind == HazardKind.nonMotorVehicle,
      cx: s.cx,
      rangeM: chosen.rangeM,
    );
    // NH-M1-17, narrowed by NH-M1-19: the short-form
    // decision, made ONCE here at issuance (the alert's
    // text is final from this point -- nothing downstream
    // re-derives it, so a replay of this alert speaks the
    // same text). NH-M1-17's original rule (remaining TTC
    // below the normal phrase's estimated duration at
    // the 0.30 s/char upper bound) fired far too early --
    // a normal urgent at tau_now ~= 2.7 s already lost
    // its item and bearing to the short form. NH-M1-19
    // gates the short form on BOTH conditions of
    // shortFormApplies: inside the vibrate-first zone
    // (tau_now < preVibrationTtcS) AND unable to finish
    // even at the fastest plausible reading speed
    // (0.25 s/char); either failing keeps the FULL
    // sentence. Warnings never take the short form (their
    // horizon is seconds longer and their wording carries
    // the distance the user needs).
    final double? remainingTtc =
        level == HazardLevel.urgent ? (chosen.ttcUrgentS ?? chosen.ttcS) : null;
    final String phrase = (remainingTtc != null &&
            shortFormApplies(remainingTtc, normalPhrase))
        ? shortUrgentPhrase(kind, spokenName, s.cx)
        : normalPhrase;
    final HazardAlert alert = HazardAlert(
      level: level,
      trackId: track.id,
      label: track.label,
      kind: kind,
      phrase: phrase,
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
    // NH-M1-13 ladder (see [HazardAlertSteps]): the
    // episode's first WARNING vibrates (step 2); a
    // WARNING -> URGENT upgrade vibrates once more
    // (step 3); an episode-opening URGENT vibrates ONLY
    // when the approach has not already spent step 1 (no
    // pre-urgent registration) -- otherwise the pure
    // pre-urgent -> U path would vibrate twice for one
    // approach; every other alert of the episode
    // (warning re-alert, urgent re-alert) does not.
    final HazardLevel? episodeLevel = _episodeAlertLevel[track.id];
    final bool vibrationAllowed = switch ((episodeLevel, level)) {
      (null, HazardLevel.warning) => true,
      (null, HazardLevel.urgent) =>
        !_preVibratedInApproach.contains(track.id),
      (HazardLevel.warning, HazardLevel.urgent) => true,
      _ => false,
    };
    _episodeAlertLevel[track.id] = level;
    return HazardPolicyResult(
        alert: alert, riskPresent: true, vibrationAllowed: vibrationAllowed);
  }
}

