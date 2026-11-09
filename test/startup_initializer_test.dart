import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/adapters/current_location.dart';
import 'package:mingtu_ai/adapters/startup_initializer.dart';
import 'package:mingtu_ai/adapters/system_voice_io.dart';
import 'package:mingtu_ai/adapters/yolo_detector.dart';
import 'package:mingtu_ai/core/camera_frame.dart';
import 'package:mingtu_ai/core/startup_guard.dart';

/// Fault injection against the PRODUCTION startup path
/// (initializeStartup is what main() runs): each module's
/// factory / initialiser is made to throw, one at a time and
/// all together. Startup must still complete with the honest
/// fallback for that module, record the module, and the
/// unified announcement must name it in Chinese.
class _OkFrameSource implements CameraFrameSource {
  @override
  Future<CameraFrameCapture> captureSingleFrame() async =>
      CameraFrameCapture.ok(Uint8List.fromList(<int>[1]));
}

class _FakeTts extends SystemVoiceOutput {
  _FakeTts(this.result);
  final bool result;
  @override
  Future<bool> initialize() async => result;
}

class _ThrowingTts extends SystemVoiceOutput {
  @override
  Future<bool> initialize() async => throw StateError('tts boom');
}

class _FakeAsr extends SystemVoiceInput {
  _FakeAsr(this.result);
  final bool result;
  @override
  Future<bool> initialize() async => result;
}

class _ThrowingAsr extends SystemVoiceInput {
  @override
  Future<bool> initialize() async => throw StateError('asr boom');
}

Future<StartupInitResult> _run(
  StartupFailureLog log, {
  CameraFrameSource Function()? frame,
  Future<void> Function()? config,
  AmapWalkingClient Function()? amap,
  CurrentLocationProvider Function()? location,
  SystemVoiceOutput Function()? tts,
  SystemVoiceInput Function()? asr,
  YoloDetector Function()? yolo,
  Future<bool> Function(String)? probe,
}) =>
    initializeStartup(
      frameSourceFactory: frame ?? () => _OkFrameSource(),
      configProbe: config ?? () async {},
      amapFactory: amap ?? () => AmapWalkingClient(proxyBaseUrl: 'x'),
      locationFactory: location ?? () => const GeolocatorCurrentLocation(),
      ttsFactory: tts ?? () => _FakeTts(true),
      asrFactory: asr ?? () => _FakeAsr(true),
      yoloFactory: yolo ?? () => UnavailableYoloDetector(),
      modelAssetProbe: probe ?? (_) async => true,
      log: log,
    );

