import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'adapters/amap_client.dart';
import 'adapters/camera_frame_source.dart';
import 'adapters/cloud_asr_client.dart';
import 'adapters/cloud_vision_client.dart';
import 'adapters/voice_recorder.dart';
import 'adapters/cloud_vision_flow.dart';
import 'adapters/current_location.dart';
import 'adapters/system_voice_io.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'adapters/voice_io.dart';
import 'adapters/yolo_detector.dart';
import 'adapters/yolo_live_view.dart';
import 'config/app_config.dart';
import 'config/verified_locations.dart';
import 'core/camera_frame.dart';
import 'core/event_bus.dart';
import 'core/cloud_asr.dart';
import 'core/cloud_vision.dart';
import 'core/health_monitor.dart';
import 'core/route_scoring.dart';
import 'core/llm_gateway.dart';
import 'core/contracts.dart';
import 'core/asr_errors.dart';
import 'core/danger_alerts.dart';
import 'core/avoidance_advisor.dart';
import 'core/cloud_vision_hazard.dart';
import 'core/orientation.dart';
import 'adapters/orientation_monitor.dart';
import 'adapters/haptics.dart';
import 'adapters/pitch_monitor.dart';
import 'core/haptics.dart';
import 'core/navhaz_config.dart';
import 'core/pitch.dart';
import 'core/hazard/ego_motion.dart';
import 'core/hazard/hazard_phrases.dart';
import 'core/hazard/hazard_pipeline.dart';
import 'core/hazard/hazard_policy.dart';
import 'core/destination_dialogue.dart';
import 'core/entrance_guidance.dart';
import 'core/navigation_tracker.dart';
import 'core/straight_pacing.dart';
import 'core/yolo_error_speech.dart';
import 'core/real_navigation.dart';
import 'core/startup_guard.dart';
import 'core/voice_log.dart';
import 'adapters/startup_initializer.dart';
import 'core/voice_commands.dart';
import 'core/voice_startup.dart';
import 'core/risk_engine.dart';
import 'core/speech_scheduler.dart';
import 'core/task_manager.dart';
import 'modules/blind_path.dart';
import 'modules/emergency.dart';
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
  // Startup backstop (P0): the whole app runs in a guarded
  // zone with a FlutterError handler installed, so an
  // unexpected framework/startup error is recorded and later
  // ANNOUNCED (see _initRealIntegrations) instead of the app
  // dying silently on launch.
  runGuardedMain(() {
    WidgetsFlutterBinding.ensureInitialized();
    installFrameworkErrorBackstop();
    runApp(const MingtuApp());
  });
}

class MingtuApp extends StatelessWidget {
  const MingtuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: '明途',
      home: MingtuHomePage(),
    );
  }
}

/// Test/debug seam (MT-1111-PTT-C): the app's interface is
/// deliberately minimal -- camera preview + one big
/// hold-to-talk area, no visible text or other controls --
/// so the flows the old on-screen demo panel used to drive
/// are driven in tests through this handle instead. It only
/// forwards to the very handlers the panel buttons called;
/// it adds no behaviour of its own and is inert in normal
/// use (nothing in the product reads it).
class MingtuHomeDebugHandle {
  MingtuHomeDebugHandle._(this._state);

  final _MingtuHomePageState _state;

  /// The in-app diagnostic log joined (state only; the
  /// panel's log area used to render it).
  String get logText => _state._log.join('\n');

  /// Debug/test seam: the app's live voice input, so a
  /// widget test can attach a fake recogniser to the
  /// adapter (see SystemVoiceInput.debugAttachSpeechForTest)
  /// and drive recognition errors through the adapter's
  /// real path into the app.
  VoiceInput get debugVoiceInput => _state._voiceInput;

  /// Debug/test seam: attach a fake recogniser to the
  /// app's CURRENT voice-input adapter (in place -- the
  /// adapter object and the app's subscriptions to it are
  /// unchanged) and re-register the adapter's listeners on
  /// it. Widget tests use this to drive adapter-level
  /// errors/results into the LIVE app: the platform
  /// channel's plugin object belongs to the first app
  /// instance in the process, so channel delivery cannot
  /// reach a later app's adapter.
  Future<void> debugAttachFakeSpeech(
      stt.SpeechToText speech) async {
    final VoiceInput input = _state._voiceInput;
    if (input is SystemVoiceInput) {
      input.debugAttachSpeechForTest(speech);
      await input.initialize();
    }
  }

  /// The current prompt text (state field; no longer
  /// rendered on screen -- status is spoken, not shown).
  String get currentPrompt => _state._currentPrompt;

  /// The current task state (for flow assertions that used
  /// to read the on-screen state line).
  TaskState get taskState => _state._tasks.state;

  /// The on-screen state line's text form, kept as state:
  /// '当前任务状态：<state>' with the same Chinese state name
  /// the panel used to render.
  String get taskStateText => '当前任务状态：${_state._stateText(_state._tasks.state)}';

  /// The on-screen prompt line's text form, kept as state:
  /// '当前提示：<prompt>'.
  String get currentPromptText => '当前提示：${_state._currentPrompt}';

  /// All status texts joined (state only): the migration
  /// target for panel-text `find.textContaining` assertions
  /// (detail lines, health line, config line).
  String get allStatusText => statusTexts.join('\n');

  /// The health line's text form, kept as state (the panel
  /// rendered 系统健康：… from the health monitor).
  String get healthText => _state._health.announcementText().isEmpty
      ? '系统健康：暂无已上报的降级（演示中仅紧急流程会主动上报本地服务状态，未上报的服务不伪造健康）。'
      : '系统健康：${_state._health.announcementText()}';

  /// The configuration status line's text form (state).
  String get configStatusText =>
      '配置状态：地图：${AppConfig.routeProxyStatus}；'
      'YOLO：${AppConfig.yoloStatus}；'
      '云端模型：${AppConfig.llmStatus}；'
      '云端识图：${AppConfig.visionProxyStatus}。';

  /// The big status line's value, kept as state only.
  String get bigStatusText => _state._bigStatusText();

  /// The status text fields, kept in the logic layer
  /// (MT-1111-PTT-C renders none of them; status is spoken).
  /// Exposed here so tests can assert state without a
  /// screen, and so the fields stay read somewhere.
  List<String> get statusTexts => <String>[
        _state._voiceText,
        _state._amapText,
        _state._yoloText,
        _state._routeText,
        _state._obstacleText,
        _state._trafficText,
        _state._entranceText,
        _state._indoorText,
        _state._emergencyText,
        _state._recordingText,
        _state._llmText,
        _state._cloudVisionText,
        _state._perceptionText,
      ];

  void stopVoiceRecognition() => _state._stopListening();
  void askDestination() => _state._askDestination();
  void voiceCommand(String text) => _state._handleVoiceCommand(text);
  void startVoiceDemo() => _state._startVoice();
  void planRoute() => _state._planRoute();
  void startNavigating() => _state._startNavigating();
  void turnAhead() => _state._turn();
  void manualStraight() => _state._manualStraight();
  void reconfirmStraight() => _state._reconfirmStraight();
  void obstacleUncertain() => _state._obstacleUncertain();
  void obstacleUncertainResolved() => _state._obstacleUncertainResolved();
  void obstacleConfirmed() => _state._obstacleConfirmed();
  void obstacleConfirmedVerified() => _state._obstacleConfirmedVerified();
  void trafficInfo() => _state._trafficInfo();
  void destinationApproach() => _state._destinationApproach();
  void findEntrance() => _state._findEntrance();
  void enterIndoor() => _state._enterIndoor();
  void indoorStep() => _state._indoorStep();
  void taskVerify() => _state._taskVerify();
  void confirmComplete() => _state._confirmComplete();
  void recordingSave() => _state._recordingSave();
  void recordingDelete() => _state._recordingDelete();
  void llmDemo() => _state._llmDemo();
  void triggerManualVision() => _state._triggerManualVision();
  void triggerEmergency() => _state._triggerEmergency();
  void resetDemo() => _state._resetDemo();
  void fetchAmapRoute() => _state._fetchAmapRoute();

  /// The simulated-detection buttons' production path:
  /// feed one detection frame to the YOLO handler.
  void simulateDetections(List<Detection> detections) =>
      _state._onYoloDetections(detections);

  void simulatePersonAhead() => simulateDetections(const <Detection>[
        Detection(label: 'person', confidence: 0.9, cx: 0.5, cy: 0.5),
      ]);

  void simulateVehicleAhead() => simulateDetections(const <Detection>[
        Detection(label: 'car', confidence: 0.9, cx: 0.5, cy: 0.5),
      ]);

  void simulateClearFrames() {
    for (int i = 0; i < 3; i++) {
      simulateDetections(const <Detection>[]);
    }
  }

  /// NAVHAZ M1 seams: substitute the haptics implementation
  /// (widget tests inject a recording fake; production
  /// never calls this).
  void debugSetHaptics(Haptics haptics) => _state._haptics = haptics;

  /// NAVHAZ M1 seam: install a live navigation tracker
  /// directly (the arbitration tests drive fixes and hazard
  /// frames against it without the network route flow).
  void debugInstallLiveTracker({
    required List<AmapStep> steps,
    required List<String> stepTexts,
    required GeoPoint destination,
    required String destinationName,
  }) {
    _state._liveNav = NavigationTracker(
      steps: steps,
      stepTexts: stepTexts,
      destination: destination,
      destinationName: destinationName,
    );
    _state._liveNavDestName = destinationName;
    _state._liveNavRemainingM = null;
  }

  /// NAVHAZ M1 seam: the installed live tracker, if any.
  NavigationTracker? get debugLiveNav => _state._liveNav;

  /// NAVHAZ M1 seam: feed one live-navigation fix through
  /// the production fix handler.
  void debugLiveFix(GeoPoint point, double? accuracyM) =>
      _state._onLiveNavFix(LocationResult.fix(point, accuracyM));

  Future<void> openYoloLive() => _state._openYoloLive();
  void closeYoloLive() => _state._closeYoloLiveView();
  bool get yoloLiveOpen => _state._yoloLiveOpen;

  /// Cloud-ASR fallback seams: substitute the recorder /
  /// ASR client a press uses (widget tests inject fakes;
  /// production never calls these).
  void setRecorder(VoiceRecorder recorder) => _state._recorder = recorder;
  void setCloudAsrClient(CloudAsrClient client) =>
      _state._cloudAsrClient = client;
  bool get localAsrBroken => _state._localAsrBroken;

  /// MT-1111-PTT-2 seams: inject a shorter recording cap
  /// (tests) and read the recoverable-error bookkeeping.
  void setRecordCapMs(int ms) => _state._recordCapMsOverride = ms;

  /// Test seam: drive the recording-cap completion
  /// directly (a widget test's fake clock cannot fire the
  /// app's private wall-clock cap timer). Production never
  /// calls this -- the cap Timer does.
  void debugFireRecordCap() =>
      unawaited(_state._onPttRecordCapReached(_state._pttSession));
  Map<String, int> get recoverableErrorCounts =>
      Map<String, int>.unmodifiable(_state._asrStreakSnapshot);

  /// CDX2 streak view: the one code currently streaking
  /// and its length (0 / null when no streak is open).
  String? get asrStreakCode => _state._asrStreakCode;
  int get asrStreakCount => _state._asrStreakCount;
  bool get recoveryPending => _state._asrRecoveryPending;

  /// CDX2 seams: the current press's session id, the
  /// TalkBack long-press entry (the same method the
  /// Semantics action calls), and firing the shared cap
  /// timer's callback for an ARBITRARY session id -- the
  /// stale-timer test fires session 1's callback during
  /// session 2 and asserts nothing happens.
  int get pttSessionId => _state._pttSession;

  /// Test-only: engine events ('restarted' /
  /// 'restart_failed') this page has handled, in order.
  List<String> get debugEngineEvents =>
      List<String>.unmodifiable(_state._debugEngineEvents);

  /// Test-only: whether the app is currently inside a
  /// close-confirmation wait (its finally has not run).
  bool get debugConfirmingClose => _state._asrConfirmingClose;

  /// Test-only: the live adapter's unconfirmed-close
  /// count (-1 when the input is not the system adapter).
  int get debugPendingCloses {
    final VoiceInput input = _state._voiceInput;
    return input is SystemVoiceInput ? input.pendingCloses : -1;
  }

  /// Test-only: run the same engine-epoch accounting a
  /// listen attempt performs (the missed-watchdog-restart
  /// replay path), without starting a listen.
  void debugEnsureEngineSubscription() =>
      _state._ensureEngineSubscription();

  /// Test-only: identity of the engineEvents stream this
  /// page believes it is subscribed to (-1 when none).
  int get debugSubscribedEngineStreamIdentity => _state
              ._subscribedEngineEvents ==
          null
      ? -1
      : identityHashCode(_state._subscribedEngineEvents);

  /// Test-only: identity of the LIVE adapter's
  /// engineEvents stream object.
  int get debugLiveEngineStreamIdentity {
    final VoiceInput input = _state._voiceInput;
    return input is SystemVoiceInput
        ? identityHashCode(input.debugEngineEventsStreamIdentity)
        : -2;
  }

  /// Test-only: run the SAME unbounded close-confirmation
  /// wait a stuck press's final-wait expiry runs
  /// (_pttFinalWaitExpired's helper): the adapter
  /// watchdog's restart is what resolves it. Used by the
  /// missed-restart replay scenario to stay inside the
  /// restart window with a live waiter when the restart
  /// lands.
  void debugConfirmClose() =>
      unawaited(_state._ensureAsrCloseConfirmed());

  /// Test-only: drop this page's live engine-events
  /// subscription (and keep it dropped) -- the
  /// subscription-gap half of the missed-restart replay
  /// scenario.
  void debugDropEngineSubscription() =>
      _state._debugDropEngineSubscription();

  /// Test-only: how many engine events the LIVE adapter
  /// has EMITTED in total (its broadcast stream drops an
  /// event with no live listener; this log does not), so
  /// a test can prove a watchdog restart really happened
  /// on THIS app's adapter while the app handled none.
  int get debugAdapterEngineEventsEmittedCount {
    final VoiceInput input = _state._voiceInput;
    return input is SystemVoiceInput
        ? input.debugEngineEventsEmitted.length
        : -1;
  }
  void debugTalkBackLongPress() => _state._talkBackLongPress();
  void debugFireCapTimerFor(int sid) =>
      unawaited(_state._onPttCapTimerFired(sid));
}

/// The live home page's debug handle (see above). Assigned
/// in initState; a fresh page replaces it.
MingtuHomeDebugHandle? mingtuHomeDebugHandle;

class MingtuHomePage extends StatefulWidget {
  const MingtuHomePage({super.key});

  @override
  State<MingtuHomePage> createState() => _MingtuHomePageState();
}



/// Push-to-talk press states. See the state fields on
/// _MingtuHomePageState for the transition contract.
enum _PttState { idle, prompting, starting, listening, stopping }

/// Test-only hook (set by widget tests before a press):
/// runs on every new push-to-talk press with the live
/// voice input, so a test can adjust the ADAPTER's debug
/// seams for exactly the presses it drives.
void Function(Object voiceInput)? mingtuPttPressDebugHook;

