/// Phone single-frame camera source (camera plugin).
///
/// One trigger = one still photo: the controller is created for
/// the shot, [CameraController.takePicture] captures exactly one
/// frame, and the controller is disposed in `finally` -- the
/// camera is never left open by this path, no image stream is
/// started, nothing is recorded, and audio is disabled
/// (enableAudio: false).
///
/// Permission handling: the plugin requests the camera permission
/// when the controller initialises; a denial surfaces as a
/// [CameraException] whose code contains "Denied"/"Restricted",
/// which is mapped to [CameraFrameFailure.permissionDenied] so
/// the caller can announce it in Chinese. No outcome is silent
/// and no outcome is faked.
library;

import 'package:camera/camera.dart';

import '../core/camera_frame.dart';

CameraFrameSource createCameraFrameSource() => CameraPackageFrameSource();

class CameraPackageFrameSource implements CameraFrameSource {
  @override
  Future<CameraFrameCapture> captureSingleFrame() async {
    CameraController? controller;
    try {
      final List<CameraDescription> cameras = await availableCameras();
      if (cameras.isEmpty) {
        return CameraFrameCapture.failed(
          CameraFrameFailure.unavailable,
          detail: '设备没有可用摄像头。',
        );
      }
      final CameraDescription back = cameras.firstWhere(
        (CameraDescription c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      controller = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await controller.initialize();
      final XFile shot = await controller.takePicture();
      final bytes = await shot.readAsBytes();
      if (bytes.isEmpty) {
        return CameraFrameCapture.failed(
          CameraFrameFailure.failure,
          detail: '摄像头返回了空帧。',
        );
      }
      return CameraFrameCapture.ok(bytes);
    } on CameraException catch (e) {
      final String code = e.code;
      if (code.contains('Denied') || code.contains('Restricted')) {
        return CameraFrameCapture.failed(
          CameraFrameFailure.permissionDenied,
          detail: '摄像头权限被拒绝（$code）。',
        );
      }
      return CameraFrameCapture.failed(
        CameraFrameFailure.failure,
        detail: '摄像头异常（$code）。',
      );
    } catch (e) {
      return CameraFrameCapture.failed(
        CameraFrameFailure.failure,
        detail: '拍照失败：$e',
      );
    } finally {
      await controller?.dispose();
    }
  }
}
