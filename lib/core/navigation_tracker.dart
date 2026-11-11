/// Live navigation tracking (step 2): GPS fixes in, spoken
/// navigation events out.
///
/// Pure and fully testable with simulated tracks. The tracker
/// walks the flattened step polylines of a real Amap walking
/// route and emits:
/// - turnAhead: approaching the next step's start point, with
///   that step's (locally generated, enum-based) spoken text;
/// - offRoute: the fix stayed too far from the route --
///   re-planning is throttled by [rerouteDecision];
/// - arrived: within the entrance radius of the destination --
///   route following stops here and the entrance-guidance
///   phase (core/entrance_guidance.dart) takes over; the
///   trip only completes when guidance reaches its own,
///   smaller arrival radius;
/// - weakSignal: GPS accuracy too poor to trust, throttled.
///
/// Distances are along-route approximations from haversine
/// segments; nothing here ever claims a position is exact.
library;

import '../adapters/amap_client.dart';
import '../modules/map_navigation.dart';
import 'hazard/hazard_phrases.dart';
import 'navhaz_config.dart';
import 'real_navigation.dart' show haversineMeters;

class NavFix {
  final GeoPoint point;
  final double? accuracyM;
  final DateTime at;
  const NavFix(
      {required this.point, required this.accuracyM, required this.at});
}

enum NavEventKind { turnAhead, offRoute, arrived, weakSignal }

class NavEvent {
  final NavEventKind kind;
  final String text;

  /// For turnAhead: the index of the step being entered.
  final int? stepIndex;
  const NavEvent(this.kind, this.text, {this.stepIndex});
}

enum RerouteDecision { doIt, throttled, exhausted }

/// Re-plan throttle state for a WHOLE TRIP. It deliberately
/// lives OUTSIDE the tracker: re-planning rebuilds the
/// tracker for the new route, and rebuilding must not reset
/// the budget (Codex re-test: a fresh tracker zeroed the
/// "at most 3 re-plans" limit on every re-plan).
class RerouteBudget {
  int count = 0;
  DateTime? lastAt;

  RerouteDecision decision(DateTime now) {
    if (count >= NavigationTracker.rerouteMaxCount) {
      return RerouteDecision.exhausted;
    }
    final DateTime? last = lastAt;
    if (last != null &&
        now.difference(last) < NavigationTracker.rerouteMinInterval) {
      return RerouteDecision.throttled;
    }
    count += 1;
    lastAt = now;
    return RerouteDecision.doIt;
  }
}

class NavigationTracker {
  static const double turnAnnounceDistanceM = 30;
  static const double offRouteDistanceM = 30;
  static const int offRouteFixesNeeded = 2;
  /// Hand-over radius for the entrance-guidance phase: the
  /// arrived event fires once when a fix comes within this
  /// distance of the destination. Mirrors
  /// EntranceGuidance.enterRadiusM (kept as a local constant
  /// so this file has no import cycle with the guidance
  /// module). The trip's actual arrival radius (15 m) lives
  /// in EntranceGuidance.arriveRadiusM.
  /// Hand-over radius to entrance guidance (step D,
  /// adjusted): the demo route is only ~155 m long, so the
  /// route keeps guiding until 30 m out. Mirrored by
  /// EntranceGuidance.enterRadiusM.
  static const double entranceRadiusM = 30;

  /// The hand-over additionally requires a trustworthy fix:
  /// only accuracy at or below this (m) may end route
  /// following. A sloppy fix that close to the destination
  /// is not evidence the user is really there.
  static const double handoverMaxAccuracyM = 20;
  static const double weakAccuracyM = 50;
  static const Duration weakSignalCooldown = Duration(seconds: 60);
  static const Duration rerouteMinInterval = Duration(seconds: 60);
  static const int rerouteMaxCount = 3;

  final List<AmapStep> steps;
  final List<String> stepTexts;
  final GeoPoint destination;
  final String destinationName;

  /// Trip-level re-plan budget (shared across the trackers
  /// built for one trip's re-plans).
  final RerouteBudget budget;

  final List<GeoPoint> _points = <GeoPoint>[];
  final List<double> _cum = <double>[]; // cumulative metres at each point
  final List<int> _stepStartPointIndex = <int>[];

  int currentStepIndex = 0;
  double? remainingM;
  bool arrived = false;
  DateTime? _lastWeakAt;
  int _offRouteStreak = 0;
  bool _offRouteAnnounced = false;

