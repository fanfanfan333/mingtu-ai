/// Amap (高德) walking-route client for Mingtu AI (v0.6).
///
/// Uses the Amap Web Service walking API -- a plain HTTPS GET, no
/// Android SDK needed:
///   https://restapi.amap.com/v3/direction/walking
///   ?origin=lon,lat&destination=lon,lat&key=<Web 服务 Key>&output=json
/// Coordinates are "lon,lat" (longitude first). The key is a Web
/// Service key from the Amap console, supplied only via
/// `--dart-define=MINGTU_AMAP_KEY=...` (see AppConfig). It is NEVER
/// logged and NEVER appears in any error string: the request URL
/// contains the key, so errors carry the status / Amap info only.
///
/// Honesty limits, enforced by construction:
/// - The route's accessibility is UNKNOWN. Amap returns no blind-path
///   / tactile-paving information, so the candidate built from a real
///   route still scores with the UNKNOWN penalty (see route_scoring).
///   A real Amap route is a real walking route, NOT a "safe route".
/// - No GPS is wired yet: the caller supplies from/to coordinates
///   (read on site in the Amap app). Without them the client is not
///   called at all; coordinates are never invented.
/// - The default transport uses dart:io HttpClient (same pattern as
///   BailianClient). Tests inject a fake [AmapSender] so no test ever
///   makes a real call.
library;

import 'dart:convert';
import 'dart:io';

import '../core/route_scoring.dart';
import '../modules/map_navigation.dart';

/// Sends one GET and returns the raw response body. Must never log
/// the URL (it contains the key).
typedef AmapSender = Future<String> Function(Uri url);

Future<String> _defaultSender(Uri url) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.getUrl(url);
    final HttpClientResponse response = await request.close();
    final String body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Amap HTTP ${response.statusCode}', uri: url);
    }
    return body;
  } finally {
    client.close();
  }
}

/// One walking step from Amap: a spoken instruction, the road name,
/// the step polyline and its distance / duration.
class AmapStep {
  final String instruction;
  final String road;
  final List<GeoPoint> polyline;
  final double distanceM;
  final double durationS;
  const AmapStep({
    required this.instruction,
    required this.road,
    required this.polyline,
    required this.distanceM,
    required this.durationS,
  });
}

class AmapWalkingResult {
  /// 'ok' | 'NOT_CONFIGURED' | 'ERROR'
  final String status;
  final double? distanceM;
  final double? durationS;
  final List<AmapStep> steps;
  final List<GeoPoint> polyline;
  final String? error;
  const AmapWalkingResult({
    required this.status,
    this.distanceM,
    this.durationS,
    this.steps = const [],
    this.polyline = const [],
    this.error,
  });

  bool get ok => status == 'ok';

  /// The real route as one scored candidate. Accessibility is
  /// UNKNOWN by construction (see the file header); dataConfidence
  /// 0.8 says "real provider data", not "safe".
  RouteCandidate? get candidate => ok && distanceM != null
      ? RouteCandidate(
          id: 'amap-walking',
          distanceM: distanceM!,
          durationS: durationS ?? 0,
          accessibility: AccessibilityStatus.unknown,
          dataConfidence: 0.8,
        )
      : null;
}

/// Parse a "lon,lat" string (longitude first, <= 6 decimals).
/// Returns null for anything malformed -- the caller reports
/// NOT_CONFIGURED rather than guessing a point.
GeoPoint? parseLonLat(String value) {
  final List<String> parts = value.trim().split(',');
  if (parts.length != 2) return null;
  final double? lon = double.tryParse(parts[0].trim());
  final double? lat = double.tryParse(parts[1].trim());
  if (lon == null || lat == null) return null;
  if (lon < -180 || lon > 180 || lat < -90 || lat > 90) return null;
  return GeoPoint(latitude: lat, longitude: lon);
}

