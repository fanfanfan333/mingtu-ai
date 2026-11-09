/// Production startup initialisation for Mingtu AI, extracted
/// so the REAL startup path can be fault-injection tested.
///
/// Every module -- camera, configuration, Amap, location /
/// permission provider, TTS, ASR, YOLO -- is constructed /
/// initialised behind its own guard (see core/startup_guard).
/// A throw records the module's Chinese name in the failure
/// log and installs the honest degraded fallback; this
/// function never throws, and the caller finishes startup with
/// ONE unified announcement naming every unavailable module.
///
/// The factories are the injection seam: production passes
/// nothing (the real adapters are built), tests pass factories
/// that throw -- exercising this exact production path, not a
/// simulation of it.
library;

import 'dart:async';

import '../core/camera_frame.dart';
import '../core/startup_guard.dart';
import '../config/app_config.dart';
import 'amap_client.dart';
import 'current_location.dart';
import 'system_voice_io.dart';
import 'yolo_detector.dart';

/// What startup managed to bring up. Fallbacks are the honest
/// "unavailable / unconfigured" variants, never simulations.
class StartupInitResult {
  const StartupInitResult({
    required this.frameSource,
    required this.amapClient,
    required this.locationProvider,
    required this.tts,
    required this.ttsOk,
    required this.asr,
    required this.asrOk,
    required this.yolo,
  });

  final CameraFrameSource frameSource;
  final AmapWalkingClient amapClient;
  final CurrentLocationProvider locationProvider;

  /// The TTS adapter when its construction succeeded (kept for
  /// status reporting even when [ttsOk] is false); null when
  /// construction itself threw.
  final SystemVoiceOutput? tts;
  final bool ttsOk;

  /// Same contract as [tts] for speech recognition.
  final SystemVoiceInput? asr;
  final bool asrOk;

  final YoloDetector yolo;
}

/// Default configuration probe: reading the compile-time
/// configuration must not be able to take startup down either.
Future<void> _defaultConfigProbe() async {
  final List<String> probe = <String>[
    AppConfig.yoloModelPath,
    AppConfig.visionProxyUrl,
    AppConfig.routeProxyUrl,
  ];
  if (probe.length != 3) {
    throw StateError('configuration probe failed');
  }
}

Future<StartupInitResult> initializeStartup({
  required CameraFrameSource Function() frameSourceFactory,
  Future<void> Function()? configProbe,
  AmapWalkingClient Function()? amapFactory,
  CurrentLocationProvider Function()? locationFactory,
  SystemVoiceOutput Function()? ttsFactory,
  SystemVoiceInput Function()? asrFactory,
  YoloDetector Function()? yoloFactory,
  StartupFailureLog? log,
}) async {
  final StartupFailureLog failures = log ?? startupFailures;

  // 摄像头: the camera pipeline itself.
  CameraFrameSource frameSource;
  try {
    frameSource = frameSourceFactory();
  } catch (_) {
    failures.record('摄像头');
    frameSource = const LastResortCameraFrameSource();
  }

  // 配置 / 高德 / 权限: construction probes (no permission is
  // requested and no network call happens at startup).
  AmapWalkingClient amapClient = AmapWalkingClient(proxyBaseUrl: '');
  CurrentLocationProvider locationProvider = const UnavailableCurrentLocation();
  await runStartupSteps(
    <StartupStep>[
      StartupStep('配置', configProbe ?? _defaultConfigProbe),
      StartupStep('高德', () async {
        amapClient = (amapFactory ??
            () => AmapWalkingClient(
                  proxyBaseUrl: AppConfig.routeProxyUrl,
                  demoKey: AppConfig.amapDemoKey,
                ))();
      }),
      StartupStep('权限', () async {
        locationProvider =
            (locationFactory ?? () => const GeolocatorCurrentLocation())();
      }),
    ],
    log: failures,
  );

  // 语音合成: a dead engine must never hang startup -- 3 s,
  // then the fallback stays. The adapter object is captured
  // before initialisation so its status stays reportable.
  SystemVoiceOutput? tts;
  final bool ttsOk = await guardStartupStep<bool>(
    '语音合成',
    () async {
      final SystemVoiceOutput adapter = (ttsFactory ?? SystemVoiceOutput.new)();
      tts = adapter;
      return adapter
          .initialize()
          .timeout(const Duration(seconds: 3), onTimeout: () => false);
    },
    fallback: false,
    log: failures,
  );

  // 语音识别: same contract.
  SystemVoiceInput? asr;
  final bool asrOk = await guardStartupStep<bool>(
    '语音识别',
    () async {
      final SystemVoiceInput adapter = (asrFactory ?? SystemVoiceInput.new)();
      asr = adapter;
      return adapter
          .initialize()
          .timeout(const Duration(seconds: 3), onTimeout: () => false);
    },
    fallback: false,
    log: failures,
  );

  // 目标检测.
  final YoloDetector yolo = await guardStartupStep<YoloDetector>(
    '目标检测',
    () async =>
        (yoloFactory ?? () => createYoloDetector(AppConfig.yoloModelPath))(),
    fallback: UnavailableYoloDetector(),
    log: failures,
  );

  return StartupInitResult(
    frameSource: frameSource,
    amapClient: amapClient,
    locationProvider: locationProvider,
    tts: tts,
    ttsOk: ttsOk,
    asr: asr,
    asrOk: asrOk,
    yolo: yolo,
  );
}
