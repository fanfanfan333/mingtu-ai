import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'adapters/amap_client.dart';
import 'adapters/bailian_client.dart';
import 'adapters/cloud_vision_client.dart';
import 'adapters/current_location.dart';
import 'adapters/system_voice_io.dart';
import 'adapters/voice_io.dart';
import 'adapters/yolo_detector.dart';
import 'adapters/yolo_live_view.dart';
import 'config/app_config.dart';
import 'core/event_bus.dart';
import 'core/cloud_vision.dart';
import 'core/health_monitor.dart';
import 'core/route_scoring.dart';
import 'core/llm_gateway.dart';
import 'core/contracts.dart';
import 'core/real_navigation.dart';
import 'core/voice_commands.dart';
import 'core/voice_startup.dart';
import 'core/risk_engine.dart';
import 'core/speech_scheduler.dart';
import 'core/task_manager.dart';
import 'modules/blind_path.dart';
import 'modules/emergency.dart';
import 'modules/hospital_task.dart';
import 'modules/entrance_finding.dart';
import 'modules/indoor_task.dart';
import 'modules/map_navigation.dart';
import 'modules/learning_backlog.dart';
import 'modules/recording.dart';
import 'modules/traffic_scene.dart';
import 'modules/visual_perception.dart';
import 'skills/destination_finding.dart';
import 'skills/environment_analysis.dart';
import 'skills/registry.dart';
import 'skills/route_planning.dart';

/// Mingtu AI v0.2 Flutter demo entry point.
///
/// Blind-first design, simulation honesty:
/// - Voice is the primary interaction in the design. This screen is an
///   auxiliary view for a sighted reviewer: it shows the current task
///   state and the current prompt as text, and every button is large
///   and labelled for Semantics.
/// - This web / VM run is a SIMULATION. It does not use a real camera,
///   GPS, microphone, TTS engine, Amap SDK or YOLO model. Buttons labelled
///   "演示" feed simulated inputs into the real core logic (task machine,
///   speech scheduler, risk engine, route scoring, LLM gateway). A
///   simulated result is never presented as a sensor measurement.
/// - Mingtu does not replace a cane, a guide dog or professional
///   orientation-and-mobility training, and it is NOT validated for
///   real-road safety. Do not use this demo for real navigation.
void main() {
  runApp(const MingtuApp());
}

class MingtuApp extends StatelessWidget {
  const MingtuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: '明途 AI v0.5',
      home: MingtuHomePage(),
    );
  }
}

class MingtuHomePage extends StatefulWidget {
  const MingtuHomePage({super.key});

  @override
  State<MingtuHomePage> createState() => _MingtuHomePageState();
}

class _MingtuHomePageState extends State<MingtuHomePage> {
  TaskManager _tasks = TaskManager();
  SpeechScheduler _scheduler = SpeechScheduler();
  MapNavigationService _mapService =
      MapNavigationService(StubMapProvider());
  late RoutePlanningSkill _routeSkill = RoutePlanningSkill(_mapService);
  final EnvironmentAnalysisSkill _envSkill = EnvironmentAnalysisSkill();
  final DestinationFindingSkill _destSkill = DestinationFindingSkill();
  final BlindPathService _blind = BlindPathService();
  IndoorTask _indoor = IndoorTask();
  final EmergencyService _emergency = EmergencyService();
  RecordingManager _recording = RecordingManager();
  VisualPerception _perception = VisualPerception();
  LlmGateway? _gateway;
  // Refactor phase 1 unified core: one event bus and one health
  // monitor for the whole demo. Modules must publish here instead of
  // keeping private state that can contradict the task manager.
  final EventBus _events = EventBus();
  final HealthMonitor _health = HealthMonitor();
  // v0.4: the demo now goes through the Skill registry, the
  // traffic-info replacement and the record-only learning backlog.
  final SkillRegistry _registry = defaultSkillRegistry();
  final TrafficSceneService _traffic = TrafficSceneService();
  final LearningBacklog _backlog = LearningBacklog();
  String _trafficText = '路口信息未提示（只提示，不放行）。';

  String _currentPrompt = '尚未开始。';
  final List<String> _log = <String>[];
  bool _straightConfirmed = false;
  bool _riskActive = false;
  String _navVersion = 'nav-v0';
  String _straightNavVersion = 'nav-v0';
  Timer? _straightTimer;

  String _routeText = '尚未规划路线。';
  String _obstacleText = '尚未模拟障碍。';
  String _entranceText = '尚未寻找入口。';
  String _indoorText = '室内任务未开始。';
  String _emergencyText = '未触发紧急求助。';
  String _recordingText = '未开始录像。';
  String _llmText = '未申请云端调用。';
  String _cloudVisionText = '云端视觉辅助：未请求。';
  // Cloud vision assist (low frequency): one client for the app's
  // lifetime so its rate limiter spans taps. Configured only with
  // the proxy base URL -- there is no key on this device.
  final CloudVisionClient _cloudVisionClient =
      CloudVisionClient(proxyBaseUrl: AppConfig.routeProxyUrl);
  // The latest camera frame, when a frame source is wired to
  // Dart. Today the YOLO live view keeps frames inside the plugin
  // view, so this stays null and the assist honestly reports
  // "没有可用画面" instead of inventing an image.
  Uint8List? _latestFrameBytes;
  String _perceptionText = '尚未模拟感知帧。';
  // v0.6 real integrations. Defaults are the unavailable fallbacks;
  // _initRealIntegrations replaces them only when the phone's own
  // engine / model actually answers. Nothing here fakes a service.
  VoiceOutput _voiceOutput = UnavailableVoiceOutput();
  VoiceInput _voiceInput = UnavailableVoiceInput();
  YoloDetector _yoloDetector = UnavailableYoloDetector();
  StreamSubscription<String>? _transcriptSub;
  StreamSubscription<String>? _asrErrorSub;
  // Voice P0 re-test fixes: once TTS has failed at runtime the app
  // is in a perceptible voice-failed state (no simulated success,
  // no automatic ASR restart); once an ASR error has been announced
  // it is not announced again (no retry/announce loop).
  bool _ttsFailed = false;
  bool _asrErrorAnnounced = false;
  String _voiceText = '语音：未初始化（演示文本播报）。';
  String _amapText = '高德真实路线：未请求。';
  String _yoloText = 'YOLO：未接入。';
  bool _yoloLiveOpen = false;
  double? _yoloLatencyMs;
  // v0.7 voice-first additions.
  AmapStepSpeaker? _amapSpeaker;
  bool _autoListenEnabled = false;
  bool _welcomeListenPending = false;
  bool _yoloRiskActive = false;
  int _yoloEmptyFrames = 0;

  // Blind-first voice control: the command text is a simulation of a
  // real recogniser transcript until system ASR is integrated (see
  // adapters/voice_io.dart). The last spoken prompt is kept so the
  // user can ask to hear it again.
  final TextEditingController _voiceController = TextEditingController();
  String _lastSpokenText = '';
  HospitalTask _hospital = HospitalTask();
  String _hospitalText = '医院挂号未开始（逻辑步骤演示，非真实挂号）。';

  @override
  void initState() {
    super.initState();
    _initRealIntegrations();
  }

  /// Try the phone's own engines once at startup. Each adapter
  /// reports unavailable instead of throwing, so a missing engine
  /// (web, VM, test harness, denied permission) just leaves the
  /// demo fallback in place.
  Future<void> _initRealIntegrations() async {
    // A dead engine must never hang startup: 3 s per engine, then
    // the demo fallback stays in place.
    final SystemVoiceOutput tts = SystemVoiceOutput();
    final bool ttsOk = await tts
        .initialize()
        .timeout(const Duration(seconds: 3), onTimeout: () => false);
    final SystemVoiceInput asr = SystemVoiceInput();
    final bool asrOk = await asr
        .initialize()
        .timeout(const Duration(seconds: 3), onTimeout: () => false);
    if (!mounted) return;
    if (asrOk) {
      _voiceInput = asr;
      _transcriptSub = asr.transcripts.listen((String text) {
        if (mounted) _handleVoiceCommand(text);
      });
      // ASR runtime errors surface through the adapter's error
      // stream (previously they only rewrote an unwatched status
      // string and the listen loop retried into the failure).
      _asrErrorSub = asr.errors.listen((String error) {
        if (mounted) _handleAsrError(error);
      });
    }
    _yoloDetector = createYoloDetector(AppConfig.yoloModelPath);
    // P0 startup plan (pure logic in core/voice_startup.dart): the
    // greeting is spoken whenever *Chinese* speech is verified
    // usable -- including when ASR failed, which previously left
    // the user in total silence because the greeting only ran
    // `if (asrOk)`. An engine that answers but has no zh-CN voice
    // is NOT adopted as the voice output: speaking Chinese text in
    // a non-Chinese voice would be a false "voice works" signal.
    final StartupVoicePlan plan = planStartupVoice(
      ttsEngineOk: ttsOk,
      chineseVoiceVerified: ttsOk && tts.chineseVoiceVerified,
      asrOk: asrOk,
    );
    if (plan.speechUsable) _voiceOutput = tts;
    _health.report(
      'voice_output',
      plan.speechUsable
          ? ServiceHealthStatus.ok
          : ServiceHealthStatus.degraded,
      '${tts.status}｜${plan.summary}',
    );
    _health.report(
      'voice_input',
      asrOk ? ServiceHealthStatus.ok : ServiceHealthStatus.degraded,
      asr.status,
    );
    setState(() {
      _voiceText = '语音：TTS：${tts.status}；ASR：${asr.status}。${plan.summary}';
      _yoloText = 'YOLO：${_yoloDetector.status}';
      if (!plan.speechUsable) {
        _currentPrompt = voiceNoticeText(VoiceNoticeKind.ttsUnavailable);
      }
    });
    if (plan.speechUsable) {
      // Hands-free entry (v0.7): greet by voice first; listening
      // starts only after the greeting finishes (see _finishSpeech),
      // so the microphone never hears the app's own voice as a
      // command. When ASR is down the greeting itself carries the
      // failure and the recoverable next step, and auto-listen
      // stays off (plan.startAutoListen is false then).
      if (plan.startAutoListen) {
        _autoListenEnabled = true;
        _welcomeListenPending = true;
      }
      _say(_request(
        id: 'voice-welcome',
        eventId: 'voice-welcome',
        text: plan.spokenText!,
        kind: SpeechKind.info,
      ));
    } else {
      // TTS cannot announce its own failure. Fall back to what is
      // actually available: a vibration cue plus the on-screen
      // status text above (readable by a screen reader), and say
      // plainly in the log that nothing was spoken.
      HapticFeedback.vibrate();
      _logMsg('语音播报不可用：已用振动提示，以上状态仅为文字显示，'
          '未被语音读出。${plan.summary}');
    }
  }

