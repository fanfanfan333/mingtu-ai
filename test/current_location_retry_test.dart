/// Real-device fix round: the location adapter's two-rung
/// acquisition ladder (adapters/current_location.dart).
///
/// A single high-accuracy request with a 15 s cap timed out on
/// every cold start and indoors, so nothing at all was announced
/// and navigation never started. The adapter now walks a pinned
/// ladder -- high accuracy (20 s), then ONE coarser retry
/// (medium, 15 s) -- and these tests are the anchors that make
/// the ladder non-optional: deleting the retry turns cases 1 and
/// 2 red.
///
/// What the ladder must NOT change is just as important, so each
/// negative case below proves the retry does not swallow an
/// access failure (permission / service are the user's to fix),
/// does not invent a coordinate, and converts WGS-84 -> GCJ-02
/// exactly once.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mingtu_ai/adapters/current_location.dart';
import 'package:mingtu_ai/core/coordinate_convert.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';

/// Scripted platform double. Each `getCurrentPosition` call
/// consumes the next scripted outcome (a [Position] to return or
/// an [Object] to throw), so the ladder's ORDER, its CALL COUNT
/// and the accuracy it asked for are all observable.
class _ScriptedGeolocator extends GeolocatorPlatform {
  _ScriptedGeolocator({
    required this.outcomes,
    this.serviceEnabled = true,
    this.permission = LocationPermission.whileInUse,
  });

  final List<Object> outcomes;
  final bool serviceEnabled;
  final LocationPermission permission;

  /// How many times a fix was actually attempted.
  int positionCalls = 0;

  /// How many times the access gate ran (must be once per rung).
  int permissionChecks = 0;

  final List<LocationAccuracy?> requestedAccuracy = <LocationAccuracy?>[];
  final List<Duration?> requestedTimeLimit = <Duration?>[];

  @override
  Future<bool> isLocationServiceEnabled() async => serviceEnabled;

  @override
  Future<LocationPermission> checkPermission() async {
    permissionChecks++;
    return permission;
  }

  @override
  Future<Position> getCurrentPosition(
      {LocationSettings? locationSettings}) async {
    final Object outcome = positionCalls < outcomes.length
        ? outcomes[positionCalls]
        : TimeoutException('no scripted outcome left');
    positionCalls++;
    requestedAccuracy.add(locationSettings?.accuracy);
    requestedTimeLimit.add(locationSettings?.timeLimit);
    if (outcome is Position) return outcome;
    throw outcome;
  }

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      const Stream<Position>.empty();
}

