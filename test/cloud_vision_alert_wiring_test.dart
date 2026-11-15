import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Wiring proof for the production call site: the cloud-vision
/// announcements in lib/main.dart's _runCloudVisionAssist (results,
/// failures, permission denials AND the duplicate-trigger refusal)
/// must be submitted as SpeechKind.alert (high priority,
/// never-expiring via _request's critical rule), never as info.
/// Behavioural delivery guarantees are proven in
/// speech_scheduler_test.dart; this test pins the production
/// call site itself to that level, as Codex required.
void main() {
  test('main.dart _runCloudVisionAssist speaks only at alert level', () {
    final String source = File('lib/main.dart').readAsStringSync();
    final int start = source.indexOf(
      'Future<void> _runCloudVisionAssist() async {',
    );
    expect(start, greaterThanOrEqualTo(0));
    final int end = source.indexOf(
      '// v0.5: every state has a Chinese name.',
      start,
    );
    expect(end, greaterThan(start));
    final String body = source.substring(start, end);
    // Every speech site in the function uses alert, including
    // the camera-permission gate added for UI-06-B8.
    final sites = RegExp(r'\b_say\s*\(|\b_sayPermissionFlowText\s*\(')
        .allMatches(body)
        .toList();
    expect(sites.length, 4);
    for (final site in sites) {
      final next = sites.indexOf(site) + 1;
      final siteBody = body.substring(
          site.start, next < sites.length ? sites[next].start : body.length);
      expect(
          RegExp(r'kind\s*:\s*SpeechKind\.alert|alert\s*:\s*true')
              .hasMatch(siteBody),
          isTrue);
    }
    expect(body.contains('SpeechKind.info'), isFalse);
    // The duplicate-trigger refusal creates no token: it goes
    // through VisionRunManager.begin() and returns early.
    expect(body.contains('_visionRuns.begin()'), isTrue);
    expect(body.contains('CloudVisionCancellation? token'), isTrue);
    // The run's token is registered with the shared camera
    // arbiter so background/dispose cancels it too.
    expect(
      body.contains('_cameraOwnership.registerCancellation(token)'),
      isTrue,
    );
  });

  test('_request marks alert (and danger kinds) neverExpires', () {
    final String source = File('lib/main.dart').readAsStringSync();
    final int start = source.indexOf('SpeechRequest _request({');
    expect(start, greaterThanOrEqualTo(0));
    final String body = source.substring(start, start + 1800);
    expect(body.contains('kind == SpeechKind.alert'), isTrue);
    expect(body.contains('neverExpires: critical'), isTrue);
  });
}
