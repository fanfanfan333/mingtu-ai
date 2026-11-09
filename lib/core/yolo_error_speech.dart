/// YOLO live-view error classification (step 2 follow-up):
/// a CAMERA PERMISSION denial and a MODEL LOAD failure are
/// different problems with different remedies, and the user
/// must hear which one happened -- not one shared sentence.
///
/// The plugin's error objects are classified by their text
/// shape. This is a heuristic over an external error surface,
/// so the fallback is an honest generic sentence that names
/// both possibilities instead of guessing one.
library;

enum YoloViewErrorKind { cameraPermissionDenied, modelLoadFailed, unknown }

YoloViewErrorKind classifyYoloViewError(Object error) {
  final String s = error.toString().toLowerCase();
  // Permission first: 'denied' is decisive even when the
  // message also mentions the camera pipeline.
  if (s.contains('permission') ||
      s.contains('denied') ||
      s.contains('not authorized') ||
      s.contains('unauthorized') ||
      s.contains('camera_access')) {
    return YoloViewErrorKind.cameraPermissionDenied;
  }
  if (s.contains('model') ||
      s.contains('tflite') ||
      s.contains('litert') ||
      s.contains('load')) {
    return YoloViewErrorKind.modelLoadFailed;
  }
  return YoloViewErrorKind.unknown;
}

String yoloViewErrorSpeech(YoloViewErrorKind kind) => switch (kind) {
      YoloViewErrorKind.cameraPermissionDenied =>
        '没有摄像头权限，无法检测危险，请在设置中开启摄像头权限。',
      YoloViewErrorKind.modelLoadFailed => '目标检测模型加载失败，YOLO 实时检测不可用。',
      YoloViewErrorKind.unknown => 'YOLO 实时检测不可用：摄像头或模型加载失败。',
    };

String yoloViewErrorStatus(YoloViewErrorKind kind) => switch (kind) {
      YoloViewErrorKind.cameraPermissionDenied => 'YOLO：没有摄像头权限，实时检测不可用',
      YoloViewErrorKind.modelLoadFailed => 'YOLO：模型加载失败，实时检测不可用',
      YoloViewErrorKind.unknown => 'YOLO：实时视图出错，目标检测不可用',
    };
