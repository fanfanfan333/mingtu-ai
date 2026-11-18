/// The single source of "what should the user be told to do
/// NEXT", recomputed from the latest position every time.
///
/// Before this module the guidance had three separate speech
/// decisions: the tracker's own turn event (fired once, keyed
/// on distance only), the straight-pacing tick (a bare
/// 「直走」 every three seconds), and the step speaker behind
/// the 下一步 command. None of them looked at the phone's
/// heading, none of them could be recomputed on demand, and
/// none of them survived being interrupted. This module is
/// the replacement for the "what now?" question: pure,
/// stateless, and safe to call at any moment -- after a
/// hazard clears, after a first-instruction timeout, after a
/// re-plan.
///
/// The heading rule is the core of it. Guidance is only
/// allowed to name a DIRECTION when the phone's compass
/// agrees with the route:
///  * no fresh heading -> say that the heading is unknown and
///    ask the user to stand still. Never name left, right or
///    straight-ahead in that sentence -- a blind user who
///    turns the wrong way because of us is worse than a user
///    who waits two seconds.
///  * heading agrees (within [headingMatchDeg]) -> name the
///    action.
///  * heading is sideways or reversed -> say the heading may
///    disagree with the route (or that the user may be
///    facing away) and ask them to stop.
///
/// Hard wording rules enforced here and pinned by tests:
///  * never a compass point (east / south / west / north and
///    the diagonals) as an action;
///  * never a claim that the way ahead is clear of anything;
///  * never "第 N 段，共 M 段" -- a segment count tells a
///    blind user nothing about what to do;
///  * never the raw action string from the upstream route
///    provider: only the fixed set of walking actions below
///    may reach the speech path.
library;

import '../../modules/map_navigation.dart';
import '../entrance_guidance.dart' show bearingDegrees;
import '../hazard/hazard_phrases.dart' show navigationDistanceText;
import '../navigation_tracker.dart';
import '../speech_scheduler.dart';

/// How the computed instruction relates to the phone's
/// heading. The caller logs this; the wording already
/// reflects it.
enum InstructionMatch {
  /// The heading agrees with the route (or the instruction
  /// needs no direction at all).
  matched,

  /// No fresh compass heading: the instruction must not name
  /// a direction.
  headingUnknown,

  /// A fresh heading exists but does not agree with the
  /// route leg (sideways or reversed).
  headingConflict,

  /// The position itself cannot be trusted (no fix, or the
  /// fix's accuracy is too poor to derive anything).
  positionUnclear,
}

/// One computed instruction, ready to submit to the speech
/// scheduler as-is.
class RouteInstruction {
  const RouteInstruction({
    required this.text,
    required this.kind,
    required this.match,
    this.stepIndex,
  });

  /// The sentence to speak. Complete, punctuated, and free of
  /// banned wording by construction.
  final String text;

  /// The delivery class. A direction change is [SpeechKind.turn]
  /// and a "keep going" leg is [SpeechKind.straight]; a
  /// position problem is [SpeechKind.alert]. This module never
  /// returns [SpeechKind.info] for guidance: info loses the
  /// arbitration race with a hazard warning and is not
  /// replayed, which is exactly how the first instruction used
  /// to disappear.
  final SpeechKind kind;

  /// How the heading check went (diagnostics only).
  final InstructionMatch match;

  /// The step this instruction points at, for diagnostics
  /// only. Deliberately NOT the scheduler's `navStepIndex`:
  /// that field drives the tracker's regeneration path, which
  /// would re-derive "前方0米…" wording from a stale index.
  final int? stepIndex;

  @override
  String toString() =>
      'RouteInstruction(kind: ${kind.name}, match: ${match.name}, '
      'step: $stepIndex, text: $text)';
}

// ---------------------------------------------------------------------------
// Spoken forms. Constants (not inline literals) so the tests can
// assert on the exact wording that reached the user.
// ---------------------------------------------------------------------------

/// No position at all: guidance cannot continue honestly.
const String positionUnknownSpeech = '现在无法确认你的位置，导航暂停，请先停下，等定位恢复。';

/// A fix exists but is too coarse to derive a direction from.
const String weakAccuracySpeech = '定位信号较差，导航暂停，先不要走；信号恢复后我会继续提示。';

