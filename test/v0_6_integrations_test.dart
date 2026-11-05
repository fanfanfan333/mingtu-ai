import 'dart:convert';

import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/adapters/yolo_detector.dart';
import 'package:mingtu_ai/core/route_scoring.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';
import 'package:test/test.dart';

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

void main() {
  test('parseLonLat accepts lon,lat and rejects garbage', () {
    final GeoPoint? p = parseLonLat('116.400000,39.900000');
    expect(p?.longitude, closeTo(116.4, 1e-9));
    expect(p?.latitude, closeTo(39.9, 1e-9));
    expect(parseLonLat('39.9,116.4,1'), isNull);
    expect(parseLonLat('not-a-point'), isNull);
    expect(parseLonLat('999,39.9'), isNull);
    expect(parseLonLat(''), isNull);
  });

  test('amap walking route parses distance, steps and polyline', () async {
    bool called = false;
    final AmapWalkingClient client = AmapWalkingClient(
      apiKey: 'test-key',
      sender: (Uri url) async {
        called = true;
        expect(url.host, 'restapi.amap.com');
        expect(url.queryParameters['origin'], '116.400000,39.900000');
        expect(url.queryParameters['destination'], '116.401000,39.900900');
        expect(url.queryParameters['output'], 'json');
        return _amapOkBody;
      },
    );
    final AmapWalkingResult result = await client.walkingRoute(
      from: parseLonLat('116.400000,39.900000')!,
      to: parseLonLat('116.401000,39.900900')!,
    );
    expect(called, isTrue);
    expect(result.ok, isTrue);
    expect(result.distanceM, 186);
    expect(result.durationS, 150);
    expect(result.steps.length, 2);
    expect(result.steps.first.instruction, '向北步行80米');
    expect(result.polyline.length, 4);
    // The real route is still UNKNOWN accessibility by construction:
    // Amap gives no blind-path data, so it must never score as safe.
    final RouteCandidate? candidate = result.candidate;
    expect(candidate, isNotNull);
    expect(candidate!.accessibility, AccessibilityStatus.unknown);
    expect(candidate.accessibilityMissingCost, 1.0);
    expect(candidate.dataConfidence, 0.8);
  });

  test('amap without a key makes no network call', () async {
    final AmapWalkingClient client = AmapWalkingClient(
      apiKey: '',
      sender: (Uri url) async {
        fail('must not call the network without a key');
      },
    );
    final AmapWalkingResult result = await client.walkingRoute(
      from: parseLonLat('116.4,39.9')!,
      to: parseLonLat('116.401,39.9009')!,
    );
    expect(result.status, 'NOT_CONFIGURED');
    expect(result.candidate, isNull);
  });

  test('amap error status is reported and the key is never leaked', () async {
    final AmapWalkingClient client = AmapWalkingClient(
      apiKey: 'secret-key-123',
      sender: (Uri url) async {
        // Simulate a transport failure whose message contains the URL.
        throw Exception('GET $url failed');
      },
    );
    final AmapWalkingResult result = await client.walkingRoute(
      from: parseLonLat('116.4,39.9')!,
      to: parseLonLat('116.401,39.9009')!,
    );
    expect(result.status, 'ERROR');
    expect(result.error, isNot(contains('secret-key-123')));
    expect(result.error, contains('[REDACTED]'));
  });

  test('amap status 0 returns the provider info, not a route', () async {
    final AmapWalkingClient client = AmapWalkingClient(
      apiKey: 'k',
      sender: (Uri url) async => jsonEncode(<String, Object>{
        'status': '0',
        'info': 'INVALID_USER_KEY',
      }),
    );
    final AmapWalkingResult result = await client.walkingRoute(
      from: parseLonLat('116.4,39.9')!,
      to: parseLonLat('116.401,39.9009')!,
    );
    expect(result.ok, isFalse);
    expect(result.error, contains('INVALID_USER_KEY'));
  });

  test('yolo result mapping uses the normalised box centre', () {
    final detection = yoloResultToDetection(
      label: 'person',
      confidence: 0.9,
      centerX: 0.5,
      centerY: 0.4,
    );
    expect(detection.label, 'person');
    expect(detection.cx, 0.5);
    expect(detection.cy, 0.4);
    // Out-of-range values are clamped, never trusted as-is.
    final clamped = yoloResultToDetection(
      label: 'car',
      confidence: 1.5,
      centerX: 1.2,
      centerY: -0.1,
    );
    expect(clamped.confidence, 1.0);
    expect(clamped.cx, 1.0);
    expect(clamped.cy, 0.0);
  });

  test('unavailable yolo detector returns no detections, never fakes', () async {
    final YoloDetector detector = UnavailableYoloDetector();
    expect(detector.isAvailable, isFalse);
    expect(await detector.detectImage(<int>[1, 2, 3]), isEmpty);
  });
}
