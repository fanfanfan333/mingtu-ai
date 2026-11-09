import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/config/app_config.dart';

/// The bundled YOLO model contract: a real official asset at
/// a local path (never a bare model ID the plugin would try
/// to download on-device), fetched and verified by script.
void main() {
  test('the default model path is the bundled asset', () {
    expect(AppConfig.yoloModelPath, 'assets/models/yolo11n.tflite');
  });

  test('pubspec declares the model asset', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- assets/models/yolo11n.tflite'));
  });

  test(
      'the fetch script pins the official source and the '
      'SHA256 of the verified download', () {
    final String script = File('tool/fetch_model.sh').readAsStringSync();
    expect(
      script,
      contains(
          'https://github.com/ultralytics/yolo-flutter-app/releases/download/v0.2.0/yolo11n_int8.tflite'),
    );
    expect(
      script,
      contains(
          '414ff688f0c47cbe03cadd3118d22b9024f68e097c8c33bbb25f704d1ca0624d'),
    );
    expect(script, contains('2831727'));
  });

  test(
      'the bundled model file, when present (after running '
      'tool/fetch_model.sh), is a real TFLite of the pinned '
      'size', () {
    final File f = File('assets/models/yolo11n.tflite');
    if (!f.existsSync()) {
      // The binary is fetched by script before building and
      // is not distributed through this repo's text channel;
      // its absence here must not fail the suite -- but the
      // declarations above still pin the contract.
      return;
    }
    final List<int> bytes = f.readAsBytesSync();
    expect(bytes.length, 2831727);
    // TFLite flatbuffer identifier at offset 4.
    expect(String.fromCharCodes(bytes.sublist(4, 8)), 'TFL3');
  });

  test(
      'the manifest declares TTS and recognition service '
      'visibility for Android 11+', () {
    final String manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android.intent.action.TTS_SERVICE'));
    expect(manifest, contains('android.speech.RecognitionService'));
  });
}
