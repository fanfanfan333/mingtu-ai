/// Amap (高德) walking-route client for Mingtu AI.
///
/// Two modes (see [AmapRouteMode]; selected by
/// [selectAmapRouteMode]):
///
/// - proxy (the production rule): the app calls the project's own
///   route proxy (server/amap_proxy.py), which holds the Amap key
///   in its server-side environment and forwards to Amap. The
///   proxy answers with a response rebuilt from whitelisted
///   fields.
/// - directDemo (USER DECISION for the demo build only): the app
///   calls Amap directly with a DISPOSABLE demo key injected at
///   build time via --dart-define=MINGTU_AMAP_KEY. The value is
///   never in the repository, never logged and never included in
///   any error text (request URLs carry it, so URLs are never
///   surfaced). A key compiled into an APK is extractable: the
///   demo key MUST be regenerated/revoked by the user after the
///   demo (see README). This mode exists only because the user
///   explicitly chose it for the demo.
///
/// In BOTH modes the response is parsed with the SAME structured
/// rules: per step only the ENUM fields action / orientation, the
/// BOUNDED numeric distance / duration and a strictly validated
/// polyline are read. The upstream free-text instruction is never
/// used, so the spoken prompt is generated locally from enums --
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
///   the vision client). Tests inject a fake [AmapSender] so no test ever
///   makes a real call.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/hazard/hazard_phrases.dart';
import '../core/route_scoring.dart';
import '../modules/map_navigation.dart';

/// Sends one GET and returns the raw response body.
typedef AmapSender = Future<String> Function(Uri url);

/// A URL that is safe to embed in an error or a log line:
/// scheme, host, port and path only. In direct demo mode the
/// request URL's QUERY carries the demo key, so the full URL
/// must never appear in an exception or a log.
Uri redactUrlForError(Uri url) => Uri(
      scheme: url.scheme,
      host: url.host,
      port: url.hasPort ? url.port : null,
      path: url.path,
    );

/// The default transport. On a non-2xx status it throws an
/// [HttpException] whose uri is REDACTED via [redactUrlForError]
/// (host + path only, no query): the exception's toString() can
/// therefore never contain the demo key.
Future<String> amapHttpSender(Uri url) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.getUrl(url);
    final HttpClientResponse response = await request.close();
    final String body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Amap HTTP ${response.statusCode}',
        uri: redactUrlForError(url),
      );
    }
    return body;
  } finally {
    client.close();
  }
}

/// How the walking route is fetched. Selected once from the
/// build-time configuration; the current mode is announced to
/// the user in Chinese ([amapRouteModeSpeech]) so a blind user
/// always knows which path their route came from.
enum AmapRouteMode { directDemo, proxy, unconfigured }

/// Mode selection: a demo key wins (direct), else a proxy URL
/// (proxy), else unconfigured. The demo key is a build-time
/// value only -- it never appears in the repository.
AmapRouteMode selectAmapRouteMode({
  required String demoKey,
  required String proxyUrl,
}) {
  if (demoKey.isNotEmpty) return AmapRouteMode.directDemo;
  if (proxyUrl.isNotEmpty) return AmapRouteMode.proxy;
  return AmapRouteMode.unconfigured;
}

