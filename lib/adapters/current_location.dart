/// Current-location adapter for Mingtu AI (navigation core).
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
///
/// Acquisition ladder (real-device fix, 2026-11): a single
/// high-accuracy request with a 15 s cap failed on every cold
/// start and indoors (the GNSS chip has no lock yet), and the
/// blind user heard nothing but silence followed by a dead end.
/// [GeolocatorCurrentLocation.currentLocation] now walks the
/// pinned [_fixRungs] ladder instead: a high-accuracy attempt
/// first, then ONE coarser retry that the fused/network
/// provider can usually answer. Both rungs are real platform
/// fixes -- the retry trades accuracy, never honesty: no
/// coordinate is invented, and a fix that is too coarse is
/// refused by the caller (core/real_navigation.dart), which
/// announces it aloud. Permission and service problems are
/// re-checked before every rung and returned as-is: they are
/// the user's to fix and are never swallowed by a retry.
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

  /// Ground speed reported by the fix itself, m/s, when
  /// the platform supplied a usable one (NAVHAZ M1 fix
  /// round: this is the ego-motion judge's GPS source).
  /// Null when unknown or negative (the platform's
  /// "no speed" sentinel).
  final double? speedMps;

  final LocationFailure? failure;

  /// Human-readable Chinese detail for status display / logs.
  final String detail;

  const LocationResult._({
    this.pointGcj02,
    this.accuracyM,
    this.speedMps,
    this.failure,
    required this.detail,
  });

  factory LocationResult.fix(GeoPoint pointGcj02, double? accuracyM,
          {double? speedMps}) =>
      LocationResult._(
        pointGcj02: pointGcj02,
        accuracyM: accuracyM,
        speedMps: speedMps,
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

  /// One rung of the acquisition ladder: which platform accuracy
  /// to ask for, and how long the platform may take to answer.
  /// [label] is never spoken -- it only labels the rung inside
  /// the diagnostic detail of a final failure, so a log reader
  /// can tell that BOTH rungs were actually tried.
  static const List<_FixRung> _fixRungs = <_FixRung>[
    // Rung 1: the good fix. Pinned at 20 s (the pre-fix code used
    // 15 s, which a cold GNSS start routinely exceeds).
    _FixRung('高精度 20 秒', LocationAccuracy.high, Duration(seconds: 20)),
    // Rung 2: the forgiving fix. A coarser source (fused /
    // network assisted) answers far more often indoors; a real
    // fix with a worse accuracy number is honest, a fabricated
    // one is not.
    _FixRung('一般精度 15 秒', LocationAccuracy.medium, Duration(seconds: 15)),
  ];

  @override
  Future<LocationResult> currentLocation() async {
    final List<String> attempts = <String>[];
    try {
      for (final _FixRung rung in _fixRungs) {
        // Access is re-verified before EVERY rung: a permission or
        // service problem must surface as itself, not as a retried
        // timeout.
        final LocationResult? blocked = await _accessFailure();
        if (blocked != null) return blocked;
        try {
          final Position position = await Geolocator.getCurrentPosition(
            locationSettings: LocationSettings(
              accuracy: rung.accuracy,
              timeLimit: rung.timeLimit,
            ),
          );
          // The platform fix is WGS-84; convert exactly once, here.
          final GeoPoint gcj02 = wgs84ToGcj02(
            GeoPoint(
              latitude: position.latitude,
              longitude: position.longitude,
            ),
          );
          return LocationResult.fix(gcj02, position.accuracy,
              speedMps: position.speed >= 0 ? position.speed : null);
        } catch (e) {
          // Timeout / platform error on THIS rung only: record it
          // and let the ladder fall through to the next rung.
          attempts.add('${rung.label}：$e');
        }
      }
      return LocationResult.error(
        LocationFailure.failed,
        '定位失败：${_fixRungs.length} 次尝试都没有取得位置'
        '（${attempts.join('；')}）。',
      );
    } catch (e) {
      // A throw from the access checks themselves (missing plugin,
      // platform error): still one honest failure, never a guess.
      return LocationResult.error(
        LocationFailure.failed,
        '定位失败：$e',
      );
    }
  }

  /// The access gate shared by every rung of the ladder. Returns
  /// the matching failure when a fix may NOT be attempted, or
  /// null when it may.
  Future<LocationResult?> _accessFailure() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationResult.error(
        LocationFailure.serviceDisabled,
        '设备定位服务未开启。',
      );
    }
    final LocationPermission permission = await Geolocator.checkPermission();
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
    return null;
  }

  @override
  Future<bool> ensurePermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      final LocationPermission permission = await Geolocator.checkPermission();
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
        return LocationResult.fix(gcj02, position.accuracy,
            speedMps: position.speed >= 0 ? position.speed : null);
      }).transform(
          StreamTransformer<LocationResult, LocationResult>.fromHandlers(
        handleError: (error, stackTrace, sink) {
          sink.add(LocationResult.error(LocationFailure.failed, '定位信号中断。'));
        },
      ));
    } catch (_) {
      return Stream<LocationResult>.value(
        LocationResult.error(LocationFailure.failed, '定位信号中断。'),
      );
    }
  }
}

/// One rung of the GPS acquisition ladder (see
/// [GeolocatorCurrentLocation._fixRungs]).
class _FixRung {
  const _FixRung(this.label, this.accuracy, this.timeLimit);

  /// Diagnostic label for the final failure detail. Never spoken.
  final String label;

  /// Platform accuracy this rung asks for.
  final LocationAccuracy accuracy;

  /// Cap on this rung; the platform throws a timeout past it.
  final Duration timeLimit;
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
