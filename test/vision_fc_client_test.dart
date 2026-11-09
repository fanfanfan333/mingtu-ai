import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/cloud_vision_client.dart';
import 'package:mingtu_ai/core/cloud_vision.dart';

/// FC vision client contract (user decision 2026-11-09):
/// Bailian via the server function only. Fixtures only -- the
/// "token" here is a fixture string, no real key exists in tests.

CloudVisionClient _client({
  String proxy = 'https://fc.example.test',
  String token = 'fixture-demo-token',
  VisionSender? sender,
}) =>
    CloudVisionClient(
      proxyBaseUrl: proxy,
      demoToken: token,
      sender: sender ??
          (Uri u, String b, Map<String, String> h) async =>
              '{"scene":"室内","obstacles":[],"parsed":true}',
      downsampler: (Uint8List bytes, int max) async => bytes,
      limiter: VisionRateLimiter(),
    );

final Uint8List _img = Uint8List.fromList(<int>[1, 2, 3]);

void main() {
  test(
      'the demo token travels as a header, never in the URL '
      'or the body', () async {
    Map<String, String>? seenHeaders;
    Uri? seenUrl;
    String? seenBody;
    final CloudVisionResult result = await _client(
      sender: (Uri u, String b, Map<String, String> h) async {
        seenUrl = u;
        seenBody = b;
        seenHeaders = h;
        return '{"scene":"室内","obstacles":[],"parsed":true}';
      },
    ).describe(imageBytes: _img, now: DateTime(2026, 1, 1));
    expect(result.ok, isTrue);
    expect(seenHeaders![visionTokenHeader], 'fixture-demo-token');
    expect(seenUrl.toString(), isNot(contains('fixture-demo-token')));
    expect(seenBody, isNot(contains('fixture-demo-token')));
  });

  test(
      'an http (non-https) proxy address is refused before '
      'any send, announced as not configured', () async {
    int sends = 0;
    final CloudVisionResult result = await _client(
      proxy: 'http://fc.example.test',
      sender: (Uri u, String b, Map<String, String> h) async {
        sends += 1;
        return '{}';
      },
    ).describe(imageBytes: _img, now: DateTime(2026, 1, 1));
    expect(sends, 0);
    expect(result.failure, CloudVisionFailure.notConfigured);
    expect(result.speechText, contains('识图未配置'));
  });

  test('no proxy address: 识图未配置, nothing sent', () async {
    final CloudVisionResult result = await _client(proxy: '')
        .describe(imageBytes: _img, now: DateTime(2026, 1, 1));
    expect(result.failure, CloudVisionFailure.notConfigured);
    expect(result.speechText, contains('识图未配置'));
  });

  test(
      '401 unauthorized and 429 rate_limited both map to '
      '识图暂时不可用', () async {
    for (final String code in <String>['unauthorized', 'rate_limited']) {
      final CloudVisionResult result = await _client(
        sender: (Uri u, String b, Map<String, String> h) async =>
            jsonEncode(<String, String>{'error': code}),
      ).describe(imageBytes: _img, now: DateTime(2026, 1, 1));
      expect(result.failure, CloudVisionFailure.unavailable, reason: code);
      expect(result.speechText, contains('识图暂时不可用'), reason: code);
      expect(result.speechText, isNot(contains('安全')), reason: code);
    }
  });

  test('an unrecognised proxy error stays the upstream failure', () async {
    final CloudVisionResult result = await _client(
      sender: (Uri u, String b, Map<String, String> h) async =>
          '{"error":"upstream failure"}',
    ).describe(imageBytes: _img, now: DateTime(2026, 1, 1));
    expect(result.failure, CloudVisionFailure.upstream);
  });
}