  /// Steps whose turn-ahead event has been EMITTED by
  /// [onFix]. This is a spam guard (one event per step, not
  /// one per fix) -- it does NOT mean the user heard the
  /// prompt: a hazard announcement can interrupt the speech
  /// after the event fired. The pre-M1 defect was treating
  /// this set as "announced, done": an interrupted turn was
  /// lost forever. Recovery now lives in the speech
  /// arbitration: the interrupted request is replayed via
  /// [regenerateTurnPrompt], which deliberately does NOT
  /// consult this set.
  final Set<int> _turnsAnnounced = <int>{};

  NavigationTracker({
    required this.steps,
    required this.stepTexts,
    required this.destination,
    required this.destinationName,
    RerouteBudget? budget,
  }) : budget = budget ?? RerouteBudget() {
    double acc = 0;
    for (int i = 0; i < steps.length; i++) {
      final List<GeoPoint> line = steps[i].polyline;
      if (line.isEmpty) continue;
      _stepStartPointIndex.add(_points.length);
      for (int j = 0; j < line.length; j++) {
        if (_points.isNotEmpty) {
          acc += haversineMeters(_points.last, line[j]);
        }
        _points.add(line[j]);
        _cum.add(acc);
      }
    }
    if (_points.isEmpty) {
      _points.add(destination);
      _cum.add(0);
    }
    remainingM = _cum.last;
  }

  int get totalPoints => _points.length;

  /// Distance in metres from [p] to the START point of
  /// step [stepIndex] (the first polyline point of that
  /// step), or null when the index names no step. Read-
  /// only: the M2 section 3.3 crossing trigger gates on
  /// the user standing near the start of a crossing
  /// step, which is exactly this distance.
  double? distanceToStepStartM(GeoPoint p, int stepIndex) {
    if (stepIndex < 0 || stepIndex >= _stepStartPointIndex.length) {
      return null;
    }
    return haversineMeters(p, _points[_stepStartPointIndex[stepIndex]]);
  }

  /// NAVHAZ M1 arbitration (spec section 2.6): regenerate an
  /// interrupted turn-ahead prompt for [stepIndex] from the
  /// LATEST fix -- the distance is recomputed against the
  /// step's start point, never copied from the interrupted
  /// text. Returns null (drop the replay) when:
  /// - the trip already handed over (arrived), or the index
  ///   names no step / no step text;
  /// - the user has already entered a LATER step, or their
  ///   nearest route point lies beyond the step's start
  ///   point: the intersection is behind them;
  /// - they are already within
  ///   [NavHazConfig.replayMinDistanceM] of the start point:
  ///   a fresh distance call-out is pointless at the kerb.
  ///
  /// Note the "passed" test is currentStepIndex > stepIndex,
  /// not >=: [onFix] parks currentStepIndex AT the announced
  /// step when the turn event fires, so equality means "in
  /// the announcement zone of that very intersection", which
  /// is exactly the case a regeneration exists for.
  String? regenerateTurnPrompt(int stepIndex, NavFix latestFix) {
    if (arrived) return null;
    if (stepIndex < 0 || stepIndex >= _stepStartPointIndex.length) {
      return null;
    }
    if (stepIndex >= stepTexts.length) return null;
    if (currentStepIndex > stepIndex) return null;
    final int startPointIdx = _stepStartPointIndex[stepIndex];
    final (int nearestIdx, double _) = _nearest(latestFix.point);
    if (nearestIdx > startPointIdx) return null;
    final double d =
        haversineMeters(latestFix.point, _points[startPointIdx]);
    if (d < NavHazConfig.replayMinDistanceM) return null;
    // Distance wording: the FIX3B navigation bands (the
    // function returns the announcement-ready form,
    // leading "about" included). CDX5 S2-1: an abnormal
    // distance (non-finite / negative -- a haversine over
    // real fixes cannot produce one, but the wording
    // layer must not trust that) yields the EMPTY
    // readout; the prompt then drops the distance prefix
    // entirely and keeps the bare turn text, a complete
    // sentence, instead of splicing a hole into it.
    final String distanceText = navigationDistanceText(d);
    if (distanceText.isEmpty) return stepTexts[stepIndex];
    return '前方$distanceText${stepTexts[stepIndex]}';
  }

