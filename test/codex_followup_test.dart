import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mingtu_ai/core/danger_alerts.dart';
import 'package:mingtu_ai/core/real_navigation.dart';
import 'package:mingtu_ai/core/risk_engine.dart';
import 'package:mingtu_ai/core/yolo_error_speech.dart';

/// Codex re-test follow-ups for 037f25c: no spoken text may
/// contain the safe-passage word, the hospital flow is out
/// of the app, and YOLO view errors are classified.
void main() {
  group('no announcement text contains the safe-passage word', () {
    test('lib/ source is completely free of it', () {
      final List<String> offenders = <String>[];
      for (final FileSystemEntity e
          in Directory('lib').listSync(recursive: true)) {
        if (e is File && e.path.endsWith('.dart')) {
          final String content = e.readAsStringSync();
          if (content.contains('安全')) offenders.add(e.path);
        }
      }
      expect(offenders, isEmpty,
          reason: 'spoken (and written) texts must never '
              'claim or negate passage with that word');
    });

    test('key announcement builders stay clean', () {
      expect(
          realRouteReadyAnnouncement(
              destinationName: '图书馆', distanceM: 155, stepsCount: 3),
          isNot(contains('安全')));
      expect(dangerTextFor(DangerCategory.vehicle), isNot(contains('安全')));
      expect(dangerTextFor(DangerCategory.person), isNot(contains('安全')));
      final DateTime now = DateTime(2026, 1, 1);
      final RiskEngine engine = RiskEngine();
      final RiskAssessment a = engine.assess(
        RiskEvent(
          id: 'followup-1',
          type: 'obstacle',
          createdAt: now,
          expiresAt: now.add(const Duration(seconds: 10)),
          evidence: const PerceptionEvidence(
            detectionConfidence: 0.95,
            spatialConfidence: 0.9,
            hasDistanceEstimate: true,
            distanceM: 2.0,
            sideSpaceConfirmed: false,
          ),
        ),
        now,
      );
      expect(a.speechText, isNot(contains('安全')));
      expect(a.speechText, contains('请先停下'));
    });
  });

  group('hospital flow is out of the app', () {
    test('main.dart and the registry carry no hospital wiring', () {
      final String mainDart = File('lib/main.dart').readAsStringSync();
      expect(mainDart, isNot(contains('hospital')));
      expect(mainDart, isNot(contains('医院')));
      final String registry =
          File('lib/skills/registry.dart').readAsStringSync();
      expect(registry, isNot(contains('hospital_registration')));
    });
  });

  group('ASR unavailable: voice + vibration, fixed texts only', () {
    test('the runtime ASR error handler vibrates and speaks a fixed notice',
        () {
      final String mainDart = File('lib/main.dart').readAsStringSync();
      final int start = mainDart.indexOf('void _handleAsrError');
      final int end = mainDart.indexOf('void _maybeStartListeningAfterSpeech');
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final String body = mainDart.substring(start, end);
      expect(body, contains('HapticFeedback.vibrate()'));
      expect(body, contains('asrErrorText(code)'));
      expect(body, contains('VoiceNoticeKind.asrUnavailable'));
      // The raw stream entry is never interpolated into a
      // surface: only its whitelisted code prefix is read.
      expect(body, contains("error.split('|').first"));
      expect(body, isNot(contains('errorMsg')));
    });
  });

  group('YOLO view error classification', () {
    test('camera permission denial gets its own announcement', () {
      final YoloViewErrorKind kind =
          classifyYoloViewError(Exception('Camera permission denied by user'));
      expect(kind, YoloViewErrorKind.cameraPermissionDenied);
      expect(yoloViewErrorSpeech(kind), '没有摄像头权限，无法检测危险，请在设置中开启摄像头权限。');
    });

    test('model load failure keeps the model announcement', () {
      final YoloViewErrorKind kind = classifyYoloViewError(Exception(
          "Could not open 'yolo11n': Failed to load model from file"));
      expect(kind, YoloViewErrorKind.modelLoadFailed);
      expect(yoloViewErrorSpeech(kind), contains('模型加载失败'));
    });

    test('unknown errors fall back to an honest generic sentence', () {
      final YoloViewErrorKind kind =
          classifyYoloViewError(Exception('something unexpected'));
      expect(kind, YoloViewErrorKind.unknown);
      expect(yoloViewErrorSpeech(kind), contains('摄像头或模型'));
      // The three announcements are pairwise different.
      final Set<String> all =
          YoloViewErrorKind.values.map(yoloViewErrorSpeech).toSet();
      expect(all.length, 3);
    });

    test('main.dart wires the classifier into the live view', () {
      final String mainDart = File('lib/main.dart').readAsStringSync();
      expect(mainDart, contains('classifyYoloViewError(error)'));
      expect(mainDart, contains('yoloViewErrorSpeech(errorKind)'));
    });
  });
}