  /// An ASR error event from the adapter: announce it ONCE through
  /// the still-working voice (or the status surface when voice is
  /// already failed), report it, and switch the turn-taking loop
  /// OFF so nothing retries listening into a dead recogniser.
  void _handleAsrError(String error) {
    if (_asrErrorAnnounced) return;
    _asrErrorAnnounced = true;
    _autoListenEnabled = false;
    _welcomeListenPending = false;
    _health.report(
      'voice_input',
      ServiceHealthStatus.degraded,
      '语音识别运行中出错：$error',
    );
    _logMsg('语音识别运行中出错（$error）：已停止自动再听，不会循环重试。');
    if (_voiceOutput.isAvailable && !_ttsFailed) {
      _say(_request(
        id: 'asr-error-${DateTime.now().millisecondsSinceEpoch}',
        eventId: 'asr-error-${DateTime.now().millisecondsSinceEpoch}',
        text: voiceNoticeText(VoiceNoticeKind.asrUnavailable),
        kind: SpeechKind.info,
      ));
    } else {
      setState(() {
        _voiceText = '语音识别运行中出错：$error。已停止自动聆听。';
      });
    }
  }

  /// Start one short ASR session, but only after speech has finished:
  /// the turn-taking loop for a blind user. Called from
  /// [_finishSpeech] (after the welcome greeting, and after every
  /// prompt while a task is running) -- never while TTS is speaking.
  void _maybeStartListeningAfterSpeech() {
    // After a runtime TTS failure the loop stays off: speech state
    // is untrusted, and ASR must not auto-restart (re-test fix).
    if (_ttsFailed) return;
    if (!_autoListenEnabled || !_voiceInput.isAvailable) return;
    if (_voiceInput is! SystemVoiceInput) return;
    final SystemVoiceInput input = _voiceInput as SystemVoiceInput;
    if (input.isListening) return;
    if (_welcomeListenPending) {
      _welcomeListenPending = false;
      _startListening();
      return;
    }
    switch (_tasks.state) {
      case TaskState.navigating:
      case TaskState.paused:
      case TaskState.avoidingObstacle:
      case TaskState.findingEntrance:
      case TaskState.indoorGuidance:
      case TaskState.waitingConfirmation:
      case TaskState.planning:
      case TaskState.understanding:
      case TaskState.preparing:
      case TaskState.executing:
      case TaskState.degraded:
      case TaskState.listening:
        _startListening();
      default:
        return;
    }
  }

  @override
  void dispose() {
    _straightTimer?.cancel();
    _transcriptSub?.cancel();
    _asrErrorSub?.cancel();
    _voiceController.dispose();
    super.dispose();
  }

  void _logMsg(String message) {
    setState(() {
      _log.insert(0, message);
      if (_log.length > 50) {
        _log.removeRange(50, _log.length);
      }
    });
  }

  SpeechRequest _request({
    required String id,
    required String eventId,
    required String text,
    required SpeechKind kind,
    bool requiresStraight = false,
    int expiresSeconds = 5,
  }) {
    final DateTime now = DateTime.now();
    return SpeechRequest(
      id: id,
      eventId: eventId,
      text: text,
      kind: kind,
      createdAt: now,
      expiresAt: now.add(Duration(seconds: expiresSeconds)),
      navigationStateVersion: _navVersion,
      requiresStraightSegment: requiresStraight,
    );
  }

  /// Submit a prompt through the scheduler only. Returns true if the
  /// scheduler accepted it as active or queued. Speech completion is
  /// simulated after a short delay in this demo; completion of a spoken
  /// prompt is NEVER treated as completion of a physical action.
  void _publishSpeech(SpeechRequest request) {
    final DateTime now = DateTime.now();
    _events.publish(
      MingtuEvent(
        eventId: 'speech-${request.id}',
        type: MingtuEventType.speechRequested,
        taskId: _tasks.taskId,
        createdAt: now,
        source: 'speech_scheduler',
        dataVersion: 0,
        expiresAt: request.expiresAt,
        payload: <String, Object?>{'text': request.text, 'kind': request.kind.name},
      ),
      now,
    );
  }

  bool _say(SpeechRequest request) {
    final DateTime now = DateTime.now();
    final bool accepted = _scheduler.submit(request, now);
    if (accepted) _publishSpeech(request);
    setState(() {
      if (accepted && _scheduler.active?.id == request.id) {
        _currentPrompt = request.text;
        _lastSpokenText = request.text;
      } else if (accepted) {
        _currentPrompt = '已排队：${request.text}';
      } else {
        _currentPrompt = '未播报（调度器已丢弃过期或重复提示）：${request.text}';
      }
    });
    // v0.6: real TTS when the phone's engine is reachable; the
    // prompt completes only when the engine reports completion.
    // Otherwise the old simulated 1200 ms timing is used.
    if (accepted && _scheduler.active?.id == request.id) {
      _speakActive(request);
    }
    return accepted;
  }

  /// Shared completion step: mark the active prompt spoken, then
  /// promote the next queued prompt if it is still valid -- and speak
  /// it too, through the same real-or-simulated path.
  void _finishSpeech(String id) {
    if (_scheduler.active?.id == id) {
      _scheduler.completeActive();
      final SpeechRequest? next = _scheduler.promoteNext(
        DateTime.now(),
        straightSegmentConfirmed: _straightConfirmed,
        riskActive: _riskActive,
      );
      if (next == null) {
        // Speech is done and nothing is queued: the turn-taking
        // loop may open the microphone now (v0.7).
        _maybeStartListeningAfterSpeech();
        return;
      }
      setState(() {
        _currentPrompt = next.text;
        _lastSpokenText = next.text;
      });
      _speakActive(next);
    }
  }

  /// Speak the currently active prompt: real TTS when available,
  /// simulated timing otherwise.
  void _speakActive(SpeechRequest request) {
    if (_voiceOutput.isAvailable) {
      _voiceOutput.speak(request.text).then((_) {
        // Stop-race guard (Codex re-test): a request the user has
        // since cancelled (pause/cancel -> cancelAll) may complete
        // late; its completion must not drive _finishSpeech (which
        // could reopen the microphone or promote stale state).
        if (!mounted) return;
        if (_scheduler.cancelledLog.contains(request.id)) {
          _logMsg('已取消播报的迟到完成回调已忽略（${request.id}）。');
          return;
        }
        _finishSpeech(request.id);
      }).catchError((Object e) {
        // Same guard for the error path: a cancelled utterance
        // failing late is not a new TTS failure.
        if (_scheduler.cancelledLog.contains(request.id)) {
          _logMsg('已取消播报的迟到失败回调已忽略（${request.id}）：$e');
          return null;
        }
        if (mounted) _handleTtsFailure(e);
        return null;
      });
    } else {
      _simulateSpeechCompletion(request.id);
    }
  }

  /// Runtime TTS failure (Codex re-test fix). The old behaviour --
  /// swap in the unavailable output and *simulate* the prompt's
  /// completion -- faked success: navigation kept running and the
  /// speech-finish chain could restart ASR as if the user had
  /// heard the prompt. Now the failure is a perceptible state:
  /// vibration, the on-screen "not read aloud" notice (screen
  /// reader), health=unavailable, all pending speech cancelled,
  /// straight prompts stopped, the task paused, and NO simulated
  /// completion and NO automatic ASR restart (_ttsFailed also
  /// blocks _maybeStartListeningAfterSpeech).
  void _handleTtsFailure(Object error) {
    _ttsFailed = true;
    _voiceOutput = UnavailableVoiceOutput();
    _health.report(
      'voice_output',
      ServiceHealthStatus.unavailable,
      '运行中语音合成失败：$error',
    );
    _stopStraightTimer();
    _scheduler.cancelAll();
    if (_tasks.canTransitionTo(TaskState.paused)) {
      _tasks.transitionTo(TaskState.paused, trigger: 'tts-failure');
    }
    setState(() {
      _straightConfirmed = false;
      _currentPrompt = voiceNoticeText(VoiceNoticeKind.ttsUnavailable);
    });
    HapticFeedback.vibrate();
    _logMsg('语音合成运行中失败：已振动提示并停用导航、取消全部待播报；'
        '未模拟播报成功，也不会自动重启语音识别。错误：$error');
  }

  /// Demo fallback only: the old simulated 1200 ms completion, used
  /// when no real TTS engine is reachable (web / VM / test).
  void _simulateSpeechCompletion(String id) {
    Future<void>.delayed(const Duration(milliseconds: 1200), () {
      if (!mounted) {
        return;
      }
      _finishSpeech(id);
    });
  }

  void _startStraightTimer() {
    _straightTimer?.cancel();
    _straightTimer = Timer.periodic(
      const Duration(milliseconds: SpeechScheduler.straightIntervalMs),
      (_) => _straightTick(),
    );
  }

  void _stopStraightTimer() {
    _straightTimer?.cancel();
    _straightTimer = null;
  }

  void _straightTick() {
    if (!mounted) {
      return;
    }
    if (_tasks.state != TaskState.navigating ||
        !_straightConfirmed ||
        _riskActive) {
      return;
    }
    final DateTime now = DateTime.now();
    if (!_scheduler.shouldPlayStraight(
      now: now,
      straightSegmentConfirmed: true,
      riskActive: false,
    )) {
      return;
    }
    final SpeechRequest request = _request(
      id: 'straight-${now.millisecondsSinceEpoch}',
      eventId: 'straight-${now.millisecondsSinceEpoch}',
      text: '直走',
      kind: SpeechKind.straight,
      requiresStraight: true,
    );
    if (_say(request)) {
      _scheduler.recordStraightPlayed(now);
      _logMsg('直行提示：直走（3 秒节奏，仅在确认直线路段且无风险时）');
    }
  }

  // ---- Demo flow, in script order ----

  void _startVoice() {
    if (_tasks.state != TaskState.idle) {
      _logMsg('请先重置演示，再开始新任务。');
      return;
    }
    if (!_tasks.startTask(id: 'demo-library-1', goalText: '带我去图书馆（演示）')) {
      _logMsg('开始任务失败：任务状态机拒绝了开始。');
      return;
    }
    // v0.4 health coverage, honest by construction: the demo map is a
    // stub and there is no camera in this run. v0.6: voice_output is
    // only degraded when no real TTS engine is reachable -- when the
    // phone's engine is up, reporting it degraded would be a lie.
    _health.report('map_navigation', ServiceHealthStatus.degraded, '演示桩路线，非真实高德数据。');
    if (!_voiceOutput.isAvailable) {
      _health.report('voice_output', ServiceHealthStatus.degraded, '演示文本播报，非真实系统 TTS。');
    }
    _health.report('camera', ServiceHealthStatus.unavailable, '演示中无真实摄像头。');
    _recording.start('demo-recording', DateTime.now());
    setState(() {
      _recordingText = '录像已开始（本地演示会话，等待任务结束后的保留/删除选择）。';
    });
    _tasks.transitionTo(TaskState.understanding, trigger: 'voice-input');
    _logMsg('演示输入（非真实语音识别）：用户说“带我去图书馆”。');
    _say(_request(
      id: 'voice-heard',
      eventId: 'voice-heard',
      text: '已听到：带我去图书馆。演示输入，不是真实语音识别。',
      kind: SpeechKind.info,
    ));
    // v0.5: degraded services must be HEARD, not only shown as text.
    // A blind user cannot see the health line on screen.
    final String healthText = _health.announcementText();
    if (healthText.isNotEmpty) {
      _say(_request(
        id: 'health-announce',
        eventId: 'health-announce',
        text: healthText,
        kind: SpeechKind.info,
      ));
    }
  }

