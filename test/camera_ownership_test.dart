import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/camera_frame.dart';

class _FuncSource implements CameraFrameSource {
  final Future<CameraFrameCapture> Function(int call) fn;
  int calls = 0;
  _FuncSource(this.fn);

  @override
  Future<CameraFrameCapture> captureSingleFrame() {
    calls += 1;
    return fn(calls);
  }
}

CameraFrameCapture _ok() =>
    CameraFrameCapture.ok(Uint8List.fromList(<int>[1, 2, 3]));

RoutedCameraFrameSource _routed(
  CameraOwnership ownership,
  CameraFrameSource single,
) =>
    RoutedCameraFrameSource(
      yoloLiveActive: () => false,
      yoloSource: _FuncSource(
        (_) async => CameraFrameCapture.failed(
          CameraFrameFailure.unavailable,
        ),
      ),
      singleShotSource: single,
      ownership: ownership,
    );

void main() {
  group('CameraOwnership leases', () {
    test('mutual exclusion: a different use is refused while held', () async {
      final CameraOwnership o = CameraOwnership();
      final CameraLease? yolo = await o.tryAcquire(CameraUse.yoloLive);
      expect(yolo, isNotNull);
      expect(await o.tryAcquire(CameraUse.singleShot), isNull);
      // The live view is a persistent holder: same-use re-acquire
      // returns the SAME lease.
      final CameraLease? again = await o.tryAcquire(CameraUse.yoloLive);
      expect(identical(again, yolo), isTrue);
      await o.release(yolo!);
      expect(o.isHeld, isFalse);
      final CameraLease? shot = await o.tryAcquire(CameraUse.singleShot);
      expect(shot, isNotNull);
      expect(await o.tryAcquire(CameraUse.yoloLive), isNull);
      // A one-shot is exclusive: no re-entry while in flight.
      expect(await o.tryAcquire(CameraUse.singleShot), isNull);
    });

    test(
        'only the current lease can release: a stale lease '
        'releases nothing', () async {
      final CameraOwnership o = CameraOwnership();
      final CameraLease a = (await o.tryAcquire(CameraUse.singleShot))!;
      await o.release(a);
      final CameraLease b = (await o.tryAcquire(CameraUse.singleShot))!;
      expect(b.generation, greaterThan(a.generation));
      await o.release(a); // stale: must NOT free b's lock
      expect(o.isHeldBy(CameraUse.singleShot), isTrue);
      expect(identical(o.currentLease, b), isTrue);
      await o.release(b);
      expect(o.isHeld, isFalse);
    });

    test(
        'acquire waits for a pending physical release; on '
        'timeout it refuses', () async {
      final CameraOwnership o = CameraOwnership();
      final CameraLease a = (await o.tryAcquire(CameraUse.yoloLive))!;
      final Completer<void> physical = Completer<void>();
      final Future<void> releasing = o.release(a, waitFor: physical.future);
      expect(o.isReleasePending, isTrue);
      // A short-timeout acquire gives up while teardown pends.
      expect(
        await o.tryAcquire(
          CameraUse.singleShot,
          timeout: const Duration(milliseconds: 50),
        ),
        isNull,
      );
      physical.complete();
      await releasing;
      expect(o.isHeld, isFalse);
      final CameraLease? b = await o.tryAcquire(CameraUse.singleShot);
      expect(b, isNotNull);
    });

    test('cancelAllAndRelease cancels EVERY registered token', () async {
      final CameraOwnership o = CameraOwnership();
      final CloudVisionCancellation a = CloudVisionCancellation();
      final CloudVisionCancellation b = CloudVisionCancellation();
      o.registerCancellation(a);
      o.registerCancellation(b);
      await o.tryAcquire(CameraUse.singleShot);
      o.cancelAllAndRelease();
      expect(a.isCancelled, isTrue);
      expect(b.isCancelled, isTrue);
      expect(o.activeCancellations, 0);
    });
  });

  group('VisionRunManager token discipline', () {
    test(
        'a duplicate begin() is refused and does NOT overwrite '
        'the running token', () {
      final VisionRunManager m = VisionRunManager();
      final CloudVisionCancellation? first = m.begin();
      expect(first, isNotNull);
      expect(m.begin(), isNull);
      expect(identical(m.activeToken, first), isTrue);
      expect(first!.isCancelled, isFalse);
      m.cancelActive();
      expect(first.isCancelled, isTrue);
      m.end(first);
      expect(m.isRunning, isFalse);
      final CloudVisionCancellation? third = m.begin();
      expect(third, isNotNull);
      expect(identical(third, first), isFalse);
    });
  });

  group('formal race: suspended A, cancelAll, then B', () {
    test(
        'after A completes late, the owner is still B and YOLO '
        'acquire is still refused; A\'s finally frees nothing', () async {
      final CameraOwnership ownership = CameraOwnership();
      final Completer<CameraFrameCapture> gateA =
          Completer<CameraFrameCapture>();
      final Completer<CameraFrameCapture> gateB =
          Completer<CameraFrameCapture>();
      final _FuncSource source = _FuncSource(
        (int call) => call == 1 ? gateA.future : gateB.future,
      );
      final RoutedCameraFrameSource routed = _routed(ownership, source);

      // A starts and hangs inside the capture.
      final Future<CameraFrameCapture> futureA = routed.captureSingleFrame();
      await Future<void>.delayed(Duration.zero);
      expect(ownership.isHeldBy(CameraUse.singleShot), isTrue);
      expect(source.calls, 1);

      // The app backgrounds: cancel everything + start release.
      ownership.cancelAllAndRelease();

      // B starts: its acquire waits for A's physical release.
      final Future<CameraFrameCapture> futureB = routed.captureSingleFrame();
      await Future<void>.delayed(Duration.zero);

      // A's hardware operation finally completes (its dispose is
      // part of that future). A's own finally tries to release
      // A's lease -- by then B owns the camera.
      gateA.complete(_ok());
      expect((await futureA).ok, isTrue);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // B is now the owner, still mid-capture.
      expect(source.calls, 2);
      expect(ownership.isHeldBy(CameraUse.singleShot), isTrue);
      // YOLO still cannot take the camera.
      expect(await ownership.tryAcquire(CameraUse.yoloLive), isNull);
      expect(ownership.isHeldBy(CameraUse.singleShot), isTrue);

      gateB.complete(_ok());
      expect((await futureB).ok, isTrue);
      expect(ownership.isHeld, isFalse);
    });

    test(
        'a routed capture while YOLO holds the arbiter is '
        'refused without touching the camera', () async {
      final CameraOwnership ownership = CameraOwnership();
      await ownership.tryAcquire(CameraUse.yoloLive);
      final _FuncSource single = _FuncSource((_) async => _ok());
      final RoutedCameraFrameSource routed = _routed(ownership, single);
      final CameraFrameCapture capture = await routed.captureSingleFrame();
      expect(capture.ok, isFalse);
      expect(capture.detail, cameraBusySpeech);
      expect(single.calls, 0);
    });
  });
}
