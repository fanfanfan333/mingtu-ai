import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/adapters/current_location.dart';
import 'package:mingtu_ai/config/verified_locations.dart';
import 'package:mingtu_ai/core/coordinate_convert.dart';
import 'package:mingtu_ai/core/real_navigation.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';
import 'package:test/test.dart';

/// Navigation P0 regression tests. All fixtures are local: no real
/// API call, no real GPS, no real key anywhere in this file.

const String _amapOkBody = '''
{
  "status": "1",
  "info": "OK",
  "route": {
    "paths": [
      {
        "distance": "186",
        "duration": "150",
        "steps": [
          {
            "instruction": "向北步行80米",
            "road": "校园路",
            "polyline": "116.400000,39.900000;116.400100,39.900800",
            "distance": "80",
            "duration": "60"
          },
          {
            "instruction": "向东步行106米到达目的地",
            "road": "",
            "polyline": "116.400100,39.900800;116.401000,39.900900",
            "distance": "106",
            "duration": "90"
          }
        ]
      }
    ]
  }
}
''';

/// Fixture destination: coordinates are placeholders in GCJ-02
/// form ONLY (a test point, not a real campus location).
const VerifiedLocation _fixtureLibrary = VerifiedLocation(
  id: 'library',
  name: '图书馆',
  pointGcj02: GeoPoint(latitude: 39.900900, longitude: 116.401000),
);

class FakeLocation implements CurrentLocationProvider {
  final LocationResult result;
  bool called = false;
  FakeLocation(this.result);
  @override
  Future<LocationResult> currentLocation() async {
    called = true;
    return result;
  }
}

LocationResult _goodFix() => LocationResult.fix(
      const GeoPoint(latitude: 39.900000, longitude: 116.400000),
      12,
    );

RealNavigationStarter _starter({
  required CurrentLocationProvider location,
  String proxy = 'https://proxy.example.test',
  AmapSender? sender,
  List<VerifiedLocation> registry = const [_fixtureLibrary],
}) =>
    RealNavigationStarter(
      locationProvider: location,
      client: AmapWalkingClient(
        proxyBaseUrl: proxy,
        sender: sender ?? (Uri url) async => _amapOkBody,
      ),
      registry: registry,
    );