void main() {
  test('all modules healthy: no failures recorded', () async {
    final StartupFailureLog log = StartupFailureLog();
    final StartupInitResult r = await _run(log);
    expect(log.hasFailures, isFalse);
    expect(r.ttsOk, isTrue);
    expect(r.asrOk, isTrue);
    expect(r.frameSource, isA<_OkFrameSource>());
  });

  test(
      '摄像头 factory throws: last-resort source, recorded, '
      'announced', () async {
    final StartupFailureLog log = StartupFailureLog();
    final StartupInitResult r =
        await _run(log, frame: () => throw StateError('cam'));
    expect(r.frameSource, isA<LastResortCameraFrameSource>());
    expect(log.modules, <String>['摄像头']);
    expect(startupFailureAnnouncement(log.modules), contains('摄像头'));
    final CameraFrameCapture cap = await r.frameSource.captureSingleFrame();
    expect(cap.ok, isFalse);
  });

  test('配置 probe throws: recorded and announced', () async {
    final StartupFailureLog log = StartupFailureLog();
    await _run(log, config: () async => throw StateError('cfg'));
    expect(log.modules, <String>['配置']);
    expect(startupFailureAnnouncement(log.modules), contains('配置'));
  });

  test(
      '高德 factory throws: unconfigured fallback client, '
      'recorded, announced', () async {
    final StartupFailureLog log = StartupFailureLog();
    final StartupInitResult r =
        await _run(log, amap: () => throw StateError('amap'));
    expect(r.amapClient.proxyBaseUrl, '');
    expect(log.modules, <String>['高德']);
    expect(startupFailureAnnouncement(log.modules), contains('高德'));
  });

  test(
      '权限 factory throws: unavailable location fallback, '
      'recorded, announced', () async {
    final StartupFailureLog log = StartupFailureLog();
    final StartupInitResult r =
        await _run(log, location: () => throw StateError('loc'));
    expect(r.locationProvider, isA<UnavailableCurrentLocation>());
    expect(log.modules, <String>['权限']);
    expect(startupFailureAnnouncement(log.modules), contains('权限'));
  });

  test('语音合成 factory throws: tts null, recorded, announced', () async {
    final StartupFailureLog log = StartupFailureLog();
    final StartupInitResult r =
        await _run(log, tts: () => throw StateError('tts'));
    expect(r.tts, isNull);
    expect(r.ttsOk, isFalse);
    expect(log.modules, <String>['语音合成']);
    expect(startupFailureAnnouncement(log.modules), contains('语音合成'));
  });

  test(
      '语音合成 initialize throws (not just construction): '
      'ttsOk false, recorded', () async {
    final StartupFailureLog log = StartupFailureLog();
    final StartupInitResult r = await _run(log, tts: _ThrowingTts.new);
    expect(r.tts, isNotNull);
    expect(r.ttsOk, isFalse);
    expect(log.modules, <String>['语音合成']);
  });

  test('语音识别 factory throws: asr null, recorded, announced', () async {
    final StartupFailureLog log = StartupFailureLog();
    final StartupInitResult r =
        await _run(log, asr: () => throw StateError('asr'));
    expect(r.asr, isNull);
    expect(r.asrOk, isFalse);
    expect(log.modules, <String>['语音识别']);
    expect(startupFailureAnnouncement(log.modules), contains('语音识别'));
  });

  test('语音识别 initialize throws: asrOk false, recorded', () async {
    final StartupFailureLog log = StartupFailureLog();
    final StartupInitResult r = await _run(log, asr: _ThrowingAsr.new);
    expect(r.asrOk, isFalse);
    expect(log.modules, <String>['语音识别']);
  });

  test(
      '目标检测 factory throws: unavailable detector, '
      'recorded, announced', () async {
    final StartupFailureLog log = StartupFailureLog();
    final StartupInitResult r =
        await _run(log, yolo: () => throw StateError('yolo'));
    expect(r.yolo, isA<UnavailableYoloDetector>());
    expect(log.modules, <String>['目标检测']);
    expect(startupFailureAnnouncement(log.modules), contains('目标检测'));
  });

  test(
      '模型资源缺失 (probe reports the bundled asset absent): '
      '目标检测 recorded, unavailable detector, announced', () async {
    final StartupFailureLog log = StartupFailureLog();
    final StartupInitResult r = await _run(log, probe: (_) async => false);
    expect(r.yolo, isA<UnavailableYoloDetector>());
    expect(log.modules, <String>['目标检测']);
    expect(startupFailureAnnouncement(log.modules), contains('目标检测'));
  });

  test(
      'EVERY module throws: startup still completes and the '
      'announcement names all seven', () async {
    final StartupFailureLog log = StartupFailureLog();
    final StartupInitResult r = await _run(
      log,
      frame: () => throw StateError('1'),
      config: () async => throw StateError('2'),
      amap: () => throw StateError('3'),
      location: () => throw StateError('4'),
      tts: () => throw StateError('5'),
      asr: () => throw StateError('6'),
      yolo: () => throw StateError('7'),
    );
    expect(r.ttsOk, isFalse);
    expect(r.asrOk, isFalse);
    expect(
      log.modules,
      <String>['摄像头', '配置', '高德', '权限', '语音合成', '语音识别', '目标检测'],
    );
    final String text = startupFailureAnnouncement(log.modules);
    for (final String m in log.modules) {
      expect(text, contains(m));
    }
    expect(text, contains('已降级启动'));
  });
}