  void _planRoute() {
    if (_tasks.state != TaskState.understanding) {
      _logMsg('请先按“语音开始”，再规划路线。');
      return;
    }
    // v0.4 Skill wiring: route planning now goes through the registry
    // gate. If the Skill were disabled, planning would be refused here
    // instead of silently running anyway.
    final SkillExecutionResult gate = _registry.execute(
      'route_planning',
      preconditionsMet: true,
      riskOk: false,
      runner: () => {'skill': 'route_planning'},
    );
    if (gate.status != SkillExecutionStatus.ok) {
      _logMsg('路线规划被 Skill 注册表拒绝：${gate.reason}，未规划。');
      return;
    }
    _tasks.transitionTo(TaskState.planning, trigger: 'plan-route');
    final RoutePlanResult result =
        _routeSkill.plan('校园起点（占位）', '图书馆（占位）');
    setState(() {
      if (result.best == null) {
        _routeText = '无可用路线（演示占位数据）。';
      } else {
        _routeText = '已选路线：${result.best!.candidate.id}，'
            '距离 ${result.best!.candidate.distanceM.toStringAsFixed(0)} 米，'
            '得分 ${result.best!.score.toStringAsFixed(3)}。'
            '${result.best!.reason}';
      }
    });
    _logMsg('路线规划完成：${result.all.length} 条候选，'
        '无障碍信息均为 UNKNOWN，未按安全处理。');
    _say(_request(
      id: 'route-planned',
      eventId: 'route-planned',
      // Simulation labelling (navigation P0): this flow is the
      // stub/demo route, and its spoken start must SAY it is a
      // simulation -- a blind user cannot see the on-screen 演示
      // labels.
      text: '模拟导航：已规划演示路线，正在开始模拟导航。',
      kind: SpeechKind.info,
    ));
  }

  /// Navigation P0: start REAL voice navigation to a verified
  /// destination. The starter (core/real_navigation.dart) checks,
  /// in order: verified destination -> route proxy configured ->
  /// GPS fix -> accuracy -> route fetch. Every failure is spoken
  /// in Chinese and navigation does NOT start; nothing falls back
  /// to the simulated route silently. On success the task machine
  /// walks its legal chain to navigating and the first step is
  /// spoken; further steps stay manual ("下一步").
  Future<void> _startRealNavigation(String destinationName) async {
    if (_tasks.state != TaskState.idle) {
      _say(_request(
        id: 'real-nav-busy-${DateTime.now().millisecondsSinceEpoch}',
        eventId: 'real-nav-busy-${DateTime.now().millisecondsSinceEpoch}',
        text: '已有任务在进行，请先取消或完成当前任务。',
        kind: SpeechKind.info,
      ));
      return;
    }
    final RealNavigationStarter starter = RealNavigationStarter(
      locationProvider: const GeolocatorCurrentLocation(),
      client: AmapWalkingClient(proxyBaseUrl: AppConfig.routeProxyUrl),
    );
    final RealNavigationOutcome outcome = await starter.start(destinationName);
    if (!mounted) return;
    if (!outcome.ready) {
      final String text = outcome.failureAnnouncement;
      final bool locationProblem = outcome.failure ==
              RealNavigationFailure.locationServiceDisabled ||
          outcome.failure == RealNavigationFailure.locationPermissionDenied ||
          outcome.failure ==
              RealNavigationFailure.locationPermissionDeniedForever ||
          outcome.failure == RealNavigationFailure.locationFailed ||
          outcome.failure == RealNavigationFailure.locationTooInaccurate;
      _health.report(
        locationProblem ? 'location' : 'map_navigation',
        ServiceHealthStatus.degraded,
        text,
      );
      setState(() {
        _amapText = '真实导航未启动：$text';
        _routeText = _amapText;
      });
      _logMsg('真实导航未启动：$text');
      _say(_request(
        id: 'real-nav-failed-${DateTime.now().millisecondsSinceEpoch}',
        eventId: 'real-nav-failed-${DateTime.now().millisecondsSinceEpoch}',
        text: text,
        kind: SpeechKind.info,
      ));
      return;
    }
    final AmapWalkingResult result = outcome.route!;
    final RouteCandidate candidate = result.candidate!;
    _amapSpeaker = AmapStepSpeaker(result.steps);
    final String? firstStep = _amapSpeaker!.nextStepText();
    _tasks.startTask(
      id: 'real-nav-${DateTime.now().millisecondsSinceEpoch}',
      goalText: '带我去$destinationName（真实路线）',
    );
    _tasks.transitionTo(TaskState.understanding, trigger: 'real-nav');
    _tasks.transitionTo(TaskState.planning, trigger: 'real-nav');
    _tasks.transitionTo(TaskState.navigating, trigger: 'real-nav');
    _health.report('map_navigation', ServiceHealthStatus.ok,
        '高德步行路线已返回真实数据（经代理；无障碍信息仍未知）。');
    _health.report('location', ServiceHealthStatus.ok,
        'GPS 起点已取得（精度约 ${outcome.accuracyM!.toStringAsFixed(0)} 米）。');
    setState(() {
      _amapText = '高德真实路线：距离 ${candidate.distanceM.toStringAsFixed(0)} 米，'
          '${result.steps.length} 个路段。无障碍信息仍为 UNKNOWN，未按安全路线处理。';
      _routeText = _amapText;
    });
    _logMsg('真实导航已启动：${candidate.distanceM.toStringAsFixed(0)} 米，'
        '${result.steps.length} 个路段（手动逐步播报）。');
    _say(_request(
      id: 'real-nav-ready-${DateTime.now().millisecondsSinceEpoch}',
      eventId: 'real-nav-ready-${DateTime.now().millisecondsSinceEpoch}',
      text: realRouteReadyAnnouncement(
            destinationName: destinationName,
            distanceM: candidate.distanceM,
            stepsCount: result.steps.length,
          ) +
          (firstStep == null ? '' : '第一段：$firstStep'),
      kind: SpeechKind.info,
    ));
  }

  /// The on-screen "real route" button runs the same real
  /// navigation attempt as the voice command (destination 图书馆，
  /// which must exist in the verified registry).
  Future<void> _fetchAmapRoute() => _startRealNavigation('图书馆');

  /// v0.7: speak the next Amap walking step, in order. Saying
  /// "下一步" while navigating speaks the next step; when the steps
  /// run out it says so instead of inventing one.
  void _speakNextAmapStep() {
    final AmapStepSpeaker? speaker = _amapSpeaker;
    if (speaker == null || speaker.isDone) {
      _say(_request(
        id: 'amap-step-done-${DateTime.now().millisecondsSinceEpoch}',
        eventId: 'amap-step-done-${DateTime.now().millisecondsSinceEpoch}',
        text: '高德路段已播报完毕，没有下一段了。',
        kind: SpeechKind.info,
      ));
      return;
    }
    final String? text = speaker.nextStepText();
    if (text == null) return;
    _say(_request(
      id: 'amap-step-${DateTime.now().millisecondsSinceEpoch}',
      eventId: 'amap-step-${DateTime.now().millisecondsSinceEpoch}',
      text: text,
      kind: SpeechKind.info,
    ));
  }

  /// v0.6: one short ASR session (max 10 s). Recognised text flows
  /// through the transcript subscription into _handleVoiceCommand.
  /// Not continuous listening: the session stops on silence.
  Future<void> _startListening() async {
    if (!_voiceInput.isAvailable) {
      _logMsg('语音识别不可用：${_voiceInput.status}');
      return;
    }
    _autoListenEnabled = true;
    final SystemVoiceInput input = _voiceInput as SystemVoiceInput;
    final bool started = await input.startListening();
    if (!mounted) return;
    setState(() {
      _voiceText = started
          ? '语音识别进行中：请说一句话（最长 10 秒，说完停顿即结束）。'
          : '语音识别：开始失败，${_voiceInput.status}';
    });
    if (started) {
      _logMsg('语音识别已开始：请说一句话。');
    } else if (_voiceOutput.isAvailable) {
      // Runtime ASR failure must not be silent either: announce it
      // through the working voice, with the recoverable next step.
      _say(_request(
        id: 'asr-failed-${DateTime.now().millisecondsSinceEpoch}',
        eventId: 'asr-failed-${DateTime.now().millisecondsSinceEpoch}',
        text: voiceNoticeText(VoiceNoticeKind.asrUnavailable),
        kind: SpeechKind.info,
      ));
    }
  }

  /// Stop the physical TTS playback, when the real engine is in
  /// use. Queued/active scheduler entries are cancelled separately
  /// via SpeechScheduler.cancelAll; this stops what is already
  /// coming out of the speaker. The adapter's stop() no longer
  /// swallows errors, so a failed stop is caught HERE and surfaced
  /// in the log/status -- the user is told the stop may not have
  /// taken effect instead of the failure disappearing silently.
  Future<void> _stopTtsPlayback() async {
    final VoiceOutput out = _voiceOutput;
    if (out is SystemVoiceOutput) {
      try {
        await out.stop();
      } catch (e) {
        _logMsg('停止语音播报失败，播报可能仍在继续：$e');
        if (mounted) {
          setState(() {
            _voiceText = '停止语音播报失败：$e';
          });
        }
      }
    }
  }

  Future<void> _stopListening() async {
    // Manual stop also switches the turn-taking loop off, so the
    // microphone does not reopen by itself after the next prompt.
    _autoListenEnabled = false;
    _welcomeListenPending = false;
    if (_voiceInput is SystemVoiceInput) {
      try {
        await (_voiceInput as SystemVoiceInput).stopListening();
      } catch (e) {
        // stopListening no longer swallows platform errors; surface
        // them instead of pretending the microphone is closed.
        _logMsg('停止语音识别失败，麦克风可能仍在监听：$e');
      }
    }
    if (!mounted) return;
    setState(() {
      _voiceText = '语音：TTS：${_voiceOutput.status}；ASR：${_voiceInput.status}。';
    });
  }

  /// Stop-then-confirm sequencer (Codex re-test race fix).
  ///
  /// The bug: pause/cancel called cancelAll() and the async
  /// _stopTtsPlayback() WITHOUT awaiting it, then immediately
  /// submitted the confirmation prompt -- so the engine stop could
  /// land after the confirmation started and cut it off, or the
  /// confirmation was swallowed by the still-flushing queue.
  ///
  /// The fix: cancel the old requests first, then AWAIT the stop
  /// (bounded by a timeout so a hung engine cannot block the
  /// confirmation forever; a timeout is logged honestly), and
  /// only then submit the confirmation. Adapter-layer ordering is
  /// covered by test/voice_adapter_test.dart; physical interruption
  /// on a real device is NOT verified.
  Future<void> _stopSpeechThenConfirm({
    required String idPrefix,
    required String confirmText,
  }) async {
    final List<String> cancelled = _scheduler.cancelAll();
    if (cancelled.isNotEmpty) {
      _logMsg('已取消 ${cancelled.length} 条待播报提示。');
    }
    try {
      await _stopTtsPlayback().timeout(const Duration(milliseconds: 800));
    } on TimeoutException {
      _logMsg('停止播报 800 毫秒内未完成，先播报确认；旧声音可能短暂残留。');
    }
    if (!mounted) return;
    _say(_request(
      id: '$idPrefix-${DateTime.now().millisecondsSinceEpoch}',
      eventId: '$idPrefix-${DateTime.now().millisecondsSinceEpoch}',
      text: confirmText,
      kind: SpeechKind.info,
    ));
  }

