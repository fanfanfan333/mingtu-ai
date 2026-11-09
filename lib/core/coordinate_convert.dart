/// Coordinate-system conversion for Mingtu AI (navigation P0).
///
/// Why this file exists, with the evidence stated once:
///
/// - Android's location APIs -- and therefore the `geolocator`
///   plugin, which is a thin wrapper over them -- return positions
///   in **WGS-84**. (Android SDK `Location` documentation; the
///   plugin adds no datum conversion of its own.)
/// - The Amap Web Service requires **GCJ-02** coordinates
///   (Amap's coordinate documentation: Web Service APIs take
///   GCJ-02 "火星坐标"). Feeding raw WGS-84 into it misplaces the
///   route by hundreds of metres inside China.
/// - Human-verified campus locations in
///   `config/verified_locations.dart` are recorded **in GCJ-02**
///   (read on site from Amap), so they must never pass through
///   this conversion.
///
/// Therefore the WGS-84 -> GCJ-02 transform below is applied
/// **exactly once**, inside the current-location adapter, at the
/// moment a platform fix enters the app. Nothing else in the app
/// converts: route requests, verified locations and Amap responses
/// are all GCJ-02 end to end. Double conversion is a bug the tests
/// pin against (converting an already-converted point must NOT be
/// what the adapter does -- it converts the raw platform values).
///
/// The transform is the standard published GCJ-02 offset algorithm
/// (the same polynomial/trigonometric form used by every public
/// implementation); outside the China bounding box coordinates are
/// returned unchanged, by the algorithm's own definition.
library;

import 'dart:math' as math;

import '../modules/map_navigation.dart';

const double _a = 6378245.0;
const double _ee = 0.00669342162296594323;

bool _outOfChina(double lon, double lat) =>
    lon < 72.004 || lon > 137.8347 || lat < 0.8293 || lat > 55.8271;

double _transformLat(double x, double y) {
  double ret = -100.0 +
      2.0 * x +
      3.0 * y +
      0.2 * y * y +
      0.1 * x * y +
      0.2 * math.sqrt(x.abs());
  ret += (20.0 * math.sin(6.0 * x * math.pi) +
          20.0 * math.sin(2.0 * x * math.pi)) *
      2.0 /
      3.0;
  ret += (20.0 * math.sin(y * math.pi) +
          40.0 * math.sin(y / 3.0 * math.pi)) *
      2.0 /
      3.0;
  ret += (160.0 * math.sin(y / 12.0 * math.pi) +
          320.0 * math.sin(y * math.pi / 30.0)) *
      2.0 /
      3.0;
  return ret;
}

double _transformLon(double x, double y) {
  double ret = 300.0 +
      x +
      2.0 * y +
      0.1 * x * x +
      0.1 * x * y +
      0.1 * math.sqrt(x.abs());
  ret += (20.0 * math.sin(6.0 * x * math.pi) +
          20.0 * math.sin(2.0 * x * math.pi)) *
      2.0 /
      3.0;
  ret += (20.0 * math.sin(x * math.pi) +
          40.0 * math.sin(x / 3.0 * math.pi)) *
      2.0 /
      3.0;
  ret += (150.0 * math.sin(x / 12.0 * math.pi) +
          300.0 * math.sin(x / 30.0 * math.pi)) *
      2.0 /
      3.0;
  return ret;
}

/// Convert one WGS-84 point (as returned by the platform location
/// APIs) to GCJ-02 (as required by Amap). Points outside China are
/// returned unchanged. A point without coordinates is returned
/// as-is -- callers must not invent coordinates to fill it.
GeoPoint wgs84ToGcj02(GeoPoint wgs84) {
  final double? lat = wgs84.latitude;
  final double? lon = wgs84.longitude;
  if (lat == null || lon == null) return wgs84;
  if (_outOfChina(lon, lat)) return wgs84;
  double dLat = _transformLat(lon - 105.0, lat - 35.0);
  double dLon = _transformLon(lon - 105.0, lat - 35.0);
  final double radLat = lat / 180.0 * math.pi;
  double magic = math.sin(radLat);
  magic = 1 - _ee * magic * magic;
  final double sqrtMagic = math.sqrt(magic);
  dLat = (dLat * 180.0) / ((_a * (1 - _ee)) / (magic * sqrtMagic) * math.pi);
  dLon = (dLon * 180.0) / (_a / sqrtMagic * math.cos(radLat) * math.pi);
  return GeoPoint(latitude: lat + dLat, longitude: lon + dLon);
}