/// A direction change is due, but the heading is unknown. Must
/// not name a direction.
const String headingUnknownTurnSpeech = '需要改变方向，但现在无法确认你的朝向，请先停下，等我说方向。';

/// A direction change is due and the heading is sideways to
/// the route leg.
const String headingMismatchTurnSpeech = '要改变方向，但你的朝向可能和路线不一致，请先停下确认方向。';

/// A direction change is due and the heading points away from
/// the route leg.
const String backFacingSpeech = '你可能背对路线，请先原地转身，等我提示方向。';

/// Keep walking, heading unknown.
const String headingUnknownStraightSpeech =
    '继续直走，但现在无法确认你的朝向，请以盲杖确认前方。';

/// Keep walking, heading disagrees with the route leg.
const String headingMismatchStraightSpeech =
    '你的朝向可能和路线不一致，请先停下确认方向，再继续走。';

/// Keep walking, nothing else to say.
const String keepStraightSpeech = '继续直走。';

/// The opening instruction's lead-in, completed by the first
/// step's action.
const String startLeadIn = '开始导航，先';

/// Walking actions the route provider may name. Anything else
/// (an empty string, a provider-specific token) is treated as
/// unknown: its raw text never reaches the speech path.
const Set<String> allowedStepActions = <String>{
  '直行',
  '左转',
  '右转',
  '向左前方行走',
  '向右前方行走',
  '向左后方行走',
  '向右后方行走',
  '到达',
};

/// Heading difference (degrees) still counted as "on the route
/// direction".
const double headingMatchDeg = 60;

/// Heading difference (degrees) up to which the route is at
/// least sideways rather than backwards.
const double headingConflictDeg = 120;

/// How close to the route's own start the user must stand for
/// the opening wording ("开始导航，先…") to apply.
const double startRadiusM = 5;

/// The next instruction for the trip [nav] tracks, recomputed
/// from [fix].
///
/// Returns a position/heading problem statement (never null
/// for those) when the caller must be told to stop, and null
/// only when the route carries no geometry to guide along at
/// all -- in which case the caller must stay silent rather
/// than invent something.
///
/// [firstInstruction] relaxes the wording for the moment the
/// route is adopted: standing at the route's own start with
/// step 0 as the target, the sentence becomes "开始导航，先…"
/// instead of the nonsense "前方约1米…".
RouteInstruction? nextRouteInstruction({
  required NavigationTracker nav,
  required GeoPoint? fix,
  required double? accuracyM,
  required double? headingDeg,
  bool firstInstruction = false,
}) {
  if (fix == null) {
    return const RouteInstruction(
      text: positionUnknownSpeech,
      kind: SpeechKind.alert,
      match: InstructionMatch.positionUnclear,
    );
  }
  if (accuracyM == null || accuracyM > NavigationTracker.weakAccuracyM) {
    return const RouteInstruction(
      text: weakAccuracySpeech,
      kind: SpeechKind.alert,
      match: InstructionMatch.positionUnclear,
    );
  }
  if (!fix.hasCoordinates) {
    return const RouteInstruction(
      text: positionUnknownSpeech,
      kind: SpeechKind.alert,
      match: InstructionMatch.positionUnclear,
    );
  }

  final int nearestIdx = nav.nearestRoutePointIndex(fix);
  int current = nav.currentStepIndex;
  if (current < 0) current = 0;
  final int? measurableCurrent = _firstMeasurable(nav, fix, current);
  if (measurableCurrent == null) {
    // No step carries geometry: nothing honest to say.
    return null;
  }

  // The tracker parks its index ON the step whose turn it has
  // just announced, so the "current" step is either
  //  (a) the step the user is walking along (its start point
  //      is behind or level with the nearest route point), or
  //  (b) the step the user is about to enter (the tracker
  //      moved the index forward while the user is still on
  //      the previous leg).
  // Case (b) is the one where a direction change is due; case
  // (a) means the next maneuver is the FOLLOWING step.
  final int? currentStartIdx = nav.stepStartPointIndexAt(measurableCurrent);
  final int targetIdx;
  if (currentStartIdx != null && nearestIdx >= currentStartIdx) {
    targetIdx = _firstMeasurable(nav, fix, measurableCurrent + 1) ?? -1;
  } else {
    targetIdx = measurableCurrent;
  }

  if (firstInstruction && _standingAtRouteStart(nav, fix)) {
    final RouteInstruction? opening =
        _openingInstruction(nav: nav, fix: fix, headingDeg: headingDeg);
    if (opening != null) return opening;
  }

  if (targetIdx < 0) {
    // Final leg: keep walking. There is no maneuver point left,
    // so the bearing reference is the destination itself.
    return _straightInstruction(
      nav: nav,
      fix: fix,
      headingDeg: headingDeg,
      toward: nav.destination,
      distanceM: null,
    );
  }

  final double? distanceM = nav.distanceToStepStartM(fix, targetIdx);
  if (distanceM == null) {
    return const RouteInstruction(
      text: positionUnknownSpeech,
      kind: SpeechKind.alert,
      match: InstructionMatch.positionUnclear,
    );
  }
  if (distanceM <= NavigationTracker.turnAnnounceDistanceM) {
    return _turnInstruction(
      nav: nav,
      fix: fix,
      headingDeg: headingDeg,
      stepIndex: targetIdx,
      distanceM: distanceM,
    );
  }
  return _straightInstruction(
    nav: nav,
    fix: fix,
    headingDeg: headingDeg,
    toward: nav.stepStartPointAt(targetIdx),
    distanceM: distanceM,
  );
}