  /// COCO classes that can be in a blind user's path, with their
  /// Chinese names for speech. Any other class is tracked but never
  /// treated as an obstacle.
  static const Map<String, String> _yoloObstacleLabels = <String, String>{
    'person': '行人',
    'bicycle': '自行车',
    'car': '汽车',
    'motorcycle': '摩托车',
    'bus': '公交车',
    'truck': '卡车',
  };

  /// v0.6: feed one YOLO frame's detections into the tracking /
  /// dedup pipeline. v0.7: a NEW track of a person/vehicle class now
  /// also enters the risk/speech loop -- it speaks a warning and
  /// stops straight prompts. It still never yields a step direction:
  /// a detection box has no distance, so no left/right step is ever
  /// spoken from YOLO alone. The risk clears only after 3 consecutive
  /// frames without such a detection, and straight never auto-resumes.
  void _onYoloDetections(List<Detection> detections) {
    final DateTime now = DateTime.now();
    final List<PerceptionEvent> events =
        _perception.processFrame(detections, now);
    final bool hasObstacleNow = detections.any((Detection d) =>
        _yoloObstacleLabels.containsKey(d.label) && d.confidence >= 0.3);
    if (hasObstacleNow) {
      _yoloEmptyFrames = 0;
    } else {
      _yoloEmptyFrames += 1;
    }
    final List<PerceptionEvent> newObstacles = events
        .where((PerceptionEvent e) =>
            e.isNewTrack && _yoloObstacleLabels.containsKey(e.label))
        .toList();
    if (newObstacles.isNotEmpty &&
        !_yoloRiskActive &&
        (_tasks.state == TaskState.navigating ||
            _tasks.state == TaskState.avoidingObstacle)) {
      _yoloRiskActive = true;
      if (_tasks.state == TaskState.navigating) {
        _tasks.transitionTo(TaskState.avoidingObstacle,
            trigger: 'yolo-obstacle');
        _stopStraightTimer();
        _scheduler.pauseStraight();
      }
      setState(() {
        _riskActive = true;
        _straightConfirmed = false;
      });
      final String names = newObstacles
          .map((PerceptionEvent e) =>
              _yoloObstacleLabels[e.label] ?? e.label)
          .join('、');
      _say(_request(
        id: 'yolo-obstacle-${now.millisecondsSinceEpoch}',
        eventId: 'yolo-obstacle-${now.millisecondsSinceEpoch}',
        text: '前方检测到$names，请注意。暂未确认距离，不给避让方向，请停下或寻求帮助。',
        kind: SpeechKind.obstacleAvoidance,
      ));
    } else if (_yoloRiskActive && _yoloEmptyFrames >= 3) {
      _yoloRiskActive = false;
      if (_tasks.state == TaskState.avoidingObstacle) {
        _tasks.transitionTo(TaskState.navigating, trigger: 'yolo-cleared');
      }
      setState(() {
        _riskActive = false;
        _straightConfirmed = false;
      });
      _say(_request(
        id: 'yolo-cleared-${now.millisecondsSinceEpoch}',
        eventId: 'yolo-cleared-${now.millisecondsSinceEpoch}',
        text: '前方已无检测到的障碍。请说继续，重新确认直行路段后再走。',
        kind: SpeechKind.info,
      ));
    }
    setState(() {
      _perceptionText = 'YOLO 实时：${detections.length} 个检测，'
          '新跟踪事件 ${events.length} 条，跟踪目标 ${_perception.tracks.length} 个。'
          '${_yoloLatencyMs == null ? '' : '单帧 ${_yoloLatencyMs!.toStringAsFixed(0)} 毫秒。'}';
    });
    if (events.isNotEmpty) {
      final String labels =
          events.map((PerceptionEvent e) => e.label).join('、');
      _logMsg('YOLO 新跟踪：$labels（仅报告检测，不给行走方向）。');
    }
  }

  void _startNavigating() {
    if (_tasks.state != TaskState.planning) {
      _logMsg('请先规划路线，再开始导航。');
      return;
    }
    _tasks.transitionTo(TaskState.navigating, trigger: 'start-navigation');
    setState(() {
      _straightConfirmed = true;
      _straightNavVersion = _navVersion;
      // v0.7: navigation starts the camera too -- a blind user must
      // not have to find and tap a button to turn perception on.
      // On web this shows the phone-only stub text.
      _yoloLiveOpen = true;
    });
    _startStraightTimer();
    _logMsg('开始导航：直行路段已确认，3 秒直行节奏已启动。');
    final DateTime now = DateTime.now();
    _say(_request(
      id: 'nav-start',
      eventId: 'nav-start',
      text: '直走',
      kind: SpeechKind.straight,
      requiresStraight: true,
    ));
    _scheduler.recordStraightPlayed(now);
  }

  void _manualStraight() {
    if (_tasks.state != TaskState.navigating ||
        !_straightConfirmed ||
        _riskActive) {
      _logMsg('当前不是可直行状态：请确认正在导航、直行路段已确认且无风险。');
      return;
    }
    final DateTime now = DateTime.now();
    if (!_scheduler.shouldPlayStraight(
      now: now,
      straightSegmentConfirmed: true,
      riskActive: false,
    )) {
      _logMsg('直行提示未到 3 秒间隔，调度器不重复播报。');
      return;
    }
    _say(_request(
      id: 'straight-manual-${now.millisecondsSinceEpoch}',
      eventId: 'straight-manual-${now.millisecondsSinceEpoch}',
      text: '直走',
      kind: SpeechKind.straight,
      requiresStraight: true,
    ));
    _scheduler.recordStraightPlayed(now);
  }

  void _turn() {
    if (_tasks.state != TaskState.navigating) {
      _logMsg('请先开始导航，再模拟转弯。');
      return;
    }
    _stopStraightTimer();
    _scheduler.pauseStraight();
    setState(() {
      _straightConfirmed = false;
    });
    _logMsg('转弯：直行节奏已暂停，过期直行提示不会补播。');
    _say(_request(
      id: 'turn-1',
      eventId: 'turn-1',
      text: '前方左转（演示）',
      kind: SpeechKind.turn,
    ));
  }

  void _reconfirmStraight() {
    if (_tasks.state != TaskState.navigating) {
      _logMsg('请先开始导航，再恢复直行。');
      return;
    }
    if (_riskActive) {
      _logMsg('仍有风险事件未解除，不能恢复直行。');
      return;
    }
    final DateTime now = DateTime.now();
    final bool resumed = _scheduler.resumeStraight(
      now: now,
      straightSegmentConfirmed: true,
      riskActive: false,
      currentNavigationVersion: _navVersion,
      straightNavigationVersion: _straightNavVersion,
    );
    if (resumed) {
      setState(() {
        _straightConfirmed = true;
      });
      _startStraightTimer();
      _logMsg('直行恢复：已重新确认直线路段与导航版本，3 秒计时器已重启。');
    } else {
      setState(() {
        _straightNavVersion = _navVersion;
        _straightConfirmed = true;
      });
      _scheduler.resumeStraight(
        now: now,
        straightSegmentConfirmed: true,
        riskActive: false,
        currentNavigationVersion: _navVersion,
        straightNavigationVersion: _navVersion,
      );
      _startStraightTimer();
      _logMsg('直行恢复：导航版本已变化，已重新确认当前路段后重启计时器，'
          '旧直行指令未补播。');
    }
    // v0.7: the re-confirmation must be HEARD, not only logged --
    // a blind user cannot see the log line.
    _say(_request(
      id: 'straight-resumed-${now.millisecondsSinceEpoch}',
      eventId: 'straight-resumed-${now.millisecondsSinceEpoch}',
      text: '已重新确认直线路段，继续直走。',
      kind: SpeechKind.straight,
      requiresStraight: true,
    ));
  }

  void _obstacleUncertain() {
    if (_tasks.state != TaskState.navigating) {
      _logMsg('请先开始导航，再模拟障碍。');
      return;
    }
    _tasks.transitionTo(TaskState.avoidingObstacle, trigger: 'obstacle');
    _stopStraightTimer();
    _scheduler.pauseStraight();
    setState(() {
      _riskActive = true;
    });
    final DateTime now = DateTime.now();
    final List<PerceptionEvent> events = _perception.processFrame(
      const <Detection>[
        Detection(label: '障碍物', confidence: 0.8, cx: 0.5, cy: 0.5),
      ],
      now,
    );
    final BlindPathAssessment blind = _blind.assess(
      blindPathVisible: true,
      blocked: true,
      alternativeConfirmed: false,
      alternativeSideKnown: false,
    );
    final RiskEvent event = RiskEvent(
      id: 'obstacle-uncertain',
      type: 'obstacle',
      createdAt: now,
      expiresAt: now.add(const Duration(seconds: 30)),
      evidence: const PerceptionEvidence(
        detectionConfidence: 0.8,
        spatialConfidence: 0.4,
        hasDistanceEstimate: false,
        sideSpaceConfirmed: false,
      ),
    );
    final RiskAssessment assessment =
        _envSkill.analyse(event, now).assessment;
    _backlog.record(
      'obstacle-uncertain-demo',
      'uncertain-side-space',
      '演示障碍：侧方未确认，只停下不给步数，离线复查用。',
      now,
    );
    setState(() {
      _perceptionText =
          '感知帧（演示）：新跟踪事件 ${events.length} 条，跟踪目标 ${_perception.tracks.length} 个。';
      _obstacleText = '障碍（侧方未确认）：${assessment.speechText}'
          '原因：${assessment.reason}，等级：${assessment.level.name}，'
          '动作：${assessment.action.name}，步数方向：${assessment.stepDirection?.name ?? 'none'}。'
          '盲道判断：${blind.speechText}';
    });
    _logMsg('障碍（侧方未确认）：风险引擎未给出左右步数，只给出停下提示。');
    _say(_request(
      id: 'obstacle-uncertain-prompt',
      eventId: 'obstacle-uncertain',
      text: assessment.speechText,
      kind: SpeechKind.obstacleAvoidance,
    ));
  }

  void _obstacleUncertainResolved() {
    if (_tasks.state != TaskState.avoidingObstacle) {
      _logMsg('当前不在避障状态。');
      return;
    }
    _tasks.transitionTo(TaskState.navigating, trigger: 'obstacle-cleared');
    setState(() {
      _riskActive = false;
      _straightConfirmed = true;
      _straightNavVersion = _navVersion;
    });
    _scheduler.resumeStraight(
      now: DateTime.now(),
      straightSegmentConfirmed: true,
      riskActive: false,
      currentNavigationVersion: _navVersion,
      straightNavigationVersion: _navVersion,
    );
    _startStraightTimer();
    _logMsg('障碍事件结束（演示重新评估）：已重新确认直行路段后恢复直行。');
  }

