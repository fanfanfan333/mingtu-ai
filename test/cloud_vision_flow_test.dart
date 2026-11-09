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

class _FuncFrameSource implements CameraFrameSource {
  final Future<CameraFrameCapture> Function() fn;
  _FuncFrameSource(this.fn);

  @override
  Future<CameraFrameCapture> captureSingleFrame() => fn();
}

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

/// The proxy's structured response (enum-only JSON).
String _visionOkBody() => jsonEncode(<String, Object>{
      'scene': '室外',
      'parsed': true,
      'obstacles': <Object>[
        <String, Object>{
          'type': '行人',
          'direction': '正前方',
          'proximity': '较近',
          'confidence': 0.9,
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
        return _visionOkBody();
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
        return _visionOkBody();
      }),
      frameSource: frames,
    );
    final List<String> heard = <String>[];
    final CloudVisionFlowOutcome outcome = await runFlow(flow, heard);
    expect(frames.calls, 1); // single frame only -- no streaming
    expect(sends, 1);
    expect(heard, hasLength(2));
    expect(heard[0], cloudVisionStartingSpeech);
    expect(heard[1], contains('正前方较近处有行人'));
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

  test(
      'reservation is taken BEFORE capture: a failed capture '
      'still consumes the slot', () async {
    final FakeFrameSource frames = FakeFrameSource(
      CameraFrameCapture.failed(CameraFrameFailure.unavailable),
    );
    final OnDemandCloudVision flow = OnDemandCloudVision(
      client: _client(sender: (Uri u, String b) async => _visionOkBody()),
      frameSource: frames,
    );
    final List<String> heard1 = <String>[];
    await flow.run(announce: heard1.add, now: now);
    expect(frames.calls, 1);
    expect(heard1.last, contains('摄像头现在不可用'));
    // Second trigger at the same time: the slot from the FAILED
    // first attempt is gone, so this one is rate-limited and the
    // camera is not opened again.
    final List<String> heard2 = <String>[];
    final CloudVisionFlowOutcome second =
        await flow.run(announce: heard2.add, now: now);
    expect(frames.calls, 1);
    expect(heard2.single, contains('调用太频繁'));
    expect(second.visionResult.failure, CloudVisionFailure.rateLimited);
  });

  test(
      'single-flight: a second trigger during recognition is '
      'answered 请稍候 and captures nothing', () async {
    final Completer<CameraFrameCapture> gate = Completer<CameraFrameCapture>();
    int captures = 0;
    final CameraFrameSource slow = _FuncFrameSource(() {
      captures += 1;
      return gate.future;
    });
    final OnDemandCloudVision flow = OnDemandCloudVision(
      client: _client(sender: (Uri u, String b) async => _visionOkBody()),
      frameSource: slow,
    );
    final List<String> heard1 = <String>[];
    final Future<CloudVisionFlowOutcome> first =
        flow.run(announce: heard1.add, now: now);
    await Future<void>.delayed(Duration.zero);
    expect(flow.inFlight, isTrue);
    final List<String> heard2 = <String>[];
    final CloudVisionFlowOutcome second =
        await flow.run(announce: heard2.add, now: now);
    expect(heard2.single, '正在识别，请稍候。');
    expect(second.visionResult.failure, CloudVisionFailure.busy);
    expect(captures, 1); // no second camera open
    gate.complete(CameraFrameCapture.ok(_fakeImage(32)));
    final CloudVisionFlowOutcome firstOutcome = await first;
    expect(firstOutcome.visionResult.ok, isTrue);
    expect(flow.inFlight, isFalse);
  });

  test(
      'cancellation after capture discards the result: the '
      'sender is never called and nothing more is announced', () async {
    final CloudVisionCancellation token = CloudVisionCancellation();
    int sends = 0;
    final CameraFrameSource cancelling = _FuncFrameSource(() async {
      token.cancel(); // app went to background during capture
      return CameraFrameCapture.ok(_fakeImage(32));
    });
    final OnDemandCloudVision flow = OnDemandCloudVision(
      client: _client(sender: (Uri u, String b) async {
        sends += 1;
        return _visionOkBody();
      }),
      frameSource: cancelling,
    );
    final List<String> heard = <String>[];
    final CloudVisionFlowOutcome outcome =
        await flow.run(announce: heard.add, now: now, cancellation: token);
    expect(outcome.cancelled, isTrue);
    expect(sends, 0);
    expect(heard, <String>[cloudVisionStartingSpeech]);
  });

  test('routed frame source never double-opens the camera', () async {
    bool yoloActive = true;
    final FakeFrameSource yolo =
        FakeFrameSource(CameraFrameCapture.ok(_fakeImage(8)));
    final FakeFrameSource single =
        FakeFrameSource(CameraFrameCapture.ok(_fakeImage(8)));
    final CameraOwnership ownership = CameraOwnership();
    final RoutedCameraFrameSource routed = RoutedCameraFrameSource(
      yoloLiveActive: () => yoloActive,
      yoloSource: yolo,
      singleShotSource: single,
      ownership: ownership,
    );
    await routed.captureSingleFrame();
    expect(yolo.calls, 1);
    expect(single.calls, 0); // YOLO owns the camera: no second open
    yoloActive = false;
    final CameraFrameCapture shot = await routed.captureSingleFrame();
    expect(shot.ok, isTrue);
    expect(yolo.calls, 1);
    expect(single.calls, 1);
    // The one-shot released the camera when it finished.
    expect(ownership.isHeld, isFalse);
  });

  test(
      'routed source refuses a still while the arbiter is held '
      'by another use: no double-open', () async {
    final CameraOwnership ownership = CameraOwnership();
    expect(ownership.tryAcquire(CameraUse.yoloLive), isTrue);
    final FakeFrameSource single =
        FakeFrameSource(CameraFrameCapture.ok(_fakeImage(8)));
    final RoutedCameraFrameSource routed = RoutedCameraFrameSource(
      yoloLiveActive: () => false, // view flag lags; arbiter rules
      yoloSource: FakeFrameSource(
        CameraFrameCapture.failed(CameraFrameFailure.unavailable),
      ),
      singleShotSource: single,
      ownership: ownership,
    );
    final CameraFrameCapture capture = await routed.captureSingleFrame();
    expect(capture.ok, isFalse);
    expect(capture.failure, CameraFrameFailure.unavailable);
    expect(single.calls, 0); // camera was never opened twice
  });
}