  /// Nearest route point to [p]: (index, distance in metres).
  (int, double) _nearest(GeoPoint p) {
    int best = 0;
    double bestD = double.infinity;
    for (int i = 0; i < _points.length; i++) {
      final double d = haversineMeters(p, _points[i]);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return (best, bestD);
  }

  /// Throttled re-plan gate, delegated to the trip-level
  /// [budget]: at most one re-plan per [rerouteMinInterval]
  /// and [rerouteMaxCount] per TRIP, across tracker rebuilds.
  RerouteDecision rerouteDecision(DateTime now) => budget.decision(now);

  /// Re-arm off-route detection after a re-plan attempt
  /// failed or was throttled: without this, the announced
  /// flag would suppress every later off-route event and an
  /// off-route user could never get another re-plan try.
  void resetOffRouteStreak() {
    _offRouteStreak = 0;
    _offRouteAnnounced = false;
  }

  int get rerouteCount => budget.count;

  /// Whether the step the user is currently on is a straight
  /// segment (Amap action 直行): the live-navigation source
  /// for the speech scheduler's straight-prompt gate.
  bool get currentSegmentIsStraight =>
      steps.isNotEmpty &&
      currentStepIndex < steps.length &&
      steps[currentStepIndex].action == '直行';

  List<NavEvent> onFix(NavFix fix) {
    final List<NavEvent> events = <NavEvent>[];
    if (arrived) return events;

    // Weak signal first: if the fix cannot be trusted, say so
    // (throttled) and do not derive turns from it.
    final double? accM = fix.accuracyM;
    if (accM == null || accM > weakAccuracyM) {
      final DateTime? last = _lastWeakAt;
      if (last == null || fix.at.difference(last) >= weakSignalCooldown) {
        _lastWeakAt = fix.at;
        events.add(const NavEvent(
          NavEventKind.weakSignal,
          'GPS 信号较差，定位可能不准，导航提示仅供参考。',
        ));
      }
      return events;
    }

    final (int nearestIdx, double nearestD) = _nearest(fix.point);
    remainingM = (_cum.last - _cum[nearestIdx]).clamp(0, double.infinity);

    // Hand-over to entrance guidance: within the entrance
    // radius AND with a fix accurate enough to trust at
    // that range (see handoverMaxAccuracyM), the route's
    // job is done, but the trip is NOT over -- the guidance
    // phase keeps announcing distance and relative
    // direction to the destination point. A fix inside the
    // radius but too inaccurate does NOT hand over: route
    // following continues. The event text is a neutral
    // hand-over marker; main speaks the guidance phase's
    // own first announcement instead, so this text never
    // reaches the user as-is.
    if (haversineMeters(fix.point, destination) <= entranceRadiusM &&
        accM <= handoverMaxAccuracyM) {
      arrived = true;
      events.add(NavEvent(
        NavEventKind.arrived,
        '已到达$destinationName附近，进入入口指引。',
      ));
      return events;
    }

    // Step progress + turn-ahead.
    for (int i = 0; i < _stepStartPointIndex.length; i++) {
      if (_stepStartPointIndex[i] <= nearestIdx && i > currentStepIndex) {
        currentStepIndex = i;
      }
    }
    for (int i = currentStepIndex + 1; i < _stepStartPointIndex.length; i++) {
      final GeoPoint wp = _points[_stepStartPointIndex[i]];
      if (haversineMeters(fix.point, wp) <= turnAnnounceDistanceM &&
          !_turnsAnnounced.contains(i)) {
        _turnsAnnounced.add(i);
        currentStepIndex = i;
        final String text = i < stepTexts.length ? stepTexts[i] : '前方路段变化，请注意。';
        events.add(NavEvent(NavEventKind.turnAhead, text, stepIndex: i));
        break;
      }
    }

    // Off-route: sustained distance from every route point.
    if (nearestD > offRouteDistanceM) {
      _offRouteStreak += 1;
      if (_offRouteStreak >= offRouteFixesNeeded && !_offRouteAnnounced) {
        _offRouteAnnounced = true;
        events.add(const NavEvent(
          NavEventKind.offRoute,
          '你已偏离路线。',
        ));
      }
    } else {
      _offRouteStreak = 0;
      if (nearestD <= offRouteDistanceM / 2) {
        _offRouteAnnounced = false;
      }
    }
    return events;
  }
}

/// Which straight-segment confirmation counts right now
/// (Codex re-test of f951240): while a live tracker exists,
/// ONLY its current step decides -- a stale confirmation
/// recorded by another flow (e.g. the demo navigation's
/// manual confirm) must never bypass the tracker. Without a
/// live tracker the caller's own confirmation applies.
bool straightSegmentConfirmedNow({
  required NavigationTracker? liveNav,
  required bool fallbackConfirmed,
}) {
  final NavigationTracker? nav = liveNav;
  if (nav != null) return nav.currentSegmentIsStraight;
  return fallbackConfirmed;
}