  void _obstacleConfirmed() {
    if (_tasks.state != TaskState.navigating) {
      _logMsg('请先回到导航状态，再模拟已确认侧方的障碍。');
      return;
    }
    _tasks.transitionTo(TaskState.avoidingObstacle, trigger: 'obstacle');
    _stopStraightTimer();
    _scheduler.pauseStraight();
    setState(() {
      _riskActive = true;
    });
    final DateTime now = DateTime.now();
    final List<PerceptionEvent> events = _perception.processFrame(
      const <Detection>[
        Detection(label: '障碍物', confidence: 0.9, cx: 0.7, cy: 0.5),
      ],
      now,
    );
    final RiskEvent event = RiskEvent(
      id: 'obstacle-confirmed',
      type: 'obstacle',
      createdAt: now,
      expiresAt: now.add(const Duration(seconds: 30)),
      evidence: const PerceptionEvidence(
        detectionConfidence: 0.9,
        spatialConfidence: 0.85,
        hasDistanceEstimate: true,
        distanceM: 2.5,
        sideSpaceConfirmed: true,
        confirmedSafeSide: StepDirection.right,
      ),
    );
    final RiskAssessment assessment =
        _envSkill.analyse(event, now).assessment;
    setState(() {
      _perceptionText =
          '感知帧（演示）：移动事件 ${events.length} 条，跟踪目标 ${_perception.tracks.length} 个。';
      _obstacleText = '障碍（侧方已确认）：${assessment.speechText}'
          '原因：${assessment.reason}，等级：${assessment.level.name}，'
          '步数方向：${assessment.stepDirection?.name ?? 'none'}。'
          '注意：播报完成不等于动作完成，需下一步重新感知确认。';
    });
    _logMsg('障碍（侧方已确认）：仅在演示数据确认右侧可通行时才给出一步指令。');
    _say(_request(
      id: 'obstacle-confirmed-prompt',
      eventId: 'obstacle-confirmed',
      text: assessment.speechText,
      kind: SpeechKind.obstacleAvoidance,
    ));
  }

  void _obstacleConfirmedVerified() {
    if (_tasks.state != TaskState.avoidingObstacle) {
      _logMsg('当前不在避障状态。');
      return;
    }
    final DateTime now = DateTime.now();
    final List<PerceptionEvent> events = _perception.processFrame(
      const <Detection>[],
      now,
    );
    _tasks.transitionTo(TaskState.navigating, trigger: 'action-verified');
    setState(() {
      _riskActive = false;
      _straightConfirmed = true;
      _straightNavVersion = _navVersion;
    });
    _scheduler.resumeStraight(
      now: now,
      straightSegmentConfirmed: true,
      riskActive: false,
      currentNavigationVersion: _navVersion,
      straightNavigationVersion: _navVersion,
    );
    _startStraightTimer();
    _logMsg('动作后重新感知（演示）：新事件 ${events.length} 条，'
        '原障碍帧不再出现，仍以本次重新感知为准恢复导航。');
  }

  // v0.4 traffic replacement demo: information only, never a
  // crossing permission. The backlog records the uncertain scene for
  // offline review; it never changes any production rule.
  void _trafficInfo() {
    if (_tasks.state != TaskState.navigating) {
      _logMsg('请先开始导航，再看路口信息提示。');
      return;
    }
    final TrafficSceneAssessment assessment = _traffic.assess(
      lightDetected: true,
      lightDirectionConfirmed: false,
      locationAccuracyOk: true,
      crossingConfirmed: false,
    );
    _backlog.record(
      'traffic-demo-1',
      'traffic-unconfirmed',
      '演示路口：信号灯方向未确认，只提示不放行。',
      DateTime.now(),
    );
    setState(() {
      _trafficText = '${assessment.speechText}（允许过马路：${assessment.allowsCrossing}，学习记录 ${_backlog.count} 条，只记录不改规则。）';
    });
    _logMsg('路口信息（替代原过街决策）：只提示，不放行。');
    _say(_request(
      id: 'traffic-info-1',
      eventId: 'traffic-info-1',
      text: assessment.speechText,
      kind: SpeechKind.obstacleAvoidance,
    ));
  }

  void _destinationApproach() {
    if (_tasks.state != TaskState.navigating) {
      _logMsg('请先开始导航，再模拟接近目的地。');
      return;
    }
    _stopStraightTimer();
    setState(() {
      _straightConfirmed = false;
    });
    NavigationState nav = _mapService.provider.updateLocation(
      const GeoPoint(),
      20.0,
    );
    int steps = 1;
    while (!_mapService.shouldSwitchToDestinationApproach(nav) &&
        steps < 30) {
      nav = _mapService.provider.updateLocation(const GeoPoint(), 20.0);
      steps += 1;
    }
    setState(() {
      _navVersion = 'nav-v${nav.version}';
    });
    if (!_mapService.shouldSwitchToDestinationApproach(nav)) {
      _logMsg('演示推进未达到目的地接近条件，请勿宣称为已到达。');
      return;
    }
    _tasks.transitionTo(TaskState.findingEntrance,
        trigger: 'destination-approach');
    _logMsg('接近目的地（演示推进 $steps 步）：剩余约 '
        '${nav.distanceRemainingM.toStringAsFixed(0)} 米，定位精度 20 米，'
        '已切换到入口寻找状态。地图显示接近不等于已找到入口。');
    _say(_request(
      id: 'approach',
      eventId: 'approach',
      text: '已接近目的地，正在寻找入口。',
      kind: SpeechKind.info,
    ));
  }

  void _findEntrance() {
    if (_tasks.state != TaskState.findingEntrance) {
      _logMsg('请先接近目的地，进入入口寻找状态。');
      return;
    }
    final EntranceResult placeholder = _destSkill.find(
      candidates: const <EntranceCandidate>[
        EntranceCandidate(
          id: 'placeholder-library-entrance',
          label: '占位：图书馆入口',
          confidence: 0.9,
          siteVerified: false,
        ),
      ],
      locationAccuracyM: 20.0,
    );
    final EntranceResult demoConfirmed = _destSkill.find(
      candidates: const <EntranceCandidate>[
        EntranceCandidate(
          id: 'demo-verified-entrance',
          label: '演示用已核验入口（非真实地点）',
          confidence: 0.85,
          siteVerified: true,
        ),
      ],
      locationAccuracyM: 20.0,
    );
    setState(() {
      _entranceText = '占位候选结果：${placeholder.state.name}，'
          '${placeholder.reason}；演示候选结果：${demoConfirmed.state.name}，'
          '${demoConfirmed.reason}。演示候选不是真实地点，'
          '真实入口必须用现场核验数据替换。';
    });
    _logMsg('入口寻找：占位数据不能确认入口；演示用已核验候选才给出确认。');
    _say(_request(
      id: 'entrance-found',
      eventId: 'entrance-found',
      text: '已确认演示入口，正在进入室内引导。演示数据，非真实地点。',
      kind: SpeechKind.info,
    ));
  }

  void _enterIndoor() {
    if (_tasks.state != TaskState.findingEntrance) {
      _logMsg('请先完成入口寻找，再进入室内引导。');
      return;
    }
    _tasks.transitionTo(TaskState.indoorGuidance, trigger: 'enter-indoor');
    setState(() {
      _indoorText = '室内任务当前步骤：找到服务台（需演示证据确认后才推进）。';
    });
    _logMsg('进入室内引导：图书馆服务台任务开始。');
  }

  void _indoorStep() {
    if (_tasks.state != TaskState.indoorGuidance) {
      _logMsg('请先进入室内引导，再推进室内步骤。');
      return;
    }
    final LibraryStep? step = _indoor.currentStep;
    if (step == null) {
      _logMsg('室内任务已完成。');
      return;
    }
    if (!_indoor.tryAdvance(verified: true, evidence: 'demo-verified')) {
      _logMsg('室内步骤未推进：缺少核验证据时不得推进。');
      return;
    }
    setState(() {
      if (_indoor.isCompleted) {
        _indoorText = '室内任务全部步骤已用演示证据确认完成，等待任务验证。';
      } else {
        _indoorText = '室内任务当前步骤：${_indoor.currentStep?.name ?? ''}'
            '（需演示证据确认后才推进）。';
      }
    });
    _logMsg('室内步骤已推进（演示证据）：${step.name}。');
    _say(_request(
      id: 'indoor-${step.name}',
      eventId: 'indoor-${step.name}',
      text: '室内步骤已确认：${step.name}。',
      kind: SpeechKind.info,
    ));
  }

  void _taskVerify() {
    if (_tasks.state != TaskState.indoorGuidance || !_indoor.isCompleted) {
      _logMsg('请先完成全部室内步骤，再验证任务。');
      return;
    }
    _tasks.transitionTo(TaskState.waitingConfirmation,
        trigger: 'verify-task');
    _recording.stopPendingConsent(DateTime.now());
    setState(() {
      _recordingText = '录像已停止，等待你的保留/删除选择（本地演示会话）。';
    });
    _logMsg('任务验证：室内步骤已完成，任务进入等待确认状态。');
    _say(_request(
      id: 'task-verified',
      eventId: 'task-verified',
      text: '任务已验证完成，等待确认。',
      kind: SpeechKind.info,
    ));
  }

  void _confirmComplete() {
    if (_tasks.state != TaskState.waitingConfirmation) {
      _logMsg('请先验证任务，再确认完成。');
      return;
    }
    _tasks.transitionTo(TaskState.completed, trigger: 'confirm-complete');
    setState(() {
      _yoloLiveOpen = false;
    });
    _logMsg('任务已完成。请选择保留或删除本地录像。');
    _say(_request(
      id: 'task-completed',
      eventId: 'task-completed',
      text: '任务已完成。是否保留本次录像？',
      kind: SpeechKind.info,
    ));
  }

  void _recordingSave() {
    if (_recording.saveWithConsent()) {
      setState(() {
        _recordingText = '录像已保留（本地演示会话）。';
      });
      _logMsg('录像：已保留本地演示会话。');
    } else {
      _logMsg('录像：当前不在等待选择状态，不能保存。');
    }
  }

  void _recordingDelete() {
    if (_recording.deleteOnDecline()) {
      setState(() {
        _recordingText = '录像已删除（本地演示会话；不宣称已删除系统外的任何副本）。';
      });
      _logMsg('录像：已删除本地演示会话，不宣称已删除系统外副本。');
    } else {
      _logMsg('录像：当前不在等待选择状态，不能删除。');
    }
  }