List<GeoPoint> _parsePolyline(String raw) {
  final List<GeoPoint> points = [];
  for (final String pair in raw.split(';')) {
    final GeoPoint? point = parseLonLat(pair);
    if (point != null) points.add(point);
  }
  return points;
}

double _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

class AmapWalkingClient {
  final String apiKey;
  final String baseUrl;
  final AmapSender sender;

  AmapWalkingClient({
    required this.apiKey,
    this.baseUrl = 'https://restapi.amap.com/v3/direction/walking',
    AmapSender? sender,
  }) : sender = sender ?? _defaultSender;

  bool get isConfigured => apiKey.isNotEmpty;

  String _redact(String value) =>
      apiKey.isEmpty ? value : value.replaceAll(apiKey, '[REDACTED]');

  /// Fetch one walking route. No call is made without a key.
  /// [from] / [to] must have coordinates; a missing coordinate is a
  /// caller error, reported as ERROR without a network call.
  Future<AmapWalkingResult> walkingRoute({
    required GeoPoint from,
    required GeoPoint to,
  }) async {
    if (!isConfigured) {
      return const AmapWalkingResult(
        status: 'NOT_CONFIGURED',
        error: '未提供高德 Web 服务 Key（--dart-define），未调用高德。',
      );
    }
    if (!from.hasCoordinates || !to.hasCoordinates) {
      return const AmapWalkingResult(
        status: 'ERROR',
        error: '未提供现场坐标（MINGTU_AMAP_FROM / MINGTU_AMAP_TO），未调用高德。',
      );
    }
    final Uri url = Uri.parse(baseUrl).replace(queryParameters: <String, String>{
      'origin':
          '${from.longitude!.toStringAsFixed(6)},${from.latitude!.toStringAsFixed(6)}',
      'destination':
          '${to.longitude!.toStringAsFixed(6)},${to.latitude!.toStringAsFixed(6)}',
      'key': apiKey,
      'output': 'json',
    });
    try {
      final String body = await sender(url);
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) {
        return const AmapWalkingResult(
          status: 'ERROR',
          error: '高德返回不是预期的 JSON 对象。',
        );
      }
      if (decoded['status'] != '1') {
        final String info = decoded['info'] is String
            ? decoded['info'] as String
            : '未知';
        return AmapWalkingResult(
          status: 'ERROR',
          error: '高德返回 status=${decoded['status']}，info=$info。',
        );
      }
      final Object? route = decoded['route'];
      if (route is! Map<String, Object?>) {
        return const AmapWalkingResult(
          status: 'ERROR',
          error: '高德返回没有 route。',
        );
      }
      final Object? paths = route['paths'];
      if (paths is! List || paths.isEmpty || paths.first is! Map) {
        return const AmapWalkingResult(
          status: 'ERROR',
          error: '高德返回没有 paths。',
        );
      }
      final Map<String, Object?> path = paths.first as Map<String, Object?>;
      final List<AmapStep> steps = [];
      final List<GeoPoint> polyline = [];
      final Object? rawSteps = path['steps'];
      if (rawSteps is List) {
        for (final Object? raw in rawSteps) {
          if (raw is! Map<String, Object?>) continue;
          final List<GeoPoint> stepLine = raw['polyline'] is String
              ? _parsePolyline(raw['polyline'] as String)
              : <GeoPoint>[];
          polyline.addAll(stepLine);
          steps.add(AmapStep(
            instruction:
                raw['instruction'] is String ? raw['instruction'] as String : '',
            road: raw['road'] is String ? raw['road'] as String : '',
            polyline: stepLine,
            distanceM: _asDouble(raw['distance']),
            durationS: _asDouble(raw['duration']),
          ));
        }
      }
      return AmapWalkingResult(
        status: 'ok',
        distanceM: _asDouble(path['distance']),
        durationS: _asDouble(path['duration']),
        steps: steps,
        polyline: polyline,
      );
    } catch (e) {
      return AmapWalkingResult(status: 'ERROR', error: _redact(e.toString()));
    }
  }
}
