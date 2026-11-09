import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';

/// Direct-demo mode tests (user decision: disposable demo key via
/// --dart-define at build time only). Fixtures only -- NO real
/// Amap call is ever made, and the "key" here is a fixture string.

const String _fixtureKey = 'fixture-demo-key-123';
const GeoPoint _from = GeoPoint(latitude: 39.9, longitude: 116.4);
const GeoPoint _to = GeoPoint(latitude: 39.91, longitude: 116.41);

String _amapOkBody() => jsonEncode(<String, Object>{
      'status': '1',
      'info': 'OK',
      'route': <String, Object>{
        'paths': <Object>[
          <String, Object>{
            'distance': '1200',
            'duration': '900',
            'steps': <Object>[
              <String, Object>{
                'instruction': '向北步行100米右转（自由文本，不得播报）',
                'action': '右转',
                'orientation': '北',
                'distance': '100',
                'duration': '80',
                'polyline': '116.400000,39.900000;116.400100,39.900100',
              },
              <String, Object>{
                'instruction': '到达',
                'action': '到达',
                'orientation': '',
                'distance': '999999999', // absurd: must clamp
                'duration': '60',
                'polyline': 'bad;1e2,39.9;116.410000,39.910000',
              },
            ],
          },
        ],
      },
    });

void main() {
  group('mode selection', () {
    test('demo key wins, else proxy, else unconfigured', () {
      expect(
        selectAmapRouteMode(demoKey: _fixtureKey, proxyUrl: 'https://p'),
        AmapRouteMode.directDemo,
      );
      expect(
        selectAmapRouteMode(demoKey: '', proxyUrl: 'https://p'),
        AmapRouteMode.proxy,
      );
      expect(
        selectAmapRouteMode(demoKey: '', proxyUrl: ''),
        AmapRouteMode.unconfigured,
      );
    });

    test('mode announcements are Chinese and name the mode', () {
      expect(amapRouteModeSpeech(AmapRouteMode.directDemo), contains('演示直连'));
      expect(amapRouteModeSpeech(AmapRouteMode.directDemo), contains('作废'));
      expect(amapRouteModeSpeech(AmapRouteMode.proxy), contains('代理'));
      expect(amapRouteModeSpeech(AmapRouteMode.unconfigured), contains('未配置'));
    });
  });

  group('direct demo client (fixture sender)', () {
    test(
        'calls restapi.amap.com with the key in the REQUEST, '
        'parses with the same structured rules', () async {
      Uri? seen;
      final AmapWalkingClient client = AmapWalkingClient(
        proxyBaseUrl: '',
        demoKey: _fixtureKey,
        sender: (Uri url) async {
          seen = url;
          return _amapOkBody();
        },
      );
      expect(client.mode, AmapRouteMode.directDemo);
      expect(client.isConfigured, isTrue);
      final AmapWalkingResult result =
          await client.walkingRoute(from: _from, to: _to);
      expect(result.ok, isTrue);
      expect(seen!.host, 'restapi.amap.com');
      expect(seen!.queryParameters['key'], _fixtureKey);
      // Structured rules: string numbers parse, absurd clamps,
      // steps are enums only, bad polyline pairs are dropped.
      expect(result.distanceM, 1200);
      expect(result.steps.length, 2);
      expect(result.steps[0].action, '右转');
      expect(result.steps[0].orientation, '北');
      expect(result.steps[1].distanceM, 100000); // clamped
      expect(result.polyline.length, 3); // 2 + 1 valid of second
      // The upstream instruction free text appears NOWHERE.
      final String speech = AmapStepSpeaker(result.steps).nextStepText()!;
      expect(speech, contains('朝北方向右转'));
      expect(speech, isNot(contains('自由文本')));
    });

    test('timeout degrades in Chinese and the error holds no key', () async {
      final AmapWalkingClient client = AmapWalkingClient(
        proxyBaseUrl: '',
        demoKey: _fixtureKey,
        sender: (Uri url) => Completer<String>().future,
        requestTimeout: const Duration(milliseconds: 60),
      );
      final AmapWalkingResult result =
          await client.walkingRoute(from: _from, to: _to);
      expect(result.ok, isFalse);
      expect(result.error, contains('超时'));
      expect(result.error, isNot(contains(_fixtureKey)));
    });

    test(
        'a transport error embedding the URL cannot leak the '
        'key into the result', () async {
      final AmapWalkingClient client = AmapWalkingClient(
        proxyBaseUrl: '',
        demoKey: _fixtureKey,
        sender: (Uri url) async => throw HttpException('boom', uri: url),
      );
      final AmapWalkingResult result =
          await client.walkingRoute(from: _from, to: _to);
      expect(result.error, isNot(contains(_fixtureKey)));
      expect(result.error, isNot(contains('key=')));
      expect(result.error, isNot(contains('restapi.amap.com')));
    });

    test(
        'an upstream failure whose info echoes the key is '
        'reduced to a fixed generic error', () async {
      final AmapWalkingClient client = AmapWalkingClient(
        proxyBaseUrl: '',
        demoKey: _fixtureKey,
        sender: (Uri url) async => jsonEncode(<String, Object>{
          'status': '0',
          'info': 'INVALID_USER_KEY $_fixtureKey',
        }),
      );
      final AmapWalkingResult result =
          await client.walkingRoute(from: _from, to: _to);
      expect(result.ok, isFalse);
      expect(result.error, isNot(contains(_fixtureKey)));
      expect(result.error, isNot(contains('INVALID_USER_KEY')));
    });
  });

  group('proxy mode unchanged in shape', () {
    test('proxy requests carry no key parameter', () async {
      Uri? seen;
      final AmapWalkingClient client = AmapWalkingClient(
        proxyBaseUrl: 'https://proxy.example.test',
        sender: (Uri url) async {
          seen = url;
          return _amapOkBody();
        },
      );
      expect(client.mode, AmapRouteMode.proxy);
      final AmapWalkingResult result =
          await client.walkingRoute(from: _from, to: _to);
      expect(result.ok, isTrue);
      expect(seen!.path, '/walking');
      expect(seen!.queryParameters.containsKey('key'), isFalse);
    });

    test('neither key nor proxy -> NOT_CONFIGURED, no call', () async {
      bool called = false;
      final AmapWalkingClient client = AmapWalkingClient(
        proxyBaseUrl: '',
        sender: (Uri url) async {
          called = true;
          return _amapOkBody();
        },
      );
      expect(client.mode, AmapRouteMode.unconfigured);
      final AmapWalkingResult result =
          await client.walkingRoute(from: _from, to: _to);
      expect(result.status, 'NOT_CONFIGURED');
      expect(called, isFalse);
    });
  });
}