  void _llmDemo() {
    if (!AppConfig.hasLlmModelId) {
      setState(() {
        _llmText = 'NOT_CONFIGURED：未提供 LLM 模型 ID（--dart-define），'
            '未调用云端。';
      });
      _logMsg('云端调用：未配置模型 ID，网关未调用。');
      return;
    }
    _gateway ??= LlmGateway(
      modelId: AppConfig.llmModelId,
      budgetCapRmb: 100.0,
    );
    final LlmDecision decision = _gateway!.requestOnDemand(
      type: LlmCallType.ocrAssist,
      reason: '演示：本地 OCR 不足，申请云端标识辅助',
      localAttempted: true,
      localInsufficient: true,
      estimatedCostRmb: 0.001,
      input: const <String, Object?>{'demo': true},
    );
    setState(() {
      _llmText = decision.allowed
          ? '云端调用已批准（决策）：${decision.reason}。'
              'v0.2 网关只返回决策，未产生真实网络调用和费用。'
          : '云端调用被拒绝：${decision.reason}。';
    });
    _logMsg('云端网关演示：allowed=${decision.allowed}，'
        '已用 0 元（无真实调用）。');
  }

  /// One explicit, user-tapped real Bailian call. This is the ONLY
  /// place in the demo UI that can spend anything: the gateway
  /// decision-only button above never calls the network. If the key
  /// is missing, this reports NOT_CONFIGURED and sends nothing. The
  /// key itself is never shown or logged here.
  Future<void> _llmRealCall() async {
    if (!AppConfig.hasLlmModelId) {
      setState(() {
        _llmText = 'NOT_CONFIGURED：未提供 LLM 模型 ID，未调用云端。';
      });
      return;
    }
    if (!AppConfig.hasDashscopeKey) {
      setState(() {
        _llmText = 'NOT_CONFIGURED：未提供百炼 Key '
            '（--dart-define=MINGTU_DASHSCOPE_API_KEY），未调用云端。';
      });
      return;
    }
    _gateway ??= LlmGateway(
      modelId: AppConfig.llmModelId,
      budgetCapRmb: 100.0,
    );
    final LlmDecision decision = _gateway!.requestOnDemand(
      type: LlmCallType.textPlanning,
      reason: '用户主动点按：百炼真实调用测试',
      localAttempted: true,
      localInsufficient: true,
      estimatedCostRmb: 0.001,
      input: const <String, Object?>{'demo': true},
    );
    if (!decision.allowed) {
      setState(() {
        _llmText = '百炼调用被网关拒绝：${decision.reason}，未产生费用。';
      });
      return;
    }
    setState(() {
      _llmText = '百炼调用中（网关已批准，等待本机网络返回）……';
    });
    final BailianClient client = BailianClient(
      apiKey: AppConfig.dashscopeApiKey,
      modelId: AppConfig.llmModelId,
    );
    final BailianResult result = await client.callText(
      gateway: _gateway!,
      decision: decision,
      prompt: '请用一句话说明：图书馆服务台标识通常包含哪些信息？',
    );
    setState(() {
      _llmText = result.ok
          ? '百炼返回：${result.text}'
          : '百炼调用失败（${result.status}）：${result.error}';
    });
    _logMsg('百炼真实调用：status=${result.status}，'
        '网关已用估算费用已记账，未记录 Key。');
  }

  /// Low-frequency cloud vision ASSIST (user-tapped only). Local
  /// YOLO stays primary: this never runs on its own, never feeds
  /// the risk engine, and its spoken result is framed as an
  /// unverified description. Every failure path announces the
  /// degradation to local detection in Chinese. The DashScope key
  /// exists only in the proxy's server environment; this device
  /// sends one downsampled frame to the proxy and nothing else.
  Future<void> _runCloudVisionAssist() async {
    final Uint8List? frame = _latestFrameBytes;
    final CloudVisionResult result;
    if (frame == null) {
      result = _cloudVisionClient.isConfigured
          ? CloudVisionResult.failed(CloudVisionFailure.noImage)
          : CloudVisionResult.failed(CloudVisionFailure.notConfigured);
    } else {
      result = await _cloudVisionClient.describe(imageBytes: frame);
    }
    if (!mounted) return;
    _health.report(
      'cloud_vision',
      result.ok ? ServiceHealthStatus.ok : ServiceHealthStatus.degraded,
      result.ok ? '云端视觉辅助返回一次描述（未验证）。' : result.speechText,
    );
    setState(() {
      _cloudVisionText = '云端视觉辅助：${result.speechText}';
    });
    _logMsg('云端视觉辅助：ok=${result.ok}，failure=${result.failure}。');
    _say(_request(
      id: 'cloud-vision-${DateTime.now().millisecondsSinceEpoch}',
      eventId: 'cloud-vision-${DateTime.now().millisecondsSinceEpoch}',
      text: result.speechText,
      kind: SpeechKind.info,
    ));
  }

  // v0.5: every state has a Chinese name. A blind user hearing the
  // status must never hear an English enum name like "understanding".
  String _stateText(TaskState state) {
    switch (state) {
      case TaskState.idle:
        return '未开始';
      case TaskState.listening:
        return '正在听你说话';
      case TaskState.understanding:
        return '正在理解你的请求';
      case TaskState.planning:
        return '正在规划路线';
      case TaskState.preparing:
        return '正在准备，检查任务所需资源';
      case TaskState.executing:
        return '正在执行';
      case TaskState.navigating:
        return '正在导航';
      case TaskState.avoidingObstacle:
        return '正在避障';
      case TaskState.findingEntrance:
        return '正在找入口';
      case TaskState.indoorGuidance:
        return '正在室内引导';
      case TaskState.waitingConfirmation:
        return '正在等待你确认';
      case TaskState.paused:
        return '已暂停';
      case TaskState.degraded:
        return '部分功能不可用，正在降级运行';
      case TaskState.emergency:
        return '紧急求助中';
      case TaskState.completed:
        return '已完成';
      case TaskState.cancelled:
        return '已取消';
      case TaskState.failed:
        return '已失败';
    }
  }

  /// Execute one recognised voice command. Illegal transitions are
  /// answered, never silently applied, and emergency never auto-resumes.
  void _handleVoiceCommand(String raw) {
    final VoiceCommand command = parseVoiceCommand(raw);
    switch (command) {
      case VoiceCommand.emergency:
        _triggerEmergency();
        return;
      case VoiceCommand.startLibrary:
        if (_tasks.state == TaskState.idle) {
          // Navigation P0: a real voice request goes to REAL
          // navigation (verified destination + GPS + proxy route).
          // The simulated flow stays available only through its
          // explicitly labelled demo buttons, never as a silent
          // fallback for a real request.
          _startRealNavigation('图书馆');
        } else {
          _say(_request(
            id: 'voice-busy-${DateTime.now().millisecondsSinceEpoch}',
            eventId: 'voice-busy-${DateTime.now().millisecondsSinceEpoch}',
            text: '已有任务在进行，请先取消或完成当前任务。',
            kind: SpeechKind.info,
          ));
        }
        return;
      case VoiceCommand.pause:
        if (_tasks.canTransitionTo(TaskState.paused)) {
          _tasks.transitionTo(TaskState.paused, trigger: 'voice-pause');
          _stopStraightTimer();
          _scheduler.pauseStraight();
          // P0: "停下" must also cancel everything still pending
          // (queued turn / navigation prompts) and stop the actual
          // playback -- not only the straight prompt. The
          // confirmation below is submitted after this, so it is
          // not cancelled itself.
          setState(() {
            _straightConfirmed = false;
          });
          // Sequenced: cancel old speech, WAIT for the engine stop
          // (or timeout), then speak the confirmation -- see
          // _stopSpeechThenConfirm.
          unawaited(_stopSpeechThenConfirm(
            idPrefix: 'voice-pause',
            confirmText: '已暂停导航，直行提醒已停止。说继续可以恢复，但要重新确认直行路段。',
          ));
        } else {
          _say(_request(
            id: 'voice-pause-no-${DateTime.now().millisecondsSinceEpoch}',
            eventId: 'voice-pause-no-${DateTime.now().millisecondsSinceEpoch}',
            text: '当前状态不能暂停。',
            kind: SpeechKind.info,
          ));
        }
        return;
      case VoiceCommand.resume:
        // v0.7: while navigating with straight unconfirmed and no
        // risk, "继续" re-confirms the straight segment (e.g. after a
        // YOLO obstacle cleared). It never resumes straight while a
        // risk is active -- _reconfirmStraight refuses that.
        if (_tasks.state == TaskState.navigating &&
            !_straightConfirmed &&
            !_riskActive) {
          _reconfirmStraight();
        } else if (_tasks.state == TaskState.paused) {
          // Resume to navigating, but do NOT restart the straight timer:
          // the user must re-confirm the straight segment first. This is
          // the blind-first safety rule, not a convenience shortcut.
          _tasks.transitionTo(TaskState.navigating, trigger: 'voice-resume');
          setState(() {
            _straightConfirmed = false;
          });
          _say(_request(
            id: 'voice-resume-${DateTime.now().millisecondsSinceEpoch}',
            eventId: 'voice-resume-${DateTime.now().millisecondsSinceEpoch}',
            text: '已恢复导航，但直行提醒还没有恢复，请先重新确认直行路段。',
            kind: SpeechKind.info,
          ));
        } else {
          _say(_request(
            id: 'voice-resume-no-${DateTime.now().millisecondsSinceEpoch}',
            eventId: 'voice-resume-no-${DateTime.now().millisecondsSinceEpoch}',
            text: '当前没有暂停的任务可以恢复。',
            kind: SpeechKind.info,
          ));
        }
        return;
      case VoiceCommand.cancel:
        if (_tasks.canTransitionTo(TaskState.cancelled)) {
          _tasks.transitionTo(TaskState.cancelled, trigger: 'voice-cancel');
          _stopStraightTimer();
          _scheduler.pauseStraight();
          // P0 + re-test: same sequenced stop semantics as pause.
          unawaited(_stopSpeechThenConfirm(
            idPrefix: 'voice-cancel',
            confirmText: '任务已取消，直行提醒已停止。',
          ));
        } else {
          _say(_request(
            id: 'voice-cancel-no-${DateTime.now().millisecondsSinceEpoch}',
            eventId: 'voice-cancel-no-${DateTime.now().millisecondsSinceEpoch}',
            text: '当前状态不能取消，请先重置演示。',
            kind: SpeechKind.info,
          ));
        }
        return;
      case VoiceCommand.repeat:
        if (_lastSpokenText.isEmpty) {
          _say(_request(
            id: 'voice-repeat-no-${DateTime.now().millisecondsSinceEpoch}',
            eventId: 'voice-repeat-no-${DateTime.now().millisecondsSinceEpoch}',
            text: '还没有上一条提示。',
            kind: SpeechKind.info,
          ));
        } else {
          _say(_request(
            id: 'voice-repeat-${DateTime.now().millisecondsSinceEpoch}',
            eventId: 'voice-repeat-${DateTime.now().millisecondsSinceEpoch}',
            text: _lastSpokenText,
            kind: SpeechKind.info,
          ));
        }
        return;
      case VoiceCommand.status:
        // v0.5: status must include the route, not only the state
        // name, so a blind user knows where they are in the journey.
        final String routePart = _routeText == '尚未规划路线。'
            ? ''
            : '路线：$_routeText';
        _say(_request(
          id: 'voice-status-${DateTime.now().millisecondsSinceEpoch}',
          eventId: 'voice-status-${DateTime.now().millisecondsSinceEpoch}',
          text: '当前状态：${_stateText(_tasks.state)}。当前提示：$_currentPrompt。$routePart',
          kind: SpeechKind.info,
        ));
        return;
      case VoiceCommand.confirmStep:
        // v0.5: indoor steps are now voice-confirmable. v0.7: while
        // navigating, "下一步" speaks the next Amap step instead.
        // Outside those states there is no step to confirm, and the
        // answer says so instead of advancing an unrelated task.
        if (_tasks.state == TaskState.indoorGuidance) {
          _indoorStep();
        } else if ((_tasks.state == TaskState.navigating ||
                _tasks.state == TaskState.planning) &&
            _amapSpeaker != null &&
            !_amapSpeaker!.isDone) {
          _speakNextAmapStep();
        } else {
          _say(_request(
            id: 'voice-confirm-no-${DateTime.now().millisecondsSinceEpoch}',
            eventId: 'voice-confirm-no-${DateTime.now().millisecondsSinceEpoch}',
            text: '当前没有室内步骤可以确认，也没有未播报的高德路段。',
            kind: SpeechKind.info,
          ));
        }
        return;
      case VoiceCommand.environment:
        _say(_request(
          id: 'voice-env-${DateTime.now().millisecondsSinceEpoch}',
          eventId: 'voice-env-${DateTime.now().millisecondsSinceEpoch}',
          text: _riskActive
              ? '前方情况：$_obstacleText'
              : '前方情况：$_perceptionText',
          kind: SpeechKind.info,
        ));
        return;
      case VoiceCommand.saveRecording:
        if (_recording.saveWithConsent()) {
          setState(() {
            _recordingText = '录像已保留（本地演示会话）。';
          });
          _say(_request(
            id: 'voice-save-${DateTime.now().millisecondsSinceEpoch}',
            eventId: 'voice-save-${DateTime.now().millisecondsSinceEpoch}',
            text: '录像已保留在本地演示会话中。注意：这不是已存入手机相册。',
            kind: SpeechKind.info,
          ));
        } else {
          _say(_request(
            id: 'voice-save-no-${DateTime.now().millisecondsSinceEpoch}',
            eventId: 'voice-save-no-${DateTime.now().millisecondsSinceEpoch}',
            text: '现在没有可以保存的录像，请先完成任务到等待确认状态。',
            kind: SpeechKind.info,
          ));
        }
        return;
      case VoiceCommand.deleteRecording:
        if (_recording.deleteOnDecline()) {
          setState(() {
            _recordingText = '录像已删除（本地演示会话；不宣称已删除系统外的任何副本）。';
          });
          _say(_request(
            id: 'voice-delete-${DateTime.now().millisecondsSinceEpoch}',
            eventId: 'voice-delete-${DateTime.now().millisecondsSinceEpoch}',
            text: '录像已删除本地演示会话，不宣称已删除系统外的任何副本。',
            kind: SpeechKind.info,
          ));
        } else {
          _say(_request(
            id: 'voice-delete-no-${DateTime.now().millisecondsSinceEpoch}',
            eventId: 'voice-delete-no-${DateTime.now().millisecondsSinceEpoch}',
            text: '现在没有可以删除的录像，请先完成任务到等待确认状态。',
            kind: SpeechKind.info,
          ));
        }
        return;
      case VoiceCommand.help:
        _say(_request(
          id: 'voice-help-${DateTime.now().millisecondsSinceEpoch}',
          eventId: 'voice-help-${DateTime.now().millisecondsSinceEpoch}',
          text: voiceCommandHelpText(),
          kind: SpeechKind.info,
        ));
        return;
      case VoiceCommand.unknown:
        _say(_request(
          id: 'voice-unknown-${DateTime.now().millisecondsSinceEpoch}',
          eventId: 'voice-unknown-${DateTime.now().millisecondsSinceEpoch}',
          text: '没听清。${voiceCommandHelpText()}',
          kind: SpeechKind.info,
        ));
        return;
    }
  }

