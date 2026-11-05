import 'dart:async';

import 'package:flutter/material.dart';

import 'adapters/bailian_client.dart';
import 'config/app_config.dart';
import 'core/event_bus.dart';
import 'core/health_monitor.dart';
import 'core/llm_gateway.dart';
import 'core/contracts.dart';
import 'core/voice_commands.dart';
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
  String _perceptionText = '尚未模拟感知帧。';

  // Blind-first voice control: the command text is a simulation of a
  // real recogniser transcript until system ASR is integrated (see
  // adapters/voice_io.dart). The last spoken prompt is kept so the
  // user can ask to hear it again.
  final TextEditingController _voiceController = TextEditingController();
  String _lastSpokenText = '';
  HospitalTask _hospital = HospitalTask();
  String _hospitalText = '医院挂号未开始（逻辑步骤演示，非真实挂号）。';

  @override
  void dispose() {
    _straightTimer?.cancel();
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
    if (accepted) {
      final String id = request.id;
      Future<void>.delayed(const Duration(milliseconds: 1200), () {
        if (!mounted) {
          return;
        }
        if (_scheduler.active?.id == id) {
          _scheduler.completeActive();
          final SpeechRequest? next = _scheduler.promoteNext(
            DateTime.now(),
            straightSegmentConfirmed: _straightConfirmed,
            riskActive: _riskActive,
          );
          setState(() {
            if (next != null) {
              _currentPrompt = next.text;
            }
          });
        }
      });
    }
    return accepted;
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
    // stub, the demo voice is text (not TTS), and there is no camera
    // in this run. Reporting them here is why the health line below
    // is not "everything is fine" in a demo.
    _health.report('map_navigation', ServiceHealthStatus.degraded, '演示桩路线，非真实高德数据。');
    _health.report('voice_output', ServiceHealthStatus.degraded, '演示文本播报，非真实系统 TTS。');
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
      text: '已规划路线，正在开始导航。',
      kind: SpeechKind.info,
    ));
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
          _startVoice();
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
          setState(() {
            _straightConfirmed = false;
          });
          _say(_request(
            id: 'voice-pause-${DateTime.now().millisecondsSinceEpoch}',
            eventId: 'voice-pause-${DateTime.now().millisecondsSinceEpoch}',
            text: '已暂停导航，直行提醒已停止。说继续可以恢复，但要重新确认直行路段。',
            kind: SpeechKind.info,
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
        if (_tasks.state == TaskState.paused) {
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
          _say(_request(
            id: 'voice-cancel-${DateTime.now().millisecondsSinceEpoch}',
            eventId: 'voice-cancel-${DateTime.now().millisecondsSinceEpoch}',
            text: '任务已取消，直行提醒已停止。',
            kind: SpeechKind.info,
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
        // v0.5: indoor steps are now voice-confirmable. Outside indoor
        // guidance there is no step to confirm, and the answer says so
        // instead of advancing an unrelated task.
        if (_tasks.state == TaskState.indoorGuidance) {
          _indoorStep();
        } else {
          _say(_request(
            id: 'voice-confirm-no-${DateTime.now().millisecondsSinceEpoch}',
            eventId: 'voice-confirm-no-${DateTime.now().millisecondsSinceEpoch}',
            text: '当前没有室内步骤可以确认。',
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
      appBar: AppBar(title: const Text('明途 AI v0.5（演示原型）')),
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
            Text('配置状态：地图：${AppConfig.amapStatus}；'
                'YOLO：${AppConfig.yoloStatus}；'
                '语音：演示文本播报，非真实 TTS；'
                '云端模型：${AppConfig.llmStatus}；'
                '百炼：${AppConfig.bailianStatus}。'),
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
              '真实语音识别还没接入，下面这个输入框是演示代替：'
              '输入一句话，点发送，就按语音指令解析执行。'
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
              label: '发送语音指令（演示）',
              semanticsLabel: '发送语音指令',
              onPressed: () => _handleVoiceCommand(_voiceController.text),
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
