/// Skill: route_planning (v0.1, IMPLEMENTED as scoring over stub routes).
///
/// Input: from / to labels. Output: best scored route + reason.
/// Accessibility UNKNOWN is never reported as SAFE; see route_scoring.dart.
library;

import '../core/route_scoring.dart';
import '../modules/map_navigation.dart';

class RoutePlanResult {
  final ScoredRoute? best;
  final List<ScoredRoute> all;
  final String status; // 'ok' | 'no-route'
  const RoutePlanResult({required this.best, required this.all, required this.status});
}

class RoutePlanningSkill {
  final MapNavigationService navigation;
  RoutePlanningSkill(this.navigation);

  RoutePlanResult plan(String from, String to, {RouteWeights weights = const RouteWeights()}) {
    final candidates = navigation.planRoutes(from, to);
    final scored = RouteScoring.scoreRoutes(candidates, weights: weights);
    if (scored.isEmpty) {
      return const RoutePlanResult(best: null, all: [], status: 'no-route');
    }
    return RoutePlanResult(best: scored.first, all: scored, status: 'ok');
  }
}
