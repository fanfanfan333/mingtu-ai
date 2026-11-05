/// Map navigation interface for Mingtu AI v0.1.
///
/// IMPORTANT: this is an interface + a stub provider only. It is NOT a
/// verified Amap (高德) integration. A real Amap SDK integration, API key,
/// quota and walking-route behaviour must be verified against the official
/// Amap documentation before any claim of "Amap integration" is made.
/// The stub deliberately returns accessibility UNKNOWN for every route.
library;

import '../core/route_scoring.dart';

class GeoPoint {
  final double? latitude;
  final double? longitude;
  const GeoPoint({this.latitude, this.longitude});
  bool get hasCoordinates => latitude != null && longitude != null;
}

class NavigationState {
  final String segmentId;
  final bool isStraightSegment;
  final String? nextTurn;
  final double distanceRemainingM;
  final double locationAccuracyM;
  final int version;
  const NavigationState({
    required this.segmentId,
    required this.isStraightSegment,
    required this.distanceRemainingM,
    required this.locationAccuracyM,
    required this.version,
    this.nextTurn,
  });
}

abstract class MapProvider {
  List<RouteCandidate> planRoutes({
    required String fromLabel,
    required String toLabel,
  });
  NavigationState updateLocation(GeoPoint point, double accuracyM);
}

class StubMapProvider implements MapProvider {
  int _version = 0;
  double _distanceRemainingM = 200.0;

  @override
  List<RouteCandidate> planRoutes({
    required String fromLabel,
    required String toLabel,
  }) {
    // Placeholder candidates only. No real map data, no real coordinates,
    // no accessibility claim. Accessibility is UNKNOWN by construction.
    return const [
      RouteCandidate(
        id: 'stub-route-a',
        distanceM: 180,
        durationS: 240,
        accessibility: AccessibilityStatus.unknown,
        dataConfidence: 0.0,
      ),
      RouteCandidate(
        id: 'stub-route-b',
        distanceM: 220,
        durationS: 300,
        accessibility: AccessibilityStatus.unknown,
        knownRiskSeverities: [0.3],
        dataConfidence: 0.0,
      ),
    ];
  }

  @override
  NavigationState updateLocation(GeoPoint point, double accuracyM) {
    _version += 1;
    if (_distanceRemainingM > 10) _distanceRemainingM -= 10;
    return NavigationState(
      segmentId: 'stub-segment-1',
      isStraightSegment: true,
      distanceRemainingM: _distanceRemainingM,
      locationAccuracyM: accuracyM,
      version: _version,
    );
  }
}

class MapNavigationService {
  final MapProvider provider;
  MapNavigationService(this.provider);

  List<RouteCandidate> planRoutes(String from, String to) =>
      provider.planRoutes(fromLabel: from, toLabel: to);

  /// Deviation: in the stub this is a placeholder rule. A real
  /// implementation must compare the live position against the route
  /// polyline from the map provider; that comparison is NOT_IMPLEMENTED.
  bool isDeviated({required double distanceFromRouteM}) =>
      distanceFromRouteM > 15.0;

  /// Switch to destination-approach / entrance-finding mode when close
  /// AND location accuracy is good enough to be meaningful. GPS near a
  /// building can be off by tens of metres, so a small remaining distance
  /// alone never proves "at the entrance".
  bool shouldSwitchToDestinationApproach(NavigationState state) =>
      state.distanceRemainingM < 50.0 && state.locationAccuracyM <= 30.0;
}