class _MingtuHomePageState extends State<MingtuHomePage>
    with WidgetsBindingObserver {
  TaskManager _tasks = TaskManager();
  SpeechScheduler _scheduler = SpeechScheduler();
  MapNavigationService _mapService = MapNavigationService(StubMapProvider());
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
  final CloudVisionClient _cloudVisionClient = CloudVisionClient(
    proxyBaseUrl: AppConfig.visionProxyUrl,
    demoToken: AppConfig.visionDemoToken,
  );
  // Cloud ASR fallback (real-device fix round): records with
  // the app's own microphone when the system speech engine
  // cannot (Xiaomi engine permission failure), and sends the
  // clip to the same FC deployment's /asr route. The recorder
  // is replaced by the platform implementation at startup;
  // tests may substitute fakes for both seams.
  VoiceRecorder _recorder = const UnavailableVoiceRecorder();
  // ignore: prefer_final_fields -- tests substitute a fake-sender client.
  CloudAsrClient _cloudAsrClient = CloudAsrClient(
    proxyBaseUrl: AppConfig.asrProxyUrl,
    demoToken: AppConfig.visionDemoToken,
  );

  /// True once the local (system) recogniser has proven
  /// broken on this device (permission error, unavailable at
  /// a press, start failure): subsequent presses go straight
  /// to the recording fallback. Never reset by an error --
  /// a working press clears nothing; the flag only routes.
  bool _localAsrBroken = false;

  /// True while the current press is served by the recorder
  /// instead of the system recogniser.
  bool _pttRecording = false;

  /// Error codes already announced in the current stretch:
  /// the same code is spoken ONCE until a recognition
  /// session succeeds, which resets the set (a later session
  /// may announce the same code again). No code ever
  /// disables future presses.
  final Set<String> _asrErrorSpokenCodes = <String>{};

  /// The ONE open streak of RECOVERABLE recognition
  /// errors (CDX2 replaces the per-code cumulative Map):
  /// only the SAME code arriving twice TRULY consecutively
  /// escalates. [_asrStreakCode] is the code of the current
  /// streak (null = no streak) and [_asrStreakCount] its
  /// length. A different code RESTARTS the streak at 1 --
  /// busy, client, busy never accumulates to an
  /// escalation. The streak lives ACROSS presses (CDX3 /
  /// MT-1111-PTT-4, tightened by MT-1111-PTT-4B): it is
  /// cleared ONLY at the moment a recognition result is
  /// actually SUBMITTED (see [_noteAsrSessionDelivered],
  /// called from the press completion point), or
  /// displaced by a different error code restarting it.
  /// A partial that merely ARRIVES clears nothing -- it
  /// is a cache entry until a release submits it. A
  /// listen that merely STARTS clears nothing either:
  /// two presses that each error busy once, with a
  /// successful listen start and no submitted result
  /// between them, are a streak of 2 and the NEXT press
  /// escalates to the cloud route. Fatal codes never
  /// land here (they route directly).
  String? _asrStreakCode;
  int _asrStreakCount = 0;

  /// The streak as a one-entry map (debug/test view kept
  /// from the per-code era).
  Map<String, int> get _asrStreakSnapshot => _asrStreakCode == null
      ? <String, int>{}
      : <String, int>{_asrStreakCode!: _asrStreakCount};

  /// Count one recoverable error occurrence against the
  /// streak: same code -> length + 1; different code ->
  /// the streak restarts at 1 for the new code. Length 2
  /// escalates (the recording route takes over from the
  /// next press); length 1 only arms the next press's
  /// recovery sequence.
  void _noteRecoverableAsrError(String code) {
    if (_asrStreakCode == code) {
      _asrStreakCount += 1;
    } else {
      _asrStreakCode = code;
      _asrStreakCount = 1;
    }
    if (_asrStreakCount >= 2) {
      _localAsrBroken = true;
    } else {
      _asrRecoveryPending = true;
    }
  }

  /// Close the streak. Called ONLY from the submission
  /// clearing point ([_noteAsrSessionDelivered]); never
  /// from a listen start or a result's mere arrival
  /// (CDX3 / MT-1111-PTT-4B).
  void _resetAsrErrorStreak() {
    _asrStreakCode = null;
    _asrStreakCount = 0;
  }

  /// A recoverable error was seen since the last session:
  /// the NEXT press must first run the fixed recovery
  /// (cancel -> re-initialize -> listen) before it may
  /// listen. Cleared when a session starts successfully.
  bool _asrRecoveryPending = false;

  /// The recoverable-error code whose escalation
  /// currently owns the recording route, or null when it
  /// does not. The switch notice is spoken on the ONE
  /// press where a NEW streak takes the route; later
  /// presses on the same streak stay silent, and a streak
  /// that re-forms after a delivered result (which
  /// cleared the streak) announces again.
  String? _asrEscalationAnnouncedFor;

  /// Test-only override of the recording cap (production
  /// always uses asrMaxRecordMs); set via the debug handle.
  int? _recordCapMsOverride;

  /// The recording cap timer for the current press: armed
  /// when a recording starts, fires the cap completion
  /// (auto-stop + transcribe) if the press is still held,
  /// and is cancelled on release / cancel / background.
  Timer? _pttRecordCapTimer;

  /// Session id of a press started through the TalkBack
  /// long-press action, or null. TalkBack has no physical
  /// release, so such a press needs the shared cap timer
  /// even on the local-ASR path; the timer is nevertheless
  /// armed only when that session's listening/recording
  /// has ACTUALLY started (ALIGN-B), never at press time.
  int? _talkBackCapSessionId;

  /// Test-only log of handled engine events (see the
  /// debug handle).
  final List<String> _debugEngineEvents = <String>[];


  /// Subscription to the adapter's no-match outcome stream.
  StreamSubscription<String>? _asrNoMatchSub;
  // On-demand single-frame camera source (production wiring):
  // one explicit trigger captures exactly one still frame via the
  // camera plugin and disposes the controller immediately -- no
  // streaming upload, no recording. On web it reports unavailable.
  // Assigned in initState: the routing closure reads
  // _yoloLiveOpen, which an initializer may not reference.
  // Starts as the last-resort source; _initStartupModules
  // replaces it with the guarded production pipeline.
  CameraFrameSource _frameSource = const LastResortCameraFrameSource();

  /// The app's single camera arbiter: the YOLO live view and
  /// the one-shot still capture share it, so the camera can
  /// never be double-opened, and background/dispose cancels
  /// every registered in-flight request through it.
  final CameraOwnership _cameraOwnership = CameraOwnership();

  /// Owns the ONE active cloud-vision run's cancellation token.
  /// A duplicate trigger is refused via begin() == null and
  /// creates NO token (the old per-call field overwrite orphaned
  /// the running run's token).
  final VisionRunManager _visionRuns = VisionRunManager();
  // The sequenced flow: configured/rate-limit checks BEFORE the
  // camera opens, "正在识别" announced first, then one frame, then
  // one rate-limited describe call. Every step is spoken.
  late final OnDemandCloudVision _cloudVisionFlow = OnDemandCloudVision(
    client: _cloudVisionClient,
    frameSource: _frameSource,
  );
  // Danger step (2026-11-09): the avoidance advisor owns the
  // three-condition direction rule; the orientation monitor
  // feeds condition 3 (fail-closed until the gyroscope seam
  // is created at startup).
  final AvoidanceAdvisor _avoidance = AvoidanceAdvisor();
  OrientationMonitor _orientation = const UnavailableOrientationMonitor();

  /// NAVHAZ M1: camera pitch for ground-plane ranging
  /// (unknown on stub platforms -> ranging off, scale TTC
  /// still applies).
  PitchMonitor _pitchMonitor = const UnavailablePitchMonitor();

  /// NAVHAZ M1: patterned vibration seam (device channel on
  /// mobile, no-op elsewhere; tests inject a recording fake
  /// through the debug handle).
  Haptics _haptics = const NoOpHaptics();

  /// NAVHAZ M1: tracking + TTC + alert policy pipeline for
  /// geometry-bearing YOLO frames.
  final HazardPipeline _hazardPipeline = HazardPipeline();
  // Cloud-vision cycle merging + 429 backoff (hazard scans).
  final VisionCycleCoordinator _visionCycle = VisionCycleCoordinator();
  final VisionRateBackoff _visionBackoff = VisionRateBackoff();
  final CloudVisionDowngradeGate _visionDowngrade = CloudVisionDowngradeGate();
  Timer? _hazardScanTimer;
  GeoPoint? _lastFixPoint;
  double? _lastFixAccuracyM;
  GeoPoint? _scanAnchorPoint;
  DateTime? _lastVisionCallAt;
  bool _manualCycleOwned = false;
  String _perceptionText = '尚未模拟感知帧。';
  // v0.6 real integrations. Defaults are the unavailable fallbacks;
  // _initRealIntegrations replaces them only when the phone's own
  // engine / model actually answers. Nothing here fakes a service.
  VoiceOutput _voiceOutput = UnavailableVoiceOutput();
  VoiceInput _voiceInput = UnavailableVoiceInput();
  YoloDetector _yoloDetector = UnavailableYoloDetector();

  // Constructed behind startup guards (see _initStartupModules);
  // the defaults are the honest unconfigured variants, replaced
  // only when construction succeeds.
  AmapWalkingClient _amapClient = AmapWalkingClient(proxyBaseUrl: '');
  CurrentLocationProvider _locationProvider =
      const UnavailableCurrentLocation();
  /// The voice input whose ASR event streams this page is
  /// currently subscribed to. Subscriptions are (re)made
  /// whenever the input OBJECT changes: the startup flow
  /// first wires the unavailable placeholder and later
  /// swaps in the real input -- a swap that skipped
  /// re-subscription would leave every event listener
  /// bound to the dead placeholder forever.
  VoiceInput? _subscribedVoiceInput;

  /// Cancel callbacks for the ASR event subscriptions,
  /// keyed to the input object they were made on (see
  /// [_subscribedVoiceInput]): invoking them cancels every
  /// subscription of that wiring round.
  List<void Function()> _asrSubCancels = <void Function()>[];

  /// The adapter's current engineEvents stream object.
  /// A broadcast stream getter can mint a NEW stream
  /// object per access; identity of THIS object is what
  /// decides whether the engine subscription needs
  /// re-making (see [_ensureEngineSubscription]).
  Stream<String>? _subscribedEngineEvents;

  /// Last engine epoch this page has accounted for; a
  /// restart that fired while no engine listener was live
  /// is replayed from the epoch bump (see
  /// [_ensureEngineSubscription]). Null until the first
  /// check: the first observation only establishes the
  /// baseline (a restart that predates any subscription
  /// cannot be distinguished from the initial state, and
  /// announcing it at startup would be wrong).
  int? _engineEpochSeen;

  /// Test-only one-shot: skip the epoch accounting of
  /// the NEXT [_ensureEngineSubscription] pass entirely
  /// (set by the missed-restart replay test through a
  /// MethodChannel marker; production code never sets
  /// it). Simulates the subscription-rebuild gap in
  /// which a watchdog restart's notification is lost.
  bool _suppressNextEngineEpochCheck = false;

  /// Account for ONE adapter epoch bump observed by
  /// [_ensureEngineSubscription]. Epochs minted by the
  /// RECOVERY re-initialize are consumed silently (the
  /// adapter attributes them; the press flow already
  /// handled that restart and spoke its own outcome).
  /// Every other bump is a WATCHDOG restart whose live
  /// notification was missed, so its outcome is replayed
  /// exactly once -- success handling when the restart's
  /// re-initialize succeeded, the failure handling when
  /// it failed (via [SystemVoiceInput.lastRestartSucceeded]).
  /// CDX3: an earlier form synced _engineEpochSeen to the
  /// current epoch UNCONDITIONALLY at the top of
  /// _ensureEngineSubscription, which rewrote the very
  /// epoch difference this replay compares -- a missed
  /// watchdog restart could never replay again. Bump
  /// attribution, not blanket syncing, is what separates
  /// the two restart kinds.
  void _noteEngineEpochBump(SystemVoiceInput input, int epoch) {
    if (input.consumeRecoveryEpoch(epoch)) return;
    if (!mounted) return;
    if (input.lastRestartSucceeded) {
      _onEngineRestarted();
    } else {
      _onEngineRestartFailed();
    }
  }

  /// Set by [_ensureAsrCloseConfirmed] while it confirms
  /// the automatic session's close: during that window a
  /// sessionEnded or error event belongs to the closing
  /// session and must not touch live bookkeeping.
  bool _asrConfirmingClose = false;

  StreamSubscription<AsrResultEvent>? _transcriptSub;
  StreamSubscription<AsrResultEvent>? _partialSub;
  StreamSubscription<String>? _asrErrorSub;

  /// Session id of the last SUCCESSFULLY started listen;
  /// kept for transcript/status validation. The error
  /// stream uses a separate LIVE-session id below, because
  /// a started session that fails before any event must
  /// not leave a stale id behind.
  int _asrLiveSessionId = 0;
  StreamSubscription<AsrStatusEvent>? _asrSessionSub;
  StreamSubscription<String>? _asrEngineSub;
  bool _yoloErrorAnnounced = false;

  // Step 2 voice navigation flow state.
  NavigationTracker? _liveNav;
  RerouteBudget? _tripRerouteBudget;
  // The ONE straight-pacing state machine (Codex re-test
  // of d01a081): pause, timing and the resume re-check all
  // live in StraightPacingMachine -- no separate pause flag,
  // no direct scheduler resumes, exactly one timer, armed
  // only on a machine transition into running.
  final StraightPacingMachine _pacing = StraightPacingMachine();
  // True while an off-route re-plan is in flight: the old
  // tracker stays installed for the failure fallback but
  // must not be read for straight confirmation.
  bool _rerouting = false;
  // The reroute-failure notice is spoken ONCE per off-route
  // episode (Codex re-test of 926901c): retries under the
  // trip budget stay silent after the first failure. Reset
  // whenever a route is successfully installed (a new trip,
  // or a re-plan that finally succeeds).
  bool _rerouteFailureAnnounced = false;
  StreamSubscription<LocationResult>? _gpsSub;
  String _liveNavDestName = '';
  double? _liveNavRemainingM;
  DateTime? _lastGpsErrorAt;
  // Step D entrance guidance: created when the tracker hands
  // over (fix within 60 m of the destination). While active,
  // GPS fixes feed the guidance instead of the tracker, and
  // the trip completes only at the guidance arrival radius.
  EntranceGuidance? _entrance;
  bool _entranceActive = false;
  DateTime? _lastEntranceWeakAt;
  bool _awaitingDestination = false;
  int _destAttempts = 0;
  bool _yoloAvailableAtStartup = false;
  final DangerAlertGate _dangerGate = DangerAlertGate();
  // Voice P0 re-test fixes: once TTS has failed at runtime the app
  // is in a perceptible voice-failed state (no simulated success,
  // no automatic ASR restart); once an ASR error has been announced
  // it is not announced again (no retry/announce loop).
  bool _ttsFailed = false;

  /// True while the last-started listening session has not
  /// yet been closed by an app-initiated stop/cancel. The
  /// adapter's error stream is stamped with a mutable
  /// session tag, so a transient error from a session that
  /// is already being closed can arrive stamped as the
  /// CURRENT session; the app therefore suppresses errors
  /// itself while such a close is in flight (they belong
  /// to the closing session, whose outcome the stop already
  /// decided) and counts them for the session that caused
  /// them.
  bool _asrCloseInFlight = false;
  String _voiceText = '语音：未初始化（演示文本播报）。';
  String _amapText = '高德真实路线：未请求。';
  String _yoloText = 'YOLO：未接入。';
  bool _yoloLiveOpen = false;

  /// Step C push-to-talk: true while the big button is held.
  /// Guards one physical press from firing the start callback
  /// twice (long-press start is delivered once per gesture,
  /// but the guard keeps the contract explicit).
  bool _pushToTalkHeld = false;

  /// Explicit push-to-talk state machine (project-lead
  /// design, Codex re-test of c104dc7): every press owns a
  /// unique [_pttSession] id; [_pttState] moves
  /// idle -> prompting -> starting -> listening ->
  /// stopping -> idle. Async callbacks validate their
  /// session id first -- a stale session's callback is
  /// always dropped. A release during prompting/starting
  /// only records [_pttPendingStop]; the sequence itself
  /// performs the stop when its current await returns, so
  /// no release window can leak an open microphone.
  _PttState _pttState = _PttState.idle;
  int _pttSession = 0;
  bool _pttPendingStop = false;

  /// This press was released too short: its recognition
  /// session is VOID. The adapter session is cancelled
  /// (not stopped), and every later final/partial from it
  /// is dropped; the press only ever speaks the too-short
  /// notice.
  bool _pttSessionVoided = false;

  /// This press is waiting in prompting for the previous
  /// recognition session to fully close (serialization
  /// barrier); when the close completes it enters the
  /// prompt step if still held.
  bool _pttDeferredByClose = false;

  /// The current press already spoke its one-time
  /// close-wait notice ('请稍等'): a press waits out an
  /// unconfirmed close exactly once, never repeatedly.
  bool _pttCloseWaitAnnounced = false;

  /// This press began during a P0 announcement: it waits
  /// (vibration only -- no cue, no ASR) and enters
  /// prompting when the P0 prompt finishes, IF the button
  /// is still held then.
  bool _pttDeferredByP0 = false;

  /// The latest recognition text cached during the current
  /// press (finals and partials alike): never executed
  /// while held, submitted once after the release.
  String? _pttCachedText;

  /// Whether [_pttCachedText] is a final result (a later
  /// partial must not overwrite a cached final).
  bool _pttCachedIsFinal = false;

  /// The adapter session id of the recognition session
  /// most recently started by this app (0 = none yet).
  /// Every result and status event is validated against it
  /// first: a late callback from an older session is
  /// dropped, however plausible its text looks.
  int _asrSessionId = 0;

  /// Waits for a post-release final result before the
  /// no-content notice may fire (1.5 s).
  Timer? _pttNoContentTimer;

  /// When the current press began (the under-300ms rule).
  DateTime? _pushToTalkPressedAt;

  /// Whether the AUTOMATIC session was the one listening
  /// when the press began: it was stopped for the press,
  /// and after the press the loop resumes only if it was
  /// actually running before.
  bool _autoListenWasActive = false;

  /// The ownership lease for the live view, held while it is
  /// open; only this lease can release the camera, and the
  /// release waits for the view to actually unmount.
  CameraLease? _yoloLease;
  double? _yoloLatencyMs;
  // v0.7 voice-first additions.
  AmapStepSpeaker? _amapSpeaker;
  bool _yoloRiskActive = false;
  int _yoloEmptyFrames = 0;

  // Blind-first voice control: the command text is a simulation of a
  // real recogniser transcript until system ASR is integrated (see
  // adapters/voice_io.dart). The last spoken prompt is kept so the
  // user can ask to hear it again.
  final TextEditingController _voiceController = TextEditingController();
  String _lastSpokenText = '';

  /// When the utterance the sequencer most recently started
  /// playing began; a push-to-talk press uses it to recognise
  /// a just-started P0 utterance whose scheduler entry has
  /// already completed (see _interruptSpeechForPushToTalk).
  DateTime? _lastSpeechStartedAt;

  /// The text of the most recent P0 (danger/emergency)
  /// utterance actually played; compared against
  /// _lastSpokenText by the push-to-talk interruption rules.
  String _lastP0SpokenText = '';

  /// The scheduler id of that P0 utterance; the scheduler's
  /// interrupted/cancelled logs carry ids, so the P0 gate
  /// can recognise a just-interrupted P0 playback.
  String _lastP0RequestId = '';

  /// When a physical stop was last issued inside an
  /// utterance's first moments; see _trackedSpeak.
  DateTime? _pttStoppedUtteranceAt;

  @override
  void initState() {
    super.initState();
    mingtuHomeDebugHandle = MingtuHomeDebugHandle._(this);
    _recorder = createVoiceRecorder();
    WidgetsBinding.instance.addObserver(this);
    // _initRealIntegrations never throws (every module is
    // guarded inside the production initializer, and startup
    // always ends with the unified announcement).
    unawaited(_initRealIntegrations());
  }

  /// Lifecycle release: going to background (or being hidden /
  /// detached) cancels any in-flight cloud-vision recognition
  /// (its late result is discarded, never spoken) and closes the
  /// YOLO live view so the camera is released. Disposal does the
  /// same via [dispose].
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      if (_yoloLiveOpen && mounted) {
        setState(() {
          _closeYoloLiveView();
        });
        _logMsg('应用进入后台：已关闭 YOLO 实时摄像头并取消进行中的云端视觉识别。');
      }
      _visionRuns.cancelActive();
      _cameraOwnership.cancelAllAndRelease();
      // MT-1111-PTT-D(4): backgrounding releases the
      // microphone. A press in listening/recording is
      // CANCELLED (existing cancel semantics: voided,
      // never submitted); a press already in its stopping
      // window is left to settle normally.
      if (_pttState == _PttState.listening) {
        _pushToTalkHeld = false;
        if (_pttRecording) {
          _pttRecordCapTimer?.cancel();
          _pttRecordCapTimer = null;
          _pttRecording = false;
          _pttState = _PttState.idle;
          unawaited(() async {
            try {
              await _recorder.cancel();
            } catch (_) {}
          }());
        } else {
          _pttSessionVoided = true;
          _pttState = _PttState.idle;
          unawaited(_cancelListeningInternal());
        }
      } else if (_pttState == _PttState.prompting ||
          _pttState == _PttState.starting) {
        _pushToTalkHeld = false;
        _pttPendingStop = true;
      }
    }
  }

  /// Try the phone's own engines once at startup. Each adapter
  /// reports unavailable instead of throwing, so a missing engine
  /// (web, VM, test harness, denied permission) just leaves the
  /// demo fallback in place.
  /// Startup entry point. Runs the module initialisation and
  /// then ALWAYS finishes with the unified degradation
  /// announcement -- even when initialisation threw before it
  /// could summarise itself (the hole this restructure closes:
  /// failures were recorded but, on that path, never spoken).
  Future<void> _initRealIntegrations() async {
    bool speechUsable = false;
    try {
      speechUsable = await _initStartupModules();
    } catch (_) {
      startupFailures.record('应用初始化');
    }
    if (!mounted) return;
    _orientation = createOrientationMonitor()..start();
    _pitchMonitor = createPitchMonitor()..start();
    _haptics = createHaptics();
    _hazardScanTimer?.cancel();
    _hazardScanTimer = Timer.periodic(
      const Duration(seconds: 8),
      (_) => _hazardScanTick(),
    );
    _announceStartupFailures(speechUsable: speechUsable);
    unawaited(_kickoffVoiceNavFlow(speechUsable));
  }

  /// Step 2 kickoff, after the startup announcements: request
  /// the location permission up front, open the camera
  /// (YOLO live view) automatically, then ask "你要去哪里？".
  /// The whole flow needs working speech; when speech is down
  /// the degradation has already been surfaced by the plan
  /// (haptics + screen) and there is nothing honest to ask
  /// with. Failures here are logged, never fatal to startup.
  Future<void> _kickoffVoiceNavFlow(bool speechUsable) async {
    try {
      if (!speechUsable) return;
      final bool locOk = await _locationProvider.ensurePermission();
      if (!mounted) return;
      if (_yoloAvailableAtStartup) {
        unawaited(_openYoloLive());
      }
      if (!locOk) {
        mingtuVoiceLog('启动权限：定位未授权，跳过目的地提问');
        _say(_request(
          id: 'perm-location-denied',
          eventId: 'perm-location-denied',
          text: '定位权限未开启，无法导航。请在系统设置里允许明途使用定位。',
          kind: SpeechKind.alert,
        ));
        return;
      }
      if (_tasks.state == TaskState.idle) {
        _askDestination();
      }
    } catch (_) {
      mingtuVoiceLog('语音导航启动流程异常，已跳过（不影响其他功能）');
    }
  }

  /// Ask the destination question and open the answer slot.
  void _askDestination({String prompt = destinationAskText}) {
    _awaitingDestination = true;
    _destAttempts = 0;
    if (mounted) setState(() {});
    _say(_request(
      id: 'ask-destination-${DateTime.now().millisecondsSinceEpoch}',
      eventId: 'ask-destination-${DateTime.now().millisecondsSinceEpoch}',
      text: prompt,
      kind: SpeechKind.info,
    ));
  }

  /// A spoken answer to the destination question. Matched:
  /// start real navigation. Unmatched: re-ask (bounded), never
  /// guess a place.
  void _answerDestination(String raw) {
    final VerifiedLocation? loc = resolveDestinationAnswer(raw);
    if (loc == null) {
      _destAttempts += 1;
      if (_destAttempts >= 3) {
        _awaitingDestination = false;
        _say(_request(
          id: 'dest-giveup',
          eventId: 'dest-giveup',
          text: destinationGiveUpText(),
          kind: SpeechKind.info,
        ));
      } else {
        _say(_request(
          id: 'dest-retry-$_destAttempts',
          eventId: 'dest-retry-$_destAttempts',
          text: destinationNotFoundText(),
          kind: SpeechKind.info,
        ));
      }
      return;
    }
    _awaitingDestination = false;
    _say(_request(
      id: 'dest-ok',
      eventId: 'dest-ok',
      text: '好的，去${loc.name}。',
      kind: SpeechKind.info,
    ));
    _startRealNavigation(loc.name);
  }

  /// Begin GPS-tracked live navigation for a ready route:
  /// build the tracker from the route's step geometry and
  /// subscribe to the (once-converted) position stream.
  void _beginLiveNavigation(
      RealNavigationOutcome outcome, String destinationName) {
    // A route was just installed: any earlier reroute-failure
    // notice belongs to a finished episode.
    _rerouteFailureAnnounced = false;
    final AmapWalkingResult result = outcome.route!;
    final List<String> texts = <String>[];
    final AmapStepSpeaker collector = AmapStepSpeaker(result.steps);
    while (true) {
      final String? t = collector.nextStepText();
      if (t == null) break;
      texts.add(t);
    }
    _liveNav = NavigationTracker(
      steps: result.steps,
      stepTexts: texts,
      destination: outcome.destination!.pointGcj02,
      destinationName: destinationName,
      budget: _tripRerouteBudget ??= RerouteBudget(),
    );
    _liveNavDestName = destinationName;
    _liveNavRemainingM = _liveNav!.remainingM;
    // A newly installed route supersedes any entrance phase
    // left over from the previous tracker (only reachable if
    // a re-plan finished after the hand-over fix).
    _entrance = null;
    _entranceActive = false;
    // A stale demo-flow straight confirmation must not leak
    // into the live trip: while the tracker exists it alone
    // governs straight confirmation (see the getter).
    _straightConfirmed = false;
    _amapSpeaker = AmapStepSpeaker(result.steps);
    _gpsSub?.cancel();
    _gpsSub = _locationProvider.positions().listen(
          _onLiveNavFix,
          onError: (Object e) => mingtuVoiceLog('定位流出错，实时导航提示暂停'),
        );
    // Live straight prompts: the shared 3 s tick reads its
    // confirmation from the tracker while live nav runs.
    if (_pacing.isPaused) {
      // A re-plan just installed the NEW tracker (or a fresh
      // trip is starting over a stale pause): straight
      // guidance resumes only through the unified re-check
      // against THIS tracker, never the replaced one. The
      // check is the machine's pause state, not the reported
      // state value: with both pause reasons set the reported
      // state names only one of them, and a risk hold alone
      // must take this branch too -- begin() must never arm
      // the timer across an unreleased pause.
      _rerouting = false;
      _recheckStraightResume();
      if (!_pacing.canTick) _stopStraightTimer();
    } else {
      _pacing.begin();
      _startStraightTimer();
    }
    _logMsg('实时导航已开始：GPS 跟踪中（转向/偏航/到达自动播报）。');
  }

  void _onLiveNavFix(LocationResult r) {
    if (!mounted || _liveNav == null) return;
    if (!r.ok) {
      final DateTime now = DateTime.now();
      if (_lastGpsErrorAt == null ||
          now.difference(_lastGpsErrorAt!) > const Duration(seconds: 60)) {
        _lastGpsErrorAt = now;
        _say(_request(
          id: 'gps-lost-$now',
          eventId: 'gps-lost',
          text: '定位信号中断，暂时无法更新你的位置。',
          kind: SpeechKind.info,
        ));
      }
      return;
    }
    _lastFixPoint = r.pointGcj02;
    _lastFixAccuracyM = r.accuracyM;
    if (_entranceActive && _entrance != null) {
      // Step D: the tracker has handed over; fixes now feed
      // the entrance guidance, not route following.
      _handleEntranceFix(r);
      return;
    }
    final List<NavEvent> events = _liveNav!.onFix(NavFix(
      point: r.pointGcj02!,
      accuracyM: r.accuracyM,
      at: DateTime.now(),
    ));
    setState(() {
      _liveNavRemainingM = _liveNav!.remainingM;
    });
    for (final NavEvent e in events) {
      _handleNavEvent(e);
    }
    if (_pacing.isPaused && !_rerouting) {
      // A re-planned route whose first segment was not
      // straight stays suspended; a later fix may reach a
      // straight segment, judged by the NEW tracker only.
      // (isPaused, not the reported state: a risk hold that
      // landed during the re-plan keeps BOTH reasons set, and
      // this re-check must still run so each reason is judged
      // against the new tracker.)
      _recheckStraightResume();
    }
  }

  /// One GPS fix during the entrance-guidance phase (step
  /// D). Trusted fixes feed the guidance: a returned text is
  /// a distance/bearing update (turn priority -- it IS the
  /// route guidance now) or, at the arrival radius, the
  /// completion line (alert), which ends the trip exactly
  /// like the old tracker arrival did, only later. Untrusted
  /// fixes produce no numbers: at most one throttled "paused"
  /// notice per minute, mirroring the tracker's weak-signal
  /// cooldown, so the phase never fails silently.
  void _handleEntranceFix(LocationResult r) {
    final EntranceGuidance g = _entrance!;
    final DateTime now = DateTime.now();
    final String? text = g.onFix(
      r.pointGcj02!,
      r.accuracyM,
      now,
      headingDeg: _currentHeadingDeg(),
    );
    setState(() {
      // The status line reads g.lastDistanceM.
    });
    if (text == null) {
      if (r.accuracyM == null ||
          r.accuracyM! > EntranceGuidance.maxTrustedAccuracyM) {
        if (_lastEntranceWeakAt == null ||
            now.difference(_lastEntranceWeakAt!) >=
                const Duration(seconds: 60)) {
          _lastEntranceWeakAt = now;
          _say(_request(
            id: 'entrance-weak-$now',
            eventId: 'entrance-weak',
            text: 'GPS 信号较差，入口指引暂停，信号恢复后继续。',
            kind: SpeechKind.info,
          ));
        }
      }
      return;
    }
    final bool done = g.completed;
    _say(_request(
      id: 'entrance-${done ? 'arrived' : 'guide'}-$now',
      eventId: done ? 'entrance-arrived' : 'entrance-guide-$now',
      text: text,
      kind: done ? SpeechKind.alert : SpeechKind.turn,
      // Entrance distance announcements are distance-class:
      // if a hazard interrupts one, the replay recomputes it
      // from the latest fix instead of repeating stale text.
      replay: done ? NavReplay.drop : NavReplay.regenerate,
    ));
    if (done) _finishEntranceTrip();
  }

  /// The phone's current compass heading, or null when it
  /// is stale (over 500 ms) or the platform has no heading
  /// source -- entrance guidance then announces the
  /// distance alone, never a direction from old data.
  double? _currentHeadingDeg() => _orientation.currentHeadingDeg;

  /// The entrance phase's trip end: identical to the old
  /// tracker-arrival ending (session ends, task completes,
  /// next-destination question) -- only the moment moved,
  /// from the 60 m hand-over to the 15 m arrival radius.
  void _finishEntranceTrip() {
    _endLiveNavigation();
    if (_tasks.state == TaskState.navigating) {
      _tasks.transitionTo(TaskState.completed, trigger: 'entrance-arrived');
      _tasks.reset();
    }
    _askDestination(prompt: '还要去别的地方吗？');
  }

  void _handleNavEvent(NavEvent e) {
    final String ts = '${DateTime.now().millisecondsSinceEpoch}';
    switch (e.kind) {
      case NavEventKind.turnAhead:
        _say(_request(
          id: 'nav-turn-$ts',
          eventId: 'nav-turn-$ts',
          text: e.text,
          kind: SpeechKind.turn,
          // NAVHAZ M1: an interrupted turn is regenerated
          // from the latest fix, never replayed verbatim.
          navStepIndex: e.stepIndex,
          replay: NavReplay.regenerate,
        ));
      case NavEventKind.weakSignal:
        _say(_request(
          id: 'nav-weak-$ts',
          eventId: 'nav-weak-$ts',
          text: e.text,
          kind: SpeechKind.info,
        ));
      case NavEventKind.arrived:
        // Step D hand-over: the route is done but the trip is
        // NOT. Route-following speech stops (pacing halts);
        // the GPS subscription and the live session stay
        // alive and fixes now feed the entrance guidance,
        // which announces distance + bearing to the
        // destination point until its own arrival radius.
        // The tracker's event text is a neutral hand-over
        // marker and is deliberately NOT spoken -- the
        // guidance phase's own first announcement replaces it.
        _pacing.stop();
        _stopStraightTimer();
        _entrance = EntranceGuidance(
          destinationName: _liveNavDestName,
          destination: _liveNav!.destination,
        );
        _entranceActive = true;
        final GeoPoint? handOverFix = _lastFixPoint;
        final String? firstText = handOverFix == null
            ? null
            : _entrance!.onFix(
                handOverFix,
                _lastFixAccuracyM,
                DateTime.now(),
                headingDeg: _currentHeadingDeg(),
              );
        final bool doneNow = _entrance!.completed;
        _say(_request(
          id: 'entrance-${doneNow ? 'arrived' : 'start'}-$ts',
          eventId: doneNow ? 'entrance-arrived' : 'entrance-start',
          text: firstText ?? _entrance!.startAnnouncement(),
          kind: doneNow ? SpeechKind.alert : SpeechKind.turn,
        ));
        if (doneNow) _finishEntranceTrip();
      case NavEventKind.offRoute:
        final RerouteDecision decision =
            _liveNav!.rerouteDecision(DateTime.now());
        if (decision == RerouteDecision.doIt) {
          _say(_request(
            id: 'nav-offroute-$ts',
            eventId: 'nav-offroute-$ts',
            text: '你已偏离路线，正在重新规划。',
            kind: SpeechKind.info,
            replay: NavReplay.shortenedReplay,
          ));
          unawaited(_rerouteLiveNavigation());
        } else if (decision == RerouteDecision.exhausted) {
          _say(_request(
            id: 'nav-offroute-max-$ts',
            eventId: 'nav-offroute-max',
            text: '你已偏离路线。已经多次重新规划仍未回到路线，'
                '先停下来确认位置，再说“去$_liveNavDestName”重新开始。',
            kind: SpeechKind.alert,
          ));
        } else {
          // Throttled: re-arm the tracker so a later
          // off-route event can retry once the interval has
          // passed (the trip budget still bounds retries).
          _liveNav?.resetOffRouteStreak();
          _say(_request(
            id: 'nav-offroute-wait-$ts',
            eventId: 'nav-offroute-wait-$ts',
            text: '你已偏离路线。',
            kind: SpeechKind.info,
            replay: NavReplay.shortenedReplay,
          ));
        }
    }
  }

  /// Re-plan from the current position after an off-route
  /// event (already throttled by the tracker). Failure keeps
  /// BOTH the suspension and the in-flight flag: the old
  /// tracker stays installed as position source but is never
  /// read for straight confirmation, and a later off-route
  /// event retries the re-plan under the trip budget.
  Future<void> _rerouteLiveNavigation() async {
    // Suspend straight guidance for the whole re-plan. The
    // old tracker stays installed ONLY as the failure
    // fallback; while _rerouting is set it is not read for
    // straight confirmation, and the tick cannot fire.
    _rerouting = true;
    _pacing.suspendForReroute();
    _stopStraightTimer();
    final RealNavigationStarter starter = RealNavigationStarter(
      locationProvider: _locationProvider,
      client: _amapClient,
    );
    final RealNavigationOutcome outcome = await starter.start(_liveNavDestName);
    if (!mounted || _liveNav == null) return;
    if (!outcome.ready) {
      // Re-arm the RETRY only: the user is still off route,
      // and a later off-route event must be able to retry the
      // re-plan (subject to the trip budget) instead of the
      // failure ending all retries.
      _liveNav?.resetOffRouteStreak();
      // Codex re-test of 926901c: on failure the suspension
      // and the in-flight flag BOTH stay set. The old tracker
      // must never release straight guidance for a route the
      // user has already left: no re-check runs here, straight
      // pacing stays paused, and only a successful re-plan
      // (installing a NEW tracker) can release it.
      if (!_rerouteFailureAnnounced) {
        _rerouteFailureAnnounced = true;
        _say(_request(
          id: 'nav-reroute-failed',
          eventId: 'nav-reroute-failed',
          text: '路线重新规划失败，请停下稍候，正在重试。',
          kind: SpeechKind.alert,
        ));
      }
      return;
    }
    _beginLiveNavigation(outcome, _liveNavDestName);
    final String? first = _amapSpeaker?.nextStepText();
    _say(_request(
      id: 'nav-rerouted',
      eventId: 'nav-rerouted',
      text: '已重新规划路线。${first == null ? '' : '第一段：$first'}',
      kind: SpeechKind.info,
    ));
  }

  /// Stop GPS tracking and clear the live session. Called on
  /// arrival, on 停下, on task end and on emergency: the
  /// microphone/speech stop alone must not leave a phantom
  /// navigation running.
  void _endLiveNavigation() {
    _gpsSub?.cancel();
    _gpsSub = null;
    _liveNav = null;
    _liveNavRemainingM = null;
    _entrance = null;
    _entranceActive = false;
    _pacing.stop();
    _rerouting = false;
    _stopStraightTimer();
  }

  /// The single announcement site for startup failures: every
  /// module whose construction / initialisation threw (camera,
  /// config, Amap, location, TTS, ASR, YOLO -- plus anything the
  /// zone backstop caught) is named here, by voice when speech
  /// works, otherwise in the log (the status surfaces already
  /// show the degradation; nothing is claimed to be spoken
  /// when speech itself is down).
  void _announceStartupFailures({required bool speechUsable}) {
    if (!startupFailures.hasFailures) return;
    final String failureText =
        startupFailureAnnouncement(startupFailures.modules);
    _logMsg(failureText);
    if (speechUsable) {
      _say(_request(
        id: 'startup-failures',
        eventId: 'startup-failures',
        text: failureText,
        kind: SpeechKind.alert,
      ));
    }
  }

  /// Test-marker channel (harness -> app -> adapter):
  /// widget tests send 'noteTestMarker' here to drive
  /// the missed-restart replay scenario; production
  /// platform code never uses this channel. Forwarded to
  /// the adapter's test inbox; the epoch check in
  /// [_ensureEngineSubscription] drains it.
  static const MethodChannel _testMarkerChannel =
      MethodChannel('dev.mingtu.test/markers');
  bool _testMarkerHandlerArmed = false;

  /// Test-only: drop the live engine-events subscription
  /// (the missed-watchdog-restart replay scenario). The
  /// flag it sets also tells the wiring pass below not to
  /// re-create it: the scenario's whole point is a window
  /// in which NO engine listener is live on this page.
  bool _debugEngineSubDropped = false;

  void _armTestMarkerChannel() {
    if (_testMarkerHandlerArmed) return;
    _testMarkerHandlerArmed = true;
    _testMarkerChannel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'noteTestMarker' && call.arguments is String) {
        final VoiceInput input = _voiceInput;
        if (input is SystemVoiceInput) {
          input.debugNoteTestMarker(call.arguments as String);
        }
      }
      return null;
    });
  }

  /// Test-only counterpart of the marker channel: drop
  /// the engine-events subscription for the replay
  /// scenario (see [_debugEngineSubDropped]).
  void _debugDropEngineSubscription() {
    _debugEngineSubDropped = true;
    _asrEngineSub?.cancel();
    _asrEngineSub = null;
    _subscribedEngineEvents = null;
  }

  Future<bool> _initStartupModules() async {
    _armTestMarkerChannel();
    // Every module is initialised behind its own guard by the
    // production initializer (adapters/startup_initializer.dart):
    // camera, configuration, Amap, location/permission, TTS,
    // ASR, YOLO. It never throws; failures land in
    // startupFailures and are announced by _initRealIntegrations.
    final StartupInitResult init = await initializeStartup(
      frameSourceFactory: () => RoutedCameraFrameSource(
        yoloLiveActive: () => _yoloLiveOpen,
        yoloSource: createYoloFrameSource(),
        singleShotSource: createCameraFrameSource(),
        ownership: _cameraOwnership,
      ),
      log: startupFailures,
    );
    _frameSource = init.frameSource;
    _amapClient = init.amapClient;
    _locationProvider = init.locationProvider;
    _yoloDetector = init.yolo;
    _yoloAvailableAtStartup = init.yolo.isAvailable;
    final SystemVoiceOutput? tts = init.tts;
    final bool ttsOk = init.ttsOk;
    final SystemVoiceInput? asr = init.asr;
    final bool asrOk = init.asrOk;
    if (!mounted) return false;
    if (!asrOk || asr == null || !asr.isAvailable) {
      // MT-1111-PTT-D(5): the engine is unavailable AT
      // STARTUP -- the very first press goes straight to
      // the recording + cloud ASR fallback instead of
      // discovering the failure on press one.
      _localAsrBroken = true;
    }
    if (asrOk && asr != null) {
      _voiceInput = asr;
      _subscribedVoiceInput = asr;
      _asrSubCancels.add(() => _transcriptSub?.cancel());
      _transcriptSub = asr.transcripts.listen((AsrResultEvent event) {
        if (!mounted) return;
        if (_asrConfirmingClose) {
          // A result of the session whose close is being
          // confirmed: it belongs to that closing session
          // and is never cached or executed for a new one.
          return;
        }
        if (event.sessionId != _asrSessionId) {
          // A late final from an older session: dropped,
          // never executed, never cached.
          return;
        }
        if (_pttSessionVoided) {
          // A too-short press voided its session: nothing
          // from it is ever cached or executed.
          return;
        }
        final String text = event.text;
        // MT-1111-PTT-4B: a result ARRIVING here is only
        // cached / routed below; it does NOT clear the
        // error streak. Clearing happens when a result is
        // SUBMITTED at the press completion point.
        if (_pttState == _PttState.listening) {
          // Cache only: while the button is held nothing is
          // executed. The release path submits the cached
          // text exactly once.
          _pttCachedText = text;
          _pttCachedIsFinal = true;
          return;
        }
        if (_pttState == _PttState.stopping) {
          // A final of THIS press's session, anywhere in
          // the stopping window -- while stop() is still in
          // flight or inside the grace that follows: it is
          // accepted and wins over any cached partial.
          _onPttFinalInStopping(text);
          return;
        }
        if (_pttState != _PttState.idle) {
          // A transcript in prompting/starting cannot belong
          // to this press (its session has not opened): it is
          // a stale callback from an earlier session and is
          // dropped, never executed.
          return;
        }
        // While the destination question is open, an utterance
        // that is not a known command IS the answer. A real
        // command (停下 / 求助 / 去图书馆 ...) supersedes the
        // question and takes the normal path.
        if (_awaitingDestination) {
          if (parseVoiceCommand(text) == VoiceCommand.unknown) {
            _answerDestination(text);
            return;
          }
          _awaitingDestination = false;
        }
        _handleVoiceCommand(text);
      });
      _asrSubCancels.add(() => _partialSub?.cancel());
      _partialSub = asr.partials.listen((AsrResultEvent event) {
        if (!mounted) return;
        if (_asrConfirmingClose) return;
        if (event.sessionId != _asrSessionId) return;
        if (_pttSessionVoided) return;
        // Partials only refresh the fallback cache below:
        // a partial is never submitted by itself, so it
        // never clears the error streak (MT-1111-PTT-4B).
        // Partials are only ever the push-to-talk fallback
        // cache; automatic sessions never act on them.
        if (_pttState == _PttState.listening) {
          // A partial refreshes the fallback cache, but a
          // final already cached for this press outranks
          // any later partial.
          if (!_pttCachedIsFinal) _pttCachedText = event.text;
        } else if (_pttState == _PttState.stopping && !_pttCachedIsFinal) {
          _pttCachedText = event.text;
        }
      });
      // ASR runtime errors surface through the adapter's error
      // stream (previously they only rewrote an unwatched status
      // string and the listen loop retried into the failure).
      _asrSubCancels.add(() => _asrSessionSub?.cancel());
      _asrSessionSub = asr.sessionEnded.listen((AsrStatusEvent event) {
        if (!mounted) return;
        if (_asrConfirmingClose) {
          // This end belongs to the session whose close
          // the press path is confirming: it is consumed
          // as that close, never as a live session end.
          return;
        }
        // A status event from an older session must not
        // drive the current session's bookkeeping.
        if (event.sessionId != _asrSessionId) return;
        // Press-and-hold only: a platform status event NEVER
        // starts a session -- there is no automatic listening
        // anymore, in any state. The handler is bookkeeping
        // only (it logs the fixed line).
        _onAsrSessionEnded();
      });
      _asrSubCancels.add(() => _asrNoMatchSub?.cancel());
      _asrNoMatchSub = asr.sessionNoMatch.listen((String code) {
        if (!mounted) return;
        if (_asrConfirmingClose) return;
        _onAsrSessionNoMatch(code);
      });
      _asrSubCancels.add(() => _asrEngineSub?.cancel());
      _subscribedEngineEvents = asr.engineEvents;
      _asrEngineSub = _debugEngineSubDropped
          ? null
          : asr.engineEvents.listen((String event) {
              if (!mounted) return;
              if (event == 'restarted') {
                // The recognition engine was force-restarted by
                // the adapter watchdog: handled by the shared
                // restart path (also used when a restart is
                // detected via its epoch bump after the fact).
                _onEngineRestarted();
              } else if (event == 'restart_failed') {
                _onEngineRestartFailed();
              }
            });
      _asrSubCancels.add(() => _asrErrorSub?.cancel());
      _asrErrorSub = asr.errors.listen((String error) {
        if (!mounted) return;
        if (_asrConfirmingClose) {
          // Belongs to the closing session (see the
          // sessionEnded guard above).
          return;
        }
        // The error stream's session tag is the adapter's
        // CURRENT session id at error time. An error from
        // a session that has already been superseded --
        // including one still closing when its successor
        // started -- must not poison the successor: only
        // an error stamped with the LIVE session's id, or
        // arriving while that session's close is in
        // flight, is acted on. The adapter already drops
        // errors from closed generations where it can;
        // this is the app-side second line.
        final int stamp = asr.currentSessionId;
        if (stamp != _asrLiveSessionId && !_asrCloseInFlight) {
          mingtuVoiceLog(
              '已作废会话的识别错误按关闭处理：${error.split('|').first}');
          return;
        }
        _handleAsrError(error);
      });
    }
    // P0 startup plan (pure logic in core/voice_startup.dart): the
    // greeting is spoken whenever *Chinese* speech is verified
    // usable -- including when ASR failed, which previously left
    // the user in total silence because the greeting only ran
    // `if (asrOk)`. An engine that answers but has no zh-CN voice
    // is NOT adopted as the voice output: speaking Chinese text in
    // a non-Chinese voice would be a false "voice works" signal.
    final StartupVoicePlan plan = planStartupVoice(
      ttsEngineOk: ttsOk,
      chineseVoiceVerified: ttsOk && (tts?.chineseVoiceVerified ?? false),
      asrOk: asrOk,
    );
    if (plan.speechUsable && tts != null) _voiceOutput = tts;
    _health.report(
      'voice_output',
      plan.speechUsable ? ServiceHealthStatus.ok : ServiceHealthStatus.degraded,
      '${tts?.status ?? '语音合成初始化失败'}｜${plan.summary}',
    );
    _health.report(
      'voice_input',
      asrOk ? ServiceHealthStatus.ok : ServiceHealthStatus.degraded,
      asr?.status ?? '语音识别初始化失败',
    );
    setState(() {
      _voiceText =
          '语音：TTS：${tts?.status ?? '语音合成初始化失败'}；ASR：${asr?.status ?? '语音识别初始化失败'}。${plan.summary}';
      _yoloText = 'YOLO：${_yoloDetector.status}';
      if (!plan.speechUsable) {
        _currentPrompt = voiceNoticeText(VoiceNoticeKind.ttsUnavailable);
        mingtuVoiceLog('启动播报不可用：已振动提示，屏幕显示引擎检查引导');
      }
    });
    if (plan.speechUsable) {
      if (!asrOk) {
        // ASR failed at startup while TTS works (Codex
        // re-test of f951240): the greeting below already
        // CARRIES the failure (plan.spokenText is the ASR-down
        // greeting), and it is paired with a vibration -- the
        // same cue the runtime ASR-error path uses -- so the
        // user feels the state as well as hears it.
        HapticFeedback.vibrate();
        _logMsg('语音识别启动失败：已振动提示，问候语中将播报识别不可用。');
      }
      // Press-and-hold only (real-device fix round): the
      // greeting is spoken and NOTHING opens the microphone
      // at startup or after any speech -- the microphone opens
      // only while the user holds the button. (The plan's
      // startAutoListen flag is retained as data; the app no
      // longer acts on it.) When ASR is down the greeting
      // itself carries the failure and the next step.
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
    return plan.speechUsable;
  }

  /// An ASR error event from the adapter: announce it ONCE through
  /// the still-working voice (or the status surface when voice is
  /// already failed), report it, and switch the turn-taking loop
  /// OFF so nothing retries listening into a dead recogniser.
  /// An ASR error event from the adapter. Deduplicated BY
  /// ERROR CODE: the same code is announced once until a
  /// recognition session succeeds (which resets
  /// [_asrErrorSpokenCodes]); a later session may announce
  /// the same code again. NOTHING here disables future
  /// presses: error_busy / error_client / error_speech_timeout
  /// / error_no_match never set any stop flag (the benign two
  /// do not even reach this handler -- they are session
  /// outcomes on the adapter's no-match stream). A permission
  /// error additionally marks the local recogniser broken,
  /// so subsequent presses use the recording fallback.
  void _handleAsrError(String error) {
    // The stream carries '<code>|permanent=<bool>' with the
    // code already whitelisted by the adapter; every surface
    // below uses the code's FIXED Chinese text, never a raw
    // platform string.
    final String code = error.split('|').first;
    final bool isPermission =
        code == 'error_permission' || code == 'error_insufficient_permissions';
    final bool isEngineUnavailable = code == 'not_available';
    // MT-1111-ALIGN routing (unified final wording): ONLY
    // no-engine (not_available) and permission-refused go
    // straight to the cloud fallback -- the fatal set.
    // error_server and the two language codes are
    // RECOVERABLE: they never mark the recogniser broken
    // on a first occurrence; they arm the recovery for the
    // next press (cancel -> re-initialize -> listen) and
    // count toward the one open streak; only the second
    // TRULY consecutive occurrence of the same code
    // escalates to the fallback.
    if (isRecoverableAsrError(code)) {
      _noteRecoverableAsrError(code);
    }
    if (isPermission || isEngineUnavailable || isFatalAsrError(code)) {
      // The engine cannot record (its own permission is
      // missing, or the service is absent): later presses
      // record with the app's own permission instead. This
      // is ROUTING only -- the error is still announced
      // (deduped) and no press is ever disabled.
      _localAsrBroken = true;
    }
    final String fixedText =
        isPermission ? asrPermissionSpeechText : asrErrorText(code);
    mingtuVoiceLog('语音识别运行出错（$code）：$fixedText');
    if (!_asrErrorSpokenCodes.add(code)) {
      // Same code already announced in this stretch: stay
      // silent (the real-device bug was this notice three
      // times in a row), but the press machinery is
      // untouched -- the next press still retries.
      _logMsg('语音识别运行中出错（$fixedText）：同一错误已播报过，本次不再重复播报。');
      return;
    }
    HapticFeedback.vibrate();
    _health.report(
      'voice_input',
      ServiceHealthStatus.degraded,
      '语音识别运行中出错：$fixedText',
    );
    _logMsg('语音识别运行中出错（$fixedText）：下次按住仍会重新尝试。');
    if (_voiceOutput.isAvailable && !_ttsFailed) {
      _say(_request(
        id: 'asr-error-${DateTime.now().millisecondsSinceEpoch}',
        eventId: 'asr-error-${DateTime.now().millisecondsSinceEpoch}',
        text: isPermission
            ? asrPermissionSpeechText
            : voiceNoticeText(VoiceNoticeKind.asrUnavailable),
        kind: SpeechKind.alert,
      ));
    } else {
      setState(() {
        _voiceText = '语音识别运行中出错：$fixedText。';
      });
    }
  }

  /// A benign session outcome (error_no_match /
  /// error_speech_timeout) for a session this app stopped:
  /// the press settling in its stopping window completes
  /// NOW, with its cached partial when it has one, else
  /// with the no-content notice -- settle-by-order: the
  /// error event never submits anything itself; it only
  /// tells the press's completion point that the session
  /// is settled, and the completion settles with the cache.
  /// When the press is still HELD, nothing happens here:
  /// the release settles with the cache exactly the same
  /// way. Outcomes outside a press are bookkeeping only.
  void _onAsrSessionNoMatch(String code) {
    mingtuVoiceLog('识别会话以无匹配结束（$code）：按缓存结算，不自动重听');
    // MT-1111-PTT-2: the benign codes (no_match /
    // speech_timeout) are RECOVERABLE codes too -- they
    // never reach _handleAsrError (they settle the session
    // on this stream instead), so their recovery arming and
    // streak are maintained HERE, with exactly the same
    // rules: first occurrence arms the next-press recovery;
    // the second TRULY consecutive occurrence of the same
    // code switches the route to the cloud recording.
    if (isRecoverableAsrError(code)) {
      _noteRecoverableAsrError(code);
    }
    if (_pttState != _PttState.stopping) return;
    if (_pttCachedText != null && !_pttCachedIsFinal) {
      _pttCompletePress(_pttSession, _pttCachedText);
    } else if (_pttCachedText == null) {
      _pttCompletePress(_pttSession, null);
    }
  }

  /// Start one short ASR session, but only after speech has finished:
  /// the turn-taking loop for a blind user. Called from
  /// [_finishSpeech] (after the welcome greeting, and after every
  /// prompt while a task is running) -- never while TTS is speaking.
  /// Retained call site from _finishSpeech: after speech
  /// finishes the microphone does NOT open (see body).
  void _maybeStartListeningAfterSpeech() {
    // Press-and-hold only (real-device fix round): speech
    // finishing NEVER opens the microphone. This used to be
    // the turn-taking loop's entry; it is kept as a no-op
    // because _finishSpeech still calls it, and the call now
    // documents that the decision was taken deliberately.
    return;
  }

  /// A recognition session ended (silence or a final result
  /// that produced no speech): reopen the microphone so voice
  /// control is continuous. Skipped while speech is playing
  /// or queued (that path restarts via _finishSpeech) and
  /// when the loop was deliberately switched off.
  /// A recognition session ended on its own. Bookkeeping
  /// only -- see the body.
  void _onAsrSessionEnded() {
    // Press-and-hold only (real-device fix round): a session
    // end is logged and NEVER re-listens. The old
    // notListening-triggered relisten collided with the
    // Xiaomi engine's late result (already-in-session /
    // capacity full -> error_client -> error_busy) and the
    // result was discarded.
    mingtuVoiceLog('识别会话结束（仅按住说话模式，不自动重听）');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // MT-1111-PTT-D(4): dispose releases the microphone. A
    // press still capturing is cancelled (voided, never
    // submitted); the recorder is cancelled likewise. The
    // adapter outlives the page by design, so this is the
    // app-side release: stop/cancel on the live session.
    if (_pttState == _PttState.listening ||
        _pttState == _PttState.starting) {
      _pttSessionVoided = true;
      if (_pttRecording) {
        _pttRecordCapTimer?.cancel();
        _pttRecordCapTimer = null;
        _pttRecording = false;
        unawaited(() async {
          try {
            await _recorder.cancel();
          } catch (_) {}
        }());
      } else {
        unawaited(_cancelListeningInternal());
      }
    }
    _closeYoloLiveView();
    _visionRuns.cancelActive();
    _cameraOwnership.cancelAllAndRelease();
    _straightTimer?.cancel();
    _hazardScanTimer?.cancel();
    _orientation.dispose();
    _pitchMonitor.dispose();
    _transcriptSub?.cancel();
    _partialSub?.cancel();
    _pttNoContentTimer?.cancel();
    _asrErrorSub?.cancel();
    _asrNoMatchSub?.cancel();
    _asrSessionSub?.cancel();
    _asrEngineSub?.cancel();
    for (final void Function() cancelSub in _asrSubCancels) {
      cancelSub();
    }
    _asrSubCancels = <void Function()>[];
    _subscribedEngineEvents = null;
    // The input object outlives this State (it is never
    // disposed here): mark it disposed so a pending
    // engine watchdog cannot restart the recogniser --
    // or leak its timers -- past this page's lifetime.
    if (_voiceInput is SystemVoiceInput) {
      (_voiceInput as SystemVoiceInput).engineDisposed = true;
    }
    _gpsSub?.cancel();
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
    bool neverExpires = false,
    int? navStepIndex,
    NavReplay? replay,
  }) {
    final DateTime now = DateTime.now();
    // Critical delivery: emergencies, danger prompts and alerts
    // (safety/failure announcements) NEVER expire -- a dropped
    // safety message is worse than a late one. Ordinary prompts
    // keep their short expiry: a stale "直走" must not be
    // spoken late.
    final bool critical = neverExpires ||
        kind == SpeechKind.emergency ||
        kind == SpeechKind.danger ||
        kind == SpeechKind.obstacleAvoidance ||
        kind == SpeechKind.alert;
    return SpeechRequest(
      id: id,
      eventId: eventId,
      text: text,
      kind: kind,
      createdAt: now,
      expiresAt: now.add(Duration(seconds: expiresSeconds)),
      navigationStateVersion: _navVersion,
      requiresStraightSegment: requiresStraight,
      neverExpires: critical,
      navStepIndex: navStepIndex,
      // NAVHAZ M1 arbitration defaults (spec section 2.6):
      // straight prompts replay shortened after an
      // interruption; turn / distance prompts opt into
      // regeneration explicitly at their call sites;
      // everything else is never replayed.
      replay: replay ??
          (kind == SpeechKind.straight
              ? NavReplay.shortenedReplay
              : NavReplay.drop),
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
        payload: <String, Object?>{
          'text': request.text,
          'kind': request.kind.name
        },
      ),
      now,
    );
  }

  /// A copy of [r] with a different [text] (banned-word
  /// substitution keeps every other field identical).
  SpeechRequest _withText(SpeechRequest r, String text) {
    return SpeechRequest(
      id: r.id,
      eventId: r.eventId,
      text: text,
      kind: r.kind,
      createdAt: r.createdAt,
      expiresAt: r.expiresAt,
      navigationStateVersion: r.navigationStateVersion,
      requiresStraightSegment: r.requiresStraightSegment,
      neverExpires: r.neverExpires,
      navStepIndex: r.navStepIndex,
      replay: r.replay,
    );
  }

  bool _say(SpeechRequest request) {
    // NAVHAZ M1 banned-word guard (spec sections 0.1 /
    // 2.4): NO announcement may grant or imply passage. In
    // debug builds the assert fires; in release builds the
    // text is replaced by the fixed fallback sentence and
    // the substitution is logged (the offending text itself
    // is never logged or spoken).
    if (containsBannedWord(request.text)) {
      assertNoBannedWords(request.text);
      _logMsg('一条播报含禁词，已改写为固定兜底句，未播报原文。');
      request = _withText(request, bannedWordFallbackPhrase);
    }
    final DateTime now = DateTime.now();
    if (request.kind == SpeechKind.danger) {
      // A danger prompt pauses straight guidance (the pacing
      // machine's persistent hold + the scheduler's straight
      // clock) and interrupts whatever it outranks via the
      // scheduler's priority rule. The PHYSICAL stop is not
      // decided here: the sequenced speak path stops the
      // current utterance unconditionally before a danger or
      // emergency prompt speaks (Codex re-test of d01a081).
      _pauseStraightForRisk();
    }
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

  /// NAVHAZ M1 arbitration (spec section 2.6): build the
  /// replay for the oldest still-replayable interrupted
  /// navigation prompt, or null. Each interrupted item is
  /// discarded exactly once here -- replayed, expired into
  /// droppedExpiredLog (15 s window from the interruption),
  /// or dropped because its moment has passed (the
  /// intersection is behind the user / too close): an old
  /// navigation text is never spoken late.
  SpeechRequest? _buildInterruptedReplay() {
    final DateTime now = DateTime.now();
    for (final SpeechRequest r
        in _scheduler.interruptedNavigationRequests()) {
      final DateTime? at = _scheduler.interruptedAtOf(r);
      if (at != null && now.difference(at) > NavHazConfig.replayExpiry) {
        _scheduler.discardInterrupted(r);
        _scheduler.droppedExpiredLog.add(r.id);
        continue;
      }
      final String? text = switch (r.replay) {
        NavReplay.regenerate => _regenerateNavText(r),
        NavReplay.shortenedReplay => _shortenedNavText(r),
        NavReplay.drop => null,
      };
      _scheduler.discardInterrupted(r);
      if (text == null) continue;
      return _request(
        id: 'nav-replay-${now.millisecondsSinceEpoch}',
        eventId: 'nav-replay-${r.eventId}',
        text: text,
        kind: r.kind,
        requiresStraight: r.kind == SpeechKind.straight,
        navStepIndex: r.navStepIndex,
        // A replay is never itself replayed: if a hazard
        // interrupts IT, the moment is gone.
        replay: NavReplay.drop,
      );
    }
    return null;
  }

  /// Regenerated text for an interrupted turn / distance
  /// prompt, recomputed from the latest GPS fix. Null when
  /// the moment has passed (see NavigationTracker).
  String? _regenerateNavText(SpeechRequest r) {
    final int? step = r.navStepIndex;
    if (step != null) {
      final NavigationTracker? nav = _liveNav;
      final GeoPoint? fix = _lastFixPoint;
      if (nav == null || fix == null) return null;
      return nav.regenerateTurnPrompt(
        step,
        NavFix(point: fix, accuracyM: _lastFixAccuracyM, at: DateTime.now()),
      );
    }
    // Entrance distance prompt: the guidance recomputes
    // from the latest fix (its own throttles apply, so a
    // replay usually -- and correctly -- yields nothing).
    if (_entranceActive && _entrance != null && _lastFixPoint != null) {
      return _entrance!.onFix(
        _lastFixPoint!,
        _lastFixAccuracyM,
        DateTime.now(),
        headingDeg: _currentHeadingDeg(),
      );
    }
    return null;
  }

  /// Shortened replay text, by the interrupted prompt's
  /// semantics: straight prompts resume as 「继续直走」,
  /// off-route prompts as 「已偏离路线」. Anything else has
  /// no honest shortened form and is dropped.
  String? _shortenedNavText(SpeechRequest r) {
    if (r.kind == SpeechKind.straight) return '继续直走';
    if (r.eventId.startsWith('nav-offroute')) return '已偏离路线';
    return null;
  }

  /// Shared completion step: mark the active prompt spoken, then
  /// promote the next queued prompt if it is still valid -- and speak
  /// it too, through the same real-or-simulated path.
  void _finishSpeech(String id) {
    if (_scheduler.active?.id == id) {
      final SpeechRequest finished = _scheduler.active!;
      _scheduler.completeActive();
      // NAVHAZ M1 arbitration: after a hazard prompt
      // (danger / obstacleAvoidance) finishes and no other
      // urgent prompt is pending, an interrupted navigation
      // prompt is replayed per its policy (see
      // _buildInterruptedReplay). If the replay becomes the
      // active prompt, promoteNext below finds the seat
      // taken and correctly does nothing.
      if ((finished.kind == SpeechKind.danger ||
              finished.kind == SpeechKind.obstacleAvoidance) &&
          !_dangerPending) {
        final SpeechRequest? replay = _buildInterruptedReplay();
        if (replay != null) _say(replay);
      }
      final SpeechRequest? next = _scheduler.promoteNext(
        DateTime.now(),
        straightSegmentConfirmed: _straightSegmentConfirmedNow,
        riskActive: _riskActive,
      );
      // Resume re-check, anchored to the DANGER completion
      // callback (Codex re-test of d01a081): straight timing
      // restarts only after a danger/emergency prompt has
      // actually finished AND no other urgent prompt is now
      // active or queued. The previous shape promoted the
      // next prompt and then re-checked unconditionally, so
      // a routine completion could re-time straight guidance
      // while a danger was still pending.
      if ((finished.kind == SpeechKind.danger ||
              finished.kind == SpeechKind.emergency) &&
          !_dangerPending) {
        _recheckStraightResume();
      }
      if (next == null) {
        // A press deferred by the P0 prompt that just
        // finished enters prompting now (still held only);
        // otherwise the turn-taking loop may open the
        // microphone (v0.7).
        _maybeEnterPttAfterP0();
        _maybeStartListeningAfterSpeech();
        return;
      }
      setState(() {
        _currentPrompt = next.text;
        _lastSpokenText = next.text;
      });
      if (finished.kind == SpeechKind.danger ||
          finished.kind == SpeechKind.emergency) {
        _maybeEnterPttAfterP0();
      }
      _speakActive(next);
    }
  }

  /// Close the microphone BEFORE any speech starts (Codex
  /// re-test of 9f6542b): the recogniser must never hear the
  /// app's own voice. _finishSpeech reopens it afterwards via
  /// _maybeStartListeningAfterSpeech. The stop also fires the
  /// adapter's sessionEnded signal, but _onAsrSessionEnded
  /// refuses to relisten while the scheduler has an active
  /// request, so this cannot race the speech it precedes.
  /// Speak the currently active prompt. Sequenced
  /// (Codex re-test of 037f25c): the microphone stop is
  /// AWAITED before playback starts -- the old
  /// fire-and-forget stop let speech begin over a still-open
  /// microphone -- and a danger/emergency prompt first awaits
  /// an unconditional physical stop of the current utterance. Cancellation that landed during the wait is
  /// honoured: a superseded request never starts speaking.
  void _speakActive(SpeechRequest request) {
    unawaited(_speakActiveSequenced(request));
  }

  Future<void> _speakActiveSequenced(SpeechRequest request) async {
    if (request.kind == SpeechKind.danger ||
        request.kind == SpeechKind.emergency) {
      // Physical preemption, UNCONDITIONAL (Codex re-test of
      // d01a081, as corrected): a high-priority prompt first
      // stops the currently playing utterance and AWAITS the
      // stop, then speaks. No active-flag test decides this:
      // the old design inspected scheduler state that the
      // straight pause had already mutated, so on the YOLO
      // path the stop silently never ran. The stop is bounded
      // so a hung engine cannot block the danger prompt.
      try {
        await _stopTtsPlayback().timeout(const Duration(milliseconds: 800));
      } on TimeoutException {
        _logMsg('停止当前播报 800 毫秒内未完成，继续播报高优先级提示；旧声音可能短暂残留。');
      }
      if (_scheduler.active?.id != request.id) return;
    }
    final VoiceInput input = _voiceInput;
    final SystemVoiceInput? sysInput = input is SystemVoiceInput ? input : null;
    if (sysInput != null && sysInput.isListening) {
      mingtuVoiceLog('播报开始：先暂停监听，避免听到自己的播报');
    }
    await speakAfterClosingMic(
      input: sysInput,
      speak: () async {
        if (!mounted) return;
        if (_scheduler.cancelledLog.contains(request.id)) {
          _logMsg('等待监听关闭期间已被取消的播报不再开始（${request.id}）。');
          return;
        }
        if (_scheduler.active?.id != request.id) return;
        _playActiveRequest(request);
      },
    );
  }

  /// Speak [request] through the output while tracking the
  /// playback for the push-to-talk interruption rules: the
  /// start time and (for P0 kinds) the text are recorded
  /// when playback actually begins, and a physical stop
  /// issued within the current utterance's first moments
  /// does not let that utterance's instant completion
  /// finish the request early.
  Future<void> _trackedSpeak(SpeechRequest request) async {
    _lastSpeechStartedAt = DateTime.now();
    if (request.kind == SpeechKind.danger ||
        request.kind == SpeechKind.emergency) {
      _lastP0SpokenText = request.text;
      _lastP0RequestId = request.id;
    }
    final DateTime myStart = _lastSpeechStartedAt!;
    final Future<void> playback = _voiceOutput.speak(request.text);
    final DateTime? stoppedAt = _pttStoppedUtteranceAt;
    if (stoppedAt == null || stoppedAt.isBefore(myStart)) {
      await playback;
      return;
    }
    // A stop landed inside this utterance's first moments
    // (a push-to-talk press interrupting it): the engine
    // may complete instantly for the stop, but the request
    // stays active and its completion is ignored by the
    // scheduler's cancel guard, so wait the playback out.
    try {
      await playback;
    } catch (_) {
      // Treated like a completed (interrupted) utterance;
      // the caller's cancelled-request guard discards it.
    }
  }

  /// Play the active prompt: real TTS when available,
  /// simulated timing otherwise.
  void _playActiveRequest(SpeechRequest request) {
    if (_voiceOutput.isAvailable) {
      _trackedSpeak(request).then((_) {
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
    mingtuVoiceLog('语音合成运行失败：已切换为不可用状态，停止自动聆听');
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
      // An entry cancelled while its simulated playback ran
      // (e.g. a push-to-talk press interrupting it) must not
      // complete: its finish would reopen the microphone
      // mid-press. Real playback gets the same protection
      // from the stop-race guard on the speak callbacks.
      if (_scheduler.cancelledLog.contains(id)) {
        _logMsg('已取消播报的模拟完成已忽略（$id）。');
        return;
      }
      _finishSpeech(id);
    });
  }

  /// The straight-segment confirmation that counts RIGHT
  /// NOW (Codex re-test of f951240): while a live navigation
  /// tracker exists, ONLY its current step decides -- a stale
  /// confirmation recorded by the demo flow must never bypass
  /// it. The rule itself is the production function
  /// [straightSegmentConfirmedNow] in the tracker module.
  bool get _straightSegmentConfirmedNow => straightSegmentConfirmedNow(
        liveNav: _liveNav,
        fallbackConfirmed: _straightConfirmed,
      );

  /// Enter the pacing machine's persistent hold and disarm
  /// the scheduler's straight clock. Interrupting the ACTIVE
  /// straight prompt is not done here: the scheduler's
  /// submit() priority rule does that when the danger prompt
  /// is submitted, and the physical stop happens in the
  /// sequenced speak path.
  void _pauseStraightForRisk() {
    _scheduler.pauseStraight();
    _pacing.hold(_navVersion);
  }

  /// True while a danger/emergency prompt is active or
  /// queued: straight timing must not restart before it has
  /// finished (see _finishSpeech).
  bool get _dangerPending {
    bool urgent(SpeechRequest? r) =>
        r != null &&
        (r.kind == SpeechKind.emergency || r.kind == SpeechKind.danger);
    return urgent(_scheduler.active) || _scheduler.queue.any(urgent);
  }

  /// The ONLY resume path for straight guidance. The pacing
  /// machine judges the state at THIS moment (risk, pending
  /// danger, reroute tracker readiness, current segment);
  /// see StraightPacingMachine.recheck.
  void _recheckStraightResume() {
    final bool resumed = _pacing.recheck(
      riskActive: _riskActive,
      dangerPending: _dangerPending,
      trackerReady: _liveNav != null && !_rerouting,
      currentSegmentStraight: _straightSegmentConfirmedNow,
      currentNavVersion: _navVersion,
    );
    if (!resumed) return;
    // The machine judged the resume valid on current state;
    // re-arm the scheduler's 3 s clock from NOW (no catch-up)
    // and restart the single timer. This is the ONLY place
    // either happens for a resume: no flow may call the
    // scheduler's resume or the timer directly (the demo
    // re-confirmation used to, bypassing the persistent
    // pacing state entirely).
    _scheduler.resumeStraight(
      now: DateTime.now(),
      straightSegmentConfirmed: true,
      riskActive: false,
      currentNavigationVersion: _navVersion,
      straightNavigationVersion: _navVersion,
    );
    _startStraightTimer();
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
        !_pacing.canTick ||
        !_straightSegmentConfirmedNow ||
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
    _health.report(
        'map_navigation', ServiceHealthStatus.degraded, '演示桩路线，非真实高德数据。');
    if (!_voiceOutput.isAvailable) {
      _health.report(
          'voice_output', ServiceHealthStatus.degraded, '演示文本播报，非真实系统 TTS。');
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
    final RoutePlanResult result = _routeSkill.plan('校园起点（占位）', '图书馆（占位）');
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
        '无障碍信息均为 UNKNOWN，未做无障碍确认。');
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
    // Announce the current route mode first (演示直连 / 代理 /
    // 未配置): a blind user must know which path a route would
    // come from before any attempt is made.
    _say(_request(
      id: 'route-mode-${DateTime.now().millisecondsSinceEpoch}',
      eventId: 'route-mode-${DateTime.now().millisecondsSinceEpoch}',
      text: amapRouteModeSpeech(selectAmapRouteMode(
        demoKey: AppConfig.amapDemoKey,
        proxyUrl: AppConfig.routeProxyUrl,
      )),
      kind: SpeechKind.info,
    ));
    final RealNavigationStarter starter = RealNavigationStarter(
      locationProvider: _locationProvider,
      client: _amapClient,
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
        kind: SpeechKind.alert,
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
          '${result.steps.length} 个路段。无障碍信息仍为 UNKNOWN，未按无障碍路线处理。';
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
    // Step 2: from here the navigation is LIVE -- GPS fixes
    // drive turn / off-route / arrival announcements until
    // arrival, 停下, cancel or emergency ends the session.
    // A fresh trip gets a fresh re-plan budget; re-plans
    // within the trip share it (never reset by a rebuild).
    _tripRerouteBudget = RerouteBudget();
    _beginLiveNavigation(outcome, destinationName);
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

  /// True while a P0 (danger/emergency) announcement is
  /// audibly playing. Three layers of evidence, strongest
  /// first: a P0 request is the scheduler's active entry
  /// or queued; a P0 entry was interrupted/cancelled a
  /// moment ago (its playback can outlive the entry); the
  /// most recent utterance started within the last 1.5 s
  /// and IS the most recent P0 text. Used to refuse
  /// push-to-talk presses during danger announcements.
  bool get _p0SpeechPlaying {
    if (_dangerPending) return true;
    final List<String> interrupted = _scheduler.interruptedLog;
    final List<String> cancelled = _scheduler.cancelledLog;
    bool recentP0(List<String> log) {
      for (int i = log.length - 1; i >= 0 && i >= log.length - 4; i--) {
        if (log[i] == _lastP0RequestId) return true;
      }
      return false;
    }

    if (_lastP0RequestId.isNotEmpty &&
        (recentP0(interrupted) || recentP0(cancelled))) {
      return true;
    }
    final DateTime? startedAt = _lastSpeechStartedAt;
    return startedAt != null &&
        _lastP0SpokenText.isNotEmpty &&
        _lastSpokenText == _lastP0SpokenText &&
        DateTime.now().difference(startedAt) <
            const Duration(milliseconds: 1500);
  }

  /// Push-to-talk press sequence (Step C, ordering fixed
  /// by the Codex re-test, refined per the project lead):
  ///   1. vibrate;
  ///   2. stop the AUTOMATIC listening session if one is
  ///      open, and stop any playing TTS utterance --
  ///      EXCEPT a P0 danger/emergency prompt, which a
  ///      press must never interrupt;
  ///   3. speak the short cue DIRECTLY through the voice
  ///      output and AWAIT its completion (never through
  ///      the scheduler, whose finish would reopen the
  ///      automatic loop mid-press), so the cue is never
  ///      recorded;
  ///   4. only then start the push-to-talk session.
  /// Release stops the session and the recogniser delivers
  /// its final result through the existing transcript
  /// subscription (that delivery IS the submission). A
  /// press released under 300 ms is too short: the fixed
  /// notice asks the user to hold the button. A start
  /// failure vibrates and speaks the fixed ASR-unavailable
  /// notice like every other ASR failure path.
  void _pushToTalkStart() {
    if (_pttState != _PttState.idle) return;
    mingtuPttPressDebugHook?.call(_voiceInput);
    final int sid = ++_pttSession;
    _pttState = _PttState.prompting;
    _pttPendingStop = false;
    _pttDeferredByP0 = false;
    _pttSessionVoided = false;
    _pttDeferredByClose = false;
    _pttCloseWaitAnnounced = false;
    _pttCachedText = null;
    _pttCachedIsFinal = false;
    _pushToTalkHeld = true;
    _pushToTalkPressedAt = DateTime.now();
    _autoListenWasActive = _voiceInput is SystemVoiceInput &&
        (_voiceInput as SystemVoiceInput).isListening;
    HapticFeedback.vibrate();
    if (_p0SpeechPlaying) {
      // P0 gate: during a danger/emergency announcement
      // the press only vibrates -- no cue, no ASR. It waits
      // in prompting; _finishSpeech enters the prompt step
      // when the P0 prompt completes, if still held.
      _pttDeferredByP0 = true;
      _logMsg('按住说话：危险播报进行中，先等待播报结束。');
      return;
    }
    final int pendingNow = _voiceInput is SystemVoiceInput
        ? (_voiceInput as SystemVoiceInput).pendingCloses
        : 0;
    if (pendingNow > 0) {
      // Unconfirmed-close rule: the previous recognition
      // session's stop/cancel has not been confirmed by
      // its closing outcome, so NO new session may open --
      // there is no timeout release anymore. The press
      // vibrated and speaks its one-time wait notice; it
      // waits here and enters prompting once every close
      // is confirmed, if still held. Until then no cue
      // ('请说') is spoken and no listen can start, so a
      // late result or status of the old session can
      // never be mistaken for this press's input.
      // The confirmation wait itself first drives the
      // close to completion (see _ensureAsrCloseConfirmed):
      // for a session the app itself stopped, the closing
      // outcome is delivered as part of confirming, not
      // merely awaited.
      _pttDeferredByClose = true;
      _logMsg('按住说话：等待上一个识别会话关闭确认。');
      _announcePttCloseWait();
      if (_autoListenWasActive) {
        // The closing session IS the automatic session
        // this press borrowed the microphone from: mark
        // it stopped NOW, so the wait notice's own speech
        // path cannot mistake a stopped session for a
        // live one and stop it a second time. (A second
        // stop is a no-op in the adapter precisely so
        // this stays harmless, but the stop must not be
        // issued in the first place: on the platform it
        // arms the recogniser's final-result timer for a
        // session that is already closing.)
        _autoListenWasActive = false;
      }
      unawaited(_ensureAsrCloseConfirmed().then((_) {
        if (!mounted) return;
        _maybeEnterPttAfterClose();
      }));
      return;
    }
    unawaited(_pttPromptStep(sid));
  }

  /// The previous session finished closing: a press that
  /// waited for the barrier enters prompting, if the
  /// button is still held and the press is still live
  /// (same shape as the P0 deferral hook).
  void _maybeEnterPttAfterClose() {
    if (_pttState != _PttState.prompting || !_pttDeferredByClose) return;
    _pttDeferredByClose = false;
    if (!_pushToTalkHeld) {
      _pttState = _PttState.idle;
      return;
    }
    // The close this press waited on is confirmed: the
    // press proceeds as an ordinary press into the
    // prompt step. Anything that becomes unconfirmed
    // from here on is gated where the session opens, by
    // the adapter's close barrier in startListening.
    unawaited(_pttPromptStep(_pttSession));
  }

  /// The one-time wait notice of a press blocked by an
  /// unconfirmed close. Spoken DIRECTLY through the voice
  /// output (like the '请说' cue), never through the
  /// scheduler: a scheduler finish would consult the
  /// automatic loop mid-press. The close itself guarantees
  /// the microphone is shut (or shutting) before the
  /// notice can be heard -- a notice spoken here is never
  /// recorded by the session being closed.
  void _announcePttCloseWait() {
    if (_pttCloseWaitAnnounced) return;
    _pttCloseWaitAnnounced = true;
    if (!_voiceOutput.isAvailable || _ttsFailed) return;
    setState(() {
      _currentPrompt = '请稍等';
    });
    unawaited(() async {
      try {
        await speakAfterClosingMic(
          input: _voiceInput is SystemVoiceInput
              ? _voiceInput as SystemVoiceInput
              : null,
          speak: () => _voiceOutput.speak('请稍等'),
        );
      } catch (e) {
        if (mounted) _handleTtsFailure(e);
      }
    }());
  }

  /// The engine was force-restarted while a press was
  /// live: wind the press up WITHOUT continuing it (no
  /// cue, no session -- the notice asks the user to press
  /// again). A press in stopping treats the restart as
  /// its completion point with no text.
  void _finishPttAfterEngineRestart() {
    _autoListenWasActive = false;
    if (_pttState == _PttState.idle) return;
    if (_pttState == _PttState.stopping) {
      _pttNoContentTimer?.cancel();
      _pttState = _PttState.idle;
      _setPttStoppingWindow(false);
      _pttCachedText = null;
      _pttCachedIsFinal = false;
      _pushToTalkHeld = false;
      _pttPendingStop = false;
      return;
    }
    _pttState = _PttState.idle;
    _pushToTalkHeld = false;
    _pttPendingStop = false;
    _pttDeferredByP0 = false;
    _pttDeferredByClose = false;
    _pttSessionVoided = false;
    _pttCachedText = null;
    _pttCachedIsFinal = false;
  }

  /// prompting: hand the microphone over, clear non-P0
  /// speech, speak the cue and await it. Every await is
  /// followed by a session + pendingStop re-check: a
  /// release recorded meanwhile is honoured by the
  /// sequence itself, never by state flags racing it.
  Future<void> _pttPromptStep(int sid) async {
    // A press that STARTED while a close was unconfirmed
    // never reaches this step (it waits in
    // _pushToTalkStart's wait branch). A close that
    // becomes unconfirmed DURING the prompt step (the
    // speech path stopping the automatic session for an
    // announcement, this step's own mic hand-over) does
    // not block the cue: the cue is speech, not a new
    // session. The one place a session opens --
    // _startListening below -- is gated by the adapter's
    // own unbounded close barrier, which is the
    // enforcement of the unconfirmed-close rule.
    if (_autoListenWasActive) {
      await _stopListeningInternal();
    }
    await _interruptSpeechForPushToTalk();
    if (!mounted || sid != _pttSession) return;
    if (_pttPendingStop) {
      _pttFinishTooShort(sid);
      return;
    }
    if (_p0SpeechPlaying) {
      // A P0 announcement began mid-prompt: defer the
      // same way as a press that started during one.
      _pttDeferredByP0 = true;
      _logMsg('按住说话：危险播报已开始，先等待播报结束。');
      return;
    }
    if (_voiceOutput.isAvailable && !_ttsFailed) {
      setState(() {
        _currentPrompt = '请说';
      });
      try {
        await speakAfterClosingMic(
          input: _voiceInput is SystemVoiceInput
              ? _voiceInput as SystemVoiceInput
              : null,
          speak: () => _voiceOutput.speak('请说'),
        );
      } catch (e) {
        if (mounted) _handleTtsFailure(e);
      }
    }
    if (!mounted || sid != _pttSession) return;
    if (_pttPendingStop) {
      _pttFinishTooShort(sid);
      return;
    }
    if (!_localAsrBroken && _asrRecoveryPending) {
      // MT-1111-PTT-2 recovery, run on THIS press before
      // it may listen: cancel (drop the previous session's
      // residue) -> re-initialize (a REAL platform
      // initialize via the adapter) -> listen (below). A
      // failed re-initialize switches THIS press to the
      // cloud recording instead -- with the switch notice.
      _asrRecoveryPending = false;
      bool recovered = false;
      if (_voiceInput is SystemVoiceInput) {
        // Step 1: cancel -- unconditional at the platform
        // (cancelForRecovery), because the errored session
        // is already closed on the adapter's books and a
        // session-guarded cancel would never reach the
        // recogniser's residue.
        try {
          // CDX2: the cancel wait is BOUNDED at 1 s. A
          // platform cancel that never returns must not
          // wedge the recovery (the 369439f lesson: a bound
          // claimed at the wrapper is no bound at all): on
          // timeout the cancel counts as best-effort done
          // and the sequence CONTINUES to the
          // re-initialize; if that fails, this press takes
          // the recording route below.
          await (_voiceInput as SystemVoiceInput)
              .cancelForRecovery()
              .timeout(const Duration(seconds: 1),
                  onTimeout: () {});
        } catch (e) {
          _logMsg('恢复前取消语音识别失败，继续重新初始化：$e');
        }
        if (!mounted || sid != _pttSession) return;
        if (_pttPendingStop) {
          _pttFinishTooShort(sid);
          return;
        }
        try {
          recovered = await (_voiceInput as SystemVoiceInput)
              .restartForRecovery();
        } catch (_) {
          recovered = false;
        }
      }
      if (!mounted || sid != _pttSession) return;
      if (_pttPendingStop) {
        _pttFinishTooShort(sid);
        return;
      }
      if (!recovered) {
        _localAsrBroken = true;
        await _pttStartRecording(sid, switchedToCloud: true);
        return;
      }
      // Recovered: fall through to the normal listen below.
    }
    if (_localAsrBroken) {
      // Cloud ASR fallback: the system recogniser cannot
      // serve this device (its engine lacks the microphone
      // permission), so the press records with the APP's
      // own permission instead. The recording branch never
      // touches the ASR session machinery. Audio order
      // (MT-1111-PTT-D(2)): this branch is reached only
      // AFTER _interruptSpeechForPushToTalk above has run
      // for this press, so any scheduler-active or
      // physically playing non-P0 TTS was already stopped
      // before the recorder opens -- the same pre-capture
      // stop the local-ASR path gets. (TalkBack speech is
      // system-level and the app cannot stop it; that
      // boundary is documented in the README.)
      // MT-1111-PTT-2: when THIS press is the one where the
      // escalation switched the route (the same recoverable
      // code twice in a row), the switch is announced once:
      // the announcing streak is remembered, so later
      // presses on the SAME streak announce nothing, while
      // presses that merely START on the fallback (startup
      // unavailability, a fatal code) carry no streak at
      // all and announce nothing either.
      bool switchedNow = false;
      if (_asrStreakCount >= 2 && _asrStreakCode != null) {
        if (_asrEscalationAnnouncedFor != _asrStreakCode) {
          switchedNow = true;
          _asrEscalationAnnouncedFor = _asrStreakCode;
        }
      } else {
        _asrEscalationAnnouncedFor = null;
      }
      await _pttStartRecording(sid, switchedToCloud: switchedNow);
      return;
    }
    _pttState = _PttState.starting;
    final bool started = await _startListening(pushToTalk: true);
    if (!mounted || sid != _pttSession) return;
    if (!started) {
      // The failure was already announced by _startListening
      // (vibration + fixed notice). The press is over either
      // way; a pending release adds nothing.
      _pttState = _PttState.idle;
      _pushToTalkHeld = false;
      _pttPendingStop = false;
      _restoreAutoListenAfterPushToTalk();
      return;
    }
    if (_pttPendingStop) {
      // Released during the starting window: the press was
      // necessarily too short, so the just-opened session
      // is VOIDED -- cancelled (not stopped), and marked
      // so nothing it still delivers is ever executed.
      _pttSessionVoided = true;
      _pttState = _PttState.stopping;
      await _cancelListeningInternal();
      if (!mounted || sid != _pttSession) return;
      _pttState = _PttState.idle;
      _pttPendingStop = false;
      _announcePushToTalkTooShort();
      return;
    }
    _pttState = _PttState.listening;
    if (_talkBackCapSessionId == sid) {
      // ALIGN-B cap discipline: a TalkBack press arms the
      // ONE shared cap timer only now that listening has
      // actually started. Arming at the long-press itself
      // would let the deadline run during the cue and end
      // the press before capture even began.
      _armPttRecordCapTimer(sid);
    }
  }

  /// The press ended inside prompting with nothing heard:
  /// back to idle with the too-short notice.
  void _pttFinishTooShort(int sid) {
    _pttState = _PttState.idle;
    _pttPendingStop = false;
    _announcePushToTalkTooShort();
  }

  /// Release of the push-to-talk button.
  Future<void> _pushToTalkEnd() async {
    switch (_pttState) {
      case _PttState.idle:
        return;
      case _PttState.prompting:
        if (_pttDeferredByClose) {
          _pttDeferredByClose = false;
          _pttCloseWaitAnnounced = false;
          _pttState = _PttState.idle;
          _pushToTalkHeld = false;
          return;
        }
        if (_pttDeferredByP0) {
          // A deferred press released before the P0 prompt
          // finished: cancel quietly; the finish hook must
          // not start a press nobody holds anymore.
          _pttDeferredByP0 = false;
          _pttState = _PttState.idle;
          _pushToTalkHeld = false;
          return;
        }
        // The sequence sees the flag after its current
        // await and finishes the press itself.
        _pttPendingStop = true;
        _pushToTalkHeld = false;
        return;
      case _PttState.starting:
        // listen() has not answered yet: record the stop;
        // the sequence stops the session the moment the
        // start returns.
        _pttPendingStop = true;
        _pushToTalkHeld = false;
        return;
      case _PttState.listening:
        _pushToTalkHeld = false;
        if (_pttRecording) {
          await _pttReleaseFromRecording();
        } else {
          await _pttReleaseFromListening();
        }
        return;
      case _PttState.stopping:
        return;
    }
  }

  /// Recording branch of the prompt step (cloud ASR
  /// fallback): permission first (no permission -> vibrate
  /// + the fixed recording-permission notice, press over),
  /// then start the recorder. A start failure ends the
  /// press with the fixed ASR-unavailable notice. The 10 s
  /// cap is enforced in the release path by the recorder
  /// configuration's caller contract -- main arms a 10 s
  /// timer that ends the press through the unified cap
  /// completion (the TalkBack long-press arms the same
  /// shared timer for its press; see _talkBackLongPress).
  Future<void> _pttStartRecording(int sid,
      {bool switchedToCloud = false}) async {
    _pttState = _PttState.starting;
    bool permitted = false;
    try {
      permitted = await _recorder.hasPermission();
    } catch (_) {
      permitted = false;
    }
    if (!mounted || sid != _pttSession) return;
    if (!permitted) {
      _pttState = _PttState.idle;
      _pushToTalkHeld = false;
      _pttPendingStop = false;
      HapticFeedback.vibrate();
      _logMsg('按住说话：没有麦克风权限，无法录音。');
      if (_voiceOutput.isAvailable && !_ttsFailed) {
        _say(_request(
          id: 'ptt-rec-noperm-${DateTime.now().millisecondsSinceEpoch}',
          eventId: 'ptt-rec-noperm-${DateTime.now().millisecondsSinceEpoch}',
          text: '没有麦克风权限，无法录音。请在系统设置里允许明途使用麦克风。',
          kind: SpeechKind.alert,
        ));
      }
      return;
    }
    try {
      await _recorder.start();
    } catch (_) {
      if (!mounted || sid != _pttSession) return;
      _pttState = _PttState.idle;
      _pushToTalkHeld = false;
      _pttPendingStop = false;
      _localAsrBroken = true;
      HapticFeedback.vibrate();
      if (_voiceOutput.isAvailable && !_ttsFailed) {
        _say(_request(
          id: 'ptt-rec-failed-${DateTime.now().millisecondsSinceEpoch}',
          eventId: 'ptt-rec-failed-${DateTime.now().millisecondsSinceEpoch}',
          text: voiceNoticeText(VoiceNoticeKind.asrUnavailable),
          kind: SpeechKind.alert,
        ));
      }
      return;
    }
    if (!mounted || sid != _pttSession) return;
    _pttRecording = true;
    _pttState = _PttState.listening;
    // MT-1111-PTT-2 cap, CDX2 form: EVERY recording path
    // is capped by the same timer (normal hold and
    // TalkBack alike -- TalkBack armed this very timer at
    // its long-press, bound to this session; arming here
    // re-arms the ONE timer, and the session/state guards
    // settle the press exactly once).
    _armPttRecordCapTimer(sid);
    if (switchedToCloud && _voiceOutput.isAvailable && !_ttsFailed) {
      // The switch notice: spoken once, on the switching
      // press only (see the prompt step). The recording is
      // already running; the notice is scheduler speech and
      // does not gate the capture.
      _say(_request(
        id: 'ptt-cloud-switch-${DateTime.now().millisecondsSinceEpoch}',
        eventId:
            'ptt-cloud-switch-${DateTime.now().millisecondsSinceEpoch}',
        text: asrCloudSwitchSpeechText,
        kind: SpeechKind.alert,
      ));
    }
    if (_pttPendingStop) {
      // Released while the recorder was starting: the
      // release was necessarily too short; the recording
      // release path applies the frozen too-short rule.
      _pttPendingStop = false;
      await _pttReleaseFromRecording();
    }
  }

  /// Arm the recording cap for press [sid]: when
  /// asrMaxRecordMs elapses with the press STILL recording,
  /// the press auto-completes exactly like a release
  /// (stop -> transcribe -> submit) via
  /// [_onPttRecordCapReached]. Cancelled by every other
  /// completion path (release, cancel, background, dispose).
  void _armPttRecordCapTimer(int sid) {
    _pttRecordCapTimer?.cancel();
    _pttRecordCapTimer = Timer(
      Duration(milliseconds: _recordCapMsOverride ?? asrMaxRecordMs),
      () {
        if (!mounted) return;
        unawaited(_onPttCapTimerFired(sid));
      },
    );
  }

  /// The ONE cap-timer callback, always bound to the
  /// session id the timer was armed for (CDX2): a fire for
  /// a session that is no longer current is a no-op, so a
  /// previous press's timer can NEVER end the press that
  /// followed it. A recording press takes the unified cap
  /// completion (vibration + cap notice + release path);
  /// a TalkBack listening press (no physical release
  /// exists) ends exactly like a release.
  Future<void> _onPttCapTimerFired(int sid) async {
    if (sid != _pttSession) return;
    if (_pttRecording) {
      await _onPttRecordCapReached(sid);
      return;
    }
    if (_pushToTalkHeld &&
        _pttState != _PttState.idle &&
        _pttState != _PttState.stopping) {
      await _pushToTalkEnd();
    }
  }

  /// The recording cap fired: short vibration + the fixed
  /// cap notice, then the press settles through the SAME
  /// release path a physical release uses. Guarded by the
  /// state machine (still listening, still recording, same
  /// session): a late fire after a release/cancel is a
  /// no-op, so the press can never complete twice.
  Future<void> _onPttRecordCapReached(int sid) async {
    if (sid != _pttSession ||
        _pttState != _PttState.listening ||
        !_pttRecording) {
      return;
    }
    _pushToTalkHeld = false;
    HapticFeedback.vibrate();
    if (_voiceOutput.isAvailable && !_ttsFailed) {
      _say(_request(
        id: 'ptt-rec-cap-${DateTime.now().millisecondsSinceEpoch}',
        eventId: 'ptt-rec-cap-${DateTime.now().millisecondsSinceEpoch}',
        text: asrRecordCapSpeechText,
        kind: SpeechKind.alert,
      ));
    }
    await _pttReleaseFromRecording();
  }

  /// Release of a recording press. Settles through the
  /// SAME single completion discipline as a system-ASR
  /// press (state stopping -> idle, exactly once), but
  /// never touches the ASR stopping window: the clip goes
  /// to the cloud ASR route and its transcript enters the
  /// ordinary command pipeline via _processPushToTalkFinal.
  Future<void> _pttReleaseFromRecording() async {
    _pttRecordCapTimer?.cancel();
    _pttRecordCapTimer = null;
    final int sid = _pttSession;
    final DateTime? pressedAt = _pushToTalkPressedAt;
    _pushToTalkPressedAt = null;
    final bool tooShort = pressedAt == null ||
        DateTime.now().difference(pressedAt) <
            const Duration(milliseconds: 300);
    _pttState = _PttState.stopping;
    _pttRecording = false;
    if (tooShort) {
      try {
        await _recorder.cancel();
      } catch (_) {}
      if (!mounted || sid != _pttSession) return;
      _pttState = _PttState.idle;
      _announcePushToTalkTooShort();
      return;
    }
    Uint8List? bytes;
    try {
      bytes = await _recorder.stop();
    } catch (_) {
      bytes = null;
    }
    if (!mounted || sid != _pttSession || _pttState != _PttState.stopping) {
      return;
    }
    if (bytes == null || bytes.isEmpty) {
      _pttState = _PttState.idle;
      _announcePushToTalkNoContent();
      return;
    }
    if (bytes.length > asrMaxAudioBytes) {
      _pttState = _PttState.idle;
      _announceCloudAsrFailure(AsrFailure.tooLarge);
      return;
    }
    if (!_cloudAsrClient.isConfigured) {
      _pttState = _PttState.idle;
      _announceCloudAsrFailure(AsrFailure.notConfigured);
      return;
    }
    setState(() {
      _currentPrompt = '正在识别';
    });
    final CloudAsrResult result = await _cloudAsrClient.transcribe(bytes);
    if (!mounted || sid != _pttSession || _pttState != _PttState.stopping) {
      return;
    }
    _pttState = _PttState.idle;
    if (result.ok) {
      _processPushToTalkFinal(result.text!);
    } else {
      _announceCloudAsrFailure(result.failure!);
    }
  }

  /// Speak a cloud-ASR failure's FIXED local detail (never
  /// an exception, never response text).
  void _announceCloudAsrFailure(AsrFailure failure) {
    _logMsg('云端识别失败：${asrFailureDetail(failure)}');
    HapticFeedback.vibrate();
    if (_voiceOutput.isAvailable && !_ttsFailed) {
      _say(_request(
        id: 'cloud-asr-failed-${DateTime.now().millisecondsSinceEpoch}',
        eventId: 'cloud-asr-failed-${DateTime.now().millisecondsSinceEpoch}',
        text: asrFailureDetail(failure),
        kind: SpeechKind.alert,
      ));
    }
  }

  /// Release while listening. A NORMAL press enters the
  /// stopping window (see below); a TOO-SHORT press voids
  /// its session instead: cancel() (not stop()), the
  /// session is marked void, and only the too-short notice
  /// is spoken -- no final or partial from it can ever be
  /// executed, whenever it arrives.
  Future<void> _pttReleaseFromListening() async {
    final int sid = _pttSession;
    final DateTime? pressedAt = _pushToTalkPressedAt;
    _pushToTalkPressedAt = null;
    final bool tooShort = pressedAt == null ||
        DateTime.now().difference(pressedAt) <
            const Duration(milliseconds: 300);
    _pttState = _PttState.stopping;
    if (!tooShort) _setPttStoppingWindow(true);
    if (tooShort) {
      _pttSessionVoided = true;
      _pttCachedText = null;
      _pttCachedIsFinal = false;
      await _cancelListeningInternal();
      if (!mounted || sid != _pttSession) return;
      _pttState = _PttState.idle;
      _announcePushToTalkTooShort();
      return;
    }
    // Settle-by-order release (this round): stop() opens
    // a window (from the release) for THIS session's
    // final. A final arriving anywhere in it -- stop still
    // in flight or already returned -- is submitted at
    // once by _onPttFinalInStopping. Only when the window
    // expires WITHOUT a final does the press escalate to
    // the cancel-confirm step (_pttFinalWaitExpired).
    // 3 s window (real-device fix round B): the Xiaomi
    // engine delivers its result ~1.4 s AFTER the release
    // stop; the old 1.5 s window raced it. 3 s leaves
    // margin; no new session may start inside the window.
    _pttNoContentTimer = Timer(const Duration(milliseconds: 3000), () {
      if (!mounted || sid != _pttSession || _pttState != _PttState.stopping) {
        return;
      }
      unawaited(_pttFinalWaitExpired(sid));
    });
    await _stopListeningInternal();
    if (!mounted || sid != _pttSession || _pttState != _PttState.stopping) {
      return;
    }
    // stop() has returned. A final that arrived during the
    // stop was already submitted by _onPttFinalInStopping
    // (state left stopping); reaching here with a cached
    // final means it was cached while held -- submit now.
    // Otherwise the 3 s final-wait above is still
    // running: it either receives the final (submitted by
    // _onPttFinalInStopping) or escalates to the cancel-
    // confirm step when it expires.
    if (_pttCachedIsFinal && _pttCachedText != null) {
      _pttCompletePress(sid, _pttCachedText);
    }
  }

  /// The 3 s final-wait expired with no final for this
  /// press's session: settle the session by CANCEL, not
  /// by guessing. cancel() makes the platform discard the
  /// session (Android's SpeechRecognizer.cancel delivers
  /// no further results), so once the cancel's close is
  /// CONFIRMED (the adapter's pending-close count reaches
  /// zero -- the same ledger that gates every new listen),
  /// no result of this session can ever surface again,
  /// in this session or a later one. The press then
  /// completes with its cached last partial if it has one,
  /// else with the no-content notice.
  ///
  /// The confirmation wait is bounded at 3 s: if the
  /// platform never confirms, the press still completes
  /// (the adapter's close watchdog remains the backstop
  /// for the ledger itself, and the new-listen barrier
  /// keeps holding until the count does reach zero), so
  /// a press can never hang on a dead recogniser.
  Future<void> _pttFinalWaitExpired(int sid) async {
    // Close the result window first: from here on a late
    // final of this session is no longer accepted for
    // this press (the cancel settles the session).
    _setPttStoppingWindow(false);
    await _cancelListeningInternal();
    if (!mounted || sid != _pttSession || _pttState != _PttState.stopping) {
      return;
    }
    if (_voiceInput is SystemVoiceInput) {
      try {
        // Drive the confirmation the way the press path
        // does (the adapter's re-registration asks the
        // platform for the closing outcome), bounded by
        // the same 3 s: the confirm helper itself waits
        // unbounded, so the timeout here is what bounds
        // this step.
        await _ensureAsrCloseConfirmed()
            .timeout(const Duration(milliseconds: 3000));
      } on TimeoutException {
        // Confirmation never landed (see the doc above):
        // complete anyway; the barrier/watchdog own the
        // ledger from here.
      }
    }
    if (!mounted || sid != _pttSession || _pttState != _PttState.stopping) {
      return;
    }
    if (_pttCachedText != null && !_pttCachedIsFinal) {
      _pttCompletePress(sid, _pttCachedText);
    } else if (_pttCachedText == null) {
      // No final and no partial ever arrived, but the
      // platform stop already returned long ago: the
      // engine had its whole window to deliver a terminal
      // outcome and produced none, so this press settles
      // HERE with the no-content notice instead of
      // depending on whether the close ever confirms.
      // (When the close DOES stay unconfirmed the adapter
      // watchdog remains the ledger's backstop, and the
      // restart it performs still speaks its own notice;
      // presses whose outcome DID arrive settle earlier
      // via _onAsrSessionNoMatch / a stopping-window
      // final, so this path is only the silent-engine
      // case.)
      _pttCompletePress(sid, null);
    }
  }

  /// A final of the current press's session arrived during
  /// the stopping window: it wins over any cached partial
  /// and completes the press immediately. (Too-short
  /// presses never reach here: their session is void and
  /// the subscription drops their results first.)
  void _onPttFinalInStopping(String text) {
    _pttCachedText = text;
    _pttCachedIsFinal = true;
    _pttCompletePress(_pttSession, text);
  }

  /// A recognition result was SUBMITTED: this is THE
  /// event that clears the recoverable-error streak
  /// (CDX3 / MT-1111-PTT-4, tightened by
  /// MT-1111-PTT-4B). Escalation measures a truly
  /// consecutive stretch of failures, and one submitted
  /// result breaks it. The ONLY call site is the press
  /// completion point submitting a result (text != null):
  /// a result that merely ARRIVED -- a cached partial, an
  /// unsubmitted final, a voided too-short press's
  /// result -- clears nothing, and neither does a listen
  /// start or a clean non-error session end; a different
  /// error code displaces the streak instead of clearing
  /// it (see _noteRecoverableAsrError).
  void _noteAsrSessionDelivered() {
    _resetAsrErrorStreak();
  }

  /// The single completion point of a released press.
  /// Guarded by the state machine: only a press still in
  /// stopping can complete, and completing leaves stopping,
  /// so a second caller (deadline, stop return, late final)
  /// can never submit twice.
  void _pttCompletePress(int sid, String? text, {bool tooShort = false}) {
    if (sid != _pttSession || _pttState != _PttState.stopping) return;
    _pttNoContentTimer?.cancel();
    _pttState = _PttState.idle;
    _setPttStoppingWindow(false);
    _pttCachedText = null;
    _pttCachedIsFinal = false;
    if (text != null) {
      // MT-1111-PTT-4B: THE streak clearing point -- a
      // recognition result is submitted and executed
      // right here, so the consecutive-failure streak
      // ends. (A no-content or too-short completion
      // submits nothing and clears nothing.)
      _noteAsrSessionDelivered();
      _processPushToTalkFinal(text);
      _restoreAutoListenAfterPushToTalk();
    } else if (tooShort) {
      _announcePushToTalkTooShort();
    } else {
      _announcePushToTalkNoContent();
    }
  }

  /// Open/close the adapter's stopping pass-through
  /// window in step with the press lifecycle: opened when
  /// a normal press's release begins its stop, closed
  /// whenever a press completes. A voided (too-short)
  /// press never opens it.
  void _setPttStoppingWindow(bool open) {
    if (_voiceInput is SystemVoiceInput) {
      (_voiceInput as SystemVoiceInput).acceptStoppingResults = open;
    }
  }

  /// Cancel the current listening session (the session is
  /// voided; the platform discards its pending result).
  /// Sibling of _stopListeningInternal for too-short
  /// push-to-talk releases.
  Future<void> _cancelListeningInternal() async {
    if (_voiceInput is SystemVoiceInput) {
      try {
        await (_voiceInput as SystemVoiceInput).cancelListening();
      } catch (e) {
        _logMsg('取消语音识别失败，麦克风可能仍在监听：$e');
      }
    }
  }

  /// Called from _finishSpeech: a deferred press whose P0
  /// prompt just completed enters prompting, if the button
  /// is still held and the press is still the live one.
  void _maybeEnterPttAfterP0() {
    if (_pttState != _PttState.prompting || !_pttDeferredByP0) return;
    if (!_pushToTalkHeld) {
      _pttDeferredByP0 = false;
      _pttState = _PttState.idle;
      return;
    }
    _pttDeferredByP0 = false;
    unawaited(_pttPromptStep(_pttSession));
  }

  /// Process the released press's submitted text: the same
  /// routing the transcript subscription applies to
  /// automatic sessions (destination answer while the
  /// question is open, otherwise the command handler).
  void _processPushToTalkFinal(String text) {
    if (_awaitingDestination) {
      if (parseVoiceCommand(text) == VoiceCommand.unknown) {
        _answerDestination(text);
        return;
      }
      _awaitingDestination = false;
    }
    _handleVoiceCommand(text);
  }

  /// Stop the currently playing utterance for a press --
  /// unless it is P0. Two layers, because the physical stop
  /// has no cancel callback: while a cancellable prompt is
  /// still the scheduler's ACTIVE entry, cancelAll both
  /// drops it (its late completion is ignored by the
  /// stop-race guard) and the physical stop silences it.
  /// When the entry already completed -- a simulated
  /// prompt whose playback outlives its entry, or a P0
  /// prompt inside its post-completion window -- the
  /// playback is recognised by recency and kind: recent
  /// non-P0 playback is stopped physically, recent P0
  /// playback is left completely alone.
  Future<void> _interruptSpeechForPushToTalk() async {
    // A queued P0 prompt is about to play: clearing the
    // queue for a cue would kill it. Leave everything.
    if (_scheduler.queue.any((SpeechRequest r) =>
        r.kind == SpeechKind.danger || r.kind == SpeechKind.emergency)) {
      return;
    }
    final SpeechRequest? active = _scheduler.active;
    if (active != null) {
      if (active.kind == SpeechKind.danger ||
          active.kind == SpeechKind.emergency) {
        return; // P0 playing: never interrupt.
      }
      _scheduler.cancelAll();
      await _stopTtsPlayback();
      return;
    }
    final DateTime? startedAt = _lastSpeechStartedAt;
    if (startedAt != null &&
        DateTime.now().difference(startedAt) <
            const Duration(milliseconds: 1500)) {
      if (_lastSpokenText == _lastP0SpokenText) return;
      await _stopTtsPlayback();
    }
  }

  /// Resume the automatic loop after a press, ONLY when it
  /// was running before the press and the ordinary
  /// turn-taking conditions hold (loop enabled, no TTS
  /// failure, nothing speaking or queued).
  /// After a press the automatic loop does NOT resume
  /// (press-and-hold only, real-device fix round): there is
  /// no automatic loop anymore. Kept as a no-op because the
  /// press-completion paths still call it; the call now only
  /// clears the borrowed-microphone snapshot.
  /// TalkBack long-press action on the PTT area (CDX2).
  /// TalkBack has no physical hold-and-release: the action
  /// starts the press, and the press is ended by the
  /// SHARED cap timer -- the same cancellable
  /// [_pttRecordCapTimer] the recording path arms. This
  /// replaces the old un-cancellable Future.delayed(10 s)
  /// that carried NO session id: it could fire after its
  /// own press had ended and terminate the NEXT press, and
  /// because it called the plain release path directly it
  /// could skip the recording cap's notice entirely. Now
  /// the fire goes through [_onPttCapTimerFired] with the
  /// armed id: stale fires are no-ops, a recording press
  /// takes the unified cap completion, and a listening
  /// press ends like a release. ALIGN-B discipline: this
  /// method only MARKS the new session as TalkBack-owned;
  /// the timer itself is armed when capture actually
  /// starts -- in _pttStartRecording after recorder start,
  /// or in the prompt step after a successful listen -- so
  /// the deadline never runs during the cue, and there is
  /// never a second, competing deadline.
  void _talkBackLongPress() {
    final int before = _pttSession;
    _pushToTalkStart();
    if (_pttSession != before) {
      _talkBackCapSessionId = _pttSession;
    }
  }

  void _restoreAutoListenAfterPushToTalk() {
    _autoListenWasActive = false;
  }

  /// Too-short press (under 300 ms): the fixed instruction.
  void _announcePushToTalkTooShort() {
    _logMsg('按住说话：按住时间不足 300 毫秒，未启动识别。');
    _restoreAutoListenAfterPushToTalk();
    if (_voiceOutput.isAvailable && !_ttsFailed) {
      _say(_request(
        id: 'ptt-short-${DateTime.now().millisecondsSinceEpoch}',
        eventId: 'ptt-short-${DateTime.now().millisecondsSinceEpoch}',
        text: '请按住说话',
        kind: SpeechKind.alert,
      ));
    }
  }

  /// A full press that recognised nothing: the fixed retry
  /// instruction (distinct from the too-short text).
  void _announcePushToTalkNoContent() {
    _logMsg('按住说话：未识别到内容（没有听清）。');
    _restoreAutoListenAfterPushToTalk();
    if (_voiceOutput.isAvailable && !_ttsFailed) {
      _say(_request(
        id: 'ptt-empty-${DateTime.now().millisecondsSinceEpoch}',
        eventId: 'ptt-empty-${DateTime.now().millisecondsSinceEpoch}',
        text: '没有听清，请按住按钮再说一次。',
        kind: SpeechKind.alert,
      ));
    }
  }

  /// Start one listening session. With [pushToTalk] the
  /// session belongs to the held button and the automatic
  /// turn-taking flag is left untouched. Returns whether a
  /// session actually started. EVERY failure to start --
  /// recogniser unavailable or engine refusal -- vibrates
  /// and speaks the fixed ASR-unavailable notice through
  /// the working voice: no ASR failure path is silent or
  /// vibration-free (the startup and error-stream paths
  /// already did; the start paths now match).
  Future<bool> _startListening({bool pushToTalk = false}) async {
    if (!_voiceInput.isAvailable) {
      // The local recogniser cannot serve a press at all:
      // route subsequent presses to the recording fallback.
      _localAsrBroken = true;
      _logMsg('语音识别不可用：${_voiceInput.status}');
      HapticFeedback.vibrate();
      if (_voiceOutput.isAvailable) {
        _say(_request(
          id: 'asr-failed-${DateTime.now().millisecondsSinceEpoch}',
          eventId: 'asr-failed-${DateTime.now().millisecondsSinceEpoch}',
          text: voiceNoticeText(VoiceNoticeKind.asrUnavailable),
          kind: SpeechKind.alert,
        ));
      }
      return false;
    }
    await _rewireAsrSubscriptionsIfInputChanged();
    _ensureEngineSubscription();
    final SystemVoiceInput input = _voiceInput as SystemVoiceInput;
    final bool started = await input.startListening();
    if (started) {
      // Tag the app's session bookkeeping with the id the
      // adapter minted for THIS listen call; result and
      // status events are validated against it.
      _asrSessionId = input.currentSessionId;
      _asrLiveSessionId = input.currentSessionId;
      // A session that actually started re-arms the
      // per-code error announcements: the same code may be
      // spoken again for a LATER session (dedup is per
      // stretch between successes, never permanent).
      _asrErrorSpokenCodes.clear();
      // CDX3 / MT-1111-PTT-4B streak rule (supersedes
      // the CDX2 listen-start clearing AND the PTT-2
      // do-not-clear note): a listen that successfully
      // STARTS clears NOTHING. The streak lives across
      // presses and is cleared only when a result is
      // actually SUBMITTED at the press completion point
      // (see _noteAsrSessionDelivered), or displaced by
      // a different error code. So two presses that each
      // error busy once -- the second press's recovery
      // listen starting fine but submitting no result --
      // form a streak of 2, and the NEXT press escalates
      // to the cloud recording route.
      _asrRecoveryPending = false;
    }
    if (!mounted) return started;
    setState(() {
      _voiceText = started
          ? '语音识别进行中：请说一句话（最长 10 秒，说完停顿即结束）。'
          : '语音识别：开始失败，${_voiceInput.status}';
    });
    if (started) {
      _logMsg('语音识别已开始：请说一句话。');
    } else {
      HapticFeedback.vibrate();
      if (_voiceOutput.isAvailable) {
        // Runtime ASR failure must not be silent either: announce it
        // through the working voice, with the recoverable next step.
        _say(_request(
          id: 'asr-failed-${DateTime.now().millisecondsSinceEpoch}',
          eventId: 'asr-failed-${DateTime.now().millisecondsSinceEpoch}',
          text: voiceNoticeText(VoiceNoticeKind.asrUnavailable),
          kind: SpeechKind.alert,
        ));
      }
    }
    return started;
  }

  /// Stop the current listening session WITHOUT touching
  /// the automatic turn-taking flags (unlike the manual
  /// _stopListening button path, which deliberately switches
  /// the loop off). Used by push-to-talk, which borrows the
  /// microphone and hands it back.
  /// Re-wire the ASR event subscriptions when the input
  /// object was swapped underneath this page (e.g. by an
  /// engine restart that replaced it): cancel every
  /// subscription made on the old object and re-subscribe
  /// on the current one by re-running the startup wiring
  /// for the input only. When the input is unchanged this
  /// is a no-op.
  /// Confirm the automatic session's close before a press
  /// proceeds. The unconfirmed-close rule forbids opening
  /// a new session while a close is unconfirmed, and the
  /// close is confirmed by the session's own closing
  /// outcome (its terminal error or closing status), which
  /// the adapter consumes. If the automatic loop left a
  /// session stopped-but-unconfirmed, the press path
  /// confirms it HERE -- by waiting for the adapter's
  /// close future -- instead of entering the indefinite
  /// wait branch: the confirmation is an event the
  /// platform owes us for a session WE stopped, and the
  /// watchdog ladder remains the backstop if it never
  /// arrives. While confirming, session events belong to
  /// the closing session.
  Future<void> _ensureAsrCloseConfirmed() async {
    if (_voiceInput is! SystemVoiceInput) return;
    final SystemVoiceInput input = _voiceInput as SystemVoiceInput;
    if (input.pendingCloses == 0) return;
    _asrConfirmingClose = true;
    // Register the epoch-accounting continuation on the
    // confirmation's resolution (test seam): the watchdog
    // restart that resolves this wait bumps the epoch,
    // and its accounting must run HERE -- at the
    // resolution -- not at some later listen attempt.
    input.debugCloseConfirmedObserver = _ensureEngineSubscription;
    try {
      await input.confirmSessionClose();
    } finally {
      input.debugCloseConfirmedObserver = null;
      _asrConfirmingClose = false;
    }
  }

  Future<void> _rewireAsrSubscriptionsIfInputChanged() async {
    if (identical(_voiceInput, _subscribedVoiceInput)) {
      // No swap: still run the epoch accounting -- the
      // close-confirmation path reaches this method after
      // the adapter may have restarted underneath an
      // UNCHANGED input object, and a missed watchdog
      // restart must be accounted there, not only at the
      // next listen attempt.
      _ensureEngineSubscription();
      return;
    }
    if (_voiceInput is! SystemVoiceInput) return;
    for (final void Function() cancelSub in _asrSubCancels) {
      cancelSub();
    }
    _asrSubCancels = <void Function()>[];
    _subscribedEngineEvents = null;
    await _initStartupModules();
  }

  /// Ensure the engine-restart notification has a live
  /// listener. The adapter publishes 'restarted' on a
  /// broadcast stream: an event fired while NO listener is
  /// attached is lost forever. A restart can also replace
  /// the stream object (a fresh controller), which orphans
  /// a subscription made on the old object. Both cases are
  /// healed here, at the one place every listen attempt
  /// passes through: if the current input's engineEvents
  /// stream is not the object the live subscription was
  /// made on, cancel and re-subscribe on the current one.
  /// When a restart ALREADY fired while unsubscribed, its
  /// event is gone -- but the restart is also visible as a
  /// bumped engine epoch, so the missed notification is
  /// replayed locally exactly once per epoch.
  void _ensureEngineSubscription() {
    if (_voiceInput is! SystemVoiceInput) return;
    final SystemVoiceInput input = _voiceInput as SystemVoiceInput;
    // Test-marker scan (empty in production): a harness
    // can ask this app to arm the adapter's restart-init
    // marker, and the adapter records a marked watchdog
    // restart's platform initialize -- together they
    // model the subscription-rebuild gap in which a
    // restart's notification (and with it, its epoch
    // accounting) is genuinely missed.
    final List<String> markers =
        input.debugDrainTestMarkers();
    if (markers.contains('restartInit')) {
      mingtuVoiceLog('测试缝：模拟丢失一次引擎重启的纪元核算');
      _suppressNextEngineEpochCheck = true;
    }
    final bool suppressEpochCheck = _suppressNextEngineEpochCheck;
    _suppressNextEngineEpochCheck = false;
    final Stream<String> current = input.engineEvents;
    if (!_debugEngineSubDropped &&
        !identical(current, _subscribedEngineEvents)) {
      _asrEngineSub?.cancel();
      _subscribedEngineEvents = current;
      _asrEngineSub = current.listen((String event) {
        if (!mounted) return;
        if (event == 'restarted') {
          _onEngineRestarted();
        } else if (event == 'restart_failed') {
          _onEngineRestartFailed();
        }
      });
      _asrSubCancels.add(() => _asrEngineSub?.cancel());
    }
    // Missed-restart accounting, epoch by epoch. The
    // FIRST observation only establishes the baseline (a
    // bump that predates any subscription cannot be told
    // apart from the initial state; undrained recovery
    // attributions are drained silently so a later real
    // bump is judged on its own). Every LATER bump is
    // accounted exactly once by _noteEngineEpochBump:
    // recovery bumps are swallowed (that restart was
    // already handled by the press flow), watchdog bumps
    // replay their missed notification -- this check runs
    // on every listen attempt, so a watchdog restart that
    // fired while the subscription was down is delivered
    // here at the latest.
    if (suppressEpochCheck) return;
    final int currentEpoch = input.engineEpoch;
    final int? seenEpoch = _engineEpochSeen;
    if (seenEpoch == null) {
      for (int e = 0; e <= currentEpoch; e++) {
        input.consumeRecoveryEpoch(e);
      }
      _engineEpochSeen = currentEpoch;
    } else if (currentEpoch > seenEpoch) {
      _engineEpochSeen = currentEpoch;
      for (int e = seenEpoch + 1; e <= currentEpoch; e++) {
        _noteEngineEpochBump(input, e);
      }
    }
  }

  /// The engine was force-restarted by the adapter
  /// watchdog: every session from before the restart is
  /// void. Any live press is wound up (never continued
  /// into prompting) and the fixed notice is spoken.
  void _onEngineRestarted() {
    _debugEngineEvents.add('restarted');
    _finishPttAfterEngineRestart();
    _say(_request(
      id: 'asr-restarted-${DateTime.now().millisecondsSinceEpoch}',
      eventId: 'asr-restarted-${DateTime.now().millisecondsSinceEpoch}',
      text: '语音已重启，请重新按住说话',
      kind: SpeechKind.alert,
    ));
  }

  /// The watchdog restart's platform re-initialize
  /// FAILED: the live press is wound up exactly as for
  /// a successful restart, but the user hears the fixed
  /// recogniser-unavailable notice -- never the restart
  /// notice. Nothing stays wedged: the adapter cleared
  /// every close ledger before reporting the failure,
  /// so the next press goes through the normal start
  /// path (and its own failure handling) instead of
  /// waiting forever.
  void _onEngineRestartFailed() {
    _debugEngineEvents.add('restart_failed');
    _finishPttAfterEngineRestart();
    HapticFeedback.vibrate();
    _say(_request(
      id: 'asr-restart-failed-${DateTime.now().millisecondsSinceEpoch}',
      eventId:
          'asr-restart-failed-${DateTime.now().millisecondsSinceEpoch}',
      text: voiceNoticeText(VoiceNoticeKind.asrUnavailable),
      kind: SpeechKind.alert,
    ));
  }

  Future<void> _stopListeningInternal() async {
    if (_voiceInput is SystemVoiceInput) {
      _asrCloseInFlight = true;
      try {
        await (_voiceInput as SystemVoiceInput).stopListening();
      } catch (e) {
        _logMsg('停止语音识别失败，麦克风可能仍在监听：$e');
      } finally {
        _asrCloseInFlight = false;
      }
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
      _pttStoppedUtteranceAt = DateTime.now();
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
    mingtuVoiceLog('用户打断（停下）：取消待播报并停止当前播报');
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
    // Avoidance advisor bookkeeping for EVERY frame: the
    // side-clear streaks behind the three-condition rule and
    // the pending-action tracker (spec 7.7-12: speech
    // completion never confirms an action; frame evidence
    // does -- or reports it unconfirmed here).
    final AvoidanceNotice? notice = _avoidance.observeFrame(detections);
    if (notice == AvoidanceNotice.actionUncertain) {
      _say(_request(
        id: 'avoid-uncertain-${now.millisecondsSinceEpoch}',
        eventId: 'avoid-uncertain-${now.millisecondsSinceEpoch}',
        text: '尚未确认避开前方障碍，请停下。',
        kind: SpeechKind.danger,
      ));
    }
    final List<PerceptionEvent> events =
        _perception.processFrame(detections, now);
    // NAVHAZ M1 routing: frames that carry real box
    // geometry run through the tracking + TTC pipeline;
    // geometry-less frames (scripted / simulated sources
    // and the existing test harness) keep the legacy chain
    // below, unchanged.
    if (detections.any((Detection d) => d.w > 0 && d.h > 0)) {
      _onYoloDetectionsPipeline(detections, now);
    } else {
      _onYoloDetectionsLegacy(detections, events, now);
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

  /// Shared risk-state entry for both hazard chains
  /// (legacy + NAVHAZ pipeline): pause straight pacing and
  /// move the task to obstacle-avoidance.
  void _enterYoloRiskState() {
    _yoloRiskActive = true;
    if (_tasks.state == TaskState.navigating) {
      _tasks.transitionTo(TaskState.avoidingObstacle,
          trigger: 'yolo-obstacle');
      _stopStraightTimer();
    }
    _pauseStraightForRisk();
    setState(() {
      _riskActive = true;
      _straightConfirmed = false;
    });
  }

  /// Shared risk-state exit: the caller observed three
  /// consecutive risk-free frames. Runs the unified resume
  /// re-check NOW, not at some later speech completion, and
  /// restarts the straight timer so the re-armed 3 s cadence
  /// can actually fire.
  void _exitYoloRiskState(DateTime now) {
    _yoloRiskActive = false;
    if (_tasks.state == TaskState.avoidingObstacle) {
      _tasks.transitionTo(TaskState.navigating, trigger: 'yolo-cleared');
    }
    setState(() {
      _riskActive = false;
      _straightConfirmed = false;
    });
    _recheckStraightResume();
    _say(_request(
      id: 'yolo-cleared-${now.millisecondsSinceEpoch}',
      eventId: 'yolo-cleared-${now.millisecondsSinceEpoch}',
      text: '前方已无检测到的障碍。请说继续，重新确认直行路段后再走。',
      kind: SpeechKind.info,
    ));
  }

  /// NAVHAZ M1: geometry-bearing frames -- multi-target
  /// tracking, TTC estimation and the hazard policy decide
  /// what (if anything) is announced; the policy also
  /// drives the risk state (three consecutive risk-free
  /// frames clear it, same as the legacy chain).
  void _onYoloDetectionsPipeline(List<Detection> detections, DateTime now) {
    final bool navigating = _tasks.state == TaskState.navigating ||
        _tasks.state == TaskState.avoidingObstacle;
    final HazardPipelineResult result = _hazardPipeline.processFrame(
      detections,
      now,
      pitchDeg: _pitchMonitor.currentPitchDeg,
      // Ego-motion evidence: the live location stream
      // carries no speed and accelerometer variance is not
      // wired in M1, so the judge reports still; closing
      // vehicles are then judged on raw relative speed --
      // the conservative direction.
      ego: EgoMotion.still,
      commit: navigating,
    );
    if (result.riskPresent) {
      _yoloEmptyFrames = 0;
      if (navigating && !_yoloRiskActive) {
        _enterYoloRiskState();
      }
    } else {
      _yoloEmptyFrames += 1;
      if (_yoloRiskActive && _yoloEmptyFrames >= 3) {
        _exitYoloRiskState(now);
      }
    }
    final HazardAlert? alert = result.alert;
    if (alert == null) return;
    // Vibration FIRST: it starts in parallel with the
    // physical TTS stop the hazard speak path performs --
    // it is never awaited before speech (spec section 2.5:
    // the voice follows the vibration start closely; the
    // sequenced speak path owns that timing).
    unawaited(
        alert.urgent ? _haptics.vibrateUrgent() : _haptics.vibrateWarning());
    String text = alert.phrase;
    if (alert.urgent) {
      // A sideways step may ONLY come from the avoidance
      // advisor's three-condition decision -- the tracking
      // / TTC pipeline never produces a direction itself.
      final AvoidanceDecision decision = _avoidance.decide(
        hazard: alert.detection,
        orientationStable: _orientation.isStable,
      );
      if (decision.advice == StepAdvice.stepLeft) {
        text = '$text，向左迈一步';
      } else if (decision.advice == StepAdvice.stepRight) {
        text = '$text，向右迈一步';
      }
      if (alert.nearCenter) {
        unawaited(_triggerHazardScan(VisionTrigger.yoloHazard));
      }
    }
    _say(_request(
      id: 'navhaz-${alert.urgent ? 'urgent' : 'warning'}-'
          '${now.millisecondsSinceEpoch}',
      eventId: 'navhaz-track-${alert.trackId}',
      text: '$text。',
      kind: alert.speechKind,
    ));
    _logMsg('NAVHAZ ${alert.urgent ? '紧急' : '警示'}：$text'
        '（track ${alert.trackId}）。');
  }

  /// The pre-M1 announcement chain, kept for frames
  /// without box geometry (see _onYoloDetections).
  void _onYoloDetectionsLegacy(
    List<Detection> detections,
    List<PerceptionEvent> events,
    DateTime now,
  ) {
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
        (_tasks.state == TaskState.navigating ||
            _tasks.state == TaskState.avoidingObstacle)) {
      // Risk onset (only the FIRST obstacle flips the state
      // and enters the unified straight pause). The danger
      // SPEECH below is deliberately NOT gated on
      // _yoloRiskActive (Codex re-test of f951240): a NEW
      // danger that appears while another risk is already
      // active must still be announced immediately -- only
      // the per-category cooldown debounces repeats.
      if (!_yoloRiskActive) {
        _enterYoloRiskState();
      }
      final String names = newObstacles
          .map((PerceptionEvent e) => _yoloObstacleLabels[e.label] ?? e.label)
          .join('、');
      _logMsg('YOLO 危险：$names（播报受同类冷却限制）。');
      // Step 2 danger alerts: short imperative text, alert
      // priority (above navigation prompts), per-category
      // cooldown so a persistent obstacle cannot spam. The
      // risk STATE above changes regardless of the gate; only
      // the speech is debounced.
      final List<DangerCategory> categories = newObstacles
          .map((PerceptionEvent e) => dangerCategoryFor(e.label))
          .toSet()
          .toList()
        ..sort((DangerCategory a, DangerCategory b) =>
            dangerPriority(a).compareTo(dangerPriority(b)));
      DangerCategory? chosen;
      for (final DangerCategory c in categories) {
        if (_dangerGate.tryPass(c, now)) {
          chosen = c;
          break;
        }
      }
      if (chosen != null) {
        // The announcement text comes from the avoidance
        // advisor: it names the hazard category and adds a
        // one-step direction ONLY when all three conditions
        // hold (central + near, other side clear for 3+
        // frames, orientation stable); otherwise it is the
        // stop instruction.
        Detection? representative;
        for (final Detection d in detections) {
          if (dangerCategoryFor(d.label) == chosen &&
              (representative == null ||
                  d.confidence > representative.confidence)) {
            representative = d;
          }
        }
        final String text;
        if (representative != null) {
          final AvoidanceDecision decision = _avoidance.decide(
            hazard: representative,
            orientationStable: _orientation.isStable,
          );
          text = decision.speech;
          if (decision.nearCenterHazard) {
            // A near hazard in the corridor also triggers a
            // cloud hazard frame, merged into the current
            // vision cycle (never an extra request).
            unawaited(_triggerHazardScan(VisionTrigger.yoloHazard));
          }
        } else {
          text = dangerTextFor(chosen);
        }
        _say(_request(
          id: 'yolo-danger-${now.millisecondsSinceEpoch}',
          eventId: 'yolo-danger-${now.millisecondsSinceEpoch}',
          text: text,
          kind: SpeechKind.danger,
        ));
      }
    } else if (_yoloRiskActive && _yoloEmptyFrames >= 3) {
      // The tick stays gated regardless: in the demo flow
      // on the user's own re-confirmation（继续）, in live
      // nav on the tracker's current step.
      _exitYoloRiskState(now);
    }
  }

  /// Open the YOLO live view under the shared arbiter. The
  /// acquire first waits for any pending physical release; when
  /// the camera is busy (or the wait times out) the view does NOT
  /// open and the user hears exactly that.
  Future<void> _openYoloLive() async {
    final CameraLease? lease =
        await _cameraOwnership.tryAcquire(CameraUse.yoloLive);
    if (lease == null) {
      _logMsg('摄像头忙：YOLO 实时视图未打开。');
      _say(_request(
        id: 'camera-busy-${DateTime.now().millisecondsSinceEpoch}',
        eventId: 'camera-busy-${DateTime.now().millisecondsSinceEpoch}',
        text: cameraBusySpeech,
        kind: SpeechKind.alert,
      ));
      return;
    }
    _yoloLease = lease;
    if (!mounted) return;
    setState(() {
      _yoloLiveOpen = true;
    });
  }

  /// Close the YOLO live view and hand the camera back to the
  /// shared arbiter. The release is asynchronous: the lock frees
  /// only after the view has actually unmounted
  /// (yoloLiveViewDisposed). Safe to call when not open.
  void _closeYoloLiveView() {
    _yoloLiveOpen = false;
    final CameraLease? lease = _yoloLease;
    _yoloLease = null;
    if (lease != null) {
      unawaited(
        _cameraOwnership.release(lease, waitFor: yoloLiveViewDisposed),
      );
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
    });
    // v0.7: navigation starts the camera too -- a blind user must
    // not have to find and tap a button to turn perception on.
    // On web this shows the phone-only stub text. The open goes
    // through the shared arbiter (async, waits for any pending
    // physical release): if the camera is busy the view simply
    // does not open and navigation proceeds without it.
    unawaited(_openYoloLive());
    _pacing.begin();
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
        !_straightSegmentConfirmedNow ||
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
    _pacing.hold(_navVersion);
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
    if (_liveNav != null) {
      // Live trip (Codex re-test of f951240): the user cannot
      // "confirm" a segment -- the tracker's current step
      // decides, via the unified re-check. Resume only when
      // it passes; say so when it does.
      _recheckStraightResume();
      if (!_pacing.canTick) {
        _logMsg('当前路段未经跟踪器确认直行，未恢复直行节奏。');
        return;
      }
      _logMsg('直行恢复：已按跟踪器当前路段重新检查，3 秒计时器已重启。');
      _say(_request(
        id: 'straight-resumed-live-${DateTime.now().millisecondsSinceEpoch}',
        eventId:
            'straight-resumed-live-${DateTime.now().millisecondsSinceEpoch}',
        text: '已重新确认直线路段，继续直走。',
        kind: SpeechKind.info,
      ));
      return;
    }
    final DateTime now = DateTime.now();
    // Unified resume path (Codex re-test of d01a081): the
    // demo re-confirmation goes through the SAME re-check
    // and persistent pacing state as every other resume.
    // The old code called the scheduler's resumeStraight
    // directly (twice, with a version fallback), bypassing
    // both the re-check and the pause state.
    setState(() {
      _straightConfirmed = true;
    });
    _recheckStraightResume();
    if (_pacing.canTick) {
      _logMsg('直行恢复：已重新确认直线路段，3 秒计时器已重启（统一重检），旧直行指令未补播。');
    } else {
      // The only remaining blocker here is a danger prompt
      // that is still playing: the confirmation is registered
      // and SPOKEN (queued behind the danger), and the timer
      // restarts at that danger's completion re-check -- the
      // resume never re-times before the danger finishes.
      _logMsg('直行恢复：已确认直线路段，待危险播报结束后按统一重检重启计时。');
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
    _pacing.hold(_navVersion);
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
    final RiskAssessment assessment = _envSkill.analyse(event, now).assessment;
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
    });
    // Resume ONLY through the unified pacing re-check (this
    // handler used to resume the scheduler and restart the
    // timer directly, bypassing the pacing machine).
    _recheckStraightResume();
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
    _pacing.hold(_navVersion);
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
    final RiskAssessment assessment = _envSkill.analyse(event, now).assessment;
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
    });
    // Resume ONLY through the unified pacing re-check (this
    // handler used to resume the scheduler and restart the
    // timer directly, bypassing the pacing machine).
    _recheckStraightResume();
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
      _trafficText =
          '${assessment.speechText}（允许过马路：${assessment.allowsCrossing}，学习记录 ${_backlog.count} 条，只记录不改规则。）';
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
    while (!_mapService.shouldSwitchToDestinationApproach(nav) && steps < 30) {
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
    _tasks.transitionTo(TaskState.waitingConfirmation, trigger: 'verify-task');
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
      _closeYoloLiveView();
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

  /// Low-frequency cloud vision ASSIST, triggered ONLY by the
  /// user (voice "看看前面" or the on-screen button). Local YOLO
  /// stays primary: this never runs on its own, never streams or
  /// records, never feeds the risk engine, and its spoken result
  /// is framed as an unverified description with the disclaimer.
  /// The flow announces every stage in Chinese -- starting,
  /// result, timeout/failure degradation, and a camera-permission
  /// denial -- so no path is silent. The DashScope key exists
  /// only in the proxy's server environment; this device sends
  /// one downsampled frame to the proxy and nothing else.
  /// Manual cloud-vision entry (voice command and button):
  /// routes through the cycle coordinator so a tap during a
  /// hazard scan JOINS that cycle's single request instead of
  /// starting a second one, and a tap during a 429 backoff is
  /// skipped silently (local detection continues).
  void _triggerManualVision() {
    if (!_visionBackoff.allow(DateTime.now())) {
      _logMsg('云端视觉：429 退避中，手动识图已跳过，只用本地检测。');
      return;
    }
    final CycleStart start = _visionCycle.trigger(VisionTrigger.manual);
    if (start == CycleStart.joined) {
      _logMsg('云端视觉：手动请求已合并到正在进行的扫描，完成后播报结果。');
      return;
    }
    if (start == CycleStart.busy) {
      // A manual run is already in flight; the existing
      // refusal inside _runCloudVisionAssist speaks for it.
      unawaited(_runCloudVisionAssist());
      return;
    }
    _manualCycleOwned = true;
    unawaited(_runCloudVisionAssist());
  }

  /// The 8-second walking-scan tick: only while walking, and
  /// during live navigation only after the user has actually
  /// moved (>= 2 m since the last scan's fix). Stationary or
  /// not navigating -> no automatic cloud calls at all.
  void _hazardScanTick() {
    if (!mounted) return;
    final bool walking = _liveNav != null ||
        _tasks.state == TaskState.navigating ||
        _tasks.state == TaskState.avoidingObstacle;
    if (!walking) return;
    if (_liveNav != null) {
      final GeoPoint? fix = _lastFixPoint;
      if (fix == null) return;
      final GeoPoint? anchor = _scanAnchorPoint;
      if (anchor != null && haversineMeters(anchor, fix) < 2) return;
    }
    unawaited(_triggerHazardScan(VisionTrigger.periodic));
  }

  /// Speak the fixed cloud-vision downgrade sentence,
  /// rate-limited by [_visionDowngrade]: repeated scan
  /// failures (for example while the FC still runs the
  /// pre-hazard build) announce ONCE per cooldown window,
  /// never on every 8-second tick.
  void _announceVisionDowngrade() {
    if (!mounted) return;
    if (!_visionDowngrade.shouldAnnounce(DateTime.now())) return;
    _say(_request(
      id: 'vision-downgrade-${DateTime.now().millisecondsSinceEpoch}',
      eventId: 'vision-downgrade-${DateTime.now().millisecondsSinceEpoch}',
      text: cloudVisionDowngradeSpeech,
      kind: SpeechKind.alert,
    ));
  }

  /// One hazard-scan cycle (periodic or YOLO-triggered; the
  /// coordinator merges overlapping triggers into this one
  /// request). Ground hazards and a tactile-paving
  /// identification are spoken from the parsed result, a 429
  /// gets the single notice per backoff episode, and EVERY
  /// failure or unknown-format outcome announces the fixed
  /// downgrade sentence (cloudVisionDowngradeSpeech),
  /// rate-limited by the downgrade gate so it cannot repeat
  /// on every tick. A manual request that joined the cycle
  /// is answered with the result description, or with the
  /// downgrade sentence when the cycle produced no usable
  /// assessment. Only the rate limiter's own slot refusal
  /// (tryReserve) stays silent: expected throttling, not a
  /// failure.
  Future<void> _triggerHazardScan(VisionTrigger kind) async {
    if (!_cloudVisionClient.isConfigured) return;
    final DateTime now = DateTime.now();
    if (!_visionBackoff.allow(now)) return;
    if (_lastVisionCallAt != null &&
        now.difference(_lastVisionCallAt!) < const Duration(seconds: 8)) {
      return;
    }
    final CycleStart start = _visionCycle.trigger(kind);
    if (start != CycleStart.hazardRun) return;
    _scanAnchorPoint = _lastFixPoint;
    _lastVisionCallAt = now;
    HazardAssessment? assessment;
    try {
      if (!_cloudVisionClient.tryReserve(now)) return;
      final CameraFrameCapture capture =
          await _frameSource.captureSingleFrame();
      if (!capture.ok || capture.bytes == null) {
        if (mounted) {
          _logMsg('云端识图：本轮自动扫描取帧失败，已降级为本地检测。');
        }
        _announceVisionDowngrade();
        return;
      }
      final HazardScanOutcome outcome = await _cloudVisionClient
          .describeHazardReserved(imageBytes: capture.bytes!);
      if (outcome.failure == CloudVisionFailure.rateLimited) {
        if (mounted) {
          _logMsg('云端识图：请求过于频繁，已按退避策略处理，其间只用本地检测。');
        }
        if (_visionBackoff.onRateLimited(DateTime.now())) {
          _say(_request(
            id: 'vision-429-${DateTime.now().millisecondsSinceEpoch}',
            eventId: 'vision-429-${DateTime.now().millisecondsSinceEpoch}',
            text: '识图暂时繁忙，稍后会自动重试，其间继续用本地检测。',
            kind: SpeechKind.alert,
          ));
        }
        return;
      }
      if (outcome.failure != null) {
        // Any other failure (network, timeout, upstream,
        // unconfigured, unparseable body) is spoken via the
        // downgrade sentence, never silent. The log line is
        // a fixed category text, written even when the
        // downgrade gate mutes the announcement.
        if (mounted) {
          _logMsg('云端识图：本轮自动扫描请求失败，已降级为本地检测。');
        }
        _announceVisionDowngrade();
        return;
      }
      if (!outcome.ok) return;
      final HazardAssessment a = outcome.assessment!;
      assessment = a;
      if (!a.parsed) {
        // Not a conforming hazard payload -- most likely
        // the FC still runs the pre-hazard build and
        // answered in the old scene shape. Unknown result:
        // announce the downgrade sentence (rate-limited)
        // and do NOT count this as a success.
        if (mounted) {
          _logMsg('云端识图：响应格式无法识别（可能仍是旧版服务），已按未知处理并降级为本地检测。');
        }
        _announceVisionDowngrade();
        return;
      }
      _visionBackoff.onSuccess();
      _visionDowngrade.noteSuccess();
      if (!mounted) return;
      final String? ground = hazardGroundSpeech(a);
      if (ground != null) {
        _say(_request(
          id: 'hazard-ground-${DateTime.now().millisecondsSinceEpoch}',
          eventId: 'hazard-ground-${DateTime.now().millisecondsSinceEpoch}',
          text: ground,
          kind: SpeechKind.danger,
        ));
      } else {
        final String? paving = hazardPavingSpeech(a);
        if (paving != null) {
          _say(_request(
            id: 'hazard-paving-${DateTime.now().millisecondsSinceEpoch}',
            eventId: 'hazard-paving-${DateTime.now().millisecondsSinceEpoch}',
            text: paving,
            kind: SpeechKind.info,
          ));
        }
      }
    } catch (_) {
      // A scan failure is announced via the downgrade
      // sentence (rate-limited by the gate): an automatic
      // scan must never fail silently. Local detection is
      // the primary channel and keeps running either way.
      // The log uses a fixed category text only: the caught
      // object itself is never written anywhere.
      if (mounted) {
        _logMsg('云端识图：本轮自动扫描出现异常，已降级为本地检测。');
      }
      _announceVisionDowngrade();
    } finally {
      final bool joined = _visionCycle.complete();
      if (joined && mounted) {
        // A joined manual request is always answered: with
        // the result description when the cycle produced a
        // usable assessment, and with the fixed downgrade
        // sentence when it did not (a failure, a capture
        // problem, or an unknown-format answer) -- it never
        // goes unanswered. This answer is spoken directly,
        // not through the rate-limit gate: the user asked
        // once, explicitly.
        final HazardAssessment? joinedAssessment = assessment;
        _say(_request(
          id: 'hazard-join-${DateTime.now().millisecondsSinceEpoch}',
          eventId: 'hazard-join-${DateTime.now().millisecondsSinceEpoch}',
          text: joinedAssessment != null && joinedAssessment.parsed
              ? hazardDescriptionSpeech(joinedAssessment)
              : cloudVisionDowngradeSpeech,
          kind: SpeechKind.alert,
        ));
      }
    }
  }

  Future<void> _runCloudVisionAssist() async {
    // Duplicate trigger: refuse WITHOUT creating a token. The
    // run in flight keeps its token, so background/dispose can
    // still cancel it (the old code overwrote the shared token
    // field on every call and orphaned the running run).
    final CloudVisionCancellation? token = _visionRuns.begin();
    if (token == null) {
      if (_manualCycleOwned) {
        // Defensive: never leak a coordinator cycle.
        _manualCycleOwned = false;
        _visionCycle.complete();
      }
      _say(_request(
        id: 'cloud-vision-busy-${DateTime.now().millisecondsSinceEpoch}',
        eventId: 'cloud-vision-busy-${DateTime.now().millisecondsSinceEpoch}',
        text: CloudVisionResult.failed(CloudVisionFailure.busy).speechText,
        kind: SpeechKind.alert,
      ));
      return;
    }
    _cameraOwnership.registerCancellation(token);
    _lastVisionCallAt = DateTime.now();
    CloudVisionFailure? runFailure;
    bool runCompleted = false;
    int seq = 0;
    try {
      final CloudVisionFlowOutcome outcome = await _cloudVisionFlow.run(
        cancellation: token,
        announce: (String text) {
          if (!mounted) return;
          seq += 1;
          setState(() {
            _cloudVisionText = '云端视觉辅助：$text';
          });
          _say(_request(
            id: 'cloud-vision-${DateTime.now().millisecondsSinceEpoch}-$seq',
            eventId:
                'cloud-vision-${DateTime.now().millisecondsSinceEpoch}-$seq',
            text: text,
            // Critical delivery: recognition results, failures
            // and camera-permission denials are high-priority
            // (alert) and never expire -- they must not be
            // dropped or interrupted by ordinary prompts.
            kind: SpeechKind.alert,
          ));
        },
      );
      if (!mounted) return;
      if (outcome.cancelled) {
        _logMsg('云端视觉辅助：应用进入后台/销毁，识别已取消，结果已丢弃。');
        return;
      }
      final CloudVisionResult result = outcome.visionResult;
      runFailure = result.failure;
      runCompleted = true;
      _health.report(
        'cloud_vision',
        result.ok ? ServiceHealthStatus.ok : ServiceHealthStatus.degraded,
        outcome.announcements.isEmpty
            ? result.speechText
            : outcome.announcements.last,
      );
      _logMsg('云端视觉辅助：ok=${result.ok}，failure=${result.failure}。');
    } finally {
      if (runFailure == CloudVisionFailure.rateLimited) {
        // The flow already announced this 429; record the
        // strike so scans back off and nothing re-announces.
        _visionBackoff.onRateLimited(DateTime.now());
      } else if (runCompleted && runFailure == null) {
        _visionBackoff.onSuccess();
      }
      if (_manualCycleOwned) {
        _manualCycleOwned = false;
        _visionCycle.complete();
      }
      _cameraOwnership.unregisterCancellation(token);
      _visionRuns.end(token);
    }
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
        _endLiveNavigation();
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
          final bool wasLiveNav = _liveNav != null;
          if (wasLiveNav) _endLiveNavigation();
          unawaited(_stopSpeechThenConfirm(
            idPrefix: 'voice-pause',
            confirmText: wasLiveNav
                ? '已停下，实时导航已结束。'
                : '已暂停导航，直行提醒已停止。说继续可以恢复，但要重新确认直行路段。',
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
          _endLiveNavigation();
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
        final String routePart =
            _routeText == '尚未规划路线。' ? '' : '路线：$_routeText';
        _say(_request(
          id: 'voice-status-${DateTime.now().millisecondsSinceEpoch}',
          eventId: 'voice-status-${DateTime.now().millisecondsSinceEpoch}',
          text:
              '当前状态：${_stateText(_tasks.state)}。当前提示：$_currentPrompt。$routePart',
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
            eventId:
                'voice-confirm-no-${DateTime.now().millisecondsSinceEpoch}',
            text: '当前没有室内步骤可以确认，也没有未播报的高德路段。',
            kind: SpeechKind.info,
          ));
        }
        return;
      case VoiceCommand.cloudVision:
        // Explicit trigger only: one frame, one low-frequency
        // cloud description, all stages spoken (see
        // _runCloudVisionAssist). Never runs in the background.
        _triggerManualVision();
        return;
      case VoiceCommand.environment:
        _say(_request(
          id: 'voice-env-${DateTime.now().millisecondsSinceEpoch}',
          eventId: 'voice-env-${DateTime.now().millisecondsSinceEpoch}',
          text: _riskActive ? '前方情况：$_obstacleText' : '前方情况：$_perceptionText',
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
      _closeYoloLiveView();
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
      _closeYoloLiveView();
      _yoloLatencyMs = null;
      _yoloRiskActive = false;
      _yoloEmptyFrames = 0;
      _trafficText = '路口信息未提示（只提示，不放行）。';
    });
    _logMsg('演示已重置（重新开始演示，非任务状态迁移）。');
  }

  /// The one big status line for the companion / TalkBack:
  /// live navigation wins, then the open destination
  /// question, then task state, then camera state.
  String _bigStatusText() {
    if (_entranceActive && _entrance != null) {
      final double? d = _entrance!.lastDistanceM;
      return '入口指引中：$_liveNavDestName${d == null ? '' : ' 约${d.round()} 米'}';
    }
    if (_liveNav != null) {
      final double? r = _liveNavRemainingM;
      return '导航中：$_liveNavDestName${r == null ? '' : ' ${r.round()} 米'}';
    }
    if (_awaitingDestination) return '请告诉我要去哪里';
    if (_tasks.state == TaskState.navigating) return '导航中';
    if (_yoloLiveOpen) return '摄像头已开启';
    return '明途';
  }

  @override
  Widget build(BuildContext context) {
    // MT-1111-PTT-C minimal interface: the opened app shows
    // ONLY two things -- the camera preview area (upper
    // half) and the big hold-to-talk area (lower half). No
    // visible text, no other controls: the demo panel, the
    // status line and even the button's own caption are
    // gone. All state (_voiceText, _currentPrompt, the big
    // status value) stays in the logic layer and is spoken
    // in Chinese through the existing speech path; nothing
    // is rendered. The button keeps its TalkBack Semantics
    // label and long-press action, and the physical
    // press-and-hold gestures are unchanged.
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // Camera preview area (upper half). While the
          // live view is open it hosts YoloLiveView;
          // otherwise the area is simply blank.
          Expanded(
            child: _yoloLiveOpen
                ? YoloLiveView(
                    modelPath: AppConfig.yoloModelPath,
                    onDetections: _onYoloDetections,
                    onLatencyMs: (double ms) {
                      setState(() {
                        _yoloLatencyMs = ms;
                      });
                    },
                    onError: (Object error) {
                      // Classified, never raw: a CAMERA
                      // PERMISSION denial and a MODEL LOAD
                      // failure get DIFFERENT announcements --
                      // the remedies differ (open system
                      // settings vs fix the bundled model). One
                      // shared sentence for both was a Codex
                      // re-test finding.
                      final YoloViewErrorKind errorKind =
                          classifyYoloViewError(error);
                      mingtuVoiceLog('YOLO 实时视图出错类别：${errorKind.name}');
                      _logMsg('YOLO 实时视图出错：${yoloViewErrorStatus(errorKind)}。');
                      setState(() {
                        _yoloText = yoloViewErrorStatus(errorKind);
                      });
                      if (!_yoloErrorAnnounced) {
                        _yoloErrorAnnounced = true;
                        _health.report(
                          'yolo',
                          ServiceHealthStatus.unavailable,
                          yoloViewErrorStatus(errorKind),
                        );
                        _say(_request(
                          id: 'yolo-view-error',
                          eventId: 'yolo-view-error',
                          text: yoloViewErrorSpeech(errorKind),
                          kind: SpeechKind.alert,
                        ));
                      }
                    },
                  )
                : Container(
                    key: const ValueKey<String>('camera-preview-area'),
                    color: Colors.black12,
                  ),
          ),
          // The one very large push-to-talk area (lower
          // half): a plain colour block with no caption.
          // Hold: vibrate, stop any non-P0 speech, speak
          // the cue and await it, then listen while held.
          // Release: stop listening and submit the result.
          // The area is never disabled: with no recogniser
          // the press still produces the vibrated, spoken
          // failure feedback instead of dead silence. The
          // semantics node carries a long-press action so
          // TalkBack users can trigger the same
          // press-and-hold flow.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              child: Semantics(
                button: true,
                container: true,
                label: '按住说话按钮，按住后说话，松开结束',
                onLongPress: _talkBackLongPress,
                child: GestureDetector(
                  onLongPressStart: (_) => _pushToTalkStart(),
                  onLongPressEnd: (_) => _pushToTalkEnd(),
                  child: Container(
                    key: const ValueKey<String>('push-to-talk-area'),
                    decoration: BoxDecoration(
                      color:
                          Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

