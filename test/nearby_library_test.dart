/// Regression tests for the nearby-search navigation path
/// (`RealNavigationStarter.startNearby`) and the client method behind it
/// (`AmapWalkingClient.searchAround`).
///
/// Context: the user reported that 「带我去图书馆」 answered with
/// technical chatter and an unactionable location failure, and then
/// clarified the intended behaviour -- "take my CURRENT position and go
/// to the library AMAP says is NEAREST". The old design navigated to a
/// coordinate typed into `verified_locations.dart` and refused to start
/// more than 300 m from a demo start point ("你不在演示路线附近").
///
/// These tests pin the new contract:
///  1. the destination comes from the search, and it is the NEAREST one;
///  2. the demo-proximity gate does NOT apply (the whole point);
///  3. "nothing found" and "the search failed" are DIFFERENT answers;
///  4. nothing is ever guessed: no place, no coordinate, no route.
///
/// All fixtures are local: no real API call, no real GPS, no key.
library;

import 'dart:convert';

import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/adapters/current_location.dart';
import 'package:mingtu_ai/config/verified_locations.dart';
import 'package:mingtu_ai/core/hazard/hazard_phrases.dart';
import 'package:mingtu_ai/core/real_navigation.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';
import 'package:test/test.dart';

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

/// The fix every test starts from. Deliberately placed ~1000 km away
/// from the shipped registry's demo start point (Hangzhou), so any test
/// that still succeeds proves the demo-proximity gate is gone.
const GeoPoint _beijingFix =
    GeoPoint(latitude: 39.900000, longitude: 116.400000);

class FakeLocation implements CurrentLocationProvider {
  final LocationResult result;
  int calls = 0;
  FakeLocation(this.result);
  @override
  Future<LocationResult> currentLocation() async {
    calls += 1;
    return result;
  }

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Stream<LocationResult> positions() => const Stream<LocationResult>.empty();
}

LocationResult _goodFix() => LocationResult.fix(_beijingFix, 12);

Map<String, Object?> _poi(String name, String lonLat, Object? distance) =>
    <String, Object?>{
      'name': name,
      'location': lonLat,
      'distance': distance,
    };

String _poiBody(List<Map<String, Object?>> pois) =>
    jsonEncode(<String, Object?>{'status': '1', 'pois': pois});

/// Records every request the starter makes, and answers per path so a
/// test can prove WHICH endpoint was (and was not) called.
class RecordingSender {
  final List<String> paths = <String>[];
  final List<Uri> urls = <Uri>[];
  String poiBody;
  String walkBody;
  Object? poiError;
  Object? walkError;

  RecordingSender({
    required this.poiBody,
    this.walkBody = _walkBody,
    this.poiError,
    this.walkError,
  });

  Future<String> call(Uri url) async {
    paths.add(url.path);
    urls.add(url);
    if (url.path.endsWith('/place/around')) {
      if (poiError != null) throw poiError!;
      return poiBody;
    }
    if (walkError != null) throw walkError!;
    return walkBody;
  }

  int countOf(String suffix) => paths.where((p) => p.endsWith(suffix)).length;

  Uri? get lastWalk => urls.where((u) => u.path.endsWith('/walking')).isEmpty
      ? null
      : urls.lastWhere((u) => u.path.endsWith('/walking'));
}

RealNavigationStarter _starter({
  required CurrentLocationProvider location,
  required AmapSender sender,
  String proxy = 'https://proxy.example.test',
  List<VerifiedLocation>? registry,
}) =>
    RealNavigationStarter(
      locationProvider: location,
      client: AmapWalkingClient(proxyBaseUrl: proxy, sender: sender),
      // Default = the SHIPPED registry, on purpose: it holds the demo
      // start point 1000 km away, which is exactly what used to refuse
      // this request.
      registry: registry ?? verifiedLocations,
    );