void main() {
  group('coordinate conversion (WGS-84 platform fix -> GCJ-02)', () {
    test('published fixture vector converts to the known GCJ-02 point', () {
      // Standard test vector used by public GCJ-02 implementations:
      // WGS-84 (116.404, 39.915) -> GCJ-02 (116.410244, 39.916404).
      final GeoPoint out = wgs84ToGcj02(
        const GeoPoint(latitude: 39.915, longitude: 116.404),
      );
      expect(out.longitude, closeTo(116.410244, 1e-4));
      expect(out.latitude, closeTo(39.916404, 1e-4));
    });

    test('outside China the point is unchanged', () {
      const GeoPoint london = GeoPoint(latitude: 51.5074, longitude: -0.1276);
      final GeoPoint out = wgs84ToGcj02(london);
      expect(out.latitude, london.latitude);
      expect(out.longitude, london.longitude);
    });

    test('a point without coordinates is never filled in', () {
      const GeoPoint empty = GeoPoint();
      expect(wgs84ToGcj02(empty).hasCoordinates, isFalse);
    });

    test('converting twice drifts materially -- why the adapter '
        'must convert exactly once', () {
      const GeoPoint wgs = GeoPoint(latitude: 39.915, longitude: 116.404);
      final GeoPoint once = wgs84ToGcj02(wgs);
      final GeoPoint twice = wgs84ToGcj02(once);
      expect((twice.longitude! - once.longitude!).abs(), greaterThan(0.0005));
    });
  });

  group('verified destination registry', () {
    test('the shipped registry is EMPTY (no field verification yet)',
        () {
      expect(verifiedLocations, isEmpty);
      expect(findVerifiedLocation('图书馆'), isNull);
    });

    test('lookup matches name and aliases in a fixture registry', () {
      const reg = <VerifiedLocation>[
        VerifiedLocation(
          id: 'lib',
          name: '图书馆',
          aliases: <String>['学校图书馆'],
          pointGcj02: GeoPoint(latitude: 39.9, longitude: 116.4),
        ),
      ];
      expect(findVerifiedLocation('图书馆', registry: reg)?.id, 'lib');
      expect(findVerifiedLocation('学校图书馆', registry: reg)?.id, 'lib');
      expect(findVerifiedLocation('食堂', registry: reg), isNull);
    });
  });

  group('RealNavigationStarter failure matrix', () {
    test('unverified destination: announced, location never queried',
        () async {
      final loc = FakeLocation(_goodFix());
      final outcome = await _starter(location: loc, registry: const [])
          .start('图书馆');
      expect(outcome.ready, isFalse);
      expect(outcome.failure, RealNavigationFailure.destinationNotConfigured);
      expect(loc.called, isFalse);
      expect(outcome.failureAnnouncement, contains('目的地未配置'));
      expect(outcome.failureAnnouncement, contains('导航未启动'));
    });

    test('proxy not deployed: announced before any location fix',
        () async {
      final loc = FakeLocation(_goodFix());
      final outcome = await _starter(location: loc, proxy: '').start('图书馆');
      expect(outcome.failure, RealNavigationFailure.proxyNotConfigured);
      expect(loc.called, isFalse);
      expect(outcome.failureAnnouncement, contains('路线服务未部署'));
      expect(outcome.failureAnnouncement, contains('导航未启动'));
    });

    test('each location failure maps to its own announcement', () async {
      final cases = <LocationFailure, RealNavigationFailure>{
        LocationFailure.serviceDisabled:
            RealNavigationFailure.locationServiceDisabled,
        LocationFailure.permissionDenied:
            RealNavigationFailure.locationPermissionDenied,
        LocationFailure.permissionDeniedForever:
            RealNavigationFailure.locationPermissionDeniedForever,
        LocationFailure.failed: RealNavigationFailure.locationFailed,
      };
      for (final entry in cases.entries) {
        final outcome = await _starter(
          location: FakeLocation(
            LocationResult.error(entry.key, 'fixture'),
          ),
        ).start('图书馆');
        expect(outcome.failure, entry.value, reason: '${entry.key}');
        expect(outcome.failureAnnouncement, contains('导航未启动'));
        // No failure text may hand out a physical step instruction.
        expect(outcome.failureAnnouncement, isNot(contains('向左')));
        expect(outcome.failureAnnouncement, isNot(contains('向右')));
        expect(outcome.failureAnnouncement, isNot(contains('过街')));
      }
    });

    test('low accuracy (80 m) refuses to start and never fetches a route',
        () async {
      bool senderCalled = false;
      final outcome = await _starter(
        location: FakeLocation(LocationResult.fix(
          const GeoPoint(latitude: 39.9, longitude: 116.4),
          80,
        )),
        sender: (Uri url) async {
          senderCalled = true;
          return _amapOkBody;
        },
      ).start('图书馆');
      expect(outcome.failure, RealNavigationFailure.locationTooInaccurate);
      expect(outcome.failureAnnouncement, contains('精度不够'));
      expect(senderCalled, isFalse);
    });

    test('unknown accuracy also refuses (unknown is not good enough)',
        () async {
      final outcome = await _starter(
        location: FakeLocation(LocationResult.fix(
          const GeoPoint(latitude: 39.9, longitude: 116.4),
          null,
        )),
      ).start('图书馆');
      expect(outcome.failure, RealNavigationFailure.locationTooInaccurate);
    });

    test('route transport failure -> routeFetchFailed, not ready',
        () async {
      final outcome = await _starter(
        location: FakeLocation(_goodFix()),
        sender: (Uri url) async => throw Exception('network down'),
      ).start('图书馆');
      expect(outcome.ready, isFalse);
      expect(outcome.failure, RealNavigationFailure.routeFetchFailed);
      expect(outcome.failureAnnouncement, contains('路线获取失败'));
    });
  });

  group('RealNavigationStarter success path', () {
    test('ready: GCJ-02 endpoints go to the proxy exactly as given '
        '(no double conversion anywhere)', () async {
      Uri? seen;
      final outcome = await _starter(
        location: FakeLocation(_goodFix()),
        sender: (Uri url) async {
          seen = url;
          return _amapOkBody;
        },
      ).start('图书馆');
      expect(outcome.ready, isTrue);
      expect(outcome.route!.steps.length, 2);
      // Origin = the adapter's GCJ-02 fix verbatim; destination =
      // the verified GCJ-02 point verbatim.
      expect(seen!.queryParameters['origin'], '116.400000,39.900000');
      expect(seen!.queryParameters['destination'], '116.401000,39.900900');
      expect(seen!.queryParameters.containsKey('key'), isFalse);
    });

    test('ready announcement keeps the not-a-safe-route warning and '
        'the manual-step honesty', () {
      final String text = realRouteReadyAnnouncement(
        destinationName: '图书馆',
        distanceM: 186,
        stepsCount: 2,
      );
      expect(text, contains('不是安全路线'));
      expect(text, contains('不会自动实时引导'));
      expect(text, contains('也不会判断你是否到达'));
    });

    test('steps advance ONLY manually through the speaker', () {
      final speaker = AmapStepSpeaker(const [
        AmapStep(
          instruction: '向北步行80米',
          road: '校园路',
          polyline: <GeoPoint>[],
          distanceM: 80,
          durationS: 60,
        ),
        AmapStep(
          instruction: '向东步行106米到达目的地',
          road: '',
          polyline: <GeoPoint>[],
          distanceM: 106,
          durationS: 90,
        ),
      ]);
      expect(speaker.remaining, 2);
      expect(speaker.nextStepText(), contains('第 1 段'));
      expect(speaker.remaining, 1);
      expect(speaker.nextStepText(), contains('第 2 段'));
      expect(speaker.nextStepText(), isNull);
    });
  });
}
