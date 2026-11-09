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
/// - arrived: within the arrival radius of the destination;
/// - weakSignal: GPS accuracy too poor to trust, throttled.
///
/// Distances are along-route approximations from haversine
/// segments; nothing here ever claims a position is exact.
library;

import '../adapters/amap_client.dart';
import '../modules/map_navigation.dart';
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
  static const double arrivalDistanceM = 20;
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

    // Arrival.
    if (haversineMeters(fix.point, destination) <= arrivalDistanceM) {
      arrived = true;
      events.add(NavEvent(
        NavEventKind.arrived,
        '已到达$destinationName附近，导航结束。到达不代表已确认入口位置，'
        '请通过语音或身边的人确认。',
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
