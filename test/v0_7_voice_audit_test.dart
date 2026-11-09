import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/core/contracts.dart';
import 'package:mingtu_ai/core/health_monitor.dart';
import 'package:test/test.dart';

void main() {
  test('health announcement speaks Chinese service names, never English ids',
      () {
    final HealthMonitor health = HealthMonitor();
    health.report('map_navigation', ServiceHealthStatus.degraded, '桩路线');
    health.report('voice_output', ServiceHealthStatus.unavailable, '无 TTS');
    health.report('voice_input', ServiceHealthStatus.degraded, '无识别');
    health.report('camera', ServiceHealthStatus.unavailable, '无摄像头');
    final String text = health.announcementText();
    expect(text, contains('地图导航'));
    expect(text, contains('语音播报'));
    expect(text, contains('语音识别'));
    expect(text, contains('摄像头'));
    expect(text, isNot(contains('map_navigation')));
    expect(text, isNot(contains('voice_output')));
    expect(text, isNot(contains('voice_input')));
    expect(text, isNot(contains('camera')));
    expect(HealthMonitor.chineseServiceName('location'), '定位');
    expect(HealthMonitor.chineseServiceName('something-new'), '一项服务');
  });

  test('health announcement is empty when nothing is degraded', () {
    final HealthMonitor health = HealthMonitor();
    health.report('voice_output', ServiceHealthStatus.ok, '正常');
    expect(health.announcementText(), isEmpty);
  });

  test('amap step speaker reads steps in order, then stops honestly', () {
    final AmapStepSpeaker speaker = AmapStepSpeaker(<AmapStep>[
      const AmapStep(
        action: '直行',
        orientation: '北',
        polyline: [],
        distanceM: 80,
        durationS: 60,
      ),
      const AmapStep(
        action: '左转',
        orientation: '东',
        polyline: [],
        distanceM: 106,
        durationS: 90,
      ),
    ]);
    expect(speaker.remaining, 2);
    final String? first = speaker.nextStepText();
    // Speech is GENERATED from the enum fields (direction +
    // action + distance), never copied from provider free text.
    expect(first, contains('朝北方向直行'));
    expect(first, contains('约 80 米'));
    expect(first, contains('第 1 段，共 2 段'));
    final String? second = speaker.nextStepText();
    expect(second, contains('朝东方向左转'));
    expect(second, contains('约 106 米'));
    expect(second, contains('第 2 段，共 2 段'));
    expect(speaker.isDone, isTrue);
    expect(speaker.nextStepText(), isNull);
    speaker.reset();
    expect(speaker.isDone, isFalse);
    expect(speaker.nextStepText(), contains('朝北方向直行'));
  });

  test('amap step speaker with no steps says nothing to invent', () {
    final AmapStepSpeaker speaker = AmapStepSpeaker(const <AmapStep>[]);
    expect(speaker.isDone, isTrue);
    expect(speaker.nextStepText(), isNull);
  });
}
