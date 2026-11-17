/// Real-navigation starter for Mingtu AI (navigation core).
///
/// ONE orchestration over injected adapters, with TWO entry points:
///
/// - [RealNavigationStarter.start] navigates to a destination that must
///   exist in the human-verified registry. The checks below describe it.
/// - [RealNavigationStarter.startNearby] resolves the destination by
///   SEARCHING near the user's own fix (「去图书馆」= the nearest library
///   Amap knows about), so no registry entry and no demo-proximity gate
///   applies. See that method for its own check order.
///
/// Everything is injectable so every branch is testable with fixtures --
/// no real API call and no real GPS in tests.
///
/// For [RealNavigationStarter.start] the check order matters, and each
/// failure is its own outcome with its own Chinese announcement; the
/// caller speaks it and does NOT start navigation. Nothing falls back to
/// a simulated route silently, and no coordinate is ever invented:
///
/// 1. destination must exist in the verified registry (empty today
///    -> always destinationNotConfigured);
/// 2. the route proxy must be configured (key lives server-side;
///    an undeployed proxy is announced, not worked around);
/// 3. a GPS fix must succeed (service / permission / failure are
///    distinct outcomes). The fix is ACQUIRED through a two-rung
///    ladder inside the adapter (see
///    adapters/current_location.dart): a high-accuracy attempt,
///    then one coarser retry, because a single capped request
///    timed out on cold starts and indoors and left the user
///    with a dead end. Only the two rungs' common failure maps
///    to [RealNavigationFailure.locationFailed]; a permission or
///    service problem is never retried away. Each of those three
///    outcomes is announced as "I cannot find you" plus the exact
///    phone setting to switch on (or, for the permanently denied
///    case, asking a nearby person to do it in system settings);
/// 4. the fix must be accurate enough to start from
///    ([maxStartAccuracyM]); a worse fix is announced and refused,
///    never silently used;
/// 4b. for the demo route (a registry start point with id
///    [demoStartLocationId] exists), the fix must be within
///    [maxDemoStartDistanceM] of that start point -- the demo
///    coordinates describe one specific place, and starting a
///    demo navigation from somewhere else is announced as
///    "你不在演示路线附近" and refused;
/// 5. the walking route must come back ok from the proxy. A failed
///    fetch is announced as "the route cannot be fetched right
///    now, maybe the network is unstable" plus "try again later",
///    not as an internal route-service error.
///
/// Step advancement after a successful start stays MANUAL (the
/// existing "下一步" voice command drives AmapStepSpeaker): this
/// starter deliberately does not track position or claim live
/// guidance or arrival -- one start fix is not a tracking system.
library;

import 'dart:math' as math;

import '../adapters/amap_client.dart';
import '../adapters/current_location.dart';
import 'hazard/hazard_phrases.dart';
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

/// Default radius (metres) for the nearby search used by
/// [RealNavigationStarter.startNearby]. 3 km is the user's decision
/// (2026-11-17): "最近的图书馆" has to be findable from a normal campus
/// or city block, while still being somewhere a person could actually
/// walk to. Beyond this radius the attempt reports "not found nearby"
/// rather than sending a blind user on an hour-long walk.
const double nearbySearchRadiusM = 3000.0;

/// The FIRST progress prompt spoken while the start attempt is
/// still waiting for its first GPS fix (see
/// `_startRealNavigation` in main.dart). A blind user cannot see
/// a spinner: up to 35 s of silence reads as a crash, and
/// silence about the GPS invites walking around while the fix is
/// still settling. It says what is happening, roughly how long
/// it may take and what to DO meanwhile -- and promises nothing
/// about the outcome.
const String navLocationProgressSpeech = '正在获取你的位置，可能需要十几秒，请保持原地不要走动。';

