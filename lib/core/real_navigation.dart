/// Real-navigation starter for Mingtu AI (navigation P0).
///
/// One attempt to start REAL voice navigation to a human-verified
/// destination, as a pure orchestration over injected adapters so
/// every branch is testable with fixtures -- no real API call and
/// no real GPS in tests.
///
/// Check order matters, and each failure is its own outcome with
/// its own Chinese announcement; the caller speaks it and does NOT
/// start navigation. Nothing falls back to a simulated route
/// silently, and no coordinate is ever invented:
///
/// 1. destination must exist in the verified registry (empty today
///    -> always destinationNotConfigured);
/// 2. the route proxy must be configured (key lives server-side;
///    an undeployed proxy is announced, not worked around);
/// 3. a GPS fix must succeed (service / permission / failure are
///    distinct outcomes);
/// 4. the fix must be accurate enough to start from
///    ([maxStartAccuracyM]); a worse fix is announced and refused,
///    never silently used;
/// 4b. for the demo route (a registry start point with id
///    [demoStartLocationId] exists), the fix must be within
///    [maxDemoStartDistanceM] of that start point -- the demo
///    coordinates describe one specific place, and starting a
///    demo navigation from somewhere else is announced as
///    "你不在演示路线附近" and refused;
/// 5. the walking route must come back ok from the proxy.
///
/// Step advancement after a successful start stays MANUAL (the
/// existing "下一步" voice command drives AmapStepSpeaker): this
/// starter deliberately does not track position or claim live
/// guidance or arrival -- one start fix is not a tracking system.
library;

import 'dart:math' as math;

import '../adapters/amap_client.dart';
import '../adapters/current_location.dart';
import '../config/verified_locations.dart';
import '../modules/map_navigation.dart';

/// Worst horizontal accuracy (metres) accepted for *starting*
/// navigation. Consistency reference: MapNavigationService only
/// replans on deviation when accuracy <= 30 m; 50 m is the looser
/// bound for merely starting, and anything worse is refused aloud.
const double maxStartAccuracyM = 50.0;

/// Farthest the user may be from the demo start point for a demo
/// navigation to start (see check 4b in the file header).
const double maxDemoStartDistanceM = 300.0;

/// Great-circle distance in metres between two GCJ-02 points.
double haversineMeters(GeoPoint a, GeoPoint b) {
  const double earthRadiusM = 6371000.0;
  final double lat1 = a.latitude! * math.pi / 180.0;
  final double lat2 = b.latitude! * math.pi / 180.0;
  final double dLat = (b.latitude! - a.latitude!) * math.pi / 180.0;
  final double dLon = (b.longitude! - a.longitude!) * math.pi / 180.0;
  final double s = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  final double root = math.sqrt(s);
  return 2 * earthRadiusM * math.asin(root > 1 ? 1 : root);
}

enum RealNavigationFailure {
  destinationNotConfigured,
  proxyNotConfigured,
  locationServiceDisabled,
  locationPermissionDenied,
  locationPermissionDeniedForever,
  locationFailed,
  locationTooInaccurate,
  tooFarFromDemoStart,
  routeFetchFailed,
}

class RealNavigationOutcome {
  final RealNavigationFailure? failure;
  final VerifiedLocation? destination;
  final GeoPoint? originGcj02;
  final double? accuracyM;
  final AmapWalkingResult? route;
  final String? routeError;

  /// Distance in metres from the GPS fix to the demo start
  /// point, when the demo-start check ran.
  final double? startDistanceM;

  const RealNavigationOutcome._({
    this.failure,
    this.destination,
    this.originGcj02,
    this.accuracyM,
    this.route,
    this.routeError,
    this.startDistanceM,
  });

  factory RealNavigationOutcome.failed(
    RealNavigationFailure failure, {
    VerifiedLocation? destination,
    double? accuracyM,
    String? routeError,
    double? startDistanceM,
  }) =>
      RealNavigationOutcome._(
        failure: failure,
        destination: destination,
        accuracyM: accuracyM,
        routeError: routeError,
        startDistanceM: startDistanceM,
      );

  factory RealNavigationOutcome.ready({
    required VerifiedLocation destination,
    required GeoPoint originGcj02,
    required double? accuracyM,
    required AmapWalkingResult route,
    double? startDistanceM,
  }) =>
      RealNavigationOutcome._(
        destination: destination,
        originGcj02: originGcj02,
        accuracyM: accuracyM,
        route: route,
        startDistanceM: startDistanceM,
      );

  bool get ready => failure == null && route != null && route!.ok;

