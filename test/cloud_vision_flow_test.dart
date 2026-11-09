import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/cloud_vision_client.dart';
import 'package:mingtu_ai/adapters/cloud_vision_flow.dart';
import 'package:mingtu_ai/core/camera_frame.dart';
import 'package:mingtu_ai/core/cloud_vision.dart';

/// On-demand cloud-vision flow tests: one explicit trigger, one
/// frame, one rate-limited call, every stage spoken in Chinese
/// with the disclaimer. All fixtures: a fake frame source and a
/// fake sender -- no real camera, no real network, no real key.

Uint8List _fakeImage(int n) => Uint8List.fromList(List<int>.filled(n, 7));

class FakeFrameSource implements CameraFrameSource {
  final CameraFrameCapture result;
  int calls = 0;
  FakeFrameSource(this.result);

  @override
  Future<CameraFrameCapture> captureSingleFrame() async {
    calls += 1;
    return result;
  }
}

CloudVisionClient _client({
  required Future<String> Function(Uri, String) sender,
  VisionRateLimiter? limiter,
  Duration? timeout,
}) {
  return CloudVisionClient(
    proxyBaseUrl: 'https://proxy.example.test',
    sender: sender,
    downsampler: (Uint8List b, int d) async => b,
    limiter: limiter ?? VisionRateLimiter(),
    requestTimeout: timeout ?? cloudVisionRequestTimeout,
  );
}

String _visionOkBody(String content) => jsonEncode(<String, Object>{
      'choices': <Object>[
        <String, Object>{
          'message': <String, String>{'role': 'assistant', 'content': content},
        },
      ],
    });

void main() {
  final DateTime now = DateTime(2026, 11, 9, 12);
  final List<String> allAnnouncements = <String>[];

  Future<CloudVisionFlowOutcome> runFlow(
    OnDemandCloudVision flow,
    List<String> sink,
  ) async {
    final CloudVisionFlowOutcome outcome =
        await flow.run(announce: sink.add, now: now);
    allAnnouncements.addAll(sink);
    return outcome;
  }

  test('not configured: announced, camera never opened', () async {
    final FakeFrameSource frames =
        FakeFrameSource(CameraFrameCapture.ok(_fakeImage(10)));
    final OnDemandCloudVision flow = OnDemandCloudVision(
      client: CloudVisionClient(proxyBaseUrl: ''),
      frameSource: frames,
    );
    final List<String> heard = <String>[];
    final CloudVisionFlowOutcome outcome = await runFlow(flow, heard);
    expect(frames.calls, 0);
    expect(heard, hasLength(1));
    expect(heard.single, contains('云端视觉未配置'));
    expect(heard.single, contains(cloudVisionDisclaimer));
    expect(outcome.visionResult.failure, CloudVisionFailure.notConfigured);
  });

  test('rate limited: announced, camera never opened', () async {
    final VisionRateLimiter limiter = VisionRateLimiter();
    expect(limiter.tryAcquire(now), isTrue); // consume the slot
    final FakeFrameSource frames =
        FakeFrameSource(CameraFrameCapture.ok(_fakeImage(10)));
    final OnDemandCloudVision flow = OnDemandCloudVision(
      client: _client(
        sender: (Uri u, String b) async => fail('must not send'),
        limiter: limiter,
      ),
      frameSource: frames,
    );
    final List<String> heard = <String>[];
    final CloudVisionFlowOutcome outcome = await runFlow(flow, heard);
    expect(frames.calls, 0);
    expect(heard, hasLength(1));
    expect(heard.single, contains('调用太频繁'));
    expect(outcome.visionResult.failure, CloudVisionFailure.rateLimited);
  });

  test(
      'camera permission denied: starting announced, denial spoken, '
      'nothing sent', () async {
    int sends = 0;
    final FakeFrameSource frames = FakeFrameSource(
      CameraFrameCapture.failed(CameraFrameFailure.permissionDenied),
    );
    final OnDemandCloudVision flow = OnDemandCloudVision(
      client: _client(sender: (Uri u, String b) async {
        sends += 1;
        return _visionOkBody('不应到达');
      }),
      frameSource: frames,
    );
    final List<String> heard = <String>[];
    final CloudVisionFlowOutcome outcome = await runFlow(flow, heard);
    expect(frames.calls, 1);
    expect(sends, 0);
    expect(heard, hasLength(2));
    expect(heard[0], contains('正在识别前方画面'));
    expect(heard[0], contains(cloudVisionDisclaimer));
    expect(heard[1], contains('摄像头权限被拒绝'));
    expect(heard[1], contains('已降级为本地检测'));
    expect(heard[1], contains(cloudVisionDisclaimer));
    expect(outcome.visionResult.failure, CloudVisionFailure.noImage);
  });

  test('camera unavailable: spoken degradation, nothing sent', () async {
    final FakeFrameSource frames = FakeFrameSource(
      CameraFrameCapture.failed(CameraFrameFailure.unavailable),
    );
    final OnDemandCloudVision flow = OnDemandCloudVision(
      client: _client(
        sender: (Uri u, String b) async => fail('must not send'),
      ),
      frameSource: frames,
    );
    final List<String> heard = <String>[];
    await runFlow(flow, heard);
    expect(heard, hasLength(2));
    expect(heard[1], contains('摄像头现在不可用'));
    expect(heard[1], contains(cloudVisionDisclaimer));
  });

  test(
      'success: exactly one frame, one send, result spoken with '
      'the disclaimer', () async {
    int sends = 0;
    final FakeFrameSource frames =
        FakeFrameSource(CameraFrameCapture.ok(_fakeImage(64)));
    final OnDemandCloudVision flow = OnDemandCloudVision(
      client: _client(sender: (Uri u, String b) async {
        sends += 1;
        return _visionOkBody('前方有一张桌子和两把椅子。');
      }),
      frameSource: frames,
    );
    final List<String> heard = <String>[];
    final CloudVisionFlowOutcome outcome = await runFlow(flow, heard);
    expect(frames.calls, 1); // single frame only -- no streaming
    expect(sends, 1);
    expect(heard, hasLength(2));
    expect(heard[0], cloudVisionStartingSpeech);
    expect(heard[1], contains('前方有一张桌子和两把椅子'));
    expect(heard[1], contains(cloudVisionDisclaimer));
    expect(outcome.visionResult.ok, isTrue);
  });

  test('timeout: spoken as a degradation, never as silence or safety',
      () async {
    final FakeFrameSource frames =
        FakeFrameSource(CameraFrameCapture.ok(_fakeImage(64)));
    final OnDemandCloudVision flow = OnDemandCloudVision(
      client: _client(
        sender: (Uri u, String b) => Completer<String>().future,
        timeout: const Duration(milliseconds: 60),
      ),
      frameSource: frames,
    );
    final List<String> heard = <String>[];
    final CloudVisionFlowOutcome outcome = await runFlow(flow, heard);
    expect(heard, hasLength(2));
    expect(heard[1], contains('请求超时'));
    expect(heard[1], contains('已降级为本地检测'));
    expect(heard[1], contains(cloudVisionDisclaimer));
    expect(outcome.visionResult.failure, CloudVisionFailure.timeout);
  });

  test('no announcement ever calls a scene safe to walk', () {
    expect(allAnnouncements, isNotEmpty);
    for (final String text in allAnnouncements) {
      expect(text, isNot(contains('安全可以走')));
      expect(text, isNot(contains('可以安全通过')));
      expect(text, isNot(contains('没有危险')));
      expect(text, isNot(contains('未检测到危险')));
    }
  });
}
