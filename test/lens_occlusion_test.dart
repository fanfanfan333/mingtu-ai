import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/lens_occlusion.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/main.dart';

void main() {
  late DateTime time;
  late LensOcclusionMonitor monitor;
  const LumaStats dark = LumaStats(10, 100);
  const LumaStats covered = LumaStats(100, 4);
  const LumaStats good = LumaStats(100, 400);

  setUp(() {
    time = DateTime.utc(2026);
    monitor = LensOcclusionMonitor(now: () => time);
  });

  LensNotice? advance(LumaStats stats, [int seconds = 1]) {
    time = time.add(Duration(seconds: seconds));
    return monitor.sample(stats);
  }

  test('dark and covered require continuous evidence and alert once', () {
    for (final LumaStats anomaly in <LumaStats>[dark, covered]) {
      monitor = LensOcclusionMonitor(now: () => time);
      expect(monitor.sample(anomaly), isNull);
      expect(advance(anomaly), isNull);
      expect(advance(anomaly), LensNotice.alert);
      expect(advance(anomaly), isNull);
      expect(LensOcclusionMonitor.alertText, '镜头可能被挡住或太暗，本地检测暂时不可靠');
    }
  });

  test('healthy samples reset the timer and recovery is emitted once', () {
    expect(monitor.sample(dark), isNull);
    expect(advance(dark), isNull);
    expect(advance(good), isNull);
    expect(advance(dark), isNull);
    expect(advance(dark), isNull);
    expect(advance(dark), LensNotice.alert);
    expect(advance(good), LensNotice.recovery);
    expect(advance(good), isNull);
  });

  test('cooldown suppresses repeated alerts and allows a later one', () {
    monitor.sample(dark);
    advance(dark);
    expect(advance(dark), LensNotice.alert);
    expect(advance(good), LensNotice.recovery);
    expect(advance(dark), isNull);
    expect(advance(dark), isNull);
    expect(advance(dark), isNull);
    for (int i = 0; i < 20; i++) {
      expect(advance(dark), isNull);
    }
    expect(advance(dark), LensNotice.alert);
  });

  test('missing samples do not establish persistence or recovery', () {
    monitor.sample(dark);
    expect(advance(dark, 3), isNull);
    expect(advance(dark), isNull);
    expect(advance(dark), LensNotice.alert);
    expect(advance(dark, 10), isNull);
    expect(advance(good), LensNotice.recovery);
  });

  test('speech avoids banned words and grayscale statistics are sampled', () {
    for (final String text in <String>[
      LensOcclusionMonitor.alertText,
      LensOcclusionMonitor.recoveryText,
    ]) {
      for (final String word in <String>['安全', '可以通行', '放心', '可以过马路']) {
        expect(text, isNot(contains(word)));
      }
    }
    final LumaStats stats = LumaStats.fromGray(<int>[0, 100, 0, 100]);
    expect(stats.mean, 50);
    expect(stats.variance, 2500);
  });

  testWidgets('pushed samples reach the speech scheduler',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MingtuApp());
    final MingtuHomeDebugHandle handle = mingtuHomeDebugHandle!;
    handle.debugSetLensClock(() => time);
    handle.debugPushLuma(10, 100);
    time = time.add(const Duration(seconds: 1));
    handle.debugPushLuma(10, 100);
    time = time.add(const Duration(seconds: 1));
    handle.debugPushLuma(10, 100);
    final bool active =
        handle.activeSpeechText == LensOcclusionMonitor.alertText &&
            handle.activeSpeechKind == SpeechKind.alert;
    final bool queued = handle.debugLensSpeechQueue.any(
        (SpeechRequest request) =>
            request.text == LensOcclusionMonitor.alertText &&
            request.kind == SpeechKind.alert);
    expect(active || queued, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  });
}