Position _wgsFix(double latitude, double longitude, {double accuracy = 8}) =>
    Position(
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.utc(2026, 1, 1),
      accuracy: accuracy,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GeolocatorPlatform original;

  setUp(() => original = GeolocatorPlatform.instance);
  tearDown(() => GeolocatorPlatform.instance = original);

  // A real WGS-84 fix; the adapter must hand back its GCJ-02 form.
  const double wgsLat = 39.908692;
  const double wgsLon = 116.397477;
  final GeoPoint expectedGcj02 =
      wgs84ToGcj02(const GeoPoint(latitude: wgsLat, longitude: wgsLon));

  group('GPS acquisition ladder', () {
    test('high accuracy times out, the coarser retry succeeds', () async {
      final _ScriptedGeolocator platform = _ScriptedGeolocator(
        outcomes: <Object>[
          TimeoutException('cold start: no GNSS lock in 20 s'),
          _wgsFix(wgsLat, wgsLon, accuracy: 42),
        ],
      );
      GeolocatorPlatform.instance = platform;

      final LocationResult result =
          await const GeolocatorCurrentLocation().currentLocation();

      expect(result.ok, isTrue, reason: result.detail);
      expect(result.failure, isNull);
      // Exactly two attempts: no more, no fewer.
      expect(platform.positionCalls, 2);
      // Rung order and the pinned caps.
      expect(platform.requestedAccuracy,
          <LocationAccuracy>[LocationAccuracy.high, LocationAccuracy.medium]);
      expect(platform.requestedTimeLimit,
          <Duration>[const Duration(seconds: 20), const Duration(seconds: 15)]);
      // Access re-checked before EVERY rung.
      expect(platform.permissionChecks, 2);
      // GCJ-02, converted exactly once, and the accuracy is the
      // retry's own (a real number, not a guess).
      final GeoPoint point = result.pointGcj02!;
      expect(point.latitude, closeTo(expectedGcj02.latitude!, 1e-9));
      expect(point.longitude, closeTo(expectedGcj02.longitude!, 1e-9));
      expect(point.latitude, isNot(closeTo(wgsLat, 1e-9)));
      expect(result.accuracyM, 42);
    });

    test('both rungs time out: one honest failure, no coordinate', () async {
      final _ScriptedGeolocator platform = _ScriptedGeolocator(
        outcomes: <Object>[
          TimeoutException('rung 1 timed out'),
          TimeoutException('rung 2 timed out'),
        ],
      );
      GeolocatorPlatform.instance = platform;

      final LocationResult result =
          await const GeolocatorCurrentLocation().currentLocation();

      expect(result.ok, isFalse);
      expect(result.pointGcj02, isNull);
      expect(result.failure, LocationFailure.failed);
      expect(platform.positionCalls, 2);
      // The detail has to show that BOTH rungs ran, otherwise a
      // log reader cannot tell a slow device from a single
      // unlucky attempt.
      expect(result.detail, contains('2 次尝试'));
      expect(result.detail, contains('高精度 20 秒'));
      expect(result.detail, contains('一般精度 15 秒'));
    });

    test('a non-timeout platform error also falls through to the retry',
        () async {
      final _ScriptedGeolocator platform = _ScriptedGeolocator(
        outcomes: <Object>[
          PlatformException(code: 'location', message: 'engine error'),
          _wgsFix(wgsLat, wgsLon, accuracy: 30),
        ],
      );
      GeolocatorPlatform.instance = platform;

      final LocationResult result =
          await const GeolocatorCurrentLocation().currentLocation();

      expect(result.ok, isTrue, reason: result.detail);
      expect(platform.positionCalls, 2);
    });
  });

  group('the retry never swallows an access failure', () {
    test('permission denied: zero fix attempts, permissionDenied returned',
        () async {
      final _ScriptedGeolocator platform = _ScriptedGeolocator(
        permission: LocationPermission.denied,
        outcomes: <Object>[_wgsFix(wgsLat, wgsLon)],
      );
      GeolocatorPlatform.instance = platform;

      final LocationResult result =
          await const GeolocatorCurrentLocation().currentLocation();

      expect(result.failure, LocationFailure.permissionDenied);
      expect(result.ok, isFalse);
      // Proof the retry did not re-ask: the platform was never
      // asked for a position at all.
      expect(platform.positionCalls, 0);
    });

    test('permission denied forever: zero fix attempts', () async {
      final _ScriptedGeolocator platform = _ScriptedGeolocator(
        permission: LocationPermission.deniedForever,
        outcomes: <Object>[_wgsFix(wgsLat, wgsLon)],
      );
      GeolocatorPlatform.instance = platform;

      final LocationResult result =
          await const GeolocatorCurrentLocation().currentLocation();

      expect(result.failure, LocationFailure.permissionDeniedForever);
      expect(platform.positionCalls, 0);
    });

    test('service switched off: zero fix attempts, no retry', () async {
      final _ScriptedGeolocator platform = _ScriptedGeolocator(
        serviceEnabled: false,
        outcomes: <Object>[_wgsFix(wgsLat, wgsLon)],
      );
      GeolocatorPlatform.instance = platform;

      final LocationResult result =
          await const GeolocatorCurrentLocation().currentLocation();

      expect(result.failure, LocationFailure.serviceDisabled);
      expect(platform.positionCalls, 0);
      // Not even the permission gate is reached: the service is
      // off, and that is returned straight away.
      expect(platform.permissionChecks, 0);
    });
  });
}
