/// Off-route re-plan round: a re-plan must route to the destination
/// the trip ALREADY resolved.
///
/// The bug: `_rerouteLiveNavigation` called `starter.start(name)`, which
/// looks the name up in `verified_locations.dart`. Consequences:
///
///  1. 「带我去药店」 could START (the nearby search finds a pharmacy)
///     but could never RE-PLAN -- 药店 is not in that table, so every
///     off-route attempt answered 「路线重新规划失败」 forever;
///  2. 「带我去图书馆」 was re-planned to the coordinate typed into the
///     table (120.443212,37.723667) instead of the POI the user had
///     actually selected.
///
/// `RealNavigationStarter.startToPoint` is the replacement: current fix
/// -> the known destination point. It performs NO place resolution, so
/// the tests below pin both the happy path and, just as importantly,
/// that no `/place/around` search and no registry lookup happens while
/// re-planning.
///
/// All fixtures are local: no real API call, no real GPS, no key.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/adapters/current_location.dart';
import 'package:mingtu_ai/config/verified_locations.dart';
import 'package:mingtu_ai/core/navigation_tracker.dart';
import 'package:mingtu_ai/core/real_navigation.dart';
import 'package:mingtu_ai/core/task_manager.dart';
import 'package:mingtu_ai/main.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';

import 'push_to_talk_ui_test.dart' as ui;
import 'ui_a11y_s1_test.dart' as s1;

const String _walkBody = '''
{
  "status": "1",
  "route": {
    "paths": [
      {
        "distance": "420",
        "duration": "330",
        "steps": [
          {
            "action": "直行",
            "orientation": "北",
            "polyline": "116.400000,39.900000;116.400100,39.900800",
            "distance": "420",
            "duration": "330"
          }
        ]
      }
    ]
  }
}
''';

/// ~1000 km from the shipped registry's demo start point (Hangzhou), so
/// nothing here can be satisfied by the registry's hard-coded pairs.
const GeoPoint _beijingFix =
    GeoPoint(latitude: 39.900000, longitude: 116.400000);

/// The pharmacy POI the nearby search picks in the widget test.
const GeoPoint _pharmacyPoi =
    GeoPoint(latitude: 39.910000, longitude: 116.410000);

/// Where the user is when the re-plan runs (they walked off the route).
const GeoPoint _rerouteFix =
    GeoPoint(latitude: 39.905000, longitude: 116.405000);

/// Far from the walk body's polyline, so the tracker reports off-route.
const GeoPoint _offRouteFix =
    GeoPoint(latitude: 39.930000, longitude: 116.450000);

class FakeLocation implements CurrentLocationProvider {
  FakeLocation(this.results);

  /// Answers in order; the last entry is repeated once the list runs
  /// out, so a test can say "the start fix, then the re-plan fix".
  final List<LocationResult> results;
  int calls = 0;

  @override
  Future<LocationResult> currentLocation() async {
    final int i = calls < results.length ? calls : results.length - 1;
    calls += 1;
    return results[i];
  }

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Stream<LocationResult> positions() => const Stream<LocationResult>.empty();
}

Map<String, Object?> _poi(String name, String lonLat, Object? distance) =>
    <String, Object?>{
      'name': name,
      'location': lonLat,
      'distance': distance,
    };

String _poiBody(List<Map<String, Object?>> pois) =>
    jsonEncode(<String, Object?>{'status': '1', 'pois': pois});

/// Records every request and answers per endpoint, so a test can prove
/// WHICH endpoint was -- and was not -- called.
class RecordingSender {
  RecordingSender({
    required this.poiBody,
    this.walkBody = _walkBody,
    this.walkError,
  });

  final List<Uri> urls = <Uri>[];
  String poiBody;
  String walkBody;
  Object? walkError;

  Future<String> call(Uri url) async {
    urls.add(url);
    if (url.path.endsWith('/place/around')) return poiBody;
    if (walkError != null) throw walkError!;
    return walkBody;
  }

  int countOf(String suffix) => urls.where((u) => u.path.endsWith(suffix)).length;

  Uri? get lastWalk => urls.where((u) => u.path.endsWith('/walking')).isEmpty
      ? null
      : urls.lastWhere((u) => u.path.endsWith('/walking'));
}

