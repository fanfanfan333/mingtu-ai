/// Repeat gate for ONE stationary obstacle.
///
/// The field complaint behind this file: standing still in
/// front of a pole (or a person who is not moving), the
/// ordinary obstacle warning re-fired every few seconds and
/// kept outranking the turn instruction -- the user heard
/// "障碍" over and over and never heard where to go.
///
/// The gate answers ONE question: "is this line worth saying
/// again right now?". It deliberately does NOT answer "is
/// there a hazard?": the risk state, the pacing hold and the
/// hazard pipeline are untouched by a suppressed line. A
/// suppressed warning is still a detected warning -- it is
/// only the SPEECH that is thinned out.
///
/// Rules (see [shouldSpeak]):
///  * urgent lines are never suppressed (a moving car that
///    just got close is new information every time);
///  * a non-urgent line on the same track, with the user not
///    moving and the range unchanged (within
///    [rangeChangeToleranceM]), stays quiet for
///    [staticRepeatQuietPeriod] after the last spoken one;
///  * a changed range, or any movement, re-opens the gate at
///    once (the situation is no longer the one the user
///    already heard about) and resets the track's record.
/// Pure: no clock, no I/O -- [now] and the ego-motion verdict
/// are supplied by the caller.
library;

/// The record kept per hazard track.
class HazardTrackMemo {
  const HazardTrackMemo({required this.lastSpokenAt, this.lastRangeM});

  final DateTime lastSpokenAt;
  final double? lastRangeM;
}

class HazardRepeatGate {
  /// How long the same unchanged line stays quiet.
  static const Duration staticRepeatQuietPeriod = Duration(seconds: 15);

  /// How much the estimated range must move before the same
  /// track counts as a new situation.
  static const double rangeChangeToleranceM = 0.5;

  /// Above this own speed (m/s) the user counts as moving.
  /// Chosen well under a walking pace (about 1.2 m/s) so a
  /// slow shuffle already re-opens the gate.
  static const double egoMovingThresholdMps = 0.3;

  /// Every track the gate has an opinion about.
  final Map<String, HazardTrackMemo> _memo = <String, HazardTrackMemo>{};

  /// Observability: the tracks this gate kept quiet, in
  /// order (one entry per suppressed line, tagged with the
  /// reason). Never contains spoken text.
  final List<String> suppressedLog = <String>[];

  /// Observability: the tracks this gate let through, in
  /// order.
  final List<String> spokenLog = <String>[];

  /// Whether a line for [trackId] may be spoken now.
  ///
  /// [urgent] marks danger / emergency lines: those are never
  /// gated (they still refresh the track record, so a later
  /// non-urgent line is measured against them).
  ///
  /// [rangeM] is the hazard's estimated range in metres, or
  /// null when it could not be estimated. [egoMoving] is the
  /// caller's ego-motion verdict for this frame; "unknown
  /// speed" must be passed as false (no evidence of movement
  /// counts as standing still).
  bool shouldSpeak({
    required String trackId,
    required bool urgent,
    required double? rangeM,
    required bool egoMoving,
    required DateTime now,
  }) {
    if (urgent) {
      // Never gated. Recording the line keeps the non-urgent
      // comparison below honest (the user HAS just heard
      // about this track, at this range).
      _memo[trackId] =
          HazardTrackMemo(lastSpokenAt: now, lastRangeM: rangeM);
      spokenLog.add('$trackId:urgent');
      return true;
    }
    final HazardTrackMemo? previous = _memo[trackId];
    if (previous == null) {
      _memo[trackId] = HazardTrackMemo(lastSpokenAt: now, lastRangeM: rangeM);
      spokenLog.add('$trackId:first');
      return true;
    }
    if (egoMoving) {
      // The user is walking: the geometry changes on its own,
      // so the same line is worth saying again.
      _memo[trackId] = HazardTrackMemo(lastSpokenAt: now, lastRangeM: rangeM);
      spokenLog.add('$trackId:moving');
      return true;
    }
    if (_rangeChanged(previous.lastRangeM, rangeM)) {
      // A closer (or further) obstacle is NEW information.
      _memo[trackId] = HazardTrackMemo(lastSpokenAt: now, lastRangeM: rangeM);
      spokenLog.add('$trackId:range-change');
      return true;
    }
    final Duration since = now.difference(previous.lastSpokenAt);
    if (since >= staticRepeatQuietPeriod) {
      // The quiet period has elapsed: one reminder is allowed
      // (a user standing still for a minute still deserves to
      // know the thing in front of them is there).
      _memo[trackId] = HazardTrackMemo(lastSpokenAt: now, lastRangeM: rangeM);
      spokenLog.add('$trackId:reminder');
      return true;
    }
    suppressedLog.add('$trackId:repeat');
    return false;
  }

  /// Whether two range readings describe the same situation.
  /// Two "unknown" readings count as unchanged: without a
  /// measurement there is no new evidence to justify a
  /// repeat.
  static bool _rangeChanged(double? previous, double? current) {
    if (previous == null && current == null) return false;
    if (previous == null || current == null) return true;
    return (current - previous).abs() > rangeChangeToleranceM;
  }

  /// Whether the ego speed reported by the caller counts as
  /// movement. Null (no evidence) is NOT movement.
  static bool isMovingSpeed(double? speedMps) =>
      speedMps != null && speedMps > egoMovingThresholdMps;

  /// Forget everything (a new trip must not inherit the
  /// previous trip's quiet tracks).
  void reset() {
    _memo.clear();
    suppressedLog.clear();
    spokenLog.clear();
  }
}