  /// The exact Chinese announcement for a FAILED start. Every text
  /// says navigation did not start; none offers a next physical
  /// step. (The ready announcement is composed by the caller, who
  /// owns the step speaker.)
  String get failureAnnouncement {
    switch (failure) {
      case RealNavigationFailure.destinationNotConfigured:
        return '目的地未配置：这个地点还没有经过人工现场核验，'
            '没有可用坐标，导航未启动。';
      case RealNavigationFailure.proxyNotConfigured:
        return '路线服务未部署：路线代理服务器还没有配置，'
            '暂时无法获取真实路线，导航未启动。';
      case RealNavigationFailure.locationServiceDisabled:
        return '定位服务未开启：请先在系统设置里打开定位，导航未启动。';
      case RealNavigationFailure.locationPermissionDenied:
        return '定位权限被拒绝：没有你的位置就无法规划真实路线，'
            '导航未启动。可以授权定位后重试。';
      case RealNavigationFailure.locationPermissionDeniedForever:
        return '定位权限已被关闭：请在系统设置里为本应用开启定位权限，'
            '导航未启动。';
      case RealNavigationFailure.locationFailed:
        return '定位失败：暂时得不到你的位置，导航未启动。'
            '请到开阔处稍后重试。';
      case RealNavigationFailure.locationTooInaccurate:
        return '当前定位精度不够（约 '
            '${accuracyM == null ? '未知' : '${accuracyM!.toStringAsFixed(0)} 米'}），'
            '用这个位置出发可能走错路，导航未启动。请到开阔处重试。';
      case RealNavigationFailure.tooFarFromDemoStart:
        return '你不在演示路线附近：当前位置离演示起点（校门口）约 '
            '${startDistanceM == null ? '未知' : startDistanceM!.toStringAsFixed(0)} 米，'
            '超过了三百米的演示范围，导航未启动。'
            '请先到校门口附近再开始去图书馆的演示导航。';
      case RealNavigationFailure.routeFetchFailed:
        return '路线获取失败：网络或路线服务出错，导航未启动。'
            '请稍后重试。';
      case null:
        return '';
    }
  }
}

class RealNavigationStarter {
  final CurrentLocationProvider locationProvider;
  final AmapWalkingClient client;
  final List<VerifiedLocation> registry;

  const RealNavigationStarter({
    required this.locationProvider,
    required this.client,
    this.registry = verifiedLocations,
  });

  Future<RealNavigationOutcome> start(String destinationName) async {
    final VerifiedLocation? destination =
        findVerifiedLocation(destinationName, registry: registry);
    if (destination == null) {
      return RealNavigationOutcome.failed(
        RealNavigationFailure.destinationNotConfigured,
      );
    }
    if (!client.isConfigured) {
      return RealNavigationOutcome.failed(
        RealNavigationFailure.proxyNotConfigured,
        destination: destination,
      );
    }
    final LocationResult fix = await locationProvider.currentLocation();
    if (!fix.ok) {
      final RealNavigationFailure mapped = switch (fix.failure) {
        LocationFailure.serviceDisabled =>
          RealNavigationFailure.locationServiceDisabled,
        LocationFailure.permissionDenied =>
          RealNavigationFailure.locationPermissionDenied,
        LocationFailure.permissionDeniedForever =>
          RealNavigationFailure.locationPermissionDeniedForever,
        _ => RealNavigationFailure.locationFailed,
      };
      return RealNavigationOutcome.failed(mapped, destination: destination);
    }
    final double? accuracy = fix.accuracyM;
    if (accuracy == null || accuracy > maxStartAccuracyM) {
      return RealNavigationOutcome.failed(
        RealNavigationFailure.locationTooInaccurate,
        destination: destination,
        accuracyM: accuracy,
      );
    }
    // Check 4b: the demo-start proximity gate. The verified
    // points are GCJ-02 and are used as-is here -- this distance
    // compares the (already converted, exactly once) GPS fix
    // against the registry's GCJ-02 start point.
    double? startDistanceM;
    for (final VerifiedLocation loc in registry) {
      if (loc.id != demoStartLocationId) continue;
      startDistanceM = haversineMeters(fix.pointGcj02!, loc.pointGcj02);
      if (startDistanceM > maxDemoStartDistanceM) {
        return RealNavigationOutcome.failed(
          RealNavigationFailure.tooFarFromDemoStart,
          destination: destination,
          accuracyM: accuracy,
          startDistanceM: startDistanceM,
        );
      }
    }
    final AmapWalkingResult route = await client.walkingRoute(
      from: fix.pointGcj02!,
      to: destination.pointGcj02,
    );
    if (!route.ok) {
      return RealNavigationOutcome.failed(
        route.status == 'NOT_CONFIGURED'
            ? RealNavigationFailure.proxyNotConfigured
            : RealNavigationFailure.routeFetchFailed,
        destination: destination,
        routeError: route.error,
      );
    }
    return RealNavigationOutcome.ready(
      destination: destination,
      originGcj02: fix.pointGcj02!,
      accuracyM: accuracy,
      route: route,
      startDistanceM: startDistanceM,
    );
  }
}

/// The ready announcement's fixed part (the caller appends the
/// first step). It keeps the "not a safe route" warning and the
/// manual-step honesty: no live guidance, no arrival claim.
String realRouteReadyAnnouncement({
  required String destinationName,
  required double distanceM,
  required int stepsCount,
}) =>
    '已获取到$destinationName的真实步行路线，距离 '
    '${distanceM.toStringAsFixed(0)} 米，共 $stepsCount 段。'
    '注意：高德不提供盲道信息，这条路线不是安全路线。'
    '我只会按你说的"下一步"逐段播报，不会自动实时引导，'
    '也不会判断你是否到达。';
