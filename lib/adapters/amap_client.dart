/// Amap (高德) walking-route client for Mingtu AI.
///
/// The app NEVER calls Amap directly and NEVER holds the Amap Web
/// Service key. It calls the project's own route proxy
/// (server/amap_proxy.py), which holds the key in its server-side
/// environment and forwards to the Amap Web Service walking API:
///   GET {proxyBaseUrl}/walking?origin=lon,lat&destination=lon,lat
/// The proxy answers with a response REBUILT from whitelisted
/// fields: per step it forwards only the ENUM fields action /
/// orientation, the numeric distance / duration and a validated
/// polyline. The upstream free-text instruction is never forwarded,
/// so the spoken prompt below is generated locally from enums --
/// no upstream sentence can reach the user's ears verbatim.
/// Coordinates
/// are "lon,lat" (longitude first) and GCJ-02 end to end: origins
/// come from the GPS adapter already converted (see
/// core/coordinate_convert.dart), destinations from
/// config/verified_locations.dart (GCJ-02, human-verified).
///
/// Honesty limits, enforced by construction:
/// - The route's accessibility is UNKNOWN. Amap returns no blind-path
///   / tactile-paving information, so the candidate built from a real
///   route still scores with the UNKNOWN penalty (see route_scoring).
///   A real Amap route is a real walking route, NOT a "safe route".
/// - Without a configured proxy base URL the client is not called
///   at all and reports NOT_CONFIGURED; coordinates are never
///   invented.
/// - The default transport uses dart:io HttpClient (same pattern as
///   BailianClient). Tests inject a fake [AmapSender] so no test ever
///   makes a real call.
library;

import 'dart:convert';
import 'dart:io';

import '../core/route_scoring.dart';
import '../modules/map_navigation.dart';

/// Sends one GET and returns the raw response body. URLs here go to
/// the project's own proxy and carry no credential.
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

/// The step actions the proxy may forward (fixed enum; anything
/// else was already dropped server-side, and is dropped again
/// here -- a rogue response cannot smuggle free text in through
/// the action field).
const Set<String> amapStepActions = <String>{
  '左转',
  '右转',
  '向左前方',
  '向右前方',
  '向左后方',
  '向右后方',
  '直行',
  '靠左',
  '靠右',
  '通过路口',
  '调头',
  '到达',
};

/// The step orientations (compass directions) the proxy may
/// forward, same fixed-enum rule.
const Set<String> amapStepOrientations = <String>{
  '东',
  '南',
  '西',
  '北',
  '东北',
  '东南',
  '西北',
  '西南',
};

/// One walking step from Amap, reduced to enum + numeric fields:
/// an [action] (e.g. 左转）, an [orientation] (e.g. 东）, the step
/// polyline and its distance / duration. There is deliberately NO
/// free-text instruction: the spoken prompt is generated from the
/// enums by [AmapStepSpeaker], never copied from the provider.
class AmapStep {
  final String action;
  final String orientation;
  final List<GeoPoint> polyline;
  final double distanceM;
  final double durationS;
  const AmapStep({
    required this.action,
    required this.orientation,
    required this.polyline,
    required this.distanceM,
    required this.durationS,
  });
}

String _enumField(Object? value, Set<String> allowed) =>
    value is String && allowed.contains(value) ? value : '';

/// Generate the spoken Chinese prompt for one step from its ENUM
/// fields + distance. This is the only place step speech text is
/// produced, and it can only ever combine fixed enum words with a
/// number -- upstream free text has no path into it.
String amapStepSpeechText({
  required String action,
  required String orientation,
  required double distanceM,
}) {
  final String direction = orientation.isEmpty ? '' : '朝$orientation方向';
  final String act;
  if (action == '到达') {
    act = '前方到达目的地附近';
  } else if (action.isEmpty) {
    act = '继续前行';
  } else {
    act = action;
  }
  final String head = direction.isEmpty ? act : '$direction$act';
  return '$head，约 ${distanceM.toStringAsFixed(0)} 米';
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

/// Speaks Amap walking steps one at a time, in order, for a blind
/// user. v0.7: before this, a real Amap route only announced its
/// total distance and left the step instructions as screen text.
/// The speaker never invents a step: when the steps run out it says
/// so and returns null.
class AmapStepSpeaker {
  final List<AmapStep> steps;
  int _index = 0;

  AmapStepSpeaker(this.steps);

  int get remaining => steps.length - _index;
  bool get isDone => _index >= steps.length;

  /// The next step's spoken text, generated from the step's enum
  /// fields, or null when all steps are spoken.
  String? nextStepText() {
    if (isDone) return null;
    final AmapStep step = steps[_index];
    _index += 1;
    return '${amapStepSpeechText(action: step.action, orientation: step.orientation, distanceM: step.distanceM)}。'
        '（第 $_index 段，共 ${steps.length} 段）';
  }

  void reset() {
    _index = 0;
  }
}

class AmapWalkingClient {
  /// Base URL of the route proxy (no trailing path; the client
  /// appends /walking). Empty means the proxy is not deployed or
  /// not configured -- the client then makes no call at all.
  final String proxyBaseUrl;
  final AmapSender sender;

  AmapWalkingClient({
    required this.proxyBaseUrl,
    AmapSender? sender,
  }) : sender = sender ?? _defaultSender;

  bool get isConfigured => proxyBaseUrl.isNotEmpty;

  /// Fetch one walking route via the proxy. No call is made when
  /// the proxy is not configured. [from] / [to] must have GCJ-02
  /// coordinates; a missing coordinate is a caller error, reported
  /// as ERROR without a network call. The request intentionally
  /// contains NO key parameter: the key exists only server-side.
  Future<AmapWalkingResult> walkingRoute({
    required GeoPoint from,
    required GeoPoint to,
  }) async {
    if (!isConfigured) {
      return const AmapWalkingResult(
        status: 'NOT_CONFIGURED',
        error: '路线代理未部署或未配置（MINGTU_ROUTE_PROXY_URL 为空），未请求路线。',
      );
    }
    if (!from.hasCoordinates || !to.hasCoordinates) {
      return const AmapWalkingResult(
        status: 'ERROR',
        error: '起点或终点缺少坐标，未请求路线。',
      );
    }
    final String base = proxyBaseUrl.endsWith('/')
        ? proxyBaseUrl.substring(0, proxyBaseUrl.length - 1)
        : proxyBaseUrl;
    final Uri url =
        Uri.parse('$base/walking').replace(queryParameters: <String, String>{
      'origin':
          '${from.longitude!.toStringAsFixed(6)},${from.latitude!.toStringAsFixed(6)}',
      'destination':
          '${to.longitude!.toStringAsFixed(6)},${to.latitude!.toStringAsFixed(6)}',
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
        final String info =
            decoded['info'] is String ? decoded['info'] as String : '未知';
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
            action: _enumField(raw['action'], amapStepActions),
            orientation: _enumField(raw['orientation'], amapStepOrientations),
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
      // No credential exists on the client side, so the transport
      // error text cannot leak one; it may contain the proxy URL,
      // which is not a secret.
      return AmapWalkingResult(status: 'ERROR', error: e.toString());
    }
  }
}
