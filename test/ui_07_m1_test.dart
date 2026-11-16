import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/config/app_config.dart';
import 'package:mingtu_ai/adapters/yolo_detector_mobile.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/core/yolo_error_speech.dart';

import 'support/posix_bash.dart';

/// Whether a release merged manifest or release APK is available to check.
///
/// Only in that case does the manifest case have to execute
/// `tool/check_release_manifest.sh`, which requires a real POSIX bash.
bool _releaseArtifactsPresent() {
  final merged = Directory('build/app/intermediates/merged_manifest/release');
  final apk = File('build/app/outputs/flutter-apk/app-release.apk');
  if (apk.existsSync()) {
    return true;
  }
  return merged.existsSync() &&
      merged
          .listSync(recursive: true)
          .whereType<File>()
          .any((file) => file.path.endsWith('AndroidManifest.xml'));
}

void main() {
  // The shell script is only executed when release artifacts exist; when it is
  // needed but no POSIX bash can run, the case is skipped with an explicit
  // reason instead of passing without ever running the script.
  final needsBash = _releaseArtifactsPresent();
  final posixBash = needsBash ? findUsableBash() : null;
  final bashSkipReason = needsBash && posixBash == null
      ? 'no usable POSIX bash on this host'
      : null;
  test('only the packaged asset is accepted', () {
    expect(AppConfig.yoloModelPath, packagedYoloModelPath);
    for (final path in [
      'yolo11n',
      'yolo11s',
      'yolo11n.tflite',
      '/tmp/model',
      'assets/other.tflite',
      '',
      ' '
    ]) {
      final logs = <String>[];
      expect(resolvePackagedYoloModelPath(path, log: logs.add),
          packagedYoloModelPath);
      expect(logs, hasLength(1));
      expect(
          logs.single, 'Non-packed model path ignored; using bundled asset.');
    }
    expect(resolvePackagedYoloModelPath(packagedYoloModelPath),
        packagedYoloModelPath);
  });
  test('model and service faults are distinct from camera denial', () {
    for (final error in [
      Exception('SecurityException'),
      Exception('Starting FGS without permission'),
      Exception('Permission Denial: startForeground'),
      PlatformException(
          code: 'failure', message: 'Permission Denial: startForeground'),
      MissingPluginException(
          'No implementation found for method getApplicationDocumentsDirectory'),
    ]) {
      expect(classifyYoloViewError(error), YoloViewErrorKind.modelLoadFailed);
    }
    expect(classifyYoloViewError(Exception('Camera permission denied')),
        YoloViewErrorKind.cameraPermissionDenied);
    expect(
        classifyYoloViewError(PlatformException(
            code: 'camera_error', message: 'Camera permission denied')),
        YoloViewErrorKind.cameraPermissionDenied);
    expect(yoloViewErrorSpeech(YoloViewErrorKind.modelLoadFailed),
        localDetectionFaultText);
    expect(localDetectionFaultText, isNot(contains('安全')));
    expect(localDetectionFaultText, isNot(contains('可以过马路')));
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('text: yoloViewErrorSpeech(errorKind)'));
    expect(main, contains('kind: SpeechKind.alert'));
  });
  test('detector catches constructor faults and does not retry', () async {
    for (final error in [
      Exception('SecurityException'),
      PlatformException(code: 'failure', message: 'startForeground')
    ]) {
      var calls = 0;
      final detector = MobileYoloDetector(
          modelPath: packagedYoloModelPath,
          createModel: (_) {
            calls++;
            throw error;
          });
      expect(await detector.detectImage([]), isEmpty);
      expect(await detector.detectImage([]), isEmpty);
      expect(detector.isAvailable, isFalse);
      expect(calls, 1);
      expect(detector.status, isNot(contains('startForeground')));
    }
  });
  test('load fault is accepted by speech scheduler as an alert', () {
    final scheduler = SpeechScheduler();
    final now = DateTime.now();
    final request = SpeechRequest(
        id: 'fault',
        eventId: 'fault',
        text: yoloViewErrorSpeech(YoloViewErrorKind.modelLoadFailed),
        kind: SpeechKind.alert,
        createdAt: now,
        expiresAt: now.add(const Duration(minutes: 1)),
        navigationStateVersion: '');
    expect(scheduler.submit(request, now), isTrue);
    expect(scheduler.active?.text, localDetectionFaultText);
    expect(scheduler.active?.kind, SpeechKind.alert);
  });
  test('manifest removes permissions and services', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    for (final name in [
      'android.permission.FOREGROUND_SERVICE',
      'android.permission.FOREGROUND_SERVICE_DATA_SYNC',
      'android.permission.RECEIVE_BOOT_COMPLETED',
      'androidx.work.impl.foreground.SystemForegroundService',
      'androidx.work.impl.background.systemalarm.RescheduleReceiver',
      'com.google.android.play.core.assetpacks.ExtractionForegroundService',
      'com.google.android.play.core.assetpacks.AssetPackExtractionService'
    ]) {
      expect(manifest, contains('android:name="$name" tools:node="remove"'));
    }
    if (needsBash) {
      // `posixBash` is guaranteed non-null here: otherwise the case below is
      // skipped with an explicit reason instead of asserting on a script that
      // never ran.
      final result = Process.runSync(
          posixBash!, const ['tool/check_release_manifest.sh']);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    }
  }, skip: bashSkipReason);
}