/// The SECOND progress prompt, spoken when the start is STILL
/// waiting long after the first one (see
/// `AppConfig.navLocationProgressSecondDelay`). The adapter's own
/// ladder may run 35 s, so one prompt at 8 s would leave up to 27 s
/// of dead air -- indistinguishable from a frozen app for a blind
/// user. This one adds no new instruction: it repeats "stay put"
/// and asks for a little more patience, because by now the user has
/// probably started to wonder whether the phone died.
const String navLocationProgressStillWaitingSpeech = '还是没拿到位置，请再等一会儿，不要走动。';

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

  /// The nearby search ran and came back OK, but found nothing within
  /// the radius. Distinct from [routeFetchFailed]: the service worked,
  /// there is simply no such place near the user.
  nearbyPlaceNotFound,

  /// The nearby search itself failed (transport, bad payload, service
  /// error). The user is told the lookup failed, not that nothing
  /// exists -- those are different facts.
  nearbyPlaceSearchFailed,
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

  /// True when this attempt resolved its destination by SEARCHING near
  /// the user's fix (see [RealNavigationStarter.startNearby]) instead of
  /// looking it up in the verified registry. The caller uses it to say
  /// which place was actually picked.
  final bool viaNearbySearch;

  /// Straight-line distance in metres from the user to the picked
  /// place, when the nearby search reported one. Null means "not
  /// reported", never "zero".
  final double? placeDistanceM;

  /// The words the user used for the nearby search (e.g. '图书馆'),
  /// kept for the failure announcements ("附近没有找到图书馆").
  final String? searchCategory;

  const RealNavigationOutcome._({
    this.failure,
    this.destination,
    this.originGcj02,
    this.accuracyM,
    this.route,
    this.routeError,
    this.startDistanceM,
    this.viaNearbySearch = false,
    this.placeDistanceM,
    this.searchCategory,
  });

  factory RealNavigationOutcome.failed(
    RealNavigationFailure failure, {
    VerifiedLocation? destination,
    double? accuracyM,
    String? routeError,
    double? startDistanceM,
    String? searchCategory,
  }) =>
      RealNavigationOutcome._(
        failure: failure,
        destination: destination,
        accuracyM: accuracyM,
        routeError: routeError,
        startDistanceM: startDistanceM,
        searchCategory: searchCategory,
      );

  factory RealNavigationOutcome.ready({
    required VerifiedLocation destination,
    required GeoPoint originGcj02,
    required double? accuracyM,
    required AmapWalkingResult route,
    double? startDistanceM,
    bool viaNearbySearch = false,
    double? placeDistanceM,
    String? searchCategory,
  }) =>
      RealNavigationOutcome._(
        destination: destination,
        originGcj02: originGcj02,
        accuracyM: accuracyM,
        route: route,
        startDistanceM: startDistanceM,
        viaNearbySearch: viaNearbySearch,
        placeDistanceM: placeDistanceM,
        searchCategory: searchCategory,
      );

  bool get ready => failure == null && route != null && route!.ok;

  /// The exact Chinese announcement for a FAILED start. Every text
  /// says navigation did not start and gives NO walking direction
  /// and no assessment of the way ahead -- a blind user cannot
  /// verify a direction, so offering one would be an invitation to
  /// walk into traffic. The only "next actions" a failure text may
  /// contain are (a) a UI action on this phone (e.g. hold the
  /// lower part of the screen to speak again) and (b) asking a
  /// nearby person for help. Neither requires the user to walk
  /// anywhere on their own. (The ready announcement is composed by
  /// the caller, who owns the step speaker.)
  String get failureAnnouncement {
    switch (failure) {
      case RealNavigationFailure.destinationNotConfigured:
        return '这个地点我还没有核对过，不能凭猜测带你走，导航没有启动。';
      case RealNavigationFailure.proxyNotConfigured:
        return '导航服务现在还没准备好，取不到真实路线，导航没有启动。'
            '请稍后再按住屏幕下方说一次“带我去图书馆”。';
      case RealNavigationFailure.locationServiceDisabled:
        return '定位没有打开，我找不到你在哪，导航没有启动。'
            '请打开手机定位，或者请身边的人帮忙打开，'
            '然后按住屏幕下方再说一次“带我去图书馆”。';
      case RealNavigationFailure.locationPermissionDenied:
        return '明途还没拿到定位权限，我找不到你在哪，导航没有启动。'
            '请允许明途使用定位，然后按住屏幕下方再说一次“带我去图书馆”。';
      case RealNavigationFailure.locationPermissionDeniedForever:
        return '明途的定位权限被关掉了，我找不到你在哪，导航没有启动。'
            '可以请身边的人在系统设置里打开明途的定位权限，'
            '然后按住屏幕下方再说一次“带我去图书馆”。';
      case RealNavigationFailure.locationFailed:
        return '定位失败：还没拿到你的位置，导航未启动。'
            '请留在原地不要走动，等十几秒后再按住屏幕下方说一次“带我去图书馆”。'
            '如果连着几次都不行，可以请身边的人带你到室外再试。';
      case RealNavigationFailure.locationTooInaccurate:
        // The accuracy figure is only spoken when it is known: a
        // blind user has no use for the literal word "未知" wedged
        // into a number slot ("约 未知 米"), so the whole
        // parenthetical is dropped instead.
        final String accuracyPhrase =
            accuracyM == null ? '' : '（约 ${accuracyM!.toStringAsFixed(0)} 米）';
        return '当前定位精度不够$accuracyPhrase，'
            '用这个位置出发可能走错路，导航没有启动。'
            '请留在原地，等十几秒后再按住屏幕下方说一次“带我去图书馆”。'
            '如果连着几次都不行，可以请身边的人带你到室外再试。';
      case RealNavigationFailure.tooFarFromDemoStart:
        return '你不在演示路线附近：当前位置离演示起点（校门口）约 '
            '${startDistanceM == null ? '未知' : startDistanceM!.toStringAsFixed(0)} 米，'
            '超过了三百米的演示范围，导航未启动。'
            '请先到校门口附近再开始去图书馆的演示导航。';
      case RealNavigationFailure.routeFetchFailed:
        return '路线暂时取不到，可能是网络不稳，导航没有启动。'
            '请稍后按住屏幕下方再说一次“带我去图书馆”。';
      case RealNavigationFailure.nearbyPlaceNotFound:
        // The lookup worked; there is simply nothing within the radius.
        // Saying "没找到" is honest, and the only next actions are a UI
        // action (speak again) or asking a person -- never "walk over
        // there and look".
        final String what =
            (searchCategory == null || searchCategory!.isEmpty)
                ? '你要去的地方'
                : searchCategory!;
        return '你附近没有找到$what，导航没有启动。'
            '可以请身边的人帮忙确认一下，'
            '或者过一会儿再按住屏幕下方说一次“带我去图书馆”。';
      case RealNavigationFailure.nearbyPlaceSearchFailed:
        // Distinct from "not found": we do not know whether a place
        // exists, so the text must not claim we looked and found none.
        return '查找附近的地点失败了，可能是网络不稳，导航没有启动。'
            '请稍后按住屏幕下方再说一次“带我去图书馆”。';
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

  /// Start real navigation to the NEAREST place matching [category]
  /// around the user's current fix.
  ///
  /// This is the behaviour the user specified for 「带我去图书馆」: take
  /// MY current position, then go to the library Amap says is nearest --
  /// not to a coordinate somebody typed into the repository.
  ///
  /// Order: proxy configured -> GPS fix -> accuracy -> nearby search ->
  /// walking route. Two checks deliberately do NOT apply here:
  ///
  /// - there is no registry lookup, so no destination must be
  ///   pre-verified for this path; and
  /// - there is no [maxDemoStartDistanceM] gate. That gate exists only
  ///   because the registry's demo coordinates describe ONE place; a
  ///   destination derived from the user's own fix is meaningful
  ///   wherever they stand, so gating it would refuse to navigate for no
  ///   reason (and used to answer 「你不在演示路线附近」).
  ///
  /// A successful but EMPTY search is reported as
  /// [RealNavigationFailure.nearbyPlaceNotFound]; a failed search is
  /// [RealNavigationFailure.nearbyPlaceSearchFailed]. Neither ever
  /// falls back to a farther place or to a guessed coordinate.
  Future<RealNavigationOutcome> startNearby(
    String category, {
    double radiusM = nearbySearchRadiusM,
  }) async {
    if (!client.isConfigured) {
      return RealNavigationOutcome.failed(
        RealNavigationFailure.proxyNotConfigured,
        searchCategory: category,
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
      return RealNavigationOutcome.failed(mapped, searchCategory: category);
    }
    final double? accuracy = fix.accuracyM;
    if (accuracy == null || accuracy > maxStartAccuracyM) {
      return RealNavigationOutcome.failed(
        RealNavigationFailure.locationTooInaccurate,
        accuracyM: accuracy,
        searchCategory: category,
      );
    }
    final AmapPlaceResult search = await client.searchAround(
      center: fix.pointGcj02!,
      keywords: category,
      radiusM: radiusM,
    );
    if (!search.ok) {
      return RealNavigationOutcome.failed(
        search.status == 'NOT_CONFIGURED'
            ? RealNavigationFailure.proxyNotConfigured
            : RealNavigationFailure.nearbyPlaceSearchFailed,
        accuracyM: accuracy,
        searchCategory: category,
      );
    }
    if (search.places.isEmpty) {
      return RealNavigationOutcome.failed(
        RealNavigationFailure.nearbyPlaceNotFound,
        accuracyM: accuracy,
        searchCategory: category,
      );
    }
    // [AmapWalkingClient.searchAround] returns nearest-first and that
    // ordering is pinned by its own test; taking `first` here is the
    // "最近的" decision, made in exactly one place.
    final AmapPlace nearest = search.places.first;
    final VerifiedLocation destination = VerifiedLocation(
      id: 'nearby-$category',
      name: nearest.name.isEmpty ? category : nearest.name,
      pointGcj02: nearest.point,
    );
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
        searchCategory: category,
      );
    }
    return RealNavigationOutcome.ready(
      destination: destination,
      originGcj02: fix.pointGcj02!,
      accuracyM: accuracy,
      route: route,
      viaNearbySearch: true,
      placeDistanceM: nearest.distanceM,
      searchCategory: category,
    );
  }
}