void main() {
  group('startNearby picks the NEAREST library', () {
    test('out-of-order payload: the closest place wins, by distance', () async {
      // The upstream list is deliberately NOT sorted: a client that
      // trusted payload order would pick 「远处图书馆」.
      final RecordingSender sender = RecordingSender(
        poiBody: _poiBody(<Map<String, Object?>>[
          _poi('远处图书馆', '116.450000,39.950000', '7800'),
          _poi('最近的图书馆', '116.401000,39.900800', '120'),
          _poi('中等距离图书馆', '116.405000,39.902000', '600'),
        ]),
      );
      final RealNavigationOutcome outcome =
          await _starter(location: FakeLocation(_goodFix()), sender: sender.call)
              .startNearby('图书馆');

      expect(outcome.ready, isTrue, reason: '${outcome.failure}');
      expect(outcome.viaNearbySearch, isTrue);
      expect(outcome.destination!.name, '最近的图书馆');
      expect(outcome.placeDistanceM, 120);
      // And the ROUTE must have been requested to that same point, not
      // to the registry's demo coordinate.
      expect(sender.lastWalk, isNotNull);
      expect(
        sender.lastWalk!.queryParameters['destination'],
        '116.401000,39.900800',
      );
      expect(sender.lastWalk!.queryParameters['origin'], '116.400000,39.900000');
    });

    test('the demo-proximity gate does NOT apply (the original complaint)',
        () async {
      // The old path refused with `tooFarFromDemoStart` ("你不在演示路线
      // 附近") whenever the fix was >300 m from the registry's demo start.
      // This fix is 1000 km away and must still start.
      final RecordingSender sender = RecordingSender(
        poiBody: _poiBody(<Map<String, Object?>>[
          _poi('城市图书馆', '116.401000,39.900800', '120'),
        ]),
      );
      final RealNavigationOutcome outcome =
          await _starter(location: FakeLocation(_goodFix()), sender: sender.call)
              .startNearby('图书馆');

      expect(outcome.failure, isNull);
      expect(outcome.failure, isNot(RealNavigationFailure.tooFarFromDemoStart));
      expect(outcome.startDistanceM, isNull, reason: 'the gate never ran');
      expect(outcome.route!.ok, isTrue);
    });

    test('search runs around the CURRENT fix, with the 3 km radius', () async {
      final RecordingSender sender = RecordingSender(
        poiBody: _poiBody(<Map<String, Object?>>[
          _poi('城市图书馆', '116.401000,39.900800', '120'),
        ]),
      );
      await _starter(location: FakeLocation(_goodFix()), sender: sender.call)
          .startNearby('图书馆');
      final Uri poi = sender.urls.firstWhere(
        (Uri u) => u.path.endsWith('/place/around'),
      );
      expect(poi.queryParameters['location'], '116.400000,39.900000');
      expect(poi.queryParameters['keywords'], '图书馆');
      expect(poi.queryParameters['radius'], '3000');
    });

    test('a place whose name is blank still yields a navigable destination',
        () async {
      final RecordingSender sender = RecordingSender(
        poiBody: _poiBody(<Map<String, Object?>>[
          _poi('', '116.401000,39.900800', '90'),
        ]),
      );
      final RealNavigationOutcome outcome =
          await _starter(location: FakeLocation(_goodFix()), sender: sender.call)
              .startNearby('图书馆');
      expect(outcome.ready, isTrue);
      // Falls back to the user's word, never to an empty announcement.
      expect(outcome.destination!.name, '图书馆');
    });
  });

  group('"nothing found" and "the search failed" are different answers', () {
    test('an empty result is not-found, and NO route is requested', () async {
      final RecordingSender sender =
          RecordingSender(poiBody: _poiBody(<Map<String, Object?>>[]));
      final RealNavigationOutcome outcome =
          await _starter(location: FakeLocation(_goodFix()), sender: sender.call)
              .startNearby('图书馆');

      expect(outcome.failure, RealNavigationFailure.nearbyPlaceNotFound);
      expect(outcome.ready, isFalse);
      expect(sender.countOf('/walking'), 0,
          reason: 'without a destination there is nothing to route to');
      final String text = outcome.failureAnnouncement;
      expect(text, contains('没有找到图书馆'));
      expect(text, contains('导航没有启动'));
      // Actionable: a UI action or asking a person -- never "walk over
      // there and look".
      expect(text, contains('按住屏幕下方'));
      expect(text, contains('身边的人'));
      expect(containsBannedWord(text), isFalse, reason: text);
      for (final String step in <String>['左', '右', '转', '向前', '直走', '安全']) {
        expect(text, isNot(contains(step)), reason: text);
      }
    });

    test('a transport failure is a SEARCH failure, not "not found"', () async {
      final RecordingSender sender = RecordingSender(
        poiBody: '{}',
        poiError: Exception('network down'),
      );
      final RealNavigationOutcome outcome =
          await _starter(location: FakeLocation(_goodFix()), sender: sender.call)
              .startNearby('图书馆');

      expect(outcome.failure, RealNavigationFailure.nearbyPlaceSearchFailed);
      final String text = outcome.failureAnnouncement;
      expect(text, contains('查找附近的地点失败'));
      // We do NOT know whether a library exists, so claiming we looked
      // and found none would be a lie.
      expect(text, isNot(contains('没有找到')));
      expect(sender.countOf('/walking'), 0);
      expect(containsBannedWord(text), isFalse, reason: text);
    });

    test('a failed status from the service is a search failure', () async {
      final RecordingSender sender = RecordingSender(
        poiBody: jsonEncode(<String, Object?>{'status': '0', 'info': 'X'}),
      );
      final RealNavigationOutcome outcome =
          await _starter(location: FakeLocation(_goodFix()), sender: sender.call)
              .startNearby('图书馆');
      expect(outcome.failure, RealNavigationFailure.nearbyPlaceSearchFailed);
    });

    test('a payload without a pois list is a search failure', () async {
      final RecordingSender sender =
          RecordingSender(poiBody: jsonEncode(<String, Object?>{'status': '1'}));
      final RealNavigationOutcome outcome =
          await _starter(location: FakeLocation(_goodFix()), sender: sender.call)
              .startNearby('图书馆');
      expect(outcome.failure, RealNavigationFailure.nearbyPlaceSearchFailed);
    });

    test('a route failure AFTER a good search reports routeFetchFailed',
        () async {
      final RecordingSender sender = RecordingSender(
        poiBody: _poiBody(<Map<String, Object?>>[
          _poi('城市图书馆', '116.401000,39.900800', '120'),
        ]),
        walkError: Exception('network down'),
      );
      final RealNavigationOutcome outcome =
          await _starter(location: FakeLocation(_goodFix()), sender: sender.call)
              .startNearby('图书馆');
      expect(outcome.failure, RealNavigationFailure.routeFetchFailed);
      expect(outcome.destination!.name, '城市图书馆');
    });
  });

  group('the search is never a way around the other guards', () {
    test('no proxy -> proxyNotConfigured, and nothing is requested', () async {
      final RecordingSender sender =
          RecordingSender(poiBody: _poiBody(<Map<String, Object?>>[]));
      final RealNavigationOutcome outcome = await _starter(
        location: FakeLocation(_goodFix()),
        sender: sender.call,
        proxy: '',
      ).startNearby('图书馆');
      expect(outcome.failure, RealNavigationFailure.proxyNotConfigured);
      expect(sender.paths, isEmpty);
    });

    test('a location failure stops before any search', () async {
      final RecordingSender sender =
          RecordingSender(poiBody: _poiBody(<Map<String, Object?>>[]));
      final RealNavigationOutcome outcome = await _starter(
        location: FakeLocation(
          LocationResult.error(LocationFailure.permissionDenied, 'fixture'),
        ),
        sender: sender.call,
      ).startNearby('图书馆');
      expect(outcome.failure, RealNavigationFailure.locationPermissionDenied);
      expect(sender.countOf('/place/around'), 0);
    });

    test('a bad fix stops before any search', () async {
      final RecordingSender sender =
          RecordingSender(poiBody: _poiBody(<Map<String, Object?>>[]));
      final RealNavigationOutcome outcome = await _starter(
        location: FakeLocation(LocationResult.fix(_beijingFix, 80)),
        sender: sender.call,
      ).startNearby('图书馆');
      expect(outcome.failure, RealNavigationFailure.locationTooInaccurate);
      expect(sender.countOf('/place/around'), 0);
    });

    test('an unknown accuracy is refused, same as the registry path',
        () async {
      final RecordingSender sender =
          RecordingSender(poiBody: _poiBody(<Map<String, Object?>>[]));
      final RealNavigationOutcome outcome = await _starter(
        location: FakeLocation(LocationResult.fix(_beijingFix, null)),
        sender: sender.call,
      ).startNearby('图书馆');
      expect(outcome.failure, RealNavigationFailure.locationTooInaccurate);
      expect(sender.countOf('/place/around'), 0);
    });
  });

  group('AmapWalkingClient.searchAround', () {
    Future<AmapPlaceResult> search(
      String body, {
      String proxy = 'https://proxy.example.test',
      String keywords = '图书馆',
      Object? error,
    }) =>
        AmapWalkingClient(
          proxyBaseUrl: proxy,
          sender: (Uri url) async {
            if (error != null) throw error;
            return body;
          },
          requestTimeout: const Duration(seconds: 1),
        ).searchAround(center: _beijingFix, keywords: keywords);

    test('results come back nearest-first', () async {
      final AmapPlaceResult result = await search(_poiBody(<Map<String, Object?>>[
        _poi('远', '116.450000,39.950000', '7800'),
        _poi('近', '116.401000,39.900800', '120'),
        _poi('中', '116.405000,39.902000', '600'),
      ]));
      expect(result.ok, isTrue);
      expect(result.places.map((AmapPlace p) => p.name).toList(),
          <String>['近', '中', '远']);
    });

    test('a place without a usable coordinate is dropped, never invented',
        () async {
      final AmapPlaceResult result = await search(_poiBody(<Map<String, Object?>>[
        _poi('没有坐标', '', '10'),
        _poi('坐标越界', '999,999', '20'),
        _poi('正常', '116.401000,39.900800', '30'),
      ]));
      expect(result.places, hasLength(1));
      expect(result.places.single.name, '正常');
    });

    test('a missing distance stays null, and sorts last', () async {
      final AmapPlaceResult result = await search(_poiBody(<Map<String, Object?>>[
        _poi('没距离', '116.402000,39.901000', null),
        _poi('有距离', '116.401000,39.900800', '120'),
      ]));
      expect(result.places.first.name, '有距离');
      expect(result.places.last.distanceM, isNull);
    });

    test('an empty success is ok with no places (not an error)', () async {
      final AmapPlaceResult result =
          await search(_poiBody(<Map<String, Object?>>[]));
      expect(result.ok, isTrue);
      expect(result.places, isEmpty);
    });

    test('direct-demo mode refuses the search (key must stay server-side)',
        () async {
      final AmapWalkingClient client = AmapWalkingClient(
        proxyBaseUrl: '',
        demoKey: 'demo-only',
        sender: (Uri url) async => fail('must not call upstream'),
      );
      final AmapPlaceResult result =
          await client.searchAround(center: _beijingFix, keywords: '图书馆');
      expect(result.status, 'NOT_CONFIGURED');
    });

    test('error text never carries the URL or the exception', () async {
      final AmapPlaceResult result = await search(
        '{}',
        proxy: 'https://proxy.example.test',
        error: StateError('boom https://proxy.example.test/place/around?key=K'),
      );
      expect(result.ok, isFalse);
      expect(result.error, isNot(contains('proxy.example.test')));
      expect(result.error, isNot(contains('boom')));
    });
  });

  group('nearbyPlaceIntro', () {
    test('registry-based starts add nothing', () {
      expect(
        nearbyPlaceIntro(
          viaNearbySearch: false,
          category: '图书馆',
          name: '图书馆',
          distanceM: 120,
        ),
        '',
      );
    });

    test('names the picked place and its distance', () {
      expect(
        nearbyPlaceIntro(
          viaNearbySearch: true,
          category: '图书馆',
          name: '城市图书馆',
          distanceM: 120,
        ),
        '找到最近的图书馆：城市图书馆，离你约 120 米。',
      );
    });

    test('an absent distance drops the clause instead of reading "未知"', () {
      final String text = nearbyPlaceIntro(
        viaNearbySearch: true,
        category: '图书馆',
        name: '城市图书馆',
        distanceM: null,
      );
      expect(text, '找到最近的图书馆：城市图书馆。');
      expect(text, isNot(contains('未知')));
      expect(text, isNot(contains('约')));
    });

    test('a blank name still reads as a sentence', () {
      expect(
        nearbyPlaceIntro(
          viaNearbySearch: true,
          category: '图书馆',
          name: '',
          distanceM: 90,
        ),
        '找到最近的图书馆：附近的图书馆，离你约 90 米。',
      );
    });
  });
}
