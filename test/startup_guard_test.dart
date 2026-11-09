import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/startup_guard.dart';

/// P0 startup resilience: simulate EVERY startup module
/// throwing (missing plugin class, native load failure -- the
/// release-APK failure shape). Startup must still complete with
/// fallbacks, and the failures must be announced by name.
void main() {
  group('guardStartupStep', () {
    test(
        'a throwing step returns the fallback and records '
        'the module; startup continues', () async {
      final StartupFailureLog log = StartupFailureLog();
      final bool ttsOk = await guardStartupStep<bool>(
        '语音合成',
        () async => throw StateError('plugin class stripped'),
        fallback: false,
        log: log,
      );
      final bool asrOk = await guardStartupStep<bool>(
        '语音识别',
        () async => throw StateError('no recogniser'),
        fallback: false,
        log: log,
      );
      final String yolo = await guardStartupStep<String>(
        '目标检测',
        () async => throw StateError('native lib missing'),
        fallback: 'unavailable',
        log: log,
      );
      // Startup "completed" with fallbacks everywhere:
      expect(ttsOk, isFalse);
      expect(asrOk, isFalse);
      expect(yolo, 'unavailable');
      expect(log.modules, <String>['语音合成', '语音识别', '目标检测']);
    });

    test(
        'a succeeding step passes its value through and '
        'records nothing', () async {
      final StartupFailureLog log = StartupFailureLog();
      final bool ok = await guardStartupStep<bool>(
        '语音合成',
        () async => true,
        fallback: false,
        log: log,
      );
      expect(ok, isTrue);
      expect(log.hasFailures, isFalse);
    });

    test(
        'the announcement names every failed module and '
        'states the degradation honestly', () {
      final String text = startupFailureAnnouncement(
        <String>['语音合成', '语音识别', '目标检测'],
      );
      expect(text, contains('启动时有模块不可用'));
      expect(text, contains('语音合成'));
      expect(text, contains('语音识别'));
      expect(text, contains('目标检测'));
      expect(text, contains('已降级启动'));
      expect(startupFailureAnnouncement(const <String>[]), '');
    });
  });

  group('production wiring (source level)', () {
    test(
        'main() runs in the guarded zone with the framework '
        'backstop, and startup steps are guarded', () {
      final String mainDart = File('lib/main.dart').readAsStringSync();
      expect(mainDart, contains('runGuardedMain(()'));
      expect(mainDart, contains('installFrameworkErrorBackstop()'));
      expect(mainDart, contains('guardStartupStep<bool>'));
      expect(mainDart, contains("'语音合成'"));
      expect(mainDart, contains("'语音识别'"));
      expect(mainDart, contains("'目标检测'"));
      expect(mainDart, contains('startupFailureAnnouncement('));
    });
  });
}