RealNavigationStarter _starter({
  required CurrentLocationProvider location,
  required AmapSender sender,
  String proxy = 'https://proxy.example.test',
}) =>
    RealNavigationStarter(
      locationProvider: location,
      client: AmapWalkingClient(proxyBaseUrl: proxy, sender: sender),
    );

FakeLocation _goodStart() => FakeLocation(<LocationResult>[
      LocationResult.fix(_beijingFix, 12),
    ]);

void main() {
  group('startToPoint routes to the point it is GIVEN', () {
    test('a place that is NOT in the registry can still be re-planned', () async {
      // 「同仁堂药店」 appears in no registry entry; the old code returned
      // destinationNotConfigured here and the user was stuck.
      final RecordingSender sender = RecordingSender(
        poiBody: _poiBody(<Map<String, Object?>>[]),
      );
      final RealNavigationOutcome outcome = await _starter(
        location: _goodStart(),
        sender: sender.call,
      ).startToPoint(to: _pharmacyPoi, name: '同仁堂药店');

      expect(outcome.ready, isTrue, reason: '${outcome.failure}');
      expect(outcome.destination!.pointGcj02.latitude, _pharmacyPoi.latitude);
      expect(outcome.destination!.pointGcj02.longitude, _pharmacyPoi.longitude);
      expect(outcome.destination!.name, '同仁堂药店');
      expect(outcome.destination!.id, 'reroute-known');
      // The route request names the POI and the CURRENT fix.
      expect(sender.lastWalk!.queryParameters['destination'],
          '116.410000,39.910000');
      expect(sender.lastWalk!.queryParameters['origin'], '116.400000,39.900000');
      // And nothing was resolved a second time.
      expect(sender.countOf('/place/around'), 0,
          reason: 'a re-plan must not search for the place again');
      expect(sender.urls.map((Uri u) => u.path).toList(),
          <String>['/walking']);
    });

    test('the name 图书馆 resolves to the POI, not to the registry pair',
        () async {
      // The registry's 图书馆 is (37.723667, 120.443212). A re-plan of the
      // SAME name must use the POI the user actually picked.
      final List<VerifiedLocation> registry = verifiedLocations
          .where((VerifiedLocation l) => l.name == '图书馆')
          .toList();
      expect(registry, isNotEmpty, reason: 'fixture sanity: 图书馆 is registered');
      expect(registry.first.pointGcj02.longitude, closeTo(120.443212, 1e-6));

      final RecordingSender sender = RecordingSender(
        poiBody: _poiBody(<Map<String, Object?>>[]),
      );
      final RealNavigationOutcome outcome = await _starter(
        location: _goodStart(),
        sender: sender.call,
      ).startToPoint(to: _pharmacyPoi, name: '图书馆');

      expect(outcome.ready, isTrue, reason: '${outcome.failure}');
      expect(sender.lastWalk!.queryParameters['destination'],
          '116.410000,39.910000');
      expect(sender.lastWalk!.queryParameters['destination'],
          isNot('120.443212,37.723667'),
          reason: 'the registry coordinate must never be re-used');
      expect(outcome.destination!.pointGcj02.longitude,
          isNot(registry.first.pointGcj02.longitude));
    });

    test('an inaccurate fix refuses the re-plan and asks for no route',
        () async {
      final RecordingSender sender = RecordingSender(
        poiBody: _poiBody(<Map<String, Object?>>[]),
      );
      final RealNavigationOutcome outcome = await _starter(
        location: FakeLocation(<LocationResult>[
          LocationResult.fix(_beijingFix, 60),
        ]),
        sender: sender.call,
      ).startToPoint(to: _pharmacyPoi, name: '药店');

      expect(outcome.failure, RealNavigationFailure.locationTooInaccurate);
      expect(sender.countOf('/walking'), 0);
      expect(outcome.failureAnnouncement, contains('精度不够'));
      expect(outcome.failureAnnouncement, contains('导航没有启动'));
    });

    test('an unconfigured client refuses before asking for a fix', () async {
      final RecordingSender sender = RecordingSender(
        poiBody: _poiBody(<Map<String, Object?>>[]),
      );
      final FakeLocation location = _goodStart();
      final RealNavigationOutcome outcome = await _starter(
        location: location,
        sender: sender.call,
        proxy: '',
      ).startToPoint(to: _pharmacyPoi, name: '药店');

      expect(outcome.failure, RealNavigationFailure.proxyNotConfigured);
      expect(location.calls, 0, reason: 'nothing to measure without a client');
      expect(sender.urls, isEmpty);
    });

    test('a location failure keeps its own outcome and requests no route',
        () async {
      final RecordingSender sender = RecordingSender(
        poiBody: _poiBody(<Map<String, Object?>>[]),
      );
      final RealNavigationOutcome outcome = await _starter(
        location: FakeLocation(<LocationResult>[
          LocationResult.error(LocationFailure.permissionDenied, 'fixture'),
        ]),
        sender: sender.call,
      ).startToPoint(to: _pharmacyPoi, name: '药店');

      expect(outcome.failure, RealNavigationFailure.locationPermissionDenied);
      expect(sender.countOf('/walking'), 0);
    });

    test('a route failure reports routeFetchFailed and keeps the destination',
        () async {
      final RecordingSender sender = RecordingSender(
        poiBody: _poiBody(<Map<String, Object?>>[]),
        walkError: Exception('network down'),
      );
      final RealNavigationOutcome outcome = await _starter(
        location: _goodStart(),
        sender: sender.call,
      ).startToPoint(to: _pharmacyPoi, name: '药店');

      expect(outcome.failure, RealNavigationFailure.routeFetchFailed);
      expect(outcome.destination!.pointGcj02.latitude, _pharmacyPoi.latitude);
      expect(outcome.failureAnnouncement, contains('药店'));
    });

    test('a blank name reads as 目的地 instead of an empty announcement',
        () async {
      final RecordingSender sender = RecordingSender(
        poiBody: _poiBody(<Map<String, Object?>>[]),
      );
      final RealNavigationOutcome outcome = await _starter(
        location: _goodStart(),
        sender: sender.call,
      ).startToPoint(to: _pharmacyPoi, name: '   ');

      expect(outcome.ready, isTrue);
      expect(outcome.destination!.name, '目的地');
      // A re-plan is the SAME place, never a new "nearest X" choice.
      expect(outcome.viaNearbySearch, isFalse);
      expect(outcome.placeDistanceM, isNull);
    });
  });

  group('the off-route re-plan in main.dart', () {
    setUp(() {
      mingtuPermissionGatewayOverride = s1.FakePermissionGateway();
      mingtuGuideStoreOverride = s1.FakeGuideStore(seen: true);
      // Keep the packaged-detector startup side effect out of the TTS
      // event stream (same isolation other wiring tests use).
      mingtuYoloAvailableOverride = false;
    });

    tearDown(() {
      mingtuPermissionGatewayOverride = null;
      mingtuGuideStoreOverride = null;
      mingtuYoloAvailableOverride = null;
      mingtuLocationProviderOverride = null;
    });

    testWidgets(
        '「带我去药店」: one search at start, and the re-plan goes to the '
        'pharmacy POI from where the user now is', (tester) async {
      // Call 1 = the start fix, call 2 = the fix the re-plan starts from.
      final FakeLocation location = FakeLocation(<LocationResult>[
        LocationResult.fix(_beijingFix, 12),
        LocationResult.fix(_rerouteFix, 12),
      ]);
      mingtuLocationProviderOverride = location;
      final RecordingSender sender = RecordingSender(
        poiBody: _poiBody(<Map<String, Object?>>[
          _poi('同仁堂药店', '116.410000,39.910000', '120'),
        ]),
      );
      final ui.RecordingVoiceChannels h = ui.RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await ui.settleRecordedApp(tester, h);

      mingtuHomeDebugHandle!.debugSetAmapClient(AmapWalkingClient(
        proxyBaseUrl: 'https://proxy.example.test',
        sender: sender.call,
      ));
      mingtuHomeDebugHandle!.voiceCommand('带我去药店');
      for (int i = 0;
          i < 60 && mingtuHomeDebugHandle!.taskState != TaskState.navigating;
          i++) {
        await tester.pump(const Duration(milliseconds: 50));
        h.completeAllSpeaks();
      }
      expect(mingtuHomeDebugHandle!.taskState, TaskState.navigating,
          reason: '${h.events}');
      // The start itself: one search, one route to the POI.
      expect(sender.countOf('/place/around'), 1);
      expect(sender.countOf('/walking'), 1);
      expect(sender.lastWalk!.queryParameters['destination'],
          '116.410000,39.910000');

      // The user walks off the route.
      for (int i = 0; i < NavigationTracker.offRouteFixesNeeded; i++) {
        mingtuHomeDebugHandle!.debugLiveFix(_offRouteFix, 5);
      }
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        h.completeAllSpeaks();
      }

      // The re-plan went to the pharmacy POI resolved at START time...
      expect(sender.countOf('/walking'), 2,
          reason: 'the re-plan must have requested a route: ${h.events}');
      expect(sender.lastWalk!.queryParameters['destination'],
          '116.410000,39.910000');
      // ...starting from where the user is NOW, not from the first fix.
      expect(sender.lastWalk!.queryParameters['origin'], '116.405000,39.905000');
      expect(location.calls, 2,
          reason: 'one fix for the start, one for the re-plan');
      // ...and it did NOT resolve the name again (that lookup is what
      // failed every single re-plan for a pharmacy).
      expect(sender.countOf('/place/around'), 1,
          reason: 'a re-plan must not search for the place again');
      expect(h.events.any((String e) => e.contains('路线重新规划失败')), isFalse,
          reason: '${h.events}');
      await ui.shutdownVoice(tester, h);
    });

    test('the re-plan never falls back to the name lookup (source pin)', () {
      final String mainDart = File('lib/main.dart').readAsStringSync();
      final int start =
          mainDart.indexOf('Future<void> _rerouteLiveNavigation() async {');
      expect(start, greaterThanOrEqualTo(0));
      final int end =
          mainDart.indexOf('/// Drop the in-flight REAL-navigation', start);
      expect(end, greaterThan(start));
      final String body = mainDart.substring(start, end);
      // Comments are prose about the old behaviour -- "must NOT fall back
      // to starter.start(name)" mentions the old call by name on purpose.
      // The pin is on the CODE, so drop comment lines first.
      final String code = body
          .split('\n')
          .where((String line) => !line.trimLeft().startsWith('//'))
          .join('\n');

      // It routes to the remembered POINT...
      expect(code, contains('startToPoint('));
      expect(code, contains('_liveNavDestPoint'));
      // ...and to nothing else: no registry lookup, no second search, no
      // silent fallback to the name-based starter.
      expect(code, isNot(contains('starter.start(')),
          reason: 'the name lookup must be gone from the re-plan');
      expect(code, isNot(contains('findVerifiedLocation')));
      expect(code, isNot(contains('startNearby')));
      expect(code, isNot(contains('searchAround')));
    });

    test('the destination point is remembered at start and dropped at the end',
        () {
      final String mainDart = File('lib/main.dart').readAsStringSync();
      final int begin = mainDart.indexOf('void _beginLiveNavigation(');
      expect(begin, greaterThanOrEqualTo(0));
      final int beginEnd =
          mainDart.indexOf('Future<void> _startAmapNaviSource(', begin);
      expect(beginEnd, greaterThan(begin));
      expect(mainDart.substring(begin, beginEnd),
          contains('_liveNavDestPoint = outcome.destination!.pointGcj02'));

      final int end = mainDart.indexOf('void _endLiveNavigation() {');
      expect(end, greaterThanOrEqualTo(0));
      final String endBody = mainDart.substring(end, end + 1200);
      expect(endBody, contains('_liveNavDestPoint = null'));

      // The debug tracker seam has no resolved point, so it must not
      // fabricate one -- the null branch covers it.
      final String seamBody = mainDart.substring(
          mainDart.indexOf('void debugInstallLiveTracker('),
          mainDart.indexOf('void debugLiveFix('));
      expect(seamBody, contains('_state._liveNavDestPoint = null'));
    });
  });
}