/// The exact Chinese announcement of the current route mode.
String amapRouteModeSpeech(AmapRouteMode mode) {
  switch (mode) {
    case AmapRouteMode.directDemo:
      return '当前路线模式：演示直连。用构建时注入的演示密钥直连高德，'
          '该密钥演示后作废。';
    case AmapRouteMode.proxy:
      return '当前路线模式：经自建代理获取路线，密钥只在服务器上。';
    case AmapRouteMode.unconfigured:
      return '路线服务未配置：没有演示密钥，也没有代理地址，'
          '无法获取真实路线。';
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
  // Step distance wording: the FIX3B navigation bands
  // (announcement-ready form from navigationDistanceText).
  // CDX5 S2-1: an abnormal distance (non-finite /
  // negative, e.g. a malformed upstream payload) yields
  // the EMPTY readout; the step text then stands alone
  // as a complete sentence instead of ending in a
  // dangling separator with no distance after it.
  final String distanceText = navigationDistanceText(distanceM);
  if (distanceText.isEmpty) return head;
  return '$head，$distanceText';
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

final RegExp _coordPart = RegExp(r'^-?\d{1,3}(\.\d{1,6})?$');

/// Strict polyline parse (same rules as the proxy): each
/// component must be plain decimal notation with at most 6
/// decimals (no exponent forms), lon/lat in range, at most 500
/// points. Invalid pairs are dropped, never guessed.
List<GeoPoint> _parsePolyline(String raw) {
  final List<GeoPoint> points = [];
  for (final String pair in raw.split(';')) {
    if (points.length >= 500) break;
    final List<String> parts = pair.trim().split(',');
    if (parts.length != 2) continue;
    if (!_coordPart.hasMatch(parts[0].trim()) ||
        !_coordPart.hasMatch(parts[1].trim())) {
      continue;
    }
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

/// A route number, bounded: junk/NaN becomes 0, negatives become
/// 0, anything above [max] clamps to [max] (100 km / 24 h at the
/// call sites). An upstream cannot smuggle an absurd (or
/// key-shaped) magnitude through a numeric field.
double _boundedNum(Object? value, double max) {
  final double n = _asDouble(value);
  if (n.isNaN || n.isInfinite || n < 0) return 0;
  return n > max ? max : n;
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
  /// Base URL of the route proxy (proxy mode; no trailing path --
  /// the client appends /walking).
  final String proxyBaseUrl;

  /// The disposable DEMO key (directDemo mode), injected at build
  /// time via --dart-define=MINGTU_AMAP_KEY. Never in the
  /// repository, never logged, never copied into any result or
  /// error text: request URLs carry it, so URLs are never
  /// surfaced anywhere.
  final String demoKey;

  /// The selected route mode (see [selectAmapRouteMode]).
  final AmapRouteMode mode;

  final AmapSender sender;

  /// Per-request timeout; a slow route service degrades aloud
  /// instead of hanging a blind user's navigation start.
  final Duration requestTimeout;

  AmapWalkingClient({
    required this.proxyBaseUrl,
    this.demoKey = '',
    AmapSender? sender,
    this.requestTimeout = const Duration(seconds: 10),
  })  : mode = selectAmapRouteMode(demoKey: demoKey, proxyUrl: proxyBaseUrl),
        sender = sender ?? amapHttpSender;

  bool get isConfigured => mode != AmapRouteMode.unconfigured;

  /// Fetch one walking route in the selected mode. [from] / [to]
  /// must have GCJ-02 coordinates; a missing coordinate is a
  /// caller error, reported as ERROR without a network call.
  ///
  /// Error hygiene: every error text here is a FIXED generic
  /// sentence. Upstream `info` free text is never copied, and the
  /// transport exception is never stringified -- in directDemo
  /// mode it can embed the request URL, which carries the demo
  /// key.
  Future<AmapWalkingResult> walkingRoute({
    required GeoPoint from,
    required GeoPoint to,
  }) async {
    if (!isConfigured) {
      return const AmapWalkingResult(
        status: 'NOT_CONFIGURED',
        error: '路线服务未配置（无演示密钥、无代理地址），未请求路线。',
      );
    }
    if (!from.hasCoordinates || !to.hasCoordinates) {
      return const AmapWalkingResult(
        status: 'ERROR',
        error: '起点或终点缺少坐标，未请求路线。',
      );
    }
    final String origin =
        '${from.longitude!.toStringAsFixed(6)},${from.latitude!.toStringAsFixed(6)}';
    final String destination =
        '${to.longitude!.toStringAsFixed(6)},${to.latitude!.toStringAsFixed(6)}';
    final Uri url;
    if (mode == AmapRouteMode.directDemo) {
      url = Uri.parse('https://restapi.amap.com/v3/direction/walking')
          .replace(queryParameters: <String, String>{
        'origin': origin,
        'destination': destination,
        'key': demoKey,
        'output': 'json',
      });
    } else {
      final String base = proxyBaseUrl.endsWith('/')
          ? proxyBaseUrl.substring(0, proxyBaseUrl.length - 1)
          : proxyBaseUrl;
      url =
          Uri.parse('$base/walking').replace(queryParameters: <String, String>{
        'origin': origin,
        'destination': destination,
        'output': 'json',
      });
    }
    final String body;
    try {
      body = await sender(url).timeout(requestTimeout);
    } on TimeoutException {
      return const AmapWalkingResult(
        status: 'ERROR',
        error: '路线请求超时，已降级：未获取路线，导航未启动。',
      );
    } catch (_) {
      return const AmapWalkingResult(
        status: 'ERROR',
        error: '路线请求失败（网络或服务错误），已降级：未获取路线。',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return const AmapWalkingResult(
        status: 'ERROR',
        error: '路线服务返回不是预期的 JSON，已降级。',
      );
    }
    if (decoded is! Map<String, Object?>) {
      return const AmapWalkingResult(
        status: 'ERROR',
        error: '路线服务返回不是预期的 JSON 对象，已降级。',
      );
    }
    if (decoded['status'] != '1') {
      // The upstream `info` free text is deliberately NOT copied
      // (structured-output rule; it could contain anything).
      return const AmapWalkingResult(
        status: 'ERROR',
        error: '路线服务返回失败状态，未获取路线，已降级。',
      );
    }
    final Object? route = decoded['route'];
    if (route is! Map<String, Object?>) {
      return const AmapWalkingResult(
        status: 'ERROR',
        error: '路线服务返回没有 route，已降级。',
      );
    }
    final Object? paths = route['paths'];
    if (paths is! List || paths.isEmpty || paths.first is! Map) {
      return const AmapWalkingResult(
        status: 'ERROR',
        error: '路线服务返回没有 paths，已降级。',
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
          distanceM: _boundedNum(raw['distance'], 100000),
          durationS: _boundedNum(raw['duration'], 86400),
        ));
      }
    }
    return AmapWalkingResult(
      status: 'ok',
      distanceM: _boundedNum(path['distance'], 100000),
      durationS: _boundedNum(path['duration'], 86400),
      steps: steps,
      polyline: polyline,
    );
  }
}