  void _hospitalAdvance() {
    if (_hospital.preRegistrationComplete) {
      setState(() {
        _hospitalText = _hospital.currentStepText;
      });
      _say(_request(
        id: 'hospital-done-${DateTime.now().millisecondsSinceEpoch}',
        eventId: 'hospital-done-${DateTime.now().millisecondsSinceEpoch}',
        text: _hospital.currentStepText,
        kind: SpeechKind.info,
      ));
      return;
    }
    final bool ok = _hospital.tryAdvance(verified: true, evidence: 'demo');
    setState(() {
      _hospitalText = _hospital.currentStepText;
    });
    _say(_request(
      id: 'hospital-${DateTime.now().millisecondsSinceEpoch}',
      eventId: 'hospital-${DateTime.now().millisecondsSinceEpoch}',
      text: ok ? _hospital.currentStepText : '医院挂号步骤不能前进，需要先核验。',
      kind: SpeechKind.info,
    ));
  }

  void _triggerEmergency() {
    final DateTime now = DateTime.now();
    _events.publish(
      MingtuEvent(
        eventId: 'emergency-${now.millisecondsSinceEpoch}',
        type: MingtuEventType.emergencyTriggered,
        taskId: _tasks.taskId,
        createdAt: now,
        source: 'emergency',
        expiresAt: now.add(const Duration(seconds: 30)),
      ),
      now,
    );
    _health.report(
      'emergency',
      ServiceHealthStatus.ok,
      '本地紧急流程已启动，不依赖大模型。',
    );
    final EmergencyResult result = _emergency.trigger(
      triggerType: 'voice-小途，我需要帮助（演示）',
      networkAvailable: false,
      llmAvailable: false,
    );
    _stopStraightTimer();
    _scheduler.pauseStraight();
    setState(() {
      _riskActive = true;
      _straightConfirmed = false;
      _yoloLiveOpen = false;
      _yoloRiskActive = false;
      _emergencyText = '${result.statusText}'
          '已联系帮助站：${result.contactClaimed}（v0.2 永不宣称已联系）。'
          '备用：${result.fallbackOptions.join('；')}';
    });
    if (_tasks.canTransitionTo(TaskState.emergency)) {
      _tasks.transitionTo(TaskState.emergency, trigger: 'emergency');
      _logMsg('紧急求助：本地流程已启动，普通导航已暂停，未宣称已联系帮助站。');
    } else {
      _logMsg('紧急求助：本地流程已启动；当前任务状态无法迁移到紧急状态，'
          '请重置演示后重新开始。');
    }
    // v0.5: the fallbacks must be SPOKEN, not only shown as text.
    // A blind user in an emergency cannot read the screen for them,
    // and must never be left waiting for a help station that was
    // never actually contacted.
    _say(_request(
      id: 'emergency-1',
      eventId: 'emergency-1',
      text: '${result.statusText}备用办法：${result.fallbackOptions.join('；')}。',
      kind: SpeechKind.emergency,
    ));
  }

  void _resetDemo() {
    _stopStraightTimer();
    if (_tasks.state == TaskState.emergency || _tasks.isTerminal) {
      _tasks.reset();
    } else if (_tasks.state != TaskState.idle &&
        _tasks.canTransitionTo(TaskState.cancelled)) {
      _tasks.transitionTo(TaskState.cancelled, trigger: 'reset-demo');
      _tasks.reset();
    }
    setState(() {
      _tasks = TaskManager();
      _scheduler = SpeechScheduler();
      _mapService = MapNavigationService(StubMapProvider());
      _routeSkill = RoutePlanningSkill(_mapService);
      _indoor = IndoorTask();
      _hospital = HospitalTask();
      _hospitalText = '医院挂号未开始（逻辑步骤演示，非真实挂号）。';
      _lastSpokenText = '';
      _voiceController.clear();
      _recording = RecordingManager();
      _perception = VisualPerception();
      _gateway = null;
      _currentPrompt = '尚未开始。';
      _log.clear();
      _straightConfirmed = false;
      _riskActive = false;
      _navVersion = 'nav-v0';
      _straightNavVersion = 'nav-v0';
      _routeText = '尚未规划路线。';
      _obstacleText = '尚未模拟障碍。';
      _entranceText = '尚未寻找入口。';
      _indoorText = '室内任务未开始。';
      _emergencyText = '未触发紧急求助。';
      _recordingText = '未开始录像。';
      _llmText = '未申请云端调用。';
      _perceptionText = '尚未模拟感知帧。';
      _amapText = '高德真实路线：未请求。';
      _amapSpeaker = null;
      _yoloLiveOpen = false;
      _yoloLatencyMs = null;
      _yoloRiskActive = false;
      _yoloEmptyFrames = 0;
      _trafficText = '路口信息未提示（只提示，不放行）。';
    });
    _logMsg('演示已重置（重新开始演示，非任务状态迁移）。');
  }

