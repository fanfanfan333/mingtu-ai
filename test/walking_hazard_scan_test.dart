import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/cloud_vision_client.dart';
import 'package:mingtu_ai/core/cloud_vision.dart';
import 'package:mingtu_ai/core/cloud_vision_hazard.dart';
import 'package:mingtu_ai/core/walking_hazard_scan.dart';

void main() {
  test('disclaimer is fixed and avoids forbidden wording', () {
    expect(walkingNavigationDisclaimer, '台阶和路沿不能可靠提醒，请用盲杖确认。');
    for (final word in ['安全', '可以通行', '放心', '可以过马路']) {
      expect(walkingNavigationDisclaimer, isNot(contains(word)));
    }
  });

  test('walking navigation has an independent one minute cadence', () async {
    var calls = 0;
    final scan = WalkingHazardScan(
      gate: CloudVisionDowngradeGate(),
      speak: (_) {},
      scan: (_) async {
        calls++;
        return const HazardScanOutcome.ok(HazardAssessment.unknown);
      },
    );
    final start = DateTime(2026);
    Future<void> tick(int seconds,
            {bool navigating = true, bool walking = true, bool busy = false}) =>
        scan.tick(
            navigating: navigating,
            walking: walking,
            busy: busy,
            now: start.add(Duration(seconds: seconds)));
    await tick(0, navigating: false);
    await tick(0, walking: false);
    await tick(0, busy: true);
    expect(calls, 0);
    await tick(0);
    await tick(59);
    expect(calls, 1);
    await tick(60);
    expect(calls, 2);
  });

  test(
      'failure is gated and valid response uses local templates and downsizing',
      () async {
    var dimension = 0;
    var fail = true;
    final spoken = <String>[];
    final client = CloudVisionClient(
      proxyBaseUrl: 'https://fixture.invalid',
      downsampler: (Uint8List bytes, int maxDimension) async {
        dimension = maxDimension;
        return bytes;
      },
      sender: (uri, body, headers) async {
        expect(uri.path, '/vision');
        expect(jsonDecode(body)['task'], 'hazard_scan');
        if (fail) throw StateError('fixture failure');
        return jsonEncode({
          'parsed': true,
          'type': 'curb',
          'direction': 'left',
          'distance_level': 'near',
          'confidence': 0.9,
          'path_status': {'suggested_action': 'shift_left', 'summary': '向左迈'}
        });
      },
    );
    final gate =
        CloudVisionDowngradeGate(announceCooldown: const Duration(minutes: 3));
    final scan = WalkingHazardScan(
        gate: gate,
        speak: spoken.add,
        scan: (_) => client.describeHazardReserved(
            imageBytes: Uint8List.fromList([1, 2])));
    final start = DateTime(2026);
    Future<void> tick(int seconds) => scan.tick(
        navigating: true,
        walking: true,
        busy: false,
        now: start.add(Duration(seconds: seconds)));
    await tick(0);
    await tick(60);
    expect(spoken, [cloudVisionDowngradeSpeech]);
    fail = false;
    await tick(120);
    expect(dimension, cloudVisionMaxDimension);
    expect(spoken.last, contains('前方有路沿，请停下。'));
    for (final word in ['向左迈', '向右迈', '安全', '可以通行', '放心', '可以过马路']) {
      expect(spoken.last, isNot(contains(word)));
    }
  });
}
