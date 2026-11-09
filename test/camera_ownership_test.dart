import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/camera_frame.dart';

class _FakeSource implements CameraFrameSource {
  final Future<CameraFrameCapture> Function() fn;
  int calls = 0;
  _FakeSource(this.fn);

  @override
  Future<CameraFrameCapture> captureSingleFrame() {
    calls += 1;
    return fn();
  }
}

void main() {
  group('CameraOwnership mutual exclusion', () {
    test('YOLO and single-shot can never hold the camera together', () {
      final CameraOwnership o = CameraOwnership();
      expect(o.tryAcquire(CameraUse.yoloLive), isTrue);
      expect(o.tryAcquire(CameraUse.singleShot), isFalse);
      // Same use re-acquire is fine; wrong-use release is a no-op.
      expect(o.tryAcquire(CameraUse.yoloLive), isTrue);
      o.release(CameraUse.singleShot);
      expect(o.isHeldBy(CameraUse.yoloLive), isTrue);
      o.release(CameraUse.yoloLive);
      expect(o.isHeld, isFalse);
      expect(o.tryAcquire(CameraUse.singleShot), isTrue);
      expect(o.tryAcquire(CameraUse.yoloLive), isFalse);
      // A one-shot is exclusive: no re-entry while in flight.
      expect(o.tryAcquire(CameraUse.singleShot), isFalse);
    });

    test(
        'cancelAllAndRelease cancels EVERY registered token and '
        'frees the camera', () {
      final CameraOwnership o = CameraOwnership();
      final CloudVisionCancellation a = CloudVisionCancellation();
      final CloudVisionCancellation b = CloudVisionCancellation();
      o.registerCancellation(a);
      o.registerCancellation(b);
      expect(o.tryAcquire(CameraUse.singleShot), isTrue);
      o.cancelAllAndRelease();
      expect(a.isCancelled, isTrue);
      expect(b.isCancelled, isTrue);
      expect(o.activeCancellations, 0);
      expect(o.isHeld, isFalse);
    });
  });

  group('VisionRunManager token discipline', () {
    test(
        'a duplicate begin() is refused and does NOT overwrite '
        'the running token', () {
      final VisionRunManager m = VisionRunManager();
      final CloudVisionCancellation? first = m.begin();
      expect(first, isNotNull);
      final CloudVisionCancellation? second = m.begin();
      expect(second, isNull);
      // The active token is still the FIRST one, untouched.
      expect(identical(m.activeToken, first), isTrue);
      expect(first!.isCancelled, isFalse);
      // Cancelling (background/dispose) reaches the real run.
      m.cancelActive();
      expect(first.isCancelled, isTrue);
      m.end(first);
      expect(m.isRunning, isFalse);
      final CloudVisionCancellation? third = m.begin();
      expect(third, isNotNull);
      expect(identical(third, first), isFalse);
    });
  });

  group('routed capture under contention', () {
    test(
        'a second routed capture while one is in flight is '
        'refused and never reaches the camera', () async {
      final CameraOwnership ownership = CameraOwnership();
      final Completer<CameraFrameCapture> gate =
          Completer<CameraFrameCapture>();
      final _FakeSource single = _FakeSource(() => gate.future);
      final RoutedCameraFrameSource routed = RoutedCameraFrameSource(
        yoloLiveActive: () => false,
        yoloSource: _FakeSource(
          () async => CameraFrameCapture.failed(
            CameraFrameFailure.unavailable,
          ),
        ),
        singleShotSource: single,
        ownership: ownership,
      );
      final Future<CameraFrameCapture> first = routed.captureSingleFrame();
      await Future<void>.delayed(Duration.zero);
      expect(ownership.isHeldBy(CameraUse.singleShot), isTrue);
      final CameraFrameCapture second = await routed.captureSingleFrame();
      expect(second.ok, isFalse);
      expect(single.calls, 1); // never double-opened
      gate.complete(
        CameraFrameCapture.ok(Uint8List.fromList(<int>[1, 2, 3])),
      );
      expect((await first).ok, isTrue);
      expect(ownership.isHeld, isFalse); // released afterwards
    });
  });
}
