/// Current-location adapter for Mingtu AI (navigation P0).
///
/// Contract: one call returns either a single GPS fix -- already
/// converted to GCJ-02, with its accuracy -- or one explicit
/// failure. Nothing here throws to the caller and nothing invents
/// a position: a blind user must hear "定位失败" rather than be
/// navigated from a guessed point.
///
/// Coordinate basis (see core/coordinate_convert.dart): the
/// platform location APIs return WGS-84, and the `geolocator`
/// plugin passes those values through unchanged, so the fix is
/// converted WGS-84 -> GCJ-02 **exactly once**, here, before any
/// other code sees it. Verified destinations are already GCJ-02
/// and never pass through this adapter.
library;

import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../core/coordinate_convert.dart';
import '../modules/map_navigation.dart';

enum LocationFailure {
  /// Location services are switched off on the device.
  serviceDisabled,

  /// The user denied the runtime permission (may be asked again).
  permissionDenied,

  /// Permission permanently denied; only system settings can fix it.
  permissionDeniedForever,

  /// Timeout, platform error, or a fix without coordinates.
  failed,
}

class LocationResult {
  /// GCJ-02 position when [ok]; null on any failure.
  final GeoPoint? pointGcj02;

  /// Horizontal accuracy in metres of the fix, when known.
  final double? accuracyM;

  final LocationFailure? failure;

  /// Human-readable Chinese detail for status display / logs.
  final String detail;

  const LocationResult._({
    this.pointGcj02,
    this.accuracyM,
    this.failure,
    required this.detail,
  });

  factory LocationResult.fix(GeoPoint pointGcj02, double? accuracyM) =>
      LocationResult._(
        pointGcj02: pointGcj02,
        accuracyM: accuracyM,
        detail: '已取得当前位置（GCJ-02，精度 '
            '${accuracyM == null ? '未知' : '${accuracyM.toStringAsFixed(0)} 米'}）。',
      );

  factory LocationResult.error(LocationFailure failure, String detail) =>
      LocationResult._(failure: failure, detail: detail);

  bool get ok => pointGcj02 != null;
}

abstract class CurrentLocationProvider {
  Future<LocationResult> currentLocation();

  /// Ask for the location permission up front (step 2: the
  /// app requests permissions at startup instead of failing
  /// later). Defaults to false for providers without a real
  /// device behind them; never throws.
  Future<bool> ensurePermission() async => false;

  /// Continuous fixes for live navigation tracking, each
  /// already converted to GCJ-02 exactly once. Defaults to an
  /// empty stream for providers that cannot stream.
  Stream<LocationResult> positions() => const Stream<LocationResult>.empty();
}

/// Real implementation on the phone's GPS via geolocator.
/// In the VM / tests there is no GPS; calls end in
/// [LocationFailure.failed] and callers announce that honestly.
class GeolocatorCurrentLocation implements CurrentLocationProvider {
  const GeolocatorCurrentLocation();

  @override
  Future<LocationResult> currentLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return LocationResult.error(
          LocationFailure.serviceDisabled,
          '设备定位服务未开启。',
        );
      }
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        return LocationResult.error(
          LocationFailure.permissionDeniedForever,
          '定位权限已被永久拒绝，需要在系统设置里开启。',
        );
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.unableToDetermine) {
        return LocationResult.error(
          LocationFailure.permissionDenied,
          '定位权限被拒绝。',
        );
      }
      final Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      // The platform fix is WGS-84; convert exactly once, here.
      final GeoPoint gcj02 = wgs84ToGcj02(
        GeoPoint(latitude: position.latitude, longitude: position.longitude),
      );
      return LocationResult.fix(gcj02, position.accuracy);
    } catch (e) {
      return LocationResult.error(
        LocationFailure.failed,
        '定位失败：$e',
      );
    }
  }

  @override
  Future<bool> ensurePermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      return permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
    } catch (_) {
      return false;
    }
  }

  @override
  Stream<LocationResult> positions() {
    try {
      return Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).map((Position position) {
        // The platform fix is WGS-84; convert exactly once.
        final GeoPoint gcj02 = wgs84ToGcj02(
          GeoPoint(latitude: position.latitude, longitude: position.longitude),
        );
        return LocationResult.fix(gcj02, position.accuracy);
      });
    } catch (_) {
      return const Stream<LocationResult>.empty();
    }
  }
}

/// Always-unavailable provider (web without GPS, VM, tests that
/// want the failure path without a fake). Reports failure, never
/// a position.
class UnavailableCurrentLocation implements CurrentLocationProvider {
  const UnavailableCurrentLocation();

  @override
  Future<LocationResult> currentLocation() async => LocationResult.error(
        LocationFailure.failed,
        '当前环境没有可用的定位设备。',
      );

  @override
  Future<bool> ensurePermission() async => false;

  @override
  Stream<LocationResult> positions() => const Stream<LocationResult>.empty();
}