  Widget _demoButton({
    required String label,
    required String semanticsLabel,
    required VoidCallback? onPressed,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        button: true,
        label: semanticsLabel,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            minimumSize: const Size(double.infinity, 56),
          ),
          onPressed: onPressed,
          child: Text(label, style: const TextStyle(fontSize: 18)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final TaskState state = _tasks.state;
    return Scaffold(
      appBar: AppBar(title: const Text('明途 AI v0.7（演示原型）')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '明途 AI：面向视障人士的校园出行辅助演示原型。',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const Text(
              '语音是主要交互方式；本页面是演示辅助界面，'
              '供有视力的评审查看当前状态和当前提示。'
              '当前在网页 / 虚拟机中运行的是模拟流程，'
              '不是真实传感器导航，不能用于真实道路，'
              '也不能替代盲杖、导盲犬或专业定向行走训练，'
              '也未经过真实道路安全验证。',
            ),
            const SizedBox(height: 12),
            Text('配置状态：地图：${AppConfig.routeProxyStatus}；'
                'YOLO：${AppConfig.yoloStatus}；'
                '云端模型：${AppConfig.llmStatus}；'
                '百炼：${AppConfig.bailianStatus}。'),
            const SizedBox(height: 8),
            // v0.6 real-integration status: TTS/ASR/YOLO/Amap report
            // their own availability; "已接入" only appears when the
            // phone's engine actually answered at startup.
            Text(_voiceText),
            const SizedBox(height: 8),
            Text(_amapText),
            const SizedBox(height: 8),
            Text(_yoloText),
            const SizedBox(height: 8),
            // Refactor phase 1 health display: only reports services
            // that actually reported. Empty means "no degradation
            // reported", never "everything is healthy".
            Text(_health.announcementText().isEmpty
                ? '系统健康：暂无已上报的降级（演示中仅紧急流程会主动上报本地服务状态，未上报的服务不伪造健康）。'
                : '系统健康：${_health.announcementText()}'),
            const SizedBox(height: 12),
            Semantics(
              label: '当前任务状态',
              // v0.5: show the Chinese state name, never the English
              // enum name, so a screen reader reads it correctly.
              child: Text('当前任务状态：${_stateText(state)}'),
            ),
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              label: '当前提示',
              child: Text(
                '当前提示：$_currentPrompt',
                style: const TextStyle(fontSize: 20),
              ),
            ),
            const SizedBox(height: 8),
            Text('路线：$_routeText'),
            const SizedBox(height: 8),
            Text('障碍：$_obstacleText'),
            const SizedBox(height: 8),
            Text('入口：$_entranceText'),
            const SizedBox(height: 8),
            Text('室内：$_indoorText'),
            const SizedBox(height: 8),
            Text('紧急求助：$_emergencyText'),
            const SizedBox(height: 8),
            Text('录像：$_recordingText'),
            const SizedBox(height: 8),
            Text('云端网关：$_llmText'),
            Text(_cloudVisionText),
            const SizedBox(height: 8),
            Text('感知：$_perceptionText'),
            const SizedBox(height: 8),
            Text('医院挂号：$_hospitalText'),
            const SizedBox(height: 8),
            Text('路口：$_trafficText'),
            const SizedBox(height: 8),
            Text('Skill 注册：${_registry.list().length} 个（车站、医院完整挂号未注册；路口只提示不放行；相册导出 NOT_CONFIGURED）。'),
            const SizedBox(height: 24),
            const Text('语音控制（盲人优先：不用看屏幕点步骤也能控制）',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
              'v0.6：真机上点“开始语音识别”就是系统语音识别（单次最长 10 秒），'
              '识别结果按语音指令解析执行；下面这个输入框是演示代替，'
              '在网页 / 没有语音引擎时用。'
              '也可以直接点下面的暂停、继续、再说一遍、现在到哪了。',
            ),
            const SizedBox(height: 8),
            Semantics(
              label: '语音指令输入，演示用，代替真实语音识别',
              child: TextField(
                controller: _voiceController,
                decoration: const InputDecoration(
                  hintText: '例如：暂停、继续、再说一遍、现在到哪了、我需要帮助',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _demoButton(
              label: '开始语音识别（真机，单次最长 10 秒）',
              semanticsLabel: '开始语音识别',
              onPressed: _voiceInput.isAvailable ? _startListening : null,
            ),
            _demoButton(
              label: '停止语音识别',
              semanticsLabel: '停止语音识别',
              onPressed: _voiceInput.isAvailable ? _stopListening : null,
            ),
            _demoButton(
              label: '发送语音指令（演示）',
              semanticsLabel: '发送语音指令',
              onPressed: () => _handleVoiceCommand(_voiceController.text),
            ),
            _demoButton(
              label: '高德真实路线（真实导航：需已核验目的地与路线代理）',
              semanticsLabel: '高德真实路线',
              onPressed: _fetchAmapRoute,
            ),
            _demoButton(
              label: _yoloLiveOpen ? '关闭 YOLO 实时摄像头' : '打开 YOLO 实时摄像头（真机）',
              semanticsLabel: '打开或关闭 YOLO 实时摄像头',
              onPressed: () {
                setState(() {
                  _yoloLiveOpen = !_yoloLiveOpen;
                });
              },
            ),
            _demoButton(
              label: '模拟 YOLO 检测：前方行人（演示，无摄像头）',
              semanticsLabel: '模拟 YOLO 检测前方行人',
              onPressed: state == TaskState.navigating
                  ? () => _onYoloDetections(const <Detection>[
                        Detection(
                            label: 'person',
                            confidence: 0.9,
                            cx: 0.5,
                            cy: 0.5),
                      ])
                  : null,
            ),
            _demoButton(
              label: '模拟 YOLO：连续 3 帧前方无障碍（演示）',
              semanticsLabel: '模拟 YOLO 前方无障碍',
              onPressed: state == TaskState.avoidingObstacle
                  ? () {
                      for (int i = 0; i < 3; i++) {
                        _onYoloDetections(const <Detection>[]);
                      }
                    }
                  : null,
            ),
            if (_yoloLiveOpen)
              SizedBox(
                height: 320,
                child: YoloLiveView(
                  modelPath: AppConfig.yoloModelPath,
                  onDetections: _onYoloDetections,
                  onLatencyMs: (double ms) {
                    setState(() {
                      _yoloLatencyMs = ms;
                    });
                  },
                  onError: (Object error) {
                    _logMsg('YOLO 实时视图出错：$error');
                    setState(() {
                      _yoloText = 'YOLO：实时视图出错：$error';
                    });
                  },
                ),
              ),
            _demoButton(
              label: '暂停导航（语音）',
              semanticsLabel: '暂停导航',
              onPressed: _tasks.canTransitionTo(TaskState.paused)
                  ? () => _handleVoiceCommand('暂停')
                  : null,
            ),
            _demoButton(
              label: '继续导航（语音，需重新确认直行）',
              semanticsLabel: '继续导航',
              onPressed: _tasks.state == TaskState.paused
                  ? () => _handleVoiceCommand('继续')
                  : null,
            ),
            _demoButton(
              label: '再说一遍',
              semanticsLabel: '再说一遍',
              onPressed: () => _handleVoiceCommand('再说一遍'),
            ),
            _demoButton(
              label: '现在到哪了',
              semanticsLabel: '现在到哪了',
              onPressed: () => _handleVoiceCommand('现在到哪了'),
            ),
            _demoButton(
              label: '取消任务（语音）',
              semanticsLabel: '取消任务',
              onPressed: _tasks.canTransitionTo(TaskState.cancelled)
                  ? () => _handleVoiceCommand('取消')
                  : null,
            ),
            _demoButton(
              label: '医院挂号下一步（逻辑步骤，非真实挂号）',
              semanticsLabel: '医院挂号下一步',
              onPressed: _hospitalAdvance,
            ),
            const SizedBox(height: 24),
            const Text('演示步骤（按顺序点按）',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            _demoButton(
              label: '语音开始（演示输入：带我去图书馆）',
              semanticsLabel: '语音开始，演示输入带我去图书馆',
              onPressed: state == TaskState.idle ? _startVoice : null,
            ),
            _demoButton(
              label: '理解并规划路线',
              semanticsLabel: '理解并规划路线',
              onPressed:
                  state == TaskState.understanding ? _planRoute : null,
            ),
            _demoButton(
              label: '开始导航（直行节奏启动）',
              semanticsLabel: '开始导航',
              onPressed: state == TaskState.planning ? _startNavigating : null,
            ),
            _demoButton(
              label: '直行提示（手动，3 秒间隔内不重复）',
              semanticsLabel: '直行提示',
              onPressed: state == TaskState.navigating &&
                      _straightConfirmed &&
                      !_riskActive
                  ? _manualStraight
                  : null,
            ),
            _demoButton(
              label: '前方转弯（暂停直行）',
              semanticsLabel: '前方转弯',
              onPressed:
                  state == TaskState.navigating ? _turn : null,
            ),
            _demoButton(
              label: '重新确认直行路段并恢复',
              semanticsLabel: '重新确认直行路段并恢复',
              onPressed: state == TaskState.navigating &&
                      !_straightConfirmed &&
                      !_riskActive
                  ? _reconfirmStraight
                  : null,
            ),
            _demoButton(
              label: '模拟障碍：侧方未确认（应停下，不给步数）',
              semanticsLabel: '模拟障碍，侧方未确认',
              onPressed:
                  state == TaskState.navigating ? _obstacleUncertain : null,
            ),
            _demoButton(
              label: '障碍已移开，重新评估并恢复直行',
              semanticsLabel: '障碍已移开，恢复直行',
              onPressed: state == TaskState.avoidingObstacle &&
                      _riskActive
                  ? _obstacleUncertainResolved
                  : null,
            ),
            _demoButton(
              label: '模拟障碍：侧方已确认（仅演示数据给一步）',
              semanticsLabel: '模拟障碍，侧方已确认',
              onPressed:
                  state == TaskState.navigating ? _obstacleConfirmed : null,
            ),
            _demoButton(
              label: '动作后重新感知，确认后恢复导航',
              semanticsLabel: '动作后重新感知',
              onPressed: state == TaskState.avoidingObstacle
                  ? _obstacleConfirmedVerified
                  : null,
            ),
            _demoButton(
              label: '路口信息提示（只提示，不放行）',
              semanticsLabel: '路口信息提示',
              onPressed:
                  state == TaskState.navigating ? _trafficInfo : null,
            ),
            _demoButton(
              label: '模拟行进至接近目的地',
              semanticsLabel: '模拟行进至接近目的地',
              onPressed:
                  state == TaskState.navigating ? _destinationApproach : null,
            ),
            _demoButton(
              label: '寻找入口（先看占位，再看演示已核验候选）',
              semanticsLabel: '寻找入口',
              onPressed: state == TaskState.findingEntrance
                  ? _findEntrance
                  : null,
            ),
            _demoButton(
              label: '进入室内引导',
              semanticsLabel: '进入室内引导',
              onPressed:
                  state == TaskState.findingEntrance ? _enterIndoor : null,
            ),
            _demoButton(
              label: '室内步骤：用演示证据推进',
              semanticsLabel: '室内步骤推进',
              onPressed:
                  state == TaskState.indoorGuidance ? _indoorStep : null,
            ),
            _demoButton(
              label: '验证任务（室内全部完成才可）',
              semanticsLabel: '验证任务',
              onPressed: state == TaskState.indoorGuidance &&
                      _indoor.isCompleted
                  ? _taskVerify
                  : null,
            ),
            _demoButton(
              label: '确认任务完成',
              semanticsLabel: '确认任务完成',
              onPressed: state == TaskState.waitingConfirmation
                  ? _confirmComplete
                  : null,
            ),
            _demoButton(
              label: '保留录像（本地）',
              semanticsLabel: '保留录像',
              onPressed: _recording.current?.status ==
                      RecordingStatus.pendingConsent
                  ? _recordingSave
                  : null,
            ),
            _demoButton(
              label: '删除录像（本地）',
              semanticsLabel: '删除录像',
              onPressed: _recording.current?.status ==
                      RecordingStatus.pendingConsent
                  ? _recordingDelete
                  : null,
            ),
            _demoButton(
              label: '云端网关演示（只返回决策，无真实调用）',
              semanticsLabel: '云端网关演示',
              onPressed: _llmDemo,
            ),
            _demoButton(
              label: '百炼真实调用（需本机 Key，点按才产生费用）',
              semanticsLabel: '百炼真实调用',
              onPressed: _llmRealCall,
            ),
            _demoButton(
              label: '云端视觉辅助（低频，经代理，本地检测仍为主）',
              semanticsLabel: '云端视觉辅助',
              onPressed: _runCloudVisionAssist,
            ),
            _demoButton(
              label: '紧急求助（本地，不依赖网络和大模型）',
              semanticsLabel: '紧急求助',
              onPressed: _triggerEmergency,
            ),
            _demoButton(
              label: '重置演示',
              semanticsLabel: '重置演示',
              onPressed: _resetDemo,
            ),
            const SizedBox(height: 12),
            const Text('演示日志（最新在前）',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            for (final String entry in _log.take(15))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('• $entry'),
              ),
          ],
        ),
      ),
    );
  }
}