/// The first step index at or after [from] whose start point
/// can actually be measured, or null.
int? _firstMeasurable(NavigationTracker nav, GeoPoint fix, int from) {
  for (int i = from; i < nav.routableStepCount; i++) {
    if (nav.distanceToStepStartM(fix, i) != null) return i;
  }
  return null;
}

/// Whether the user still stands at the beginning of the
/// route (the opening wording is only honest there).
bool _standingAtRouteStart(NavigationTracker nav, GeoPoint fix) {
  final double? d = nav.distanceToStepStartM(fix, 0);
  return d != null && d <= startRadiusM;
}

/// Distance to the next maneuver point after [fromStep], as a
/// spoken readout, or the empty string when there is none (the
/// caller then drops the distance instead of splicing a hole).
String _nextManeuverDistanceText(
    NavigationTracker nav, GeoPoint fix, int fromStep) {
  final int? next = _firstMeasurable(nav, fix, fromStep + 1);
  if (next == null) return '';
  final double? d = nav.distanceToStepStartM(fix, next);
  if (d == null) return '';
  return navigationDistanceText(d);
}

/// The route provider's action for [stepIndex], but only when
/// it is one of [allowedStepActions]. Null otherwise -- an
/// unknown token is never spliced into a sentence.
String? _knownAction(NavigationTracker nav, int stepIndex) {
  if (stepIndex < 0 || stepIndex >= nav.steps.length) return null;
  final String action = nav.steps[stepIndex].action;
  return allowedStepActions.contains(action) ? action : null;
}

/// `前方约25米` / `前方` -- the "ahead" phrase with the
/// distance folded in only when a readout exists.
String _aheadPhrase(String distanceText) =>
    distanceText.isEmpty ? '前方' : '前方$distanceText';

/// Absolute angular difference in degrees, folded into
/// [0, 180].
double _angleDiff(double a, double b) {
  final double d = ((a - b) % 360.0 + 360.0) % 360.0;
  return d > 180.0 ? 360.0 - d : d;
}

/// Bearing from [fix] to [toward], or null when either point
/// lacks coordinates.
double? _bearingTo(GeoPoint fix, GeoPoint? toward) {
  if (toward == null || !toward.hasCoordinates) return null;
  return bearingDegrees(fix, toward);
}