/// The ready announcement's fixed part (the caller appends the
/// first step). It states the route was not accessibility-
/// checked, and it matches the shipped behaviour: step 2 added
/// LIVE GPS guidance on top of this announcement (turn, off-
/// route and arrival prompts), so the text must not claim the
/// opposite.
/// Spoken lead-in for a start that resolved its destination by nearby
/// search. It names the place that was ACTUALLY picked and how far it
/// is, because the user asked for "the nearest library" and deserves to
/// hear which one it turned out to be.
///
/// Returns '' for a registry-based start, so the caller can prepend this
/// unconditionally.
///
/// The distance clause is DROPPED when the upstream reported no
/// distance: an absent number must never be read out as "约 未知 米"
/// (same rule as [RealNavigationOutcome.failureAnnouncement]).
String nearbyPlaceIntro({
  required bool viaNearbySearch,
  required String? category,
  required String name,
  required double? distanceM,
}) {
  if (!viaNearbySearch) return '';
  final String rawCategory = category ?? '';
  final String noun = rawCategory.isEmpty ? '地点' : rawCategory;
  final String where = name.isEmpty ? '附近的$noun' : name;
  if (distanceM == null) return '找到最近的$noun：$where。';
  return '找到最近的$noun：$where，离你约 ${distanceM.round()} 米。';
}

String realRouteReadyAnnouncement({
  required String destinationName,
  required double distanceM,
  required int stepsCount,
}) {
  // Route distance wording: the FIX3B navigation bands.
  // CDX5 S2-1: an abnormal distance (non-finite /
  // negative) yields the EMPTY readout; the distance
  // clause is then dropped wholesale ("...路线，共 N 段")
  // so the sentence stays complete instead of reading
  // "距离，共 N 段" with a hole where the figure belongs.
  final String distanceText = navigationDistanceText(distanceM);
  final String distanceClause =
      distanceText.isEmpty ? '' : '，距离$distanceText';
  return '已获取到$destinationName的真实步行路线$distanceClause，共 $stepsCount 段。'
      '注意：高德不提供盲道信息，这条路线没有经过无障碍核查。'
      '接下来我会按你的实时位置播报转向和偏航，'
      '到达时会提醒你。';
}