/// A direction change at [stepIndex], [distanceM] away.
RouteInstruction _turnInstruction({
  required NavigationTracker nav,
  required GeoPoint fix,
  required double? headingDeg,
  required int stepIndex,
  required double distanceM,
}) {
  final String ahead = _aheadPhrase(navigationDistanceText(distanceM));
  final String? action = _knownAction(nav, stepIndex);
  final double? bearing = _bearingTo(fix, nav.stepStartPointAt(stepIndex));

  // No fresh heading (or no usable bearing): say that the
  // direction is unknown. This sentence must not name left,
  // right or straight-ahead.
  if (headingDeg == null || bearing == null) {
    return RouteInstruction(
      text: '$ahead$headingUnknownTurnSpeech',
      kind: SpeechKind.turn,
      match: InstructionMatch.headingUnknown,
      stepIndex: stepIndex,
    );
  }
  // The heading agrees with the route, but the provider's
  // action is outside the known set: keep the honest
  // "change direction" form rather than repeating upstream
  // text nobody vetted.
  if (action == null) {
    return RouteInstruction(
      text: '$ahead$headingUnknownTurnSpeech',
      kind: SpeechKind.turn,
      match: InstructionMatch.headingUnknown,
      stepIndex: stepIndex,
    );
  }
  final double diff = _angleDiff(bearing, headingDeg);
  if (diff <= headingMatchDeg) {
    return RouteInstruction(
      text: '$ahead$action',
      kind: SpeechKind.turn,
      match: InstructionMatch.matched,
      stepIndex: stepIndex,
    );
  }
  if (diff <= headingConflictDeg) {
    return RouteInstruction(
      text: '$ahead$headingMismatchTurnSpeech',
      kind: SpeechKind.turn,
      match: InstructionMatch.headingConflict,
      stepIndex: stepIndex,
    );
  }
  return RouteInstruction(
    text: backFacingSpeech,
    kind: SpeechKind.turn,
    match: InstructionMatch.headingConflict,
    stepIndex: stepIndex,
  );
}

/// A "keep walking" leg whose maneuver point is [toward],
/// [distanceM] away (null when the leg runs to the
/// destination).
RouteInstruction _straightInstruction({
  required NavigationTracker nav,
  required GeoPoint fix,
  required double? headingDeg,
  required GeoPoint? toward,
  required double? distanceM,
}) {
  final String distanceText =
      distanceM == null ? '' : navigationDistanceText(distanceM);
  final double? bearing = _bearingTo(fix, toward);

  if (headingDeg == null || bearing == null) {
    return const RouteInstruction(
      text: headingUnknownStraightSpeech,
      kind: SpeechKind.straight,
      match: InstructionMatch.headingUnknown,
    );
  }
  if (_angleDiff(bearing, headingDeg) <= headingMatchDeg) {
    return RouteInstruction(
      text: distanceText.isEmpty
          ? keepStraightSpeech
          : '继续直走，$distanceText后需要改变方向。',
      kind: SpeechKind.straight,
      match: InstructionMatch.matched,
    );
  }
  return const RouteInstruction(
    text: headingMismatchStraightSpeech,
    kind: SpeechKind.straight,
    match: InstructionMatch.headingConflict,
  );
}

/// The opening instruction, spoken the moment the route is
/// adopted. Null when the honest form does not apply (an
/// unknown first action, or a heading that contradicts the
/// first leg) -- the caller then falls through to the normal
/// rules.
RouteInstruction? _openingInstruction({
  required NavigationTracker nav,
  required GeoPoint fix,
  required double? headingDeg,
}) {
  final String? action = _knownAction(nav, 0);
  if (action == null) return null;
  final String distanceText = _nextManeuverDistanceText(nav, fix, 0);

  if (action == '直行') {
    // Walking straight ahead needs no compass confirmation to
    // be stated -- but a REVERSED heading must not be
    // papered over: fall through so the caller says the
    // heading disagrees.
    final double? bearing = _bearingTo(fix, nav.stepStartPointAt(0));
    if (headingDeg != null &&
        bearing != null &&
        _angleDiff(bearing, headingDeg) > headingMatchDeg) {
      return null;
    }
    return RouteInstruction(
      text: distanceText.isEmpty
          ? '$startLeadIn直走。'
          : '$startLeadIn直走$distanceText',
      kind: SpeechKind.straight,
      match: InstructionMatch.matched,
      stepIndex: 0,
    );
  }

  // A turn as the very first action may only be named when the
  // heading supports it.
  if (headingDeg == null) return null;
  final double? bearing = _bearingTo(fix, nav.stepStartPointAt(0));
  if (bearing == null) return null;
  if (_angleDiff(bearing, headingDeg) > headingMatchDeg) return null;
  return RouteInstruction(
    text: '$startLeadIn$action',
    kind: SpeechKind.turn,
    match: InstructionMatch.matched,
    stepIndex: 0,
  );
}
